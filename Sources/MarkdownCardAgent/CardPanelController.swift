import AppKit
import MarkdownCardCore

enum CardLayoutPreset: Int, CaseIterable {
    case mini
    case stickyNote
    case middleNote
    case fullScreen

    var mode: CardLayoutMode {
        switch self {
        case .mini: .mini
        case .stickyNote: .sticky
        case .middleNote: .middle
        case .fullScreen: .fullScreen
        }
    }

    var title: String {
        switch self {
        case .mini: "Mini"
        case .stickyNote: "Sticky Note"
        case .middleNote: "Middle Note"
        case .fullScreen: "Full Screen"
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
        visibleFrame: NSRect
    ) -> CGFloat {
        switch mode {
        case .mini:
            return headerHeight
        case .fullScreen:
            return visibleFrame.height
        case .sticky:
            return clamp(
                headerHeight + contentHeight,
                to: fittedRange(stickyHeightRange, visibleFrame: visibleFrame)
            )
        case .middle:
            return clamp(
                headerHeight + contentHeight,
                to: fittedRange(middleHeightRange, visibleFrame: visibleFrame)
            )
        case .custom:
            let settings = custom?.isValid == true ? custom! : .legacyDefault
            return clamp(
                headerHeight + contentHeight,
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
        case .fullScreen: proposed = visibleFrame.width
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
        visibleFrame: NSRect
    ) -> NSRect {
        if mode == .fullScreen { return visibleFrame }
        let size = NSSize(
            width: width(for: mode, custom: custom, visibleFrame: visibleFrame),
            height: totalHeight(
                for: mode,
                contentHeight: contentHeight,
                custom: custom,
                visibleFrame: visibleFrame
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
        visibleFrame: NSRect
    ) -> NSRect {
        let targetWidth = width(for: mode, custom: custom, visibleFrame: visibleFrame)
        let targetHeight = totalHeight(
            for: mode,
            contentHeight: contentHeight,
            custom: custom,
            visibleFrame: visibleFrame
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
    var onRequestHide: ((UUID) -> Void)?
    var onCreateCard: (() -> Void)?
    var onFrameChange: ((UUID, WindowFrame, String?) -> Void)?
    var onLayoutChange: ((UUID, CardLayoutMode, CustomCardLayout?) -> Void)?
    var onBecameKey: ((UUID) -> Void)?

    private(set) var card: CardRecord
    let editorSourceID = EditorSourceID()
    private let appearanceController: AppearanceController
    private let rootView = AppearanceObservingView()
    private let headerView = CardHeaderView()
    private let previewView: MarkdownPreviewView
    private let exportService = MarkdownExportService()
    private var appearance: ResolvedAppearance
    private var revision: UInt64 = 0
    private weak var layoutMenuAnchor: NSView?
    private var customSizePopover: NSPopover?
    private var lastContentHeight: CGFloat = 0
    private var isApplyingFrame = false
    private var isUserLiveResizing = false
    private var frameBeforeFullScreen: NSRect?

    init(card: CardRecord, appearanceController: AppearanceController) {
        self.card = card
        self.appearanceController = appearanceController
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
        let previousLayoutMode = card.layoutMode
        let markdownChanged = newCard.markdown != card.markdown
        let layoutChanged = newCard.layoutMode != card.layoutMode
            || newCard.customLayout != card.customLayout
        let transitionAnchor = prepareLayoutTransition(
            from: previousLayoutMode,
            to: newCard.layoutMode
        )
        card = newCard
        if let authoritativeRevision {
            revision = max(revision, authoritativeRevision)
        } else if markdownChanged {
            revision &+= 1
        }
        updateHeader()
        updateLayoutPresentation()
        if layoutChanged {
            applyCurrentLayout(
                centered: false,
                animate: false,
                anchorFrame: transitionAnchor
            )
            finishLayoutTransition(from: previousLayoutMode, to: newCard.layoutMode)
        }
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

        if centerIfNeeded || card.layoutMode == .fullScreen {
            applyCurrentLayout(on: screen, centered: true, animate: false)
        } else if let visibleFrame = (screen ?? panel.screen ?? NSScreen.main)?.visibleFrame {
            panel.setFrame(panel.frame.constrained(to: visibleFrame), display: false)
        }

        guard activate else {
            panel.orderFront(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        onBecameKey?(card.id)
        if card.layoutMode != .mini {
            previewView.focusEditor()
            previewView.requestContentHeight()
        }
    }

    func hide(flushingPendingChanges shouldFlush: Bool = true) {
        if shouldFlush { flushPendingChanges() }
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

    func flushLatestMarkdownForTermination() async {
        if let markdown = await previewView.currentMarkdown(), markdown != card.markdown {
            revision &+= 1
            card.updateMarkdown(markdown)
            updateHeader()
            onMarkdownChange?(card.id, markdown, revision, editorSourceID)
        }
        flushPendingChanges()
    }

    func requestHide() {
        flushPendingChanges()
        onRequestHide?(card.id)
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        appearance = resolvedAppearance
        if let window { appearanceController.applyMode(to: window) }
        synchronizeWindowSurface()
        headerView.apply(resolvedAppearance: appearance)
        previewView.apply(resolvedAppearance: appearance)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestHide()
        return false
    }

    func windowDidMove(_ notification: Notification) { scheduleFrameSave() }

    func windowDidResize(_ notification: Notification) {
        synchronizeContentViewFrame()
        synchronizeWindowSurface()
        scheduleFrameSave()
        if !isApplyingFrame, card.layoutMode != .mini, card.layoutMode != .fullScreen {
            previewView.requestContentHeight()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onBecameKey?(card.id)
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
              card.layoutMode != .fullScreen,
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
        case .fullScreen: return NSSize(width: 900, height: 640)
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
        panel.setAccessibilityLabel(card.title.isEmpty ? "Easy Card" : card.title)

        panel.onHide = { [weak self] in self?.requestHide() }
        panel.onCreateCard = { [weak self] in self?.onCreateCard?() }
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

        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.onMarkdownChange = { [weak self] cardID, markdown, incomingRevision in
            guard let self, cardID == card.id else { return }
            revision = max(revision, incomingRevision)
            guard markdown != card.markdown else { return }
            card.updateMarkdown(markdown, explicitTitle: nil)
            updateHeader()
            onMarkdownChange?(card.id, markdown, incomingRevision, editorSourceID)
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

        rootView.addSubview(headerView)
        rootView.addSubview(previewView)
        panel.contentView = rootView
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

    private func updateHeader() {
        headerView.update(title: card.title)
        window?.setAccessibilityLabel(card.title.isEmpty ? "Easy Card" : card.title)
    }

    private func updateLayoutPresentation() {
        let isMini = card.layoutMode == .mini
        headerView.setMiniMode(isMini)
        previewView.isHidden = isMini
        updateWindowSizingLimits()
    }

    private func renderDocument() {
        previewView.render(
            RenderPayload(
                cardID: card.id,
                markdown: card.markdown,
                title: card.title,
                resolvedAppearance: appearance,
                revision: revision
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
            item.keyEquivalentModifierMask = [.command]
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
        custom.keyEquivalentModifierMask = [.command]
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
        let previousLayoutMode = card.layoutMode
        let transitionAnchor = prepareLayoutTransition(from: previousLayoutMode, to: mode)
        card.layoutMode = mode
        card.customLayout = mode == .custom
            ? (custom?.isValid == true ? custom : card.customLayout ?? .legacyDefault)
            : card.customLayout
        card.touch()
        updateLayoutPresentation()
        onLayoutChange?(card.id, card.layoutMode, card.customLayout)
        applyCurrentLayout(
            centered: false,
            animate: animate,
            anchorFrame: transitionAnchor
        )
        finishLayoutTransition(from: previousLayoutMode, to: mode)
        if mode != .mini && mode != .fullScreen {
            previewView.requestContentHeight()
        }
    }

    private func applyCurrentLayout(
        on preferredScreen: NSScreen? = nil,
        centered: Bool,
        animate: Bool,
        anchorFrame: NSRect? = nil
    ) {
        guard let panel = window,
              let visibleFrame = (preferredScreen ?? panel.screen ?? NSScreen.main)?.visibleFrame
        else { return }

        let frame: NSRect
        if centered || card.layoutMode == .fullScreen {
            frame = CardLayoutGeometry.centeredFrame(
                for: card.layoutMode,
                contentHeight: lastContentHeight,
                custom: card.customLayout,
                visibleFrame: visibleFrame
            )
        } else {
            frame = CardLayoutGeometry.topAnchoredFrame(
                from: anchorFrame ?? panel.frame,
                mode: card.layoutMode,
                contentHeight: lastContentHeight,
                custom: card.customLayout,
                visibleFrame: visibleFrame
            )
        }
        isApplyingFrame = true
        synchronizeWindowSurface(preparingFor: frame)
        panel.setFrame(frame, display: true, animate: animate)
        synchronizeContentViewFrame()
        synchronizeWindowSurface()
        isApplyingFrame = false
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

    private func prepareLayoutTransition(
        from previousMode: CardLayoutMode,
        to nextMode: CardLayoutMode
    ) -> NSRect? {
        guard let panel = window else { return nil }
        if previousMode != .fullScreen, nextMode == .fullScreen {
            frameBeforeFullScreen = panel.frame
            return nil
        }
        guard previousMode == .fullScreen, nextMode != .fullScreen else { return nil }
        if let frameBeforeFullScreen { return frameBeforeFullScreen }
        guard let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame else {
            return panel.frame
        }
        return NSRect(
            x: visibleFrame.minX,
            y: visibleFrame.maxY - panel.frame.height,
            width: panel.frame.width,
            height: panel.frame.height
        )
    }

    private func finishLayoutTransition(
        from previousMode: CardLayoutMode,
        to nextMode: CardLayoutMode
    ) {
        if previousMode == .fullScreen, nextMode != .fullScreen {
            frameBeforeFullScreen = nil
        }
    }

    private func handleContentHeight(_ height: CGFloat) {
        guard height.isFinite, height >= 0 else { return }
        lastContentHeight = height
        guard card.layoutMode != .mini, card.layoutMode != .fullScreen else { return }
        guard let panel = window,
              let visibleFrame = (panel.screen ?? NSScreen.main)?.visibleFrame
        else { return }
        let targetHeight = CardLayoutGeometry.totalHeight(
            for: card.layoutMode,
            contentHeight: height,
            custom: card.customLayout,
            visibleFrame: visibleFrame
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
        case .fullScreen:
            panel.minSize = visibleFrame.size
            panel.maxSize = visibleFrame.size
            panel.contentMinSize = visibleFrame.size
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
private final class CommandPanel: NSPanel {
    var onHide: (() -> Void)?
    var onCreateCard: (() -> Void)?
    var onApplyLayout: ((Int) -> Void)?
    var onShowCustomLayout: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 53, modifiers.isEmpty {
            onHide?()
            return true
        }

        guard modifiers.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased()
        else {
            return super.performKeyEquivalent(with: event)
        }

        switch key {
        case "n":
            onCreateCard?()
            return true
        case "w":
            onHide?()
            return true
        case "1", "2", "3", "4":
            if let raw = Int(key).map({ $0 - 1 }) { onApplyLayout?(raw) }
            return true
        case "5":
            onShowCustomLayout?()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
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
