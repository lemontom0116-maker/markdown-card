import AppKit
import MarkdownCardCore
import QuartzCore

enum CardContentLayoutMetrics {
    static let compactBreakpoint: CGFloat = 620
    static let compactLeading: CGFloat = 28
    static let regularLeading: CGFloat = 40

    static func leadingInset(for width: CGFloat) -> CGFloat {
        width <= compactBreakpoint ? compactLeading : regularLeading
    }
}

@MainActor
final class CardHeaderView: NSView, AppearanceConsumer {
    static let titleRowHeight: CGFloat = 48
    static let tagRailTop: CGFloat = 44
    static let tagRailHeight: CGFloat = 24
    static let expandedHeight: CGFloat = tagRailTop + tagRailHeight
    /// Compatibility alias for callers that mean the Mini/no-tag height.
    static let height: CGFloat = titleRowHeight

    var onClose: (() -> Void)?
    var onShowLayoutMenu: ((NSView) -> Void)?
    var onCopyMarkdown: (() -> Void)?
    var onExportMarkdown: (() -> Void)?
    var onTagSelectionChange: ((CardTag?) -> Void)?
    var onRemoveTag: ((CardTag) -> Void)?
    var onPreferredHeightChange: ((_ oldHeight: CGFloat, _ newHeight: CGFloat, _ animated: Bool) -> Void)?
    var windowDragHandler: (NSWindow, NSEvent) -> Void = { window, event in
        window.performDrag(with: event)
    }

    private let closeButton = CloseDotButton()
    private let titleLabel = DraggableTitleLabel(string: CardRecord.untitledTitle)
    private let fileStatusLabel = DraggableTitleLabel(string: "")
    private let layoutButton = HeaderIconButton(
        symbolName: "rectangle.3.group",
        accessibilityDescription: "Card layout"
    )
    private let copyButton = HeaderIconButton(
        symbolName: "doc.on.doc",
        accessibilityDescription: "Copy Markdown"
    )
    private let exportButton = HeaderIconButton(
        symbolName: "square.and.arrow.down",
        accessibilityDescription: "Export Markdown"
    )
    private let tagStrip = CurtainTagStripView()
    private var copyFeedbackTask: Task<Void, Never>?
    private var exportFeedbackTask: Task<Void, Never>?
    private var resolvedStyle: ResolvedAppearance = .dark
    private var isMini = false
    private var hasManagedAttachments = false
    private var layoutToCopyConstraint: NSLayoutConstraint?
    private var layoutToTrailingConstraint: NSLayoutConstraint?
    private var exportWidthConstraint: NSLayoutConstraint?
    private var copyToExportConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var tagLeadingConstraint: NSLayoutConstraint?
    private var titleToLayoutConstraint: NSLayoutConstraint?
    private var titleToFileStatusConstraint: NSLayoutConstraint?
    private var currentTags: [CardTag] = []
    private var linkedFileURL: URL?
    private var linkedFileIsDirty = false
    private(set) var preferredHeight: CGFloat = CardHeaderView.titleRowHeight
    var layoutAnchor: NSView { layoutButton }

    // Forward the gesture to AppKit so the Window Server handles display and
    // Space transitions for this borderless panel.
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        performWindowDrag(with: event)
    }

    override func layout() {
        updateTagLeadingInset()
        super.layout()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.target = self
        closeButton.action = #selector(closeCard(_:))
        closeButton.setAccessibilityLabel("Hide card")
        closeButton.toolTip = "Hide Card (Esc)"

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.dragOwner = self

        fileStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        fileStatusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        fileStatusLabel.lineBreakMode = .byTruncatingMiddle
        fileStatusLabel.maximumNumberOfLines = 1
        fileStatusLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        fileStatusLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        fileStatusLabel.dragOwner = self
        fileStatusLabel.isHidden = true
        fileStatusLabel.setAccessibilityLabel("Linked Markdown file")

        layoutButton.translatesAutoresizingMaskIntoConstraints = false
        layoutButton.target = self
        layoutButton.action = #selector(showLayoutMenu(_:))
        layoutButton.toolTip = "Card Layout"
        layoutButton.setAccessibilityHelp("Choose a card layout")

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.target = self
        copyButton.action = #selector(copyMarkdown(_:))
        copyButton.toolTip = "Copy Markdown"

        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.target = self
        exportButton.action = #selector(exportMarkdown(_:))
        exportButton.toolTip = "Export Markdown"

        tagStrip.translatesAutoresizingMaskIntoConstraints = false
        tagStrip.isHidden = true
        tagStrip.onSelectionChange = { [weak self] tag in self?.onTagSelectionChange?(tag) }
        tagStrip.onRemoveTag = { [weak self] tag in self?.onRemoveTag?(tag) }

        addSubview(closeButton)
        addSubview(titleLabel)
        addSubview(fileStatusLabel)
        addSubview(layoutButton)
        addSubview(copyButton)
        addSubview(exportButton)
        addSubview(tagStrip)

        let regularLayoutTrailing = layoutButton.trailingAnchor.constraint(
            equalTo: copyButton.leadingAnchor,
            constant: -2
        )
        let miniLayoutTrailing = layoutButton.trailingAnchor.constraint(
            equalTo: trailingAnchor,
            constant: -12
        )
        layoutToCopyConstraint = regularLayoutTrailing
        layoutToTrailingConstraint = miniLayoutTrailing
        let copyToExport = copyButton.trailingAnchor.constraint(
            equalTo: exportButton.leadingAnchor
        )
        let exportWidth = exportButton.widthAnchor.constraint(equalToConstant: 0)
        copyToExportConstraint = copyToExport
        exportWidthConstraint = exportWidth
        let headerHeight = heightAnchor.constraint(equalToConstant: Self.titleRowHeight)
        heightConstraint = headerHeight
        let titleToLayout = titleLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: layoutButton.leadingAnchor,
            constant: -8
        )
        let titleToFileStatus = titleLabel.trailingAnchor.constraint(
            lessThanOrEqualTo: fileStatusLabel.leadingAnchor,
            constant: -8
        )
        titleToLayoutConstraint = titleToLayout
        titleToFileStatusConstraint = titleToFileStatus
        let tagLeading = tagStrip.leadingAnchor.constraint(
            equalTo: leadingAnchor,
            constant: CardContentLayoutMetrics.leadingInset(for: frame.width)
        )
        tagLeadingConstraint = tagLeading

        NSLayoutConstraint.activate([
            headerHeight,

            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.titleRowHeight / 2),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.titleRowHeight / 2),
            titleToLayout,

            fileStatusLabel.trailingAnchor.constraint(equalTo: layoutButton.leadingAnchor, constant: -8),
            fileStatusLabel.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.titleRowHeight / 2),
            fileStatusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 190),

            regularLayoutTrailing,
            layoutButton.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.titleRowHeight / 2),
            layoutButton.widthAnchor.constraint(equalToConstant: 36),
            layoutButton.heightAnchor.constraint(equalToConstant: 36),

            copyButton.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.titleRowHeight / 2),
            copyButton.widthAnchor.constraint(equalToConstant: 36),
            copyButton.heightAnchor.constraint(equalToConstant: 36),

            copyToExport,
            exportButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            exportButton.centerYAnchor.constraint(equalTo: topAnchor, constant: Self.titleRowHeight / 2),
            exportWidth,
            exportButton.heightAnchor.constraint(equalToConstant: 36),

            tagLeading,
            tagStrip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            tagStrip.topAnchor.constraint(equalTo: topAnchor, constant: Self.tagRailTop),
            tagStrip.heightAnchor.constraint(equalToConstant: Self.tagRailHeight),
        ])
        updateExportVisibility(animated: false)
    }

    private func updateTagLeadingInset() {
        let inset = CardContentLayoutMetrics.leadingInset(for: bounds.width)
        guard tagLeadingConstraint?.constant != inset else { return }
        tagLeadingConstraint?.constant = inset
    }

    fileprivate func performWindowDrag(with event: NSEvent) {
        guard let window else { return }
        windowDragHandler(window, event)
    }

    func update(title: String) {
        titleLabel.stringValue = title.isEmpty ? CardRecord.untitledTitle : title
    }

    func updateLinkedFile(_ fileURL: URL?, isDirty: Bool) {
        linkedFileURL = fileURL?.standardizedFileURL
        linkedFileIsDirty = isDirty
        updateFileStatusPresentation()
    }

    func update(tags: [CardTag], activeTagID: String?, animated: Bool) {
        currentTags = tags
        tagStrip.update(tags: tags, activeTagID: activeTagID, animated: animated)
        updateTagPresentation(animated: animated)
    }

    func setMiniMode(_ enabled: Bool) {
        guard isMini != enabled else { return }
        isMini = enabled
        copyButton.isHidden = enabled
        copyButton.alphaValue = enabled ? 0 : 1
        layoutToCopyConstraint?.isActive = !enabled
        layoutToTrailingConstraint?.isActive = enabled
        updateExportVisibility(animated: false)
        updateLayoutButtonPresentation()
        updateTagPresentation(animated: false)
        updateFileStatusPresentation()
    }

    func setManagedAttachmentsPresent(_ present: Bool, animated: Bool) {
        guard hasManagedAttachments != present else { return }
        hasManagedAttachments = present
        exportButton.toolTip = present
            ? "Export Markdown with Attachments"
            : "Export Markdown"
        updateExportVisibility(animated: animated)
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        resolvedStyle = resolvedAppearance
        titleLabel.textColor = MonochromePalette.secondaryText(for: resolvedStyle)
        fileStatusLabel.textColor = linkedFileIsDirty
            ? MonochromePalette.primaryText(for: resolvedStyle)
            : MonochromePalette.secondaryText(for: resolvedStyle)
        closeButton.apply(resolvedAppearance: resolvedStyle)
        layoutButton.apply(resolvedAppearance: resolvedStyle)
        copyButton.apply(resolvedAppearance: resolvedStyle)
        exportButton.apply(resolvedAppearance: resolvedStyle)
        tagStrip.apply(resolvedAppearance: resolvedStyle)
    }

    func showCopySuccess(_ announcement: String = "Copied") {
        showCopyFeedback(
            symbol: "checkmark",
            announcement: announcement,
            accessibilityValue: "Copied"
        )
    }

    func showCopyFailure(_ announcement: String = "Unable to copy Markdown") {
        showCopyFeedback(
            symbol: "exclamationmark",
            announcement: announcement,
            accessibilityValue: "Copy failed"
        )
    }

    func showExportSuccess(_ announcement: String = "Markdown exported") {
        showExportFeedback(
            symbol: "checkmark",
            announcement: announcement,
            accessibilityValue: "Exported"
        )
    }

    func showExportFailure(_ announcement: String = "Unable to export Markdown") {
        showExportFeedback(
            symbol: "exclamationmark",
            announcement: announcement,
            accessibilityValue: "Export failed"
        )
    }

    private func showCopyFeedback(
        symbol: String,
        announcement: String,
        accessibilityValue: String
    ) {
        copyFeedbackTask?.cancel()
        copyButton.setSymbol(symbol, accessibilityDescription: announcement)
        copyButton.setAccessibilityValue(accessibilityValue)
        NSAccessibility.post(
            element: copyButton,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
        copyFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.copyButton.setSymbol("doc.on.doc", accessibilityDescription: "Copy Markdown")
            self?.copyButton.setAccessibilityValue(nil)
        }
    }

    private func showExportFeedback(
        symbol: String,
        announcement: String,
        accessibilityValue: String
    ) {
        exportFeedbackTask?.cancel()
        exportButton.setSymbol(symbol, accessibilityDescription: announcement)
        exportButton.setAccessibilityValue(accessibilityValue)
        NSAccessibility.post(
            element: exportButton,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
        exportFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.exportButton.setSymbol(
                "square.and.arrow.down",
                accessibilityDescription: "Export Markdown"
            )
            self?.exportButton.setAccessibilityValue(nil)
        }
    }

    @objc private func closeCard(_ sender: Any?) {
        onClose?()
    }

    @objc private func showLayoutMenu(_ sender: NSView) {
        onShowLayoutMenu?(sender)
    }

    @objc private func copyMarkdown(_ sender: Any?) {
        onCopyMarkdown?()
    }

    @objc private func exportMarkdown(_ sender: Any?) {
        onExportMarkdown?()
    }

    private func updateLayoutButtonPresentation() {
        if isMini {
            layoutButton.toolTip = "Choose Card Layout — Restore from Mini (⌃2 for Sticky Note)"
            layoutButton.setAccessibilityHelp(
                "Choose another card layout to restore the editor. "
                    + "Press Control-2 for Sticky Note."
            )
        } else {
            layoutButton.toolTip = "Card Layout"
            layoutButton.setAccessibilityHelp("Choose a card layout")
        }
    }

    private func updateExportVisibility(animated: Bool) {
        let shouldReserveSpace = !isMini
        let shouldDisplay = shouldReserveSpace
        if shouldDisplay { exportButton.isHidden = false }
        copyToExportConstraint?.constant = shouldReserveSpace ? -2 : 0
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
        let applyChanges = { [self] in
            exportWidthConstraint?.animator().constant = shouldReserveSpace ? 36 : 0
            exportButton.animator().alphaValue = shouldDisplay ? 1 : 0
            layoutSubtreeIfNeeded()
        }
        guard animated, duration > 0, window?.isVisible == true else {
            exportWidthConstraint?.constant = shouldReserveSpace ? 36 : 0
            exportButton.alphaValue = shouldDisplay ? 1 : 0
            exportButton.isHidden = !shouldDisplay
            layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            applyChanges()
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.exportButton.isHidden = !shouldDisplay
            }
        }
    }

    private func updateTagPresentation(animated: Bool) {
        let shouldReserveTagRail = !isMini && !currentTags.isEmpty
        let shouldDisplay = shouldReserveTagRail
        tagStrip.isHidden = !shouldDisplay
        tagStrip.alphaValue = shouldDisplay ? 1 : 0
        let nextHeight = shouldReserveTagRail
            ? Self.expandedHeight
            : Self.titleRowHeight
        guard preferredHeight != nextHeight else { return }

        let oldHeight = preferredHeight
        preferredHeight = nextHeight
        let shouldAnimate = animated
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        onPreferredHeightChange?(oldHeight, nextHeight, shouldAnimate)

        let duration: TimeInterval = 0.14
        guard shouldAnimate, window?.isVisible == true else {
            heightConstraint?.constant = nextHeight
            layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            heightConstraint?.animator().constant = nextHeight
            layoutSubtreeIfNeeded()
        }
    }

    private func updateFileStatusPresentation() {
        let shouldReserveSpace = !isMini && linkedFileURL != nil
        let shouldDisplay = shouldReserveSpace
        fileStatusLabel.isHidden = !shouldDisplay
        fileStatusLabel.alphaValue = shouldDisplay ? 1 : 0
        titleToLayoutConstraint?.isActive = !shouldReserveSpace
        titleToFileStatusConstraint?.isActive = shouldReserveSpace
        guard shouldReserveSpace, let linkedFileURL else { return }

        let filename = linkedFileURL.lastPathComponent
        fileStatusLabel.stringValue = linkedFileIsDirty
            ? "\(filename) · Edited"
            : filename
        fileStatusLabel.toolTip = linkedFileIsDirty
            ? "\(linkedFileURL.path) — changes have not been saved to this file"
            : linkedFileURL.path
        fileStatusLabel.setAccessibilityHelp(
            linkedFileIsDirty
                ? "\(filename), edited and not saved to the linked file"
                : "\(filename), saved to the linked file"
        )
        fileStatusLabel.textColor = linkedFileIsDirty
            ? MonochromePalette.primaryText(for: resolvedStyle)
            : MonochromePalette.secondaryText(for: resolvedStyle)
    }

}

@MainActor
private final class DraggableTitleLabel: NSTextField {
    weak var dragOwner: CardHeaderView?

    init(string: String) {
        super.init(frame: .zero)
        stringValue = string
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragOwner?.performWindowDrag(with: event)
    }
}

@MainActor
private final class HeaderIconButton: NSButton {
    private var resolvedStyle: ResolvedAppearance = .dark
    private var trackingAreaReference: NSTrackingArea?
    private var isHovering = false
    private(set) var hasKeyboardFocus = false

    init(symbolName: String, accessibilityDescription: String) {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setButtonType(.momentaryChange)
        focusRingType = .none
        setSymbol(symbolName, accessibilityDescription: accessibilityDescription)
        setAccessibilityLabel(accessibilityDescription)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        updateKeyboardFocus(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        updateKeyboardFocus(false)
        return true
    }

    func setSymbol(_ symbolName: String, accessibilityDescription: String) {
        image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        )
        image?.isTemplate = true
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        resolvedStyle = resolvedAppearance
        contentTintColor = MonochromePalette.secondaryText(for: resolvedStyle)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovering || hasKeyboardFocus {
            MonochromePalette.controlFill(for: resolvedStyle).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
        super.draw(dirtyRect)
        if hasKeyboardFocus {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focusPath = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 3, dy: 3),
                xRadius: 7,
                yRadius: 7
            )
            focusPath.lineWidth = 2
            focusPath.stroke()
        }
    }

    private func updateKeyboardFocus(_ focused: Bool) {
        guard hasKeyboardFocus != focused else { return }
        hasKeyboardFocus = focused
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }
}

@MainActor
private final class CloseDotButton: NSButton {
    private var resolvedStyle: ResolvedAppearance = .dark
    private var trackingAreaReference: NSTrackingArea?
    private var isHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .noImage
        setButtonType(.momentaryChange)
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        resolvedStyle = resolvedAppearance
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let diameter: CGFloat = 12
        let dotRect = NSRect(
            x: floor((bounds.width - diameter) / 2),
            y: floor((bounds.height - diameter) / 2),
            width: diameter,
            height: diameter
        )
        let dot = NSBezierPath(ovalIn: dotRect)
        NSColor(calibratedRed: 1.0, green: 0.37, blue: 0.34, alpha: 1).setFill()
        dot.fill()

        guard isHovering else { return }
        let markColor = resolvedStyle == .dark
            ? NSColor(calibratedWhite: 0.12, alpha: 0.86)
            : NSColor(calibratedWhite: 0.18, alpha: 0.82)
        markColor.setStroke()
        let inset: CGFloat = 3.35
        let first = NSBezierPath()
        first.move(to: NSPoint(x: dotRect.minX + inset, y: dotRect.minY + inset))
        first.line(to: NSPoint(x: dotRect.maxX - inset, y: dotRect.maxY - inset))
        first.lineWidth = 1.15
        first.lineCapStyle = .round
        first.stroke()
        let second = NSBezierPath()
        second.move(to: NSPoint(x: dotRect.minX + inset, y: dotRect.maxY - inset))
        second.line(to: NSPoint(x: dotRect.maxX - inset, y: dotRect.minY + inset))
        second.lineWidth = 1.15
        second.lineCapStyle = .round
        second.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }
}
