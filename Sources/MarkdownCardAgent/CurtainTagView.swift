import AppKit
import MarkdownCardCore
import QuartzCore

@MainActor
enum CurtainTagMetrics {
    static let fontSize: CGFloat = 10
    static let horizontalPadding: CGFloat = 5
    static let labelSafetyPadding: CGFloat = 2
    static let spacing: CGFloat = 8
    static let minimumWidth: CGFloat = 32
    static let maximumWidth: CGFloat = 96
    static let hitHeight: CGFloat = 24
    static let chipHeight: CGFloat = 22
    static let cornerRadius: CGFloat = 3
    static let outlineWidth: CGFloat = 1
    static let selectedOutlineWidth: CGFloat = 1.4
    static let underlineHeight: CGFloat = 2
    static let underlineInset: CGFloat = 8

    static func width(for name: String) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let textWidth = ceil((name as NSString).size(withAttributes: [.font: font]).width)
        return min(
            maximumWidth,
            max(minimumWidth, textWidth + horizontalPadding * 2 + labelSafetyPadding)
        )
    }
}

@MainActor
enum CurtainTagPalette {
    private static let colors: [NSColor] = [
        color(hex: 0x86AEDD), // Dust Blue
        color(hex: 0xF78A6E), // Coral
        color(hex: 0x9CBE7C), // Sage
        color(hex: 0x71B5AF), // Teal
        color(hex: 0xC9AAEF), // Lavender
        color(hex: 0xD4AD6F), // Amber
        color(hex: 0xE58AA8), // Rose
        color(hex: 0x75B9D1), // Sky
    ]

    static var count: Int { colors.count }

    static func color(for tag: CardTag, selected: Bool) -> NSColor {
        let index = tag.paletteIndex(paletteCount: colors.count) ?? 0
        let base = colors[index]
        return base.blended(
            withFraction: selected ? 0.05 : 0,
            of: NSColor.white
        ) ?? base
    }

    static func accent(
        for tag: CardTag,
        selected: Bool,
        appearance: ResolvedAppearance
    ) -> NSColor {
        let base = color(for: tag, selected: selected)
        guard appearance == .light else { return base }
        return base.blended(withFraction: 0.24, of: NSColor.black) ?? base
    }

    private static func color(hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

@MainActor
final class CurtainTagStripView: NSView, AppearanceConsumer {
    var onSelectionChange: ((CardTag?) -> Void)?
    var onRemoveTag: ((CardTag) -> Void)?

    private let scrollView = NSScrollView()
    private let documentView = CurtainTagDocumentView()
    private var orderedTags: [CardTag] = []
    private var buttonsByID: [String: CurtainTagButton] = [:]
    private(set) var activeTagID: String?
    private var resolvedAppearance: ResolvedAppearance = .dark

    var tags: [CardTag] { orderedTags }
    var tagButtons: [CurtainTagButton] {
        orderedTags.compactMap { buttonsByID[$0.id] }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CurtainTagMetrics.hitHeight)
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
        wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .automatic
        scrollView.verticalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.documentView = documentView
        addSubview(scrollView)
    }

    func update(tags: [CardTag], activeTagID: String?, animated: Bool) {
        let validActiveID = activeTagID.flatMap { candidate in
            tags.contains(where: { $0.id == candidate }) ? candidate : nil
        }
        let incomingIDs = Set(tags.map(\.id))

        for (id, button) in buttonsByID where !incomingIDs.contains(id) {
            button.removeFromSuperview()
            buttonsByID[id] = nil
        }

        for tag in tags {
            guard let button = buttonsByID[tag.id], button.cardTag != tag else { continue }
            button.removeFromSuperview()
            buttonsByID[tag.id] = nil
        }

        var addedIDs = Set<String>()
        for tag in tags where buttonsByID[tag.id] == nil {
            let button = CurtainTagButton(tag: tag)
            button.onActivate = { [weak self] tag in
                guard let self else { return }
                self.onSelectionChange?(self.activeTagID == tag.id ? nil : tag)
            }
            button.onRemove = { [weak self] tag in self?.onRemoveTag?(tag) }
            button.apply(resolvedAppearance: resolvedAppearance)
            buttonsByID[tag.id] = button
            documentView.addSubview(button)
            addedIDs.insert(tag.id)
        }

        orderedTags = tags
        self.activeTagID = validActiveID
        documentView.orderedButtons = tagButtons
        needsLayout = true
        layoutSubtreeIfNeeded()

        for tag in tags {
            buttonsByID[tag.id]?.setSelected(
                tag.id == validActiveID,
                animated: animated && !addedIDs.contains(tag.id)
            )
        }
        scrollActiveTagToVisible()
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        self.resolvedAppearance = resolvedAppearance
        tagButtons.forEach { $0.apply(resolvedAppearance: resolvedAppearance) }
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        documentView.layoutButtons(minimumWidth: scrollView.contentSize.width)
        scrollActiveTagToVisible()
    }

    private func scrollActiveTagToVisible() {
        guard let activeTagID, let button = buttonsByID[activeTagID] else { return }
        documentView.scrollToVisible(button.frame.insetBy(dx: -4, dy: 0))
    }
}

@MainActor
final class CurtainTagButton: NSButton, AppearanceConsumer {
    static let labelFont = NSFont.monospacedSystemFont(
        ofSize: CurtainTagMetrics.fontSize,
        weight: .medium
    )

    let cardTag: CardTag
    var onActivate: ((CardTag) -> Void)?
    var onRemove: ((CardTag) -> Void)?

    let tagLabel = PassthroughTagLabel(labelWithString: "")
    let outlineLayer = CAShapeLayer()
    let underlineLayer = CAShapeLayer()
    private var trackingAreaReference: NSTrackingArea?
    private var resolvedAppearance: ResolvedAppearance = .dark
    private var isHovering = false
    private var isPressed = false
    private(set) var isTagSelected = false

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: CurtainTagMetrics.width(for: cardTag.name),
            height: CurtainTagMetrics.hitHeight
        )
    }

    override var isEnabled: Bool {
        didSet { updateColors() }
    }

    init(tag: CardTag) {
        cardTag = tag
        super.init(frame: .zero)

        title = ""
        isBordered = false
        imagePosition = .noImage
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        target = self
        action = #selector(activateTag(_:))
        setAccessibilityLabel(tag.name)
        setAccessibilityRole(.button)
        setAccessibilityValue("Not selected")
        toolTip = CurtainTagMetrics.width(for: tag.name) >= CurtainTagMetrics.maximumWidth
            ? tag.name
            : nil

        let contextMenu = NSMenu(title: tag.name)
        let removeItem = NSMenuItem(
            title: "Remove Tag",
            action: #selector(removeTag(_:)),
            keyEquivalent: ""
        )
        removeItem.target = self
        contextMenu.addItem(removeItem)
        menu = contextMenu

        wantsLayer = true
        outlineLayer.actions = [
            "path": NSNull(),
            "fillColor": NSNull(),
            "strokeColor": NSNull(),
            "lineWidth": NSNull(),
            "opacity": NSNull(),
        ]
        underlineLayer.actions = [
            "path": NSNull(),
            "strokeColor": NSNull(),
            "opacity": NSNull(),
        ]
        underlineLayer.fillColor = nil
        underlineLayer.lineWidth = CurtainTagMetrics.underlineHeight
        underlineLayer.lineCap = .butt
        underlineLayer.opacity = 0
        layer?.addSublayer(outlineLayer)
        layer?.addSublayer(underlineLayer)

        tagLabel.stringValue = tag.name
        tagLabel.font = Self.labelFont
        tagLabel.alignment = .center
        tagLabel.lineBreakMode = .byTruncatingTail
        tagLabel.maximumNumberOfLines = 1
        tagLabel.drawsBackground = false
        addSubview(tagLabel)

        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setSelected(_ selected: Bool, animated: Bool) {
        guard selected != isTagSelected else { return }
        isTagSelected = selected
        state = selected ? .on : .off
        setAccessibilityValue(selected ? "Selected" : "Not selected")
        updateColors()
        updateSelectionIndicator(animated: animated)
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        self.resolvedAppearance = resolvedAppearance
        updateColors()
    }

    override func layout() {
        super.layout()
        outlineLayer.frame = bounds
        underlineLayer.frame = bounds
        tagLabel.frame = NSRect(
            x: CurtainTagMetrics.horizontalPadding,
            y: floor((bounds.height - CurtainTagMetrics.chipHeight) / 2),
            width: max(0, bounds.width - CurtainTagMetrics.horizontalPadding * 2),
            height: CurtainTagMetrics.chipHeight
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outlineLayer.path = outlinePath()
        underlineLayer.path = underlinePath()
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateColors()
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        isPressed = flag
        updateColors()
    }

    @objc private func activateTag(_ sender: Any?) {
        onActivate?(cardTag)
    }

    @objc private func removeTag(_ sender: Any?) {
        onRemove?(cardTag)
    }

    private func updateColors() {
        let accent = CurtainTagPalette.accent(
            for: cardTag,
            selected: isTagSelected,
            appearance: resolvedAppearance
        )
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let outlineAlpha: CGFloat = highContrast
            ? 1
            : (isTagSelected ? 0.92 : (isHovering ? 0.78 : 0.58))
        let labelAlpha: CGFloat = highContrast
            ? 1
            : (isTagSelected ? 1 : (isHovering ? 0.92 : 0.80))
        let fillAlpha: CGFloat
        if isPressed {
            fillAlpha = 0.12
        } else if isHovering {
            fillAlpha = 0.07
        } else {
            fillAlpha = 0
        }

        outlineLayer.fillColor = accent.withAlphaComponent(fillAlpha).cgColor
        outlineLayer.strokeColor = accent.withAlphaComponent(outlineAlpha).cgColor
        outlineLayer.lineWidth = isTagSelected
            ? CurtainTagMetrics.selectedOutlineWidth
            : CurtainTagMetrics.outlineWidth
        underlineLayer.strokeColor = accent.cgColor
        tagLabel.textColor = accent.withAlphaComponent(labelAlpha)
        tagLabel.font = NSFont.monospacedSystemFont(
            ofSize: CurtainTagMetrics.fontSize,
            weight: isTagSelected ? .semibold : .medium
        )
        tagLabel.needsDisplay = true
        alphaValue = isEnabled ? 1 : 0.42
    }

    private func updateSelectionIndicator(animated: Bool) {
        guard bounds.width > 0, bounds.height > 0 else {
            needsLayout = true
            return
        }
        let targetOpacity: Float = isTagSelected ? 1 : 0
        let sourceOpacity = underlineLayer.presentation()?.opacity ?? underlineLayer.opacity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        underlineLayer.opacity = targetOpacity
        CATransaction.commit()

        guard animated,
              window?.isVisible == true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = sourceOpacity
        fade.toValue = targetOpacity
        fade.duration = 0.13
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        underlineLayer.add(fade, forKey: "selectionUnderline")
    }

    private func chipRect() -> CGRect {
        let y = floor((bounds.height - CurtainTagMetrics.chipHeight) / 2)
        return CGRect(
            x: 0.75,
            y: y + 0.75,
            width: max(0, bounds.width - 1.5),
            height: max(0, CurtainTagMetrics.chipHeight - 1.5)
        )
    }

    private func outlinePath() -> CGPath {
        CGPath(
            roundedRect: chipRect(),
            cornerWidth: CurtainTagMetrics.cornerRadius,
            cornerHeight: CurtainTagMetrics.cornerRadius,
            transform: nil
        )
    }

    private func underlinePath() -> CGPath {
        let chip = chipRect()
        let y = chip.maxY - 2.25
        let path = CGMutablePath()
        path.move(to: CGPoint(x: chip.minX + CurtainTagMetrics.underlineInset, y: y))
        path.addLine(to: CGPoint(x: chip.maxX - CurtainTagMetrics.underlineInset, y: y))
        return path
    }
}

@MainActor
final class PassthroughTagLabel: NSTextField {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let font, let textColor else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let textRect = NSRect(
            x: 0,
            y: floor((bounds.height - lineHeight) / 2) - 1,
            width: bounds.width,
            height: lineHeight + 2
        )
        (stringValue as NSString).draw(
            in: textRect,
            withAttributes: [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraph,
            ]
        )
    }
}

@MainActor
private final class CurtainTagDocumentView: NSView {
    var orderedButtons: [CurtainTagButton] = []

    override var isFlipped: Bool { true }

    func layoutButtons(minimumWidth: CGFloat) {
        var x: CGFloat = 0
        for button in orderedButtons {
            let width = button.intrinsicContentSize.width
            button.frame = NSRect(
                x: x,
                y: 0,
                width: width,
                height: CurtainTagMetrics.hitHeight
            )
            x += width + CurtainTagMetrics.spacing
        }
        if !orderedButtons.isEmpty { x -= CurtainTagMetrics.spacing }
        frame.size = NSSize(
            width: max(minimumWidth, ceil(x)),
            height: CurtainTagMetrics.hitHeight
        )
    }
}
