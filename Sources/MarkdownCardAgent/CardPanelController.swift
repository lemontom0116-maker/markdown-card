import AppKit
import MarkdownCardCore
import QuartzCore

enum CardLayoutPreset: Int, CaseIterable {
    case mini
    case stickyNote
    case middleNote

    var mode: CardLayoutMode {
        switch self {
        case .mini: .mini
        case .stickyNote: .sticky
        case .middleNote: .middle
        }
    }

    var title: String {
        switch self {
        case .mini: "Mini"
        case .stickyNote: "Sticky Note"
        case .middleNote: "Middle Note"
        }
    }

    var keyEquivalent: String { String(rawValue + 1) }
}

enum CardLayoutGeometry {
    static let headerHeight: CGFloat = 48
    static let miniSize = NSSize(width: 228, height: headerHeight)
    static let stickyWidth: CGFloat = 360
    static let middleWidth: CGFloat = 720
    static let stickyHeightRange: ClosedRange<CGFloat> = 240 ... 560
    static let middleHeightRange: ClosedRange<CGFloat> = 360 ... 840
    static let defaultCustomHeightRange: ClosedRange<CGFloat> = 240 ... 840

    static func totalHeight(
        for mode: CardLayoutMode,
        contentHeight: CGFloat,
        custom: CustomCardLayout?,
        visibleFrame: NSRect,
        chromeHeight: CGFloat = headerHeight
    ) -> CGFloat {
        switch mode {
        case .mini:
            return headerHeight
        case .sticky:
            return clamp(
                chromeHeight + contentHeight,
                to: fittedRange(stickyHeightRange, visibleFrame: visibleFrame)
            )
        case .middle:
            return clamp(
                chromeHeight + contentHeight,
                to: fittedRange(middleHeightRange, visibleFrame: visibleFrame)
            )
        case .custom:
            let settings = custom?.isValid == true ? custom! : .legacyDefault
            return clamp(
                chromeHeight + contentHeight,
                to: fittedRange(
                    CGFloat(settings.minimumHeight) ... CGFloat(settings.maximumHeight),
                    visibleFrame: visibleFrame
                )
            )
        }
    }

    static func width(
        for mode: CardLayoutMode,
        custom: CustomCardLayout?,
        visibleFrame: NSRect
    ) -> CGFloat {
        let proposed: CGFloat
        switch mode {
        case .mini: proposed = miniSize.width
        case .sticky: proposed = stickyWidth
        case .middle: proposed = middleWidth
        case .custom:
            proposed = CGFloat((custom?.isValid == true ? custom : .legacyDefault)!.width)
        }
        let minimum: CGFloat = mode == .mini ? 200 : 320
        return min(max(proposed, min(minimum, visibleFrame.width)), visibleFrame.width)
    }

    static func centeredFrame(
        for mode: CardLayoutMode,
        contentHeight: CGFloat,
        custom: CustomCardLayout?,
        visibleFrame: NSRect,
        chromeHeight: CGFloat = headerHeight
    ) -> NSRect {
        let size = NSSize(
            width: width(for: mode, custom: custom, visibleFrame: visibleFrame),
            height: totalHeight(
                for: mode,
                contentHeight: contentHeight,
                custom: custom,
                visibleFrame: visibleFrame,
                chromeHeight: chromeHeight
            )
        )
        return NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).constrained(to: visibleFrame)
    }

    static func topAnchoredFrame(
        from oldFrame: NSRect,
        mode: CardLayoutMode,
        contentHeight: CGFloat,
        custom: CustomCardLayout?,
        visibleFrame: NSRect,
        chromeHeight: CGFloat = headerHeight
    ) -> NSRect {
        let targetWidth = width(for: mode, custom: custom, visibleFrame: visibleFrame)
        let targetHeight = totalHeight(
            for: mode,
            contentHeight: contentHeight,
            custom: custom,
            visibleFrame: visibleFrame,
            chromeHeight: chromeHeight
        )
        let anchor = CardResizeAnchor.nearest(to: oldFrame, in: visibleFrame)
        let originX = anchor == .topRight ? oldFrame.maxX - targetWidth : oldFrame.minX
        return NSRect(
            x: originX,
            y: oldFrame.maxY - targetHeight,
            width: targetWidth,
            height: targetHeight
        ).constrained(to: visibleFrame)
    }

    private static func fittedRange(
        _ range: ClosedRange<CGFloat>,
        visibleFrame: NSRect
    ) -> ClosedRange<CGFloat> {
        let upper = max(1, min(range.upperBound, visibleFrame.height))
        let lower = min(range.lowerBound, upper)
        return lower ... upper
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

enum CardResizeAnchor: Equatable {
    case topLeft
    case topRight

    static func nearest(to frame: NSRect, in visibleFrame: NSRect) -> Self {
        let leftGap = abs(frame.minX - visibleFrame.minX)
        let rightGap = abs(visibleFrame.maxX - frame.maxX)
        return rightGap < leftGap ? .topRight : .topLeft
    }
}

@MainActor
final class CardPanelController: NSWindowController, NSWindowDelegate, AppearanceConsumer {
    var onMarkdownChange: ((UUID, String, UInt64, EditorSourceID) -> Void)?
    var onTagCommandSubmitted: ((UUID, String, String, UInt64, EditorSourceID) -> Void)?
    var onActivateTag: ((UUID, String) -> Void)?
    var onRemoveTag: ((UUID, String) -> Void)?
    var onNavigateSeries: ((UUID, String, SeriesNavigationDirection) -> Void)?
    var onRequestHide: ((UUID) -> Void)?
    var onCreateCard: (() -> Void)?
    var onFrameChange: ((UUID, WindowFrame, String?) -> Void)?
    var onLayoutChange: ((UUID, CardLayoutMode, CustomCardLayout?) -> Void)?
    var onBecameKey: ((UUID) -> Void)?
    var onRequestPresetPlacement: ((UUID) -> Void)?
    var onRequestFoldAllCards: (() -> Void)?
    var onRequestSaveAs: ((UUID) -> Void)?

    private(set) var card: CardRecord
    private(set) var activeTagID: String?
    let editorSourceID = EditorSourceID()
    private let appearanceController: AppearanceController
    private let rootView = AppearanceObservingView()
    private let headerView = CardHeaderView()
    private let previewView: MarkdownPreviewView
    private let externalSeriesNavigation = ExternalSeriesNavigationController()
    private let exportService = MarkdownExportService()
    private let placementPreferences: CardPlacementPreferences
    private var appearance: ResolvedAppearance
    private var revision: UInt64 = 0
    private weak var layoutMenuAnchor: NSView?
    private var customSizePopover: NSPopover?
    private var lastContentHeight: CGFloat = 0
    private var isApplyingFrame = false
    private var isUserLiveResizing = false
    private var isUpdatingLayoutPresentation = false
    private var isRebindingCard = false
    private var seriesNeighbors: CardSeriesNeighbors?
    private var fileBinding: CardFileBinding?

    private var documentRootURL: URL? {
        fileBinding?.fileURL.deletingLastPathComponent().standardizedFileURL
    }

    init(
        card: CardRecord,
        appearanceController: AppearanceController,
        placementPreferences: CardPlacementPreferences = CardPlacementPreferences(),
        fileBinding: CardFileBinding? = nil
    ) {
        self.card = card
        activeTagID = nil
        self.appearanceController = appearanceController
        self.placementPreferences = placementPreferences
        self.fileBinding = fileBinding
        let initialAppearance = appearanceController.resolvedAppearance
        appearance = initialAppearance
        previewView = MarkdownPreviewView(initialAppearance: initialAppearance)

        let initialSize = Self.initialSize(for: card)
        let panel = CommandPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        configurePanel(panel)
        configureContent()
        previewView.setDocumentRoot(self.documentRootURL, for: card.id)
        appearanceController.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NSObject.cancelPreviousPerformRequests(withTarget: self)
    }

    func update(card newCard: CardRecord, revision authoritativeRevision: UInt64? = nil) {
        let markdownChanged = newCard.markdown != card.markdown
        let layoutChanged = newCard.layoutMode != card.layoutMode
            || newCard.customLayout != card.customLayout
        card = newCard
        activeTagID = Self.validatedActiveTagID(activeTagID, for: card.tags)
        if activeTagID == nil {
            seriesNeighbors = nil
        }
        if let authoritativeRevision {
            revision = max(revision, authoritativeRevision)
        } else if markdownChanged {
            revision &+= 1
        }
        updateHeader()
        updateLayoutPresentation()
        if layoutChanged {
            applyCurrentLayout(centered: false, animate: false)
        }
        renderDocument()
    }

    /// Updates only native Tag/series chrome. This deliberately does not send
    /// a render payload back into WebKit, so a source editor that submitted a
    /// `/tag` command keeps its selection and undo history intact.
    func applyTagMetadata(
        card newCard: CardRecord,
        activeTagID requestedActiveTagID: String?,
        neighbors: CardSeriesNeighbors?,
        animated: Bool = true
    ) {
        guard newCard.id == card.id else { return }
        card.title = newCard.title
        card.titleOverride = newCard.titleOverride
        card.tags = newCard.tags
        card.updatedAt = newCard.updatedAt
        activeTagID = Self.validatedActiveTagID(
            requestedActiveTagID,
            for: card.tags
        )
        seriesNeighbors = activeTagID == nil ? nil : neighbors
        updateHeader(animatedTags: animated)
        updateSeriesNavigationPresentation(animated: animated)
    }

    /// Applies the Agent's current immutable series snapshot without touching
    /// the editor document.
    func applySeriesContext(
        activeTagID requestedActiveTagID: String?,
        neighbors: CardSeriesNeighbors?,
        animated: Bool = true
    ) {
        activeTagID = Self.validatedActiveTagID(
            requestedActiveTagID,
            for: card.tags
        )
        seriesNeighbors = activeTagID == nil ? nil : neighbors
        updateHeader(animatedTags: animated)
        updateSeriesNavigationPresentation(animated: animated)
    }

    /// Reuses this physical window for another card in the active Tag series.
    /// The current frame and Layout belong to the window, not the page, so they
    /// are retained while the target document and authoritative revision are
    /// replaced atomically.
    func rebind(
        card newCard: CardRecord,
        revision authoritativeRevision: UInt64,
        activeTagID requestedActiveTagID: String?,
        neighbors: CardSeriesNeighbors?,
        fileBinding: CardFileBinding? = nil
    ) {
        let preservedLayoutMode = card.layoutMode
        let preservedCustomLayout = card.customLayout
        let preservedWindowFrame = window.map { panel in
            return WindowFrame(
                x: panel.frame.origin.x,
                y: panel.frame.origin.y,
                width: panel.frame.width,
                height: panel.frame.height
            )
        }
        let preservedScreenID = window?.screen?.localizedName ?? card.screenID

        var reboundCard = newCard
        reboundCard.layoutMode = preservedLayoutMode
        reboundCard.customLayout = preservedCustomLayout
        reboundCard.windowFrame = preservedWindowFrame
        reboundCard.screenID = preservedScreenID

        isRebindingCard = true
        card = reboundCard
        revision = authoritativeRevision
        self.fileBinding = fileBinding
        previewView.setDocumentRoot(self.documentRootURL, for: card.id)
        activeTagID = Self.validatedActiveTagID(
            requestedActiveTagID,
            for: card.tags
        )
        seriesNeighbors = activeTagID == nil ? nil : neighbors
        updateHeader(animatedTags: false)
        updateLayoutPresentation()
        isRebindingCard = false

        updateSeriesNavigationPresentation(animated: false)
        renderDocument()
        if card.layoutMode != .mini {
            previewView.focusEditor()
            previewView.requestContentHeight()
        }
        onBecameKey?(card.id)
    }

    func setFileBinding(_ binding: CardFileBinding?) {
        guard binding != fileBinding else { return }
        fileBinding = binding
        previewView.setDocumentRoot(documentRootURL, for: card.id)
        updateHeader()
        renderDocument()
    }

    func show(
        on screen: NSScreen? = nil,
        centerIfNeeded: Bool = false,
        activate: Bool = true
    ) {
        guard let panel = window as? CommandPanel else { return }
        appearanceController.applyMode(to: panel)
        updateLayoutPresentation()

        if centerIfNeeded {
            applyCurrentLayout(on: screen, centered: true, animate: false)
        } else if let visibleFrame = (screen ?? panel.screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrame(panel.frame.constrained(to: visibleFrame), display: false)
        }

        guard activate else {
            panel.orderFront(nil)
            updateSeriesNavigationPresentation(animated: false)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        onBecameKey?(card.id)
        updateSeriesNavigationPresentation(animated: false)
        if card.layoutMode != .mini {
            previewView.focusEditor()
            previewView.requestContentHeight()
        }
    }

    func hide(flushingPendingChanges shouldFlush: Bool = true) {
        if shouldFlush { flushPendingChanges() }
        previewView.dismissTransientUI()
        externalSeriesNavigation.setVisible(false, animated: false)
        window?.orderOut(nil)
    }

    func flushPendingChanges() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(flushFrameSave),
            object: nil
        )
        flushFrameSave()
    }

    func logicalWindowFrame() -> WindowFrame? {
        guard let window else { return nil }
        let frame = window.frame
        return WindowFrame(
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.width,
            height: frame.height
        )
    }

    func flushLatestMarkdownForTermination() async {
        _ = try? await latestMarkdownForFileOperation()
        flushPendingChanges()
    }

    /// Pulls the live editor snapshot before an external file operation. The
    /// renderer's state is authoritative here; the native card can still be
    /// waiting for a coalesced bridge update when the user presses Save.
    func latestMarkdownForFileOperation() async throws -> String {
        let markdown: String
        switch await previewView.currentMarkdownSnapshot() {
        case let .markdown(value):
            markdown = value
        case .notLoaded:
            // A WebView that has not finished loading has no newer editable
            // state, so the last accepted native snapshot remains the safest
            // compatibility fallback.
            return card.markdown
        case let .failure(error):
            // File operations must never turn a renderer read failure into a
            // successful save of an older native snapshot.
            throw error
        }
        if markdown != card.markdown {
            revision &+= 1
            card.updateMarkdown(markdown)
            updateHeader()
            onMarkdownChange?(card.id, markdown, revision, editorSourceID)
        }
        return markdown
    }

    func latestMarkdownExportBundleForFileOperation() async throws -> MarkdownExportBundle {
        let firstSnapshot = try await latestMarkdownForFileOperation()
        guard let bundle = await previewView.currentMarkdownExportBundle() else {
            throw RendererMarkdownSnapshotError.unavailable
        }
        // The bundle bridge is a second asynchronous round trip. If the user
        // typed between the two replies, make the exact exported Markdown the
        // native baseline used by the Save As race guard.
        if bundle.markdown != firstSnapshot, bundle.markdown != card.markdown {
            revision &+= 1
            card.updateMarkdown(bundle.markdown)
            updateHeader()
            onMarkdownChange?(card.id, bundle.markdown, revision, editorSourceID)
        }
        return bundle
    }

    func requestHide() {
        flushPendingChanges()
        onRequestHide?(card.id)
    }

    func requestPresetPlacement() {
        onRequestPresetPlacement?(card.id)
    }

    func moveToPresetPlacement(avoiding occupiedFrames: [NSRect]) {
        guard let panel = window as? CommandPanel,
              let visibleFrame = panel.screen?.visibleFrame,
              let anchor = placementPreferences.anchor(for: card.layoutMode)
        else { return }

        guard let targetFrame = CardPlacementGeometry.availableFrame(
            for: panel.frame,
            anchor: anchor,
            visibleFrame: visibleFrame,
            avoiding: occupiedFrames
        ) else { return }
        guard !NSEqualRects(panel.frame, targetFrame) else { return }
        let shouldAnimate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        isApplyingFrame = true
        panel.setFrame(targetFrame, display: true, animate: shouldAnimate)
        isApplyingFrame = false
        externalSeriesNavigation.updateLayout()
        scheduleFrameSave()
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        appearance = resolvedAppearance
        if let window { appearanceController.applyMode(to: window) }
        synchronizeWindowSurface()
        headerView.apply(resolvedAppearance: appearance)
        previewView.apply(resolvedAppearance: appearance)
        externalSeriesNavigation.apply(resolvedAppearance: appearance)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestHide()
        return false
    }

    func windowDidMove(_ notification: Notification) {
        externalSeriesNavigation.updateLayout()
        scheduleFrameSave()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateWindowSizingLimits()
        synchronizeWindowSurface()
        externalSeriesNavigation.updateLayout()
        scheduleFrameSave()
    }

    func windowDidResize(_ notification: Notification) {
        synchronizeContentViewFrame()
        synchronizeWindowSurface()
        externalSeriesNavigation.updateLayout()
        scheduleFrameSave()
        if !isApplyingFrame,
           card.layoutMode != .mini {
            previewView.requestContentHeight()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onBecameKey?(card.id)
        updateSeriesNavigationPresentation(animated: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        previewView.dismissTransientUI()
        externalSeriesNavigation.setVisible(false, animated: true)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard !isApplyingFrame else { return }
        isUserLiveResizing = true
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard isUserLiveResizing else { return }
        isUserLiveResizing = false
        guard let panel = window,
              card.layoutMode != .mini,
              let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame
        else { return }
        let maximumHeight = min(CardLayoutGeometry.defaultCustomHeightRange.upperBound, visibleFrame.height)
        let custom = CustomCardLayout(
            width: Double(min(max(panel.frame.width, 320), visibleFrame.width)),
            minimumHeight: 240,
            maximumHeight: Double(max(240, maximumHeight))
        )
        setLayout(.custom, custom: custom, animate: false)
    }

    private static func initialSize(for card: CardRecord) -> NSSize {
        if let frame = card.windowFrame, frame.isValid {
            return NSSize(width: frame.width, height: frame.height)
        }
        switch card.layoutMode {
        case .mini: return CardLayoutGeometry.miniSize
        case .sticky: return NSSize(width: CardLayoutGeometry.stickyWidth, height: 240)
        case .middle: return NSSize(width: CardLayoutGeometry.middleWidth, height: 360)
        case .custom:
            let custom = card.customLayout?.isValid == true ? card.customLayout! : .legacyDefault
            return NSSize(width: custom.width, height: custom.minimumHeight)
        }
    }

    private func configurePanel(_ panel: CommandPanel) {
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Keep the outer rounded corners transparent. The native transition
        // surface and renderer canvas share the same color token, so animated
        // Layout expansion remains seamless without making the borderless
        // window itself opaque.
        panel.isOpaque = false
        panel.backgroundColor = MonochromePalette.windowBackground(for: appearance)
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.setAccessibilityLabel(card.title.isEmpty ? "Markdown Card" : card.title)

        panel.onHide = { [weak self] in self?.requestHide() }
        panel.onCreateCard = { [weak self] in self?.onCreateCard?() }
        panel.onMoveActiveCard = { [weak self] in self?.requestPresetPlacement() }
        panel.onFoldAllCards = { [weak self] in self?.onRequestFoldAllCards?() }
        panel.isMarkdownEditorFocused = { [weak self, weak panel] in
            guard let self else { return false }
            return previewView.ownsFirstResponder(in: panel)
        }
        panel.isMarkdownEditorComposing = { [weak self] in
            self?.previewView.isEditorComposing == true
        }
        panel.onApplyLayout = { [weak self] rawValue in
            guard let preset = CardLayoutPreset(rawValue: rawValue) else { return }
            self?.setLayout(preset.mode, custom: nil, animate: true)
        }
        panel.onShowCustomLayout = { [weak self] in self?.showCustomSize(nil) }
        updateWindowSizingLimits()
    }

    private func configureContent() {
        guard let panel = window else { return }

        rootView.translatesAutoresizingMaskIntoConstraints = true
        rootView.autoresizingMask = [.width, .height]
        rootView.frame = NSRect(origin: .zero, size: panel.contentLayoutRect.size)
        rootView.wantsLayer = true
        rootView.layerContentsRedrawPolicy = .duringViewResize
        rootView.backgroundColor = MonochromePalette.windowBackground(for: appearance)
        rootView.layer?.cornerRadius = 10
        rootView.layer?.cornerCurve = .continuous
        rootView.layer?.borderWidth = 0
        rootView.layer?.masksToBounds = true
        rootView.onAppearanceChange = { [weak self] in
            guard let self, appearanceController.mode == .system else { return }
            appearanceController.refresh()
        }

        headerView.onClose = { [weak self] in self?.requestHide() }
        headerView.onShowLayoutMenu = { [weak self] anchor in self?.showLayoutMenu(from: anchor) }
        headerView.onCopyMarkdown = { [weak self] in
            self?.copyMarkdown(nil)
        }
        headerView.onExportMarkdown = { [weak self] in
            self?.exportMarkdown(nil)
        }
        headerView.onTagSelectionChange = { [weak self] tag in
            guard let self else { return }
            activeTagID = tag?.id
            seriesNeighbors = nil
            updateHeader(animatedTags: true)
            updateSeriesNavigationPresentation(animated: true)
            if let tag {
                onActivateTag?(card.id, tag.id)
            }
        }
        headerView.onRemoveTag = { [weak self] tag in
            guard let self else { return }
            onRemoveTag?(card.id, tag.id)
        }
        headerView.onPreferredHeightChange = {
            [weak self] oldHeight, newHeight, animated in
            self?.handlePreferredHeaderHeightChange(
                from: oldHeight,
                to: newHeight,
                animated: animated
            )
        }

        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.onMarkdownChange = { [weak self] cardID, markdown, incomingRevision in
            guard let self, cardID == card.id else { return }
            revision = max(revision, incomingRevision)
            guard markdown != card.markdown else { return }
            card.updateMarkdown(markdown, explicitTitle: nil)
            updateHeader()
            onMarkdownChange?(card.id, markdown, incomingRevision, editorSourceID)
        }
        previewView.onTagCommandSubmitted = {
            [weak self] cardID, tagName, markdown, incomingRevision in
            guard let self, cardID == card.id else { return }
            revision = max(revision, incomingRevision)
            if markdown != card.markdown {
                card.updateMarkdown(markdown, explicitTitle: nil)
                updateHeader()
            }
            onTagCommandSubmitted?(
                cardID,
                tagName,
                markdown,
                incomingRevision,
                editorSourceID
            )
        }
        previewView.onRequestHide = { [weak self] in self?.requestHide() }
        previewView.onContentHeightChange = { [weak self] cardID, height in
            guard let self, cardID == card.id else { return }
            handleContentHeight(height)
        }
        previewView.onManagedAttachmentsChange = { [weak self] cardID, identifiers in
            guard let self, cardID == card.id else { return }
            headerView.setManagedAttachmentsPresent(
                !identifiers.isEmpty,
                animated: true
            )
        }
        previewView.onRequestSaveAs = { [weak self] in
            guard let self else { return }
            onRequestSaveAs?(card.id)
        }

        rootView.addSubview(headerView)
        rootView.addSubview(previewView)
        panel.contentView = rootView
        externalSeriesNavigation.onNavigate = { [weak self] direction in
            self?.requestSeriesNavigation(direction)
        }
        externalSeriesNavigation.attach(to: panel)
        synchronizeContentViewFrame()
        synchronizeWindowSurface()

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: rootView.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            previewView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])

        updateHeader()
        updateLayoutPresentation()
        apply(resolvedAppearance: appearance)
        renderDocument()
    }

    private func updateHeader(animatedTags: Bool? = nil) {
        headerView.update(title: card.title)
        let currentDigest = ExternalMarkdownDocumentService.digest(Data(card.markdown.utf8))
        headerView.updateLinkedFile(
            fileBinding?.fileURL,
            isDirty: fileBinding.map { $0.baseDigest != currentDigest } ?? false
        )
        headerView.update(
            tags: card.tags,
            activeTagID: activeTagID,
            animated: animatedTags ?? window?.isVisible == true
        )
        window?.setAccessibilityLabel(card.title.isEmpty ? "Markdown Card" : card.title)
    }

    private func updateLayoutPresentation() {
        let isMini = card.layoutMode == .mini
        isUpdatingLayoutPresentation = true
        headerView.setMiniMode(isMini)
        isUpdatingLayoutPresentation = false
        if isMini { previewView.dismissTransientUI() }
        previewView.isHidden = isMini
        updateWindowSizingLimits()
        updateSeriesNavigationPresentation(animated: false)
    }

    private func updateSeriesNavigationPresentation(animated: Bool) {
        let hasActiveSeries = activeTagID.map { activeTagID in
            card.tags.contains(where: { $0.id == activeTagID })
        } ?? false
        let canNavigateNewer = seriesNeighbors?.newerCardID != nil
        let canNavigateOlder = seriesNeighbors?.olderCardID != nil

        externalSeriesNavigation.update(
            canNavigateNewer: canNavigateNewer,
            canNavigateOlder: canNavigateOlder
        )

        let isFocused = window?.isVisible == true && window?.isKeyWindow == true
        let shouldShowExternal = hasActiveSeries
            && isFocused
            && card.layoutMode != .mini
        externalSeriesNavigation.setVisible(shouldShowExternal, animated: animated)
        if shouldShowExternal {
            externalSeriesNavigation.updateLayout()
        }
    }

    private func requestSeriesNavigation(_ direction: SeriesNavigationDirection) {
        guard let activeTagID else { return }
        switch direction {
        case .newer:
            guard seriesNeighbors?.newerCardID != nil else { return }
        case .older:
            guard seriesNeighbors?.olderCardID != nil else { return }
        }
        onNavigateSeries?(card.id, activeTagID, direction)
    }

    private func handlePreferredHeaderHeightChange(
        from oldHeight: CGFloat,
        to newHeight: CGFloat,
        animated: Bool
    ) {
        guard oldHeight != newHeight,
              !isUpdatingLayoutPresentation,
              !isRebindingCard,
              card.layoutMode != .mini
        else { return }
        applyCurrentLayout(centered: false, animate: animated)
        previewView.requestContentHeight()
    }

    private static func validatedActiveTagID(
        _ requested: String?,
        for tags: [CardTag]
    ) -> String? {
        requested.flatMap { candidate in
            tags.contains(where: { $0.id == candidate }) ? candidate : nil
        }
    }

    private func renderDocument() {
        previewView.render(
            RenderPayload(
                cardID: card.id,
                markdown: card.markdown,
                title: card.title,
                resolvedAppearance: appearance,
                revision: revision,
                documentImagesAvailable: documentRootURL != nil
            )
        )
    }

    private func showLayoutMenu(from anchor: NSView) {
        layoutMenuAnchor = anchor
        let menu = NSMenu(title: "Card Layout")
        for preset in CardLayoutPreset.allCases {
            let item = NSMenuItem(
                title: preset.title,
                action: #selector(applyLayoutPreset(_:)),
                keyEquivalent: preset.keyEquivalent
            )
            item.target = self
            item.tag = preset.rawValue
            item.keyEquivalentModifierMask = [.control]
            item.state = card.layoutMode == preset.mode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let custom = NSMenuItem(
            title: "Custom Size…",
            action: #selector(showCustomSize(_:)),
            keyEquivalent: "5"
        )
        custom.target = self
        custom.keyEquivalentModifierMask = [.control]
        custom.state = card.layoutMode == .custom ? .on : .off
        menu.addItem(custom)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.minY - 2), in: anchor)
    }

    @objc private func applyLayoutPreset(_ sender: NSMenuItem) {
        guard let preset = CardLayoutPreset(rawValue: sender.tag) else { return }
        setLayout(preset.mode, custom: nil, animate: true)
    }

    @objc private func showCustomSize(_ sender: Any?) {
        guard let panel = window,
              let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame
        else { return }
        let existing = card.customLayout?.isValid == true
            ? card.customLayout!
            : CustomCardLayout(
                width: Double(max(320, panel.frame.width)),
                minimumHeight: 240,
                maximumHeight: Double(min(840, visibleFrame.height))
            )
        let controller = CustomCardSizeViewController(
            layout: existing,
            maximumSize: visibleFrame.size
        )
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        controller.onApply = { [weak self, weak popover] custom in
            self?.setLayout(.custom, custom: custom, animate: true)
            popover?.performClose(nil)
        }
        customSizePopover = popover
        let anchor = layoutMenuAnchor ?? headerView.layoutAnchor
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func setLayout(
        _ mode: CardLayoutMode,
        custom: CustomCardLayout?,
        animate: Bool
    ) {
        card.layoutMode = mode
        card.customLayout = mode == .custom
            ? (custom?.isValid == true ? custom : card.customLayout ?? .legacyDefault)
            : card.customLayout
        card.touch()
        updateLayoutPresentation()
        onLayoutChange?(card.id, card.layoutMode, card.customLayout)
        applyCurrentLayout(centered: false, animate: animate)
        if mode != .mini {
            previewView.requestContentHeight()
        }
    }

    private func applyCurrentLayout(
        on preferredScreen: NSScreen? = nil,
        centered: Bool,
        animate: Bool
    ) {
        guard let panel = window,
              let visibleFrame = (preferredScreen ?? panel.screen ?? NSScreen.main)?.visibleFrame
        else { return }

        let frame: NSRect
        if centered {
            frame = CardLayoutGeometry.centeredFrame(
                for: card.layoutMode,
                contentHeight: lastContentHeight,
                custom: card.customLayout,
                visibleFrame: visibleFrame,
                chromeHeight: headerView.preferredHeight
            )
        } else {
            frame = CardLayoutGeometry.topAnchoredFrame(
                from: panel.frame,
                mode: card.layoutMode,
                contentHeight: lastContentHeight,
                custom: card.customLayout,
                visibleFrame: visibleFrame,
                chromeHeight: headerView.preferredHeight
            )
        }
        isApplyingFrame = true
        synchronizeWindowSurface(preparingFor: frame)
        panel.setFrame(frame, display: true, animate: animate)
        synchronizeContentViewFrame()
        synchronizeWindowSurface()
        isApplyingFrame = false
        externalSeriesNavigation.updateLayout()
        scheduleFrameSave()
    }

    private func synchronizeContentViewFrame() {
        guard let panel = window, panel.contentView === rootView else { return }
        let targetFrame = NSRect(origin: .zero, size: panel.contentLayoutRect.size)
        if rootView.frame != targetFrame {
            rootView.frame = targetFrame
        }
        rootView.layoutSubtreeIfNeeded()
        rootView.needsDisplay = true
    }

    private func synchronizeWindowSurface(preparingFor targetFrame: NSRect? = nil) {
        guard let panel = window else { return }
        let background = MonochromePalette.windowBackground(for: appearance)
        panel.backgroundColor = background

        let targetContentSize = targetFrame.map {
            panel.contentRect(forFrameRect: $0).size
        }

        if let frameHost = panel.contentView?.superview {
            frameHost.wantsLayer = true
            frameHost.layerContentsRedrawPolicy = .duringViewResize
            frameHost.layer?.backgroundColor = background.cgColor
            frameHost.layer?.cornerRadius = 10
            frameHost.layer?.cornerCurve = .continuous
            frameHost.layer?.masksToBounds = true
        }

        rootView.wantsLayer = true
        rootView.backgroundColor = background
        rootView.layer?.backgroundColor = background.cgColor
        rootView.layer?.cornerRadius = 10
        rootView.layer?.cornerCurve = .continuous
        rootView.layer?.masksToBounds = true

        if let targetContentSize {
            rootView.frame = NSRect(origin: .zero, size: targetContentSize)
        }
        rootView.layoutSubtreeIfNeeded()
        rootView.needsDisplay = true
        rootView.displayIfNeeded()
        panel.contentView?.superview?.displayIfNeeded()
    }

    private func handleContentHeight(_ height: CGFloat) {
        guard height.isFinite, height >= 0 else { return }
        lastContentHeight = height
        guard card.layoutMode != .mini else { return }
        guard let panel = window,
              let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame
        else { return }
        let targetHeight = CardLayoutGeometry.totalHeight(
            for: card.layoutMode,
            contentHeight: height,
            custom: card.customLayout,
            visibleFrame: visibleFrame,
            chromeHeight: headerView.preferredHeight
        )
        guard abs(targetHeight - panel.frame.height) >= 1 else { return }
        applyCurrentLayout(centered: false, animate: false)
    }

    private func updateWindowSizingLimits() {
        guard let panel = window,
              let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame
        else { return }
        switch card.layoutMode {
        case .mini:
            panel.minSize = NSSize(width: min(200, visibleFrame.width), height: CardHeaderView.height)
            panel.maxSize = NSSize(width: visibleFrame.width, height: CardHeaderView.height)
            panel.contentMinSize = panel.minSize
        case .sticky, .middle, .custom:
            panel.minSize = NSSize(width: min(320, visibleFrame.width), height: min(240, visibleFrame.height))
            panel.maxSize = visibleFrame.size
            panel.contentMinSize = panel.minSize
        }
    }

    @objc private func copyMarkdown(_ sender: Any?) {
        previewView.currentMarkdownForCopy { [weak self] currentMarkdown in
            guard let self else { return }
            guard let markdown = currentMarkdown else {
                NSSound.beep()
                headerView.showCopyFailure()
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(markdown, forType: .string) else {
                NSSound.beep()
                headerView.showCopyFailure()
                return
            }
            headerView.showCopySuccess("Markdown copied")
        }
    }

    @objc private func exportMarkdown(_ sender: Any?) {
        guard let window else { return }
        previewView.currentMarkdownExportBundle { [weak self, weak window] bundle in
            guard let self, let window else { return }
            guard let bundle else {
                NSSound.beep()
                headerView.showExportFailure()
                return
            }
            exportService.present(
                bundle: bundle,
                title: card.title,
                from: window
            ) { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .cancelled:
                    break
                case .success:
                    headerView.showExportSuccess()
                case .failure:
                    headerView.showExportFailure()
                }
            }
        }
    }

    private func scheduleFrameSave() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(flushFrameSave),
            object: nil
        )
        perform(#selector(flushFrameSave), with: nil, afterDelay: 0.3)
    }

    @objc private func flushFrameSave() {
        guard let window else { return }
        let frame = window.frame
        onFrameChange?(
            card.id,
            WindowFrame(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.width,
                height: frame.height
            ),
            window.screen?.localizedName
        )
    }
}

@MainActor
private final class CustomCardSizeViewController: NSViewController {
    var onApply: ((CustomCardLayout) -> Void)?

    private let widthField = NSTextField()
    private let minimumHeightField = NSTextField()
    private let maximumHeightField = NSTextField()
    private let maximumSize: NSSize

    init(layout: CustomCardLayout, maximumSize: NSSize) {
        self.maximumSize = maximumSize
        super.init(nibName: nil, bundle: nil)
        widthField.stringValue = String(Int(layout.width.rounded()))
        minimumHeightField.stringValue = String(Int(layout.minimumHeight.rounded()))
        maximumHeightField.stringValue = String(Int(layout.maximumHeight.rounded()))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 278, height: 166))
        let widthLabel = NSTextField(labelWithString: "Width")
        let minimumLabel = NSTextField(labelWithString: "Minimum Height")
        let maximumLabel = NSTextField(labelWithString: "Maximum Height")
        let applyButton = NSButton(title: "Apply", target: self, action: #selector(apply(_:)))
        applyButton.keyEquivalent = "\r"

        let rows: [(NSTextField, NSTextField)] = [
            (widthLabel, widthField),
            (minimumLabel, minimumHeightField),
            (maximumLabel, maximumHeightField),
        ]
        for (label, field) in rows {
            label.translatesAutoresizingMaskIntoConstraints = false
            field.translatesAutoresizingMaskIntoConstraints = false
            field.alignment = .right
            root.addSubview(label)
            root.addSubview(field)
        }
        applyButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(applyButton)

        widthField.formatter = Self.dimensionFormatter(minimum: 320, maximum: maximumSize.width)
        minimumHeightField.formatter = Self.dimensionFormatter(minimum: 240, maximum: maximumSize.height)
        maximumHeightField.formatter = Self.dimensionFormatter(minimum: 240, maximum: maximumSize.height)

        NSLayoutConstraint.activate([
            widthLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            widthLabel.centerYAnchor.constraint(equalTo: widthField.centerYAnchor),
            widthField.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            widthField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            widthField.widthAnchor.constraint(equalToConstant: 104),

            minimumLabel.leadingAnchor.constraint(equalTo: widthLabel.leadingAnchor),
            minimumLabel.centerYAnchor.constraint(equalTo: minimumHeightField.centerYAnchor),
            minimumHeightField.topAnchor.constraint(equalTo: widthField.bottomAnchor, constant: 10),
            minimumHeightField.trailingAnchor.constraint(equalTo: widthField.trailingAnchor),
            minimumHeightField.widthAnchor.constraint(equalTo: widthField.widthAnchor),

            maximumLabel.leadingAnchor.constraint(equalTo: widthLabel.leadingAnchor),
            maximumLabel.centerYAnchor.constraint(equalTo: maximumHeightField.centerYAnchor),
            maximumHeightField.topAnchor.constraint(equalTo: minimumHeightField.bottomAnchor, constant: 10),
            maximumHeightField.trailingAnchor.constraint(equalTo: widthField.trailingAnchor),
            maximumHeightField.widthAnchor.constraint(equalTo: widthField.widthAnchor),

            applyButton.topAnchor.constraint(equalTo: maximumHeightField.bottomAnchor, constant: 14),
            applyButton.trailingAnchor.constraint(equalTo: widthField.trailingAnchor),
            applyButton.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -12),
        ])
        view = root
    }

    @objc private func apply(_ sender: Any?) {
        guard let width = Double(widthField.stringValue),
              let minimumHeight = Double(minimumHeightField.stringValue),
              let maximumHeight = Double(maximumHeightField.stringValue),
              width >= 320,
              minimumHeight >= 240,
              maximumHeight >= minimumHeight,
              width <= maximumSize.width,
              maximumHeight <= maximumSize.height
        else {
            NSSound.beep()
            return
        }
        onApply?(CustomCardLayout(
            width: width,
            minimumHeight: minimumHeight,
            maximumHeight: maximumHeight
        ))
    }

    private static func dimensionFormatter(minimum: CGFloat, maximum: CGFloat) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: Double(minimum))
        formatter.maximum = NSNumber(value: Double(maximum))
        return formatter
    }
}

@MainActor
final class CommandPanel: NSPanel {
    var onHide: (() -> Void)?
    var onCreateCard: (() -> Void)?
    var onMoveActiveCard: (() -> Void)?
    var onFoldAllCards: (() -> Void)?
    var onApplyLayout: ((Int) -> Void)?
    var onShowCustomLayout: (() -> Void)?
    var isMarkdownEditorFocused: (() -> Bool)?
    var isMarkdownEditorComposing: (() -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let modifiers = event.modifierFlags.intersection(relevantModifiers)
        let editorFocused = isMarkdownEditorFocused?() == true
        let editorComposing = editorFocused && isMarkdownEditorComposing?() == true

        if editorFocused,
           (MarkdownShortcutContract.matches(event)
               || (event.keyCode == 53 && modifiers.isEmpty))
        {
            return super.performKeyEquivalent(with: event)
        }

        // File and layout commands are part of the card-window contract. Resolve them before
        // configurable actions so a legacy stored Fold/Move binding can never steal Save,
        // Save As, New/Close, or a layout shortcut.
        if let fixedShortcut = CardWindowFixedShortcut.command(for: event) {
            switch fixedShortcut {
            case .newCard:
                onCreateCard?()
                return true
            case .closeCard:
                onHide?()
                return true
            case let .layout(rawValue):
                guard !editorComposing else {
                    // Consume an identified native action while IME owns the
                    // keystroke. Passing it to AppKit could match a menu item
                    // after the panel declined it.
                    return true
                }
                onApplyLayout?(rawValue)
                return true
            case .customLayout:
                guard !editorComposing else {
                    return true
                }
                onShowCustomLayout?()
                return true
            case .openMarkdown, .quit, .save, .saveAs:
                return super.performKeyEquivalent(with: event)
            }
        }

        if ShortcutMatcher.matches(event, name: .toggleFoldedCards) {
            guard !editorComposing else { return true }
            onFoldAllCards?()
            return true
        }

        if ShortcutMatcher.matches(event, name: .moveActiveCard) {
            guard !editorComposing else { return true }
            onMoveActiveCard?()
            return true
        }

        if event.keyCode == 53, modifiers.isEmpty {
            onHide?()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if isMarkdownEditorFocused?() == true {
                super.keyDown(with: event)
                return
            }
            onHide?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class AppearanceObservingView: NSView {
    var onAppearanceChange: (() -> Void)?
    var backgroundColor: NSColor = .clear {
        didSet {
            layer?.backgroundColor = backgroundColor.cgColor
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { backgroundColor.alphaComponent >= 1 }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        backgroundColor.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

private extension NSRect {
    func constrained(to visibleFrame: NSRect) -> NSRect {
        var result = self
        result.size.width = min(result.width, visibleFrame.width)
        result.size.height = min(result.height, visibleFrame.height)
        result.origin.x = min(max(result.minX, visibleFrame.minX), visibleFrame.maxX - result.width)
        result.origin.y = min(max(result.minY, visibleFrame.minY), visibleFrame.maxY - result.height)
        return result
    }
}
