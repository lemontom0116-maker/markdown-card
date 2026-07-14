import AppKit
import MarkdownCardCore
import QuartzCore

@MainActor
final class CardHeaderView: NSView, AppearanceConsumer {
    static let height: CGFloat = 48

    var onClose: (() -> Void)?
    var onShowLayoutMenu: ((NSView) -> Void)?
    var onCopyMarkdown: (() -> Void)?
    var onExportMarkdown: (() -> Void)?
    var windowDragHandler: (NSWindow, NSEvent) -> Void = { window, event in
        window.performDrag(with: event)
    }

    private let closeButton = CloseDotButton()
    private let titleLabel = DraggableTitleLabel(string: CardRecord.untitledTitle)
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
    private var copyFeedbackTask: Task<Void, Never>?
    private var exportFeedbackTask: Task<Void, Never>?
    private var resolvedStyle: ResolvedAppearance = .dark
    private var trackingAreaReference: NSTrackingArea?
    private var isMini = false
    private var hasManagedAttachments = false
    private var isHoveringHeader = false
    private var layoutToCopyConstraint: NSLayoutConstraint?
    private var layoutToTrailingConstraint: NSLayoutConstraint?
    private var exportWidthConstraint: NSLayoutConstraint?
    private var copyToExportConstraint: NSLayoutConstraint?
    var layoutAnchor: NSView { layoutButton }

    // Forward the gesture to AppKit so the Window Server handles display and
    // Space transitions for this borderless panel.
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        performWindowDrag(with: event)
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

        layoutButton.translatesAutoresizingMaskIntoConstraints = false
        layoutButton.target = self
        layoutButton.action = #selector(showLayoutMenu(_:))
        layoutButton.toolTip = "Card Layout"

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.target = self
        copyButton.action = #selector(copyMarkdown(_:))
        copyButton.toolTip = "Copy Markdown"

        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.target = self
        exportButton.action = #selector(exportMarkdown(_:))
        exportButton.toolTip = "Export Markdown with Attachments"
        exportButton.alphaValue = 0
        exportButton.isHidden = true

        addSubview(closeButton)
        addSubview(titleLabel)
        addSubview(layoutButton)
        addSubview(copyButton)
        addSubview(exportButton)

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

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: layoutButton.leadingAnchor, constant: -8),

            regularLayoutTrailing,
            layoutButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            layoutButton.widthAnchor.constraint(equalToConstant: 36),
            layoutButton.heightAnchor.constraint(equalToConstant: 36),

            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 36),
            copyButton.heightAnchor.constraint(equalToConstant: 36),

            copyToExport,
            exportButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            exportButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            exportWidth,
            exportButton.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    fileprivate func performWindowDrag(with event: NSEvent) {
        guard let window else { return }
        windowDragHandler(window, event)
    }

    func update(title: String) {
        titleLabel.stringValue = title.isEmpty ? CardRecord.untitledTitle : title
    }

    func setMiniMode(_ enabled: Bool) {
        guard isMini != enabled else { return }
        isMini = enabled
        copyButton.isHidden = enabled
        layoutToCopyConstraint?.isActive = !enabled
        layoutToTrailingConstraint?.isActive = enabled
        updateExportVisibility(animated: false)
        updateMiniControls(animated: false)
    }

    func setManagedAttachmentsPresent(_ present: Bool, animated: Bool) {
        guard hasManagedAttachments != present else { return }
        hasManagedAttachments = present
        updateExportVisibility(animated: animated)
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        resolvedStyle = resolvedAppearance
        titleLabel.textColor = MonochromePalette.secondaryText(for: resolvedStyle)
        closeButton.apply(resolvedAppearance: resolvedStyle)
        layoutButton.apply(resolvedAppearance: resolvedStyle)
        copyButton.apply(resolvedAppearance: resolvedStyle)
        exportButton.apply(resolvedAppearance: resolvedStyle)
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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHoveringHeader = true
        updateMiniControls(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHoveringHeader = false
        updateMiniControls(animated: true)
    }

    private func updateMiniControls(animated: Bool) {
        let shouldShowLayout = !isMini || isHoveringHeader
        layoutButton.isEnabled = shouldShowLayout
        let changes = { [self] in
            layoutButton.animator().alphaValue = shouldShowLayout ? 1 : 0
        }
        if animated, window?.isVisible == true {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                changes()
            }
        } else {
            layoutButton.alphaValue = shouldShowLayout ? 1 : 0
        }
    }

    private func updateExportVisibility(animated: Bool) {
        let shouldShow = hasManagedAttachments && !isMini
        if shouldShow { exportButton.isHidden = false }
        copyToExportConstraint?.constant = shouldShow ? -2 : 0
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
        let applyChanges = { [self] in
            exportWidthConstraint?.animator().constant = shouldShow ? 36 : 0
            exportButton.animator().alphaValue = shouldShow ? 1 : 0
            layoutSubtreeIfNeeded()
        }
        guard animated, duration > 0, window?.isVisible == true else {
            exportWidthConstraint?.constant = shouldShow ? 36 : 0
            exportButton.alphaValue = shouldShow ? 1 : 0
            exportButton.isHidden = !shouldShow
            layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            applyChanges()
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.exportButton.isHidden = !shouldShow
            }
        }
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
        if isHovering {
            MonochromePalette.controlFill(for: resolvedStyle).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 8, yRadius: 8).fill()
        }
        super.draw(dirtyRect)
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
