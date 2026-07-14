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

@MainActor
final class MarkdownPreviewView: NSView, AppearanceConsumer {
    var onMarkdownChange: ((UUID, String, UInt64) -> Void)?
    var onRequestHide: (() -> Void)?
    var onContentHeightChange: ((UUID, CGFloat) -> Void)?
    var onManagedAttachmentsChange: ((UUID, [String]) -> Void)?

    private let webView: WKWebView
    private let messageLabel = NSTextField(labelWithString: "")
    private let navigationDelegate: PreviewNavigationDelegate
    private let thumbnailSchemeHandler: YouTubeThumbnailSchemeHandler
    private let attachmentStore: LocalAttachmentStore
    private var resolvedAppearance: ResolvedAppearance
    private var loaded = false
    private var hasStartedLoading = false
    private var pendingPayload: RenderPayload?
    private var pendingFocus = false

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

        addSubview(webView)
        addSubview(messageLabel)
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

        navigationDelegate.didFinish = { [weak self] in
            guard let self else { return }
            loaded = true
            messageLabel.isHidden = true
            webView.isHidden = false
            flushPayload()
            if pendingFocus {
                focusEditor()
            }
        }
        navigationDelegate.didFail = { [weak self] error in
            self?.showFailure("Unable to load the Markdown renderer.\n\(error.localizedDescription)")
        }
        navigationDelegate.didChangeMarkdown = { [weak self] cardID, markdown, revision in
            self?.onMarkdownChange?(cardID, markdown, revision)
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
        navigationDelegate.didRequestLocalAttachment = { [weak self] request in
            self?.saveLocalAttachment(request)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !hasStartedLoading else { return }
        hasStartedLoading = true
        loadRenderer()
    }

    func loadRenderer() {
        loaded = false
        guard let indexURL = RendererLocator.indexURL() else {
            showFailure(
                "Renderer not found. Build the renderer or set MARKDOWN_CARD_RENDERER_DIR."
            )
            return
        }
        webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
    }

    func render(_ payload: RenderPayload) {
        pendingPayload = payload
        flushPayload()
    }

    func focusEditor() {
        pendingFocus = true
        guard loaded else { return }
        pendingFocus = false
        webView.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript(
            "window.MarkdownCard?.focusEditor?.();",
            completionHandler: nil
        )
    }

    func currentMarkdown(completion: @escaping (String?) -> Void) {
        guard loaded else {
            completion(nil)
            return
        }
        webView.evaluateJavaScript(
            "window.MarkdownCard?.getState?.().markdown ?? null;"
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

    func currentMarkdown() async -> String? {
        await withCheckedContinuation { continuation in
            currentMarkdown { markdown in
                continuation.resume(returning: markdown)
            }
        }
    }

    func currentMarkdownForCopy(completion: @escaping (String?) -> Void) {
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
            showFailure("Unable to encode this card for preview.")
            return
        }

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
            if let error {
                self?.showFailure("Preview failed.\n\(error.localizedDescription)")
            }
        }
    }

    private func showFailure(_ message: String) {
        loaded = false
        webView.isHidden = true
        messageLabel.stringValue = message
        messageLabel.isHidden = false
    }

    private static func javascriptString(_ string: String) -> String {
        guard let data = try? JSONEncoder().encode(string),
              let json = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return json
    }

    private static func bootstrapUserScript(for appearance: ResolvedAppearance) -> WKUserScript {
        let value = javascriptString(appearance.rawValue)
        let source = """
        (() => {
          const appearance = \(value);
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
    var didFinish: (() -> Void)?
    var didFail: ((Error) -> Void)?
    var didChangeMarkdown: ((UUID, String, UInt64) -> Void)?
    var didRequestHide: (() -> Void)?
    var didChangeContentHeight: ((UUID, CGFloat) -> Void)?
    var didChangeManagedAttachments: ((UUID, [String]) -> Void)?
    var didRequestLocalAttachment: ((LocalAttachmentPasteRequest) -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish?()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        didFail?(error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        didFail?(error)
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
        case "openExternalLink":
            guard let rawURL = payload["url"] as? String,
                  let url = URL(string: rawURL),
                  let scheme = url.scheme?.lowercased(),
                  ["https", "http", "mailto"].contains(scheme)
            else { return }
            NSWorkspace.shared.open(url)

        case "markdownChanged":
            guard let rawCardID = payload["cardID"] as? String,
                  let cardID = UUID(uuidString: rawCardID),
                  let markdown = payload["markdown"] as? String,
                  markdown.lengthOfBytes(using: .utf8) <= IPCFrameCodec.maximumPayloadSize,
                  let rawRevision = payload["revision"] as? NSNumber
            else { return }
            didChangeMarkdown?(cardID, markdown, rawRevision.uint64Value)

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

        default:
            return
        }
    }
}
