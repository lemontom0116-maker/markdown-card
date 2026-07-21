import AppKit
import MarkdownCardCore
import WebKit

private struct LocalAttachmentPasteRequest: Sendable {
    let requestID: String
    let cardID: UUID
    let mimeType: String
    let data: Data
    let alt: String
}

struct RendererTagCommandSubmission: Equatable, Sendable {
    let cardID: UUID
    let tagName: String
    let markdown: String
    let revision: UInt64

    init?(payload: [String: Any]) {
        guard let rawCardID = payload["cardID"] as? String,
              let cardID = UUID(uuidString: rawCardID),
              let rawTagName = payload["tagName"] as? String,
              rawTagName.utf8.count <= CardTag.maximumUTF8ByteCount,
              let tag = try? CardTag(rawTagName),
              let markdown = payload["markdown"] as? String,
              markdown.lengthOfBytes(using: .utf8) <= IPCFrameCodec.maximumPayloadSize,
              let rawRevision = payload["revision"] as? NSNumber,
              CFGetTypeID(rawRevision) != CFBooleanGetTypeID()
        else { return nil }
        let revisionValue = rawRevision.doubleValue
        guard revisionValue.isFinite,
              revisionValue >= 0,
              revisionValue <= 9_007_199_254_740_991,
              revisionValue.rounded(.towardZero) == revisionValue
        else { return nil }

        self.cardID = cardID
        tagName = tag.name
        self.markdown = markdown
        revision = UInt64(revisionValue)
    }
}

enum RendererMarkdownSnapshotError: LocalizedError, Equatable, Sendable {
    case documentTooLarge
    case unavailable

    var errorDescription: String? {
        switch self {
        case .documentTooLarge:
            "The current editor content is larger than 4 MiB. Shorten it before saving."
        case .unavailable:
            "Markdown Card could not read the latest editor content. The linked file was not changed."
        }
    }
}

enum RendererMarkdownSnapshot: Equatable, Sendable {
    case markdown(String)
    case notLoaded
    case failure(RendererMarkdownSnapshotError)
}

struct RendererAttemptGate: Equatable, Sendable {
    private(set) var generation: UInt64 = 0

    mutating func begin() -> UInt64 {
        generation &+= 1
        return generation
    }

    func accepts(_ attempt: UInt64) -> Bool {
        attempt == generation
    }

    mutating func invalidate() {
        generation &+= 1
    }
}

private enum MarkdownPreviewPresentation {
    case web
    case loading
    case recovery
    case nativeSource
}

@MainActor
final class MarkdownPreviewView: NSView, AppearanceConsumer {
    var onMarkdownChange: ((UUID, String, UInt64) -> Void)?
    var onTagCommandSubmitted: ((UUID, String, String, UInt64) -> Void)?
    var onRequestHide: (() -> Void)?
    var onContentHeightChange: ((UUID, CGFloat) -> Void)?
    var onManagedAttachmentsChange: ((UUID, [String]) -> Void)?
    var onRequestSaveAs: (() -> Void)?

    private let webView: WKWebView
    private let messageLabel = NSTextField(labelWithString: "")
    private let recoveryView: MarkdownPreviewRecoveryView
    private let nativeSourceView: MarkdownNativeSourceRecoveryView
    private let linkNoticeView: MarkdownLinkNoticeView
    private let navigationDelegate: PreviewNavigationDelegate
    private let thumbnailSchemeHandler: YouTubeThumbnailSchemeHandler
    private let attachmentStore: LocalAttachmentStore
    private let documentLinkCoordinator = DocumentLinkCoordinator()
    private let slashCommandMenuController = SlashCommandMenuController()
    private var resolvedAppearance: ResolvedAppearance
    private var loaded = false
    private var hasStartedLoading = false
    private var pendingPayload: RenderPayload?
    private var pendingFocus = false
    private var documentRootsByCardID: [UUID: URL] = [:]
    private var presentation: MarkdownPreviewPresentation = .web
    private var renderAttemptGate = RendererAttemptGate()
    private var activeNavigation: WKNavigation?
    private var activeNavigationAttempt: UInt64?
    private var renderTimeoutTask: Task<Void, Never>?
    private var linkNoticeTask: Task<Void, Never>?
    private(set) var isEditorComposing = false

    private static let renderTimeoutNanoseconds: UInt64 = 4_000_000_000

    init(
        initialAppearance: ResolvedAppearance,
        attachmentStore: LocalAttachmentStore = LocalAttachmentStore()
    ) {
        let navigationDelegate = PreviewNavigationDelegate()
        let thumbnailSchemeHandler = YouTubeThumbnailSchemeHandler(
            attachmentStore: attachmentStore
        )
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(navigationDelegate, name: "markdownCard")
        configuration.userContentController.addUserScript(
            Self.bootstrapUserScript(for: initialAppearance)
        )
        configuration.setURLSchemeHandler(
            thumbnailSchemeHandler,
            forURLScheme: YouTubeThumbnailSchemeHandler.scheme
        )
        self.navigationDelegate = navigationDelegate
        self.thumbnailSchemeHandler = thumbnailSchemeHandler
        self.attachmentStore = attachmentStore
        resolvedAppearance = initialAppearance
        recoveryView = MarkdownPreviewRecoveryView(resolvedAppearance: initialAppearance)
        nativeSourceView = MarkdownNativeSourceRecoveryView(
            resolvedAppearance: initialAppearance
        )
        linkNoticeView = MarkdownLinkNoticeView(resolvedAppearance: initialAppearance)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = MonochromePalette.windowBackground(for: resolvedAppearance).cgColor

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = navigationDelegate
        webView.underPageBackgroundColor = MonochromePalette.windowBackground(
            for: resolvedAppearance
        )
        webView.allowsMagnification = false

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: 13, weight: .regular)
        messageLabel.maximumNumberOfLines = 3
        messageLabel.textColor = MonochromePalette.secondaryText(for: resolvedAppearance)
        messageLabel.isHidden = true

        recoveryView.isHidden = true
        nativeSourceView.isHidden = true
        linkNoticeView.isHidden = true

        // Recovery surfaces are overlays, not document content. Keeping them in
        // the parent Auto Layout graph lets their intrinsic button/label sizes
        // raise the card window's fitting size even while they are hidden (the
        // native Source header is wider than a 360 pt Sticky card). Frame-based
        // overlays preserve the card layout contract; each surface still uses
        // Auto Layout internally once it has a concrete frame.
        for overlay in [recoveryView, nativeSourceView, linkNoticeView] {
            overlay.translatesAutoresizingMaskIntoConstraints = true
            // `layout()` owns these frames. A flexible autoresizing mask would
            // let AppKit replace the concrete width/height with the overlay's
            // intrinsic fitting size while solving the window content tree.
            overlay.autoresizingMask = []
        }
        recoveryView.frame = bounds
        nativeSourceView.frame = bounds

        addSubview(webView)
        addSubview(messageLabel)
        addSubview(recoveryView)
        addSubview(nativeSourceView)
        addSubview(linkNoticeView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        recoveryView.onRetry = { [weak self] in self?.retryRenderer() }
        recoveryView.onOpenSource = { [weak self] in self?.openNativeSourceRecovery() }
        recoveryView.onCopyMarkdown = { [weak self] in self?.copyRecoveryMarkdown() }
        nativeSourceView.onRetry = { [weak self] in self?.retryRenderer() }
        nativeSourceView.onCopyMarkdown = { [weak self] in self?.copyRecoveryMarkdown() }
        nativeSourceView.onMarkdownChange = { [weak self] markdown in
            self?.acceptNativeSourceChange(markdown)
        }
        linkNoticeView.onSaveAs = { [weak self] in self?.requestSaveAsFromNotice() }
        linkNoticeView.onDismiss = { [weak self] in self?.hideDocumentLinkNotice() }

        navigationDelegate.didFinish = { [weak self] navigation in
            guard let self else { return }
            guard let activeNavigation,
                  navigation === activeNavigation,
                  let activeNavigationAttempt,
                  renderAttemptGate.accepts(activeNavigationAttempt),
                  presentation == .loading
            else { return }
            self.activeNavigation = nil
            self.activeNavigationAttempt = nil
            renderTimeoutTask?.cancel()
            renderTimeoutTask = nil
            loaded = true
            showWebPresentation()
            flushPayload()
            if pendingFocus {
                focusEditor()
            }
        }
        navigationDelegate.didFail = { [weak self] navigation, error in
            guard let self,
                  let activeNavigation,
                  navigation === activeNavigation,
                  let activeNavigationAttempt,
                  renderAttemptGate.accepts(activeNavigationAttempt)
            else { return }
            showRecovery(.navigationFailed, diagnostic: error.localizedDescription)
        }
        navigationDelegate.didChangeMarkdown = { [weak self] cardID, markdown, revision in
            self?.acceptRendererMarkdown(cardID: cardID, markdown: markdown, revision: revision)
        }
        navigationDelegate.didSubmitTagCommand = { [weak self] submission in
            self?.onTagCommandSubmitted?(
                submission.cardID,
                submission.tagName,
                submission.markdown,
                submission.revision
            )
        }
        navigationDelegate.didRequestHide = { [weak self] in
            self?.onRequestHide?()
        }
        navigationDelegate.didChangeContentHeight = { [weak self] cardID, height in
            self?.onContentHeightChange?(cardID, height)
        }
        navigationDelegate.didChangeManagedAttachments = { [weak self] cardID, identifiers in
            self?.onManagedAttachmentsChange?(cardID, identifiers)
        }
        navigationDelegate.didChangeEditorComposition = { [weak self] isComposing in
            self?.updateEditorCompositionState(isComposing)
        }
        navigationDelegate.didRequestLocalAttachment = { [weak self] request in
            self?.saveLocalAttachment(request)
        }
        navigationDelegate.didChangeSlashCommandMenu = { [weak self] state in
            guard let self else { return }
            slashCommandMenuController.update(state: state, relativeTo: webView)
        }
        navigationDelegate.didRequestDocumentLink = { [weak self] cardID, href in
            self?.openDocumentLink(cardID: cardID, href: href)
        }
        navigationDelegate.didTerminateWebContent = { [weak self] in
            self?.showRecovery(.webContentTerminated)
        }
        slashCommandMenuController.onChoose = { [weak self] identifier in
            self?.chooseSlashCommand(identifier)
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            slashCommandMenuController.detach()
            updateEditorCompositionState(false)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !hasStartedLoading else { return }
        hasStartedLoading = true
        loadRenderer()
    }

    override func layout() {
        super.layout()
        recoveryView.frame = bounds
        nativeSourceView.frame = bounds
        layoutDocumentLinkNotice()
        slashCommandMenuController.updateLayout()
    }

    func loadRenderer() {
        updateEditorCompositionState(false)
        invalidateRenderAttempt()
        loaded = false
        presentation = .loading
        webView.stopLoading()
        webView.isHidden = true
        recoveryView.isHidden = true
        nativeSourceView.isHidden = true
        hideDocumentLinkNotice()
        messageLabel.stringValue = "Loading preview…"
        messageLabel.isHidden = false
        guard let indexURL = RendererLocator.indexURL() else {
            showRecovery(
                .rendererUnavailable,
                diagnostic: "Renderer not found. Build the renderer or set MARKDOWN_CARD_RENDERER_DIR."
            )
            return
        }
        guard let navigation = webView.loadFileURL(
            indexURL,
            allowingReadAccessTo: indexURL.deletingLastPathComponent()
        ) else {
            showRecovery(.navigationFailed, diagnostic: "WebKit did not start the renderer load.")
            return
        }
        activeNavigation = navigation
        let attempt = renderAttemptGate.begin()
        activeNavigationAttempt = attempt
        startRenderWatchdog(attempt: attempt)
    }

    func render(_ payload: RenderPayload) {
        slashCommandMenuController.hide()
        pendingPayload = payload
        if presentation == .nativeSource {
            nativeSourceView.setMarkdown(payload.markdown)
            return
        }
        guard presentation != .recovery else { return }
        flushPayload()
    }

    /// Grants one card access to raster images below its linked Markdown
    /// document directory. The WebView never receives the filesystem path;
    /// it only learns whether the native, root-confined scheme is available.
    func setDocumentRoot(_ root: URL?, for cardID: UUID) {
        thumbnailSchemeHandler.setDocumentRoot(root, for: cardID)
        if let root {
            documentRootsByCardID[cardID] = root.standardizedFileURL
        } else {
            documentRootsByCardID.removeValue(forKey: cardID)
        }
        guard loaded else { return }
        let identifier = Self.javascriptString(cardID.uuidString)
        let available = root == nil ? "false" : "true"
        webView.evaluateJavaScript(
            "window.MarkdownCard?.setDocumentImagesAvailable?.(\(identifier), \(available));",
            completionHandler: nil
        )
    }

    func dismissTransientUI() {
        slashCommandMenuController.hide()
        hideDocumentLinkNotice()
        guard loaded else { return }
        webView.evaluateJavaScript(
            "window.MarkdownCard?.dismissSlashCommandMenu?.();",
            completionHandler: nil
        )
    }

    func focusEditor() {
        pendingFocus = true
        if presentation == .nativeSource {
            pendingFocus = false
            nativeSourceView.focusEditor()
            NotificationCenter.default.post(
                name: .markdownCardEditorFocusMayHaveChanged,
                object: window
            )
            return
        }
        guard loaded else { return }
        pendingFocus = false
        webView.window?.makeFirstResponder(webView)
        NotificationCenter.default.post(
            name: .markdownCardEditorFocusMayHaveChanged,
            object: webView.window
        )
        webView.evaluateJavaScript(
            "window.MarkdownCard?.focusEditor?.();",
            completionHandler: nil
        )
    }

    func ownsFirstResponder(in window: NSWindow?) -> Bool {
        guard let responderView = window?.firstResponder as? NSView else { return false }
        return responderView === webView
            || responderView.isDescendant(of: webView)
            || responderView === nativeSourceView.textView
            || responderView.isDescendant(of: nativeSourceView)
    }

    /// Mirrors the renderer's capture-phase composition guard for native
    /// shortcut routing. This state belongs to the shared preview component,
    /// so card panels and the Library editor observe the same contract.
    func updateEditorCompositionState(_ isComposing: Bool) {
        self.isEditorComposing = isComposing
    }

    func currentMarkdownSnapshot(completion: @escaping (RendererMarkdownSnapshot) -> Void) {
        if presentation == .nativeSource {
            completion(Self.validatedMarkdownSnapshot(
                value: nativeSourceView.markdown,
                error: nil
            ))
            return
        }
        if presentation == .recovery, let pendingPayload {
            completion(Self.validatedMarkdownSnapshot(value: pendingPayload.markdown, error: nil))
            return
        }
        guard loaded else {
            completion(.notLoaded)
            return
        }
        webView.evaluateJavaScript(
            "window.MarkdownCard?.getState?.().markdown ?? null;"
        ) { value, error in
            completion(Self.validatedMarkdownSnapshot(value: value, error: error))
        }
    }

    func currentMarkdownSnapshot() async -> RendererMarkdownSnapshot {
        await withCheckedContinuation { continuation in
            currentMarkdownSnapshot { snapshot in
                continuation.resume(returning: snapshot)
            }
        }
    }

    func currentMarkdown(completion: @escaping (String?) -> Void) {
        currentMarkdownSnapshot { snapshot in
            guard case let .markdown(markdown) = snapshot else {
                completion(nil)
                return
            }
            completion(markdown)
        }
    }

    func currentMarkdown() async -> String? {
        guard case let .markdown(markdown) = await currentMarkdownSnapshot() else {
            return nil
        }
        return markdown
    }

    static func validatedMarkdownSnapshot(
        value: Any?,
        error: Error?
    ) -> RendererMarkdownSnapshot {
        guard error == nil, let markdown = value as? String else {
            return .failure(.unavailable)
        }
        guard markdown.lengthOfBytes(using: .utf8) <= IPCFrameCodec.maximumPayloadSize else {
            return .failure(.documentTooLarge)
        }
        return .markdown(markdown)
    }

    func currentMarkdownForCopy(completion: @escaping (String?) -> Void) {
        if presentation == .nativeSource {
            completion(nativeSourceView.markdown)
            return
        }
        if presentation == .recovery {
            completion(pendingPayload?.markdown)
            return
        }
        guard loaded,
              let encodedBaseURL = try? JSONEncoder().encode(
                  attachmentStore.standardizedDirectoryFileURL.absoluteString
              ),
              let baseURLLiteral = String(data: encodedBaseURL, encoding: .utf8)
        else {
            completion(nil)
            return
        }
        webView.evaluateJavaScript(
            "window.MarkdownCard?.getMarkdownForCopy?.(\(baseURLLiteral)) ?? null;"
        ) { value, error in
            guard error == nil,
                  let markdown = value as? String,
                  markdown.lengthOfBytes(using: .utf8) <= IPCFrameCodec.maximumPayloadSize
            else {
                completion(nil)
                return
            }
            completion(markdown)
        }
    }

    func currentMarkdownExportBundle(
        completion: @escaping (MarkdownExportBundle?) -> Void
    ) {
        guard loaded else {
            completion(nil)
            return
        }
        webView.evaluateJavaScript(
            "window.MarkdownCard?.getMarkdownExportBundle?.() ?? null;"
        ) { value, error in
            guard error == nil,
                  let payload = value as? [String: Any],
                  let markdown = payload["markdown"] as? String,
                  markdown.lengthOfBytes(using: .utf8) <= IPCFrameCodec.maximumPayloadSize,
                  let rawIdentifiers = payload["attachmentIDs"] as? [String],
                  rawIdentifiers.count <= 4_096
            else {
                completion(nil)
                return
            }
            var seen = Set<String>()
            let identifiers = rawIdentifiers.compactMap { rawIdentifier -> String? in
                let identifier = rawIdentifier.lowercased()
                guard LocalAttachmentStore.isValidAttachmentID(identifier),
                      seen.insert(identifier).inserted
                else { return nil }
                return identifier
            }
            guard identifiers.count == rawIdentifiers.count else {
                completion(nil)
                return
            }
            completion(MarkdownExportBundle(markdown: markdown, attachmentIDs: identifiers))
        }
    }

    func currentMarkdownExportBundle() async -> MarkdownExportBundle? {
        await withCheckedContinuation { continuation in
            currentMarkdownExportBundle { bundle in
                continuation.resume(returning: bundle)
            }
        }
    }

    private func saveLocalAttachment(_ request: LocalAttachmentPasteRequest) {
        let attachmentStore = attachmentStore
        Task { [weak self] in
            do {
                let source = try await Task.detached(priority: .userInitiated) {
                    try attachmentStore.saveClipboardImage(
                        data: request.data,
                        mimeType: request.mimeType
                    )
                }.value
                self?.completeLocalAttachmentPaste(request, source: source, error: nil)
            } catch {
                NSSound.beep()
                self?.completeLocalAttachmentPaste(
                    request,
                    source: nil,
                    error: error.localizedDescription
                )
            }
        }
    }

    private func completeLocalAttachmentPaste(
        _ request: LocalAttachmentPasteRequest,
        source: String?,
        error: String?
    ) {
        guard loaded else { return }
        var payload: [String: Any] = [
            "requestID": request.requestID,
            "cardID": request.cardID.uuidString,
            "alt": request.alt,
        ]
        if let source { payload["source"] = source }
        if let error { payload["error"] = error }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript(
            "window.MarkdownCard?.completeImagePaste?.(\(json));",
            completionHandler: nil
        )
    }

    func requestContentHeight() {
        guard loaded else { return }
        webView.evaluateJavaScript(
            "window.MarkdownCard?.measureContentHeight?.();",
            completionHandler: nil
        )
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        self.resolvedAppearance = resolvedAppearance
        let background = MonochromePalette.windowBackground(for: resolvedAppearance)
        layer?.backgroundColor = background.cgColor
        webView.underPageBackgroundColor = background
        messageLabel.textColor = MonochromePalette.secondaryText(for: resolvedAppearance)
        recoveryView.apply(resolvedAppearance: resolvedAppearance)
        nativeSourceView.apply(resolvedAppearance: resolvedAppearance)
        linkNoticeView.apply(resolvedAppearance: resolvedAppearance)
        slashCommandMenuController.apply(resolvedAppearance: resolvedAppearance)

        if var payload = pendingPayload {
            payload.resolvedAppearance = resolvedAppearance
            pendingPayload = payload
        }

        // Keep future navigations on the selected appearance from the first
        // document-start instruction, before the renderer's CSS or module runs.
        // Replacing user scripts does not navigate or mutate the live document.
        let contentController = webView.configuration.userContentController
        contentController.removeAllUserScripts()
        contentController.addUserScript(Self.bootstrapUserScript(for: resolvedAppearance))

        guard loaded else { return }

        let appearance = resolvedAppearance.rawValue
        let script = """
        (() => {
          const appearance = \(Self.javascriptString(appearance));
          document.documentElement.dataset.theme = appearance;
          document.documentElement.style.colorScheme = appearance;
          if (window.MarkdownCard && typeof window.MarkdownCard.setAppearance === 'function') {
            window.MarkdownCard.setAppearance(appearance);
          }
          window.dispatchEvent(new CustomEvent('markdown-card:appearance', {
            detail: { appearance }
          }));
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func flushPayload() {
        guard loaded, let payload = pendingPayload else { return }
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8)
        else {
            showRecovery(.renderFailed, diagnostic: "Unable to encode this card for preview.")
            return
        }

        let attempt = renderAttemptGate.begin()
        startRenderWatchdog(attempt: attempt)

        let script = """
        (() => {
          const payload = \(json);
          document.documentElement.dataset.theme = payload.resolvedAppearance;
          document.documentElement.style.colorScheme = payload.resolvedAppearance;
          if (window.MarkdownCard && typeof window.MarkdownCard.render === 'function') {
            window.MarkdownCard.render(payload);
          } else if (typeof window.renderMarkdownCard === 'function') {
            window.renderMarkdownCard(payload);
          }
          window.dispatchEvent(new CustomEvent('markdown-card:render', { detail: payload }));
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let self, renderAttemptGate.accepts(attempt) else { return }
            renderTimeoutTask?.cancel()
            renderTimeoutTask = nil
            if let error {
                showRecovery(.renderFailed, diagnostic: error.localizedDescription)
                return
            }
            showWebPresentation()
        }
    }

    private func showRecovery(
        _ reason: MarkdownRendererRecoveryReason,
        diagnostic: String? = nil
    ) {
        updateEditorCompositionState(false)
        invalidateRenderAttempt()
        webView.stopLoading()
        loaded = false
        presentation = .recovery
        slashCommandMenuController.hide()
        hideDocumentLinkNotice()
        webView.isHidden = true
        nativeSourceView.isHidden = true
        messageLabel.isHidden = true
        recoveryView.update(reason: reason, diagnostic: diagnostic)
        recoveryView.isHidden = false
        NSAccessibility.post(
            element: recoveryView,
            notification: .announcementRequested,
            userInfo: [.announcement: "\(reason.title). \(reason.guidance)"]
        )
    }

    private func showWebPresentation() {
        presentation = .web
        recoveryView.isHidden = true
        nativeSourceView.isHidden = true
        messageLabel.isHidden = true
        webView.isHidden = false
    }

    private func retryRenderer() {
        loadRenderer()
    }

    private func openNativeSourceRecovery() {
        invalidateRenderAttempt()
        loaded = false
        presentation = .nativeSource
        slashCommandMenuController.hide()
        hideDocumentLinkNotice()
        webView.isHidden = true
        recoveryView.isHidden = true
        messageLabel.isHidden = true
        nativeSourceView.setMarkdown(pendingPayload?.markdown ?? "")
        nativeSourceView.isHidden = false
        nativeSourceView.focusEditor()
        NSAccessibility.post(
            element: nativeSourceView.textView,
            notification: .announcementRequested,
            userInfo: [.announcement: "Markdown Source editor opened"]
        )
    }

    private func acceptNativeSourceChange(_ markdown: String) {
        guard presentation == .nativeSource, var payload = pendingPayload else { return }
        guard markdown.lengthOfBytes(using: .utf8) <= IPCFrameCodec.maximumPayloadSize else {
            NSSound.beep()
            return
        }
        guard markdown != payload.markdown else { return }
        payload.markdown = markdown
        payload.revision &+= 1
        pendingPayload = payload
        onMarkdownChange?(payload.cardID, markdown, payload.revision)
    }

    private func acceptRendererMarkdown(cardID: UUID, markdown: String, revision: UInt64) {
        if var payload = pendingPayload,
           payload.cardID == cardID,
           revision >= payload.revision {
            payload.markdown = markdown
            payload.revision = revision
            pendingPayload = payload
        }
        onMarkdownChange?(cardID, markdown, revision)
    }

    private func copyRecoveryMarkdown() {
        let markdown = presentation == .nativeSource
            ? nativeSourceView.markdown
            : pendingPayload?.markdown
        guard let markdown else {
            recoveryView.showCopyResult(success: false)
            NSSound.beep()
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let success = pasteboard.setString(markdown, forType: .string)
        if !success { NSSound.beep() }
        if presentation == .nativeSource {
            nativeSourceView.showCopyResult(success: success)
        } else {
            recoveryView.showCopyResult(success: success)
        }
    }

    private func invalidateRenderAttempt() {
        renderAttemptGate.invalidate()
        activeNavigation = nil
        activeNavigationAttempt = nil
        renderTimeoutTask?.cancel()
        renderTimeoutTask = nil
    }

    private func startRenderWatchdog(attempt: UInt64) {
        renderTimeoutTask?.cancel()
        renderTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.renderTimeoutNanoseconds)
            } catch {
                return
            }
            guard let self, renderAttemptGate.accepts(attempt) else { return }
            showRecovery(.renderTimedOut)
        }
    }

    private static func javascriptString(_ string: String) -> String {
        guard let data = try? JSONEncoder().encode(string),
              let json = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return json
    }

    private func chooseSlashCommand(_ identifier: String) {
        guard loaded else { return }
        slashCommandMenuController.hide()
        let identifierLiteral = Self.javascriptString(identifier)
        webView.evaluateJavaScript(
            "window.MarkdownCard?.chooseSlashCommand?.(\(identifierLiteral));",
            completionHandler: nil
        )
    }

    private func openDocumentLink(cardID: UUID, href: String) {
        guard let root = documentRootsByCardID[cardID] else {
            showDocumentLinkNotice(
                "Relative links need a linked Markdown file. Choose Save As… to set its folder."
            )
            return
        }
        do {
            try documentLinkCoordinator.open(href, documentRoot: root)
        } catch {
            showDocumentLinkNotice(
                "\(error.localizedDescription) Choose Save As… to link a different document folder."
            )
        }
    }

    private func showDocumentLinkNotice(_ message: String) {
        guard presentation == .web else { return }
        linkNoticeTask?.cancel()
        linkNoticeView.show(message: message)
        layoutDocumentLinkNotice()
        linkNoticeView.isHidden = false
        NSAccessibility.post(
            element: linkNoticeView,
            notification: .announcementRequested,
            userInfo: [.announcement: message]
        )
        linkNoticeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 12_000_000_000)
            } catch {
                return
            }
            self?.hideDocumentLinkNotice()
        }
    }

    private func hideDocumentLinkNotice() {
        linkNoticeTask?.cancel()
        linkNoticeTask = nil
        linkNoticeView.isHidden = true
    }

    private func layoutDocumentLinkNotice() {
        let noticeWidth = min(680, max(0, bounds.width - 24))
        guard noticeWidth > 0, bounds.height > 0 else {
            linkNoticeView.frame = .zero
            return
        }
        let noticeHeight = min(
            linkNoticeView.preferredHeight(for: noticeWidth),
            max(0, bounds.height - 20)
        )
        linkNoticeView.frame = NSRect(
            x: floor(bounds.midX - noticeWidth / 2),
            y: max(bounds.minY, bounds.maxY - 10 - noticeHeight),
            width: noticeWidth,
            height: noticeHeight
        )
    }

    private func requestSaveAsFromNotice() {
        hideDocumentLinkNotice()
        if let onRequestSaveAs {
            onRequestSaveAs()
            return
        }
        let selector = Selector(("saveMarkdownAsFromMenu:"))
        let sent = NSApp.sendAction(selector, to: nil, from: self)
        if !sent {
            showDocumentLinkNotice("Choose File > Save As… (⌥⌘S) to link this card.")
        }
    }

    private static func bootstrapUserScript(for appearance: ResolvedAppearance) -> WKUserScript {
        let value = javascriptString(appearance.rawValue)
        let source = """
        (() => {
          const appearance = \(value);
          window.__markdownCardNativeCapabilities = Object.freeze({
            slashCommandPanel: true
          });
          document.documentElement.dataset.theme = appearance;
          document.documentElement.style.colorScheme = appearance;
        })();
        """
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }
}

@MainActor
private final class PreviewNavigationDelegate: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var didFinish: ((WKNavigation?) -> Void)?
    var didFail: ((WKNavigation?, Error) -> Void)?
    var didChangeMarkdown: ((UUID, String, UInt64) -> Void)?
    var didSubmitTagCommand: ((RendererTagCommandSubmission) -> Void)?
    var didRequestHide: (() -> Void)?
    var didChangeContentHeight: ((UUID, CGFloat) -> Void)?
    var didChangeManagedAttachments: ((UUID, [String]) -> Void)?
    var didRequestLocalAttachment: ((LocalAttachmentPasteRequest) -> Void)?
    var didChangeSlashCommandMenu: ((SlashCommandMenuState) -> Void)?
    var didRequestDocumentLink: ((UUID, String) -> Void)?
    var didChangeEditorComposition: ((Bool) -> Void)?
    var didTerminateWebContent: (() -> Void)?

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        didChangeEditorComposition?(false)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish?(navigation)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        didFail?(navigation, error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        didFail?(navigation, error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        didChangeEditorComposition?(false)
        didTerminateWebContent?()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url
        else {
            decisionHandler(.allow)
            return
        }

        if let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           ["https", "http", "mailto"].contains(scheme)
        {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "markdownCard",
              let payload = message.body as? [String: Any],
              let type = payload["type"] as? String
        else { return }

        switch type {
        case "editorCompositionChanged":
            guard let rawValue = payload["isComposing"] as? NSNumber,
                  CFGetTypeID(rawValue) == CFBooleanGetTypeID()
            else { return }
            didChangeEditorComposition?(rawValue.boolValue)

        case "openExternalLink":
            guard let rawURL = payload["url"] as? String,
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  ["https", "http", "mailto"].contains(scheme)
            else { return }
            NSWorkspace.shared.open(url)

        case "openDocumentLink":
            guard let rawCardID = payload["cardID"] as? String,
                  let cardID = UUID(uuidString: rawCardID),
                  let href = payload["href"] as? String,
                  !href.isEmpty,
                  href.utf8.count <= 4_096
            else { return }
            didRequestDocumentLink?(cardID, href)

        case "markdownChanged":
            guard let rawCardID = payload["cardID"] as? String,
                  let cardID = UUID(uuidString: rawCardID),
                  let markdown = payload["markdown"] as? String,
                  markdown.lengthOfBytes(using: .utf8) <= IPCFrameCodec.maximumPayloadSize,
                  let rawRevision = payload["revision"] as? NSNumber
            else { return }
            didChangeMarkdown?(cardID, markdown, rawRevision.uint64Value)

        case "tagCommandSubmitted":
            guard let submission = RendererTagCommandSubmission(payload: payload) else { return }
            didSubmitTagCommand?(submission)

        case "hideRequested":
            didRequestHide?()

        case "contentHeightChanged":
            guard let rawCardID = payload["cardID"] as? String,
                  let cardID = UUID(uuidString: rawCardID),
                  let rawHeight = payload["height"] as? NSNumber
            else { return }
            let height = CGFloat(rawHeight.doubleValue)
            guard height.isFinite, height >= 0, height <= 100_000 else { return }
            didChangeContentHeight?(cardID, height)

        case "managedAttachmentsChanged":
            guard let rawCardID = payload["cardID"] as? String,
                  let cardID = UUID(uuidString: rawCardID),
                  let rawIdentifiers = payload["attachmentIDs"] as? [String],
                  rawIdentifiers.count <= 4_096
            else { return }
            var seen = Set<String>()
            let identifiers = rawIdentifiers.compactMap { rawIdentifier -> String? in
                let identifier = rawIdentifier.lowercased()
                guard LocalAttachmentStore.isValidAttachmentID(identifier),
                      seen.insert(identifier).inserted
                else { return nil }
                return identifier
            }
            guard identifiers.count == rawIdentifiers.count else { return }
            didChangeManagedAttachments?(cardID, identifiers)

        case "localImagePasteRequested":
            guard let requestID = payload["requestID"] as? String,
                  !requestID.isEmpty,
                  requestID.utf8.count <= 128,
                  let rawCardID = payload["cardID"] as? String,
                  let cardID = UUID(uuidString: rawCardID),
                  let mimeType = payload["mimeType"] as? String,
                  mimeType.utf8.count <= 64,
                  let base64 = payload["base64"] as? String,
                  base64.utf8.count <= ((LocalAttachmentStore.maximumInputSize + 2) / 3) * 4,
                  let data = Data(base64Encoded: base64),
                  data.count <= LocalAttachmentStore.maximumInputSize
            else { return }
            let rawAlt = (payload["alt"] as? String) ?? "Pasted image"
            let alt = String(rawAlt.prefix(200))
            didRequestLocalAttachment?(
                LocalAttachmentPasteRequest(
                    requestID: requestID,
                    cardID: cardID,
                    mimeType: mimeType,
                    data: data,
                    alt: alt.isEmpty ? "Pasted image" : alt
                )
            )

        case "slashCommandMenuChanged":
            guard let state = SlashCommandMenuState(payload: payload) else { return }
            if state.visible {
                guard let rawCardID = payload["cardID"] as? String,
                      UUID(uuidString: rawCardID) != nil
                else { return }
            }
            didChangeSlashCommandMenu?(state)

        default:
            return
        }
    }
}
