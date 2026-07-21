import AppKit
import Foundation
import MarkdownCardCore
import QuartzCore

struct SlashCommandMenuItem: Equatable, Sendable {
    static let maximumIdentifierUTF8Count = 64
    static let maximumTitleUTF8Count = 256
    static let maximumDescriptionUTF8Count = 512

    let id: String
    let title: String
    let description: String

    init(id: String, title: String, description: String) {
        self.id = id
        self.title = title
        self.description = description
    }

    init?(payload: [String: Any]) {
        guard let id = payload["id"] as? String,
              !id.isEmpty,
              id.utf8.count <= Self.maximumIdentifierUTF8Count,
              id.utf8.allSatisfy(Self.isAllowedIdentifierByte),
              let title = payload["title"] as? String,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= Self.maximumTitleUTF8Count,
              let description = payload["description"] as? String,
              description.utf8.count <= Self.maximumDescriptionUTF8Count
        else { return nil }

        self.init(id: id, title: title, description: description)
    }

    private static func isAllowedIdentifierByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 48 ... 57, 65 ... 90, 97 ... 122, 45, 46, 95:
            true
        default:
            false
        }
    }
}

struct SlashCommandMenuState: Equatable, Sendable {
    static let maximumItemCount = 16
    private static let maximumAnchorMagnitude: Double = 1_000_000

    let visible: Bool
    let items: [SlashCommandMenuItem]
    let selectedIndex: Int
    /// CSS viewport X coordinate. The renderer reports this from `coordsAtPos`.
    let anchorLeft: CGFloat
    /// CSS viewport Y coordinate for the caret's upper edge.
    let anchorTop: CGFloat
    /// CSS viewport Y coordinate for the caret's lower edge.
    let anchorBottom: CGFloat

    init(
        visible: Bool,
        items: [SlashCommandMenuItem] = [],
        selectedIndex: Int = 0,
        anchorLeft: CGFloat = 0,
        anchorTop: CGFloat = 0,
        anchorBottom: CGFloat = 0
    ) {
        self.visible = visible
        self.items = items
        self.selectedIndex = selectedIndex
        self.anchorLeft = anchorLeft
        self.anchorTop = anchorTop
        self.anchorBottom = anchorBottom
    }

    /// Strictly parses a WebKit message payload. A hidden presentation may be
    /// represented by only `visible: false`; a visible presentation must carry
    /// a non-empty, bounded item list, an in-range integer selection, and the
    /// caret anchor as `anchor: { left, top, bottom }`.
    init?(payload: [String: Any]) {
        guard let visible = SlashCommandPayload.boolean(payload["visible"]) else { return nil }
        guard visible else {
            self.init(visible: false)
            return
        }

        guard let rawItems = payload["items"] as? [[String: Any]],
              !rawItems.isEmpty,
              rawItems.count <= Self.maximumItemCount
        else { return nil }
        let items = rawItems.compactMap(SlashCommandMenuItem.init(payload:))
        guard items.count == rawItems.count,
              Set(items.map(\.id)).count == items.count,
              let selectedIndex = SlashCommandPayload.integer(payload["selectedIndex"]),
              items.indices.contains(selectedIndex),
              let anchor = payload["anchor"] as? [String: Any],
              let left = SlashCommandPayload.finiteDouble(anchor["left"]),
              let top = SlashCommandPayload.finiteDouble(anchor["top"]),
              let bottom = SlashCommandPayload.finiteDouble(anchor["bottom"]),
              abs(left) <= Self.maximumAnchorMagnitude,
              abs(top) <= Self.maximumAnchorMagnitude,
              abs(bottom) <= Self.maximumAnchorMagnitude,
              bottom >= top
        else { return nil }

        self.init(
            visible: true,
            items: items,
            selectedIndex: selectedIndex,
            anchorLeft: CGFloat(left),
            anchorTop: CGFloat(top),
            anchorBottom: CGFloat(bottom)
        )
    }
}

private enum SlashCommandPayload {
    static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    static func finiteDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    static func integer(_ value: Any?) -> Int? {
        guard let number = finiteDouble(value),
              number.rounded(.towardZero) == number,
              number >= Double(Int.min),
              number <= Double(Int.max)
        else { return nil }
        return Int(number)
    }
}

/// A caret anchor expressed in AppKit screen coordinates. Screen Y increases
/// upward, so `top` is always greater than or equal to `bottom`.
struct SlashCommandScreenAnchor: Equatable, Sendable {
    let left: CGFloat
    let top: CGFloat
    let bottom: CGFloat

    init(left: CGFloat, top: CGFloat, bottom: CGFloat) {
        self.left = left
        self.top = max(top, bottom)
        self.bottom = min(top, bottom)
    }
}

enum SlashCommandPanelLayout {
    static let gap: CGFloat = 6
    static let screenMargin: CGFloat = 8

    /// Returns a frame constrained only by the screen's visible frame. It does
    /// not take the parent card frame, which deliberately allows the menu to
    /// extend beyond the card. The menu prefers the caret's lower side and
    /// flips above it whenever the lower side cannot fit but the upper side can.
    static func frame(
        anchor: SlashCommandScreenAnchor,
        panelSize: NSSize,
        visibleFrame: NSRect,
        gap: CGFloat = Self.gap,
        screenMargin: CGFloat = Self.screenMargin
    ) -> NSRect {
        guard visibleFrame.width.isFinite,
              visibleFrame.height.isFinite,
              visibleFrame.width > 0,
              visibleFrame.height > 0
        else { return NSRect(origin: .zero, size: panelSize) }

        let margin = max(0, min(screenMargin, min(visibleFrame.width, visibleFrame.height) / 2))
        let usableFrame = visibleFrame.insetBy(dx: margin, dy: margin)
        let width = min(max(1, panelSize.width), max(1, usableFrame.width))
        let height = min(max(1, panelSize.height), max(1, usableFrame.height))
        let effectiveGap = max(0, gap)

        let roomBelow = anchor.bottom - effectiveGap - usableFrame.minY
        let roomAbove = usableFrame.maxY - anchor.top - effectiveGap
        let placeBelow: Bool
        if roomBelow >= height {
            placeBelow = true
        } else if roomAbove >= height {
            placeBelow = false
        } else {
            placeBelow = roomBelow >= roomAbove
        }

        let desiredY = placeBelow
            ? anchor.bottom - effectiveGap - height
            : anchor.top + effectiveGap
        let maximumX = usableFrame.maxX - width
        let maximumY = usableFrame.maxY - height
        let x = min(max(anchor.left, usableFrame.minX), maximumX)
        let y = min(max(desiredY, usableFrame.minY), maximumY)
        return NSRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor
final class SlashCommandMenuController: AppearanceConsumer {
    static let preferredWidth: CGFloat = 310
    static let itemHeight: CGFloat = 46
    static let contentPadding: CGFloat = 5

    var onChoose: ((String) -> Void)?

    private(set) weak var parentWindow: NSWindow?
    private(set) var state: SlashCommandMenuState?
    var panel: NSPanel { menuPanel }

    private weak var anchorView: NSView?
    private let menuPanel: SlashCommandMenuPanel
    private let surfaceView: SlashCommandMenuSurface
    private var resolvedAppearance: ResolvedAppearance = .dark

    init() {
        surfaceView = SlashCommandMenuSurface()
        menuPanel = SlashCommandMenuPanel(contentView: surfaceView)
        surfaceView.onChoose = { [weak self] identifier in
            self?.onChoose?(identifier)
        }
        apply(resolvedAppearance: resolvedAppearance)
    }

    func update(state: SlashCommandMenuState, relativeTo view: NSView) {
        self.state = state
        anchorView = view
        guard state.visible, !state.items.isEmpty, let window = view.window else {
            hide()
            return
        }

        attach(to: window)
        surfaceView.update(
            items: state.items,
            selectedIndex: state.selectedIndex,
            resolvedAppearance: resolvedAppearance
        )
        let size = preferredPanelSize(for: state.items.count)
        menuPanel.setContentSize(size)
        guard layoutPanel() else {
            hide()
            return
        }
        menuPanel.orderFront(nil)
    }

    func updateLayout() {
        guard layoutPanel() else {
            hide()
            return
        }
    }

    private func layoutPanel() -> Bool {
        guard let state,
              state.visible,
              let anchorView,
              let parentWindow,
              anchorView.window === parentWindow,
              !anchorView.isHiddenOrHasHiddenAncestor
        else { return false }
        let visibleFrame = parentWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? parentWindow.frame.insetBy(dx: -Self.preferredWidth, dy: -1_000)

        // A caret wholly outside the Web view's viewport should not leave a
        // detached menu pinned to a screen edge. The menu itself may still
        // extend freely beyond the parent card once the caret is visible.
        let viewportHeight = anchorView.bounds.height
        guard state.anchorBottom >= 0, state.anchorTop <= viewportHeight else { return false }

        let topPoint = screenPoint(
            cssX: state.anchorLeft,
            cssY: state.anchorTop,
            relativeTo: anchorView,
            in: parentWindow
        )
        let bottomPoint = screenPoint(
            cssX: state.anchorLeft,
            cssY: state.anchorBottom,
            relativeTo: anchorView,
            in: parentWindow
        )
        let anchor = SlashCommandScreenAnchor(
            left: min(topPoint.x, bottomPoint.x),
            top: max(topPoint.y, bottomPoint.y),
            bottom: min(topPoint.y, bottomPoint.y)
        )
        let targetFrame = SlashCommandPanelLayout.frame(
            anchor: anchor,
            panelSize: preferredPanelSize(for: state.items.count),
            visibleFrame: visibleFrame
        )
        menuPanel.setFrame(targetFrame, display: menuPanel.isVisible)
        return true
    }

    func hide() {
        menuPanel.orderOut(nil)
    }

    func detach() {
        if let parentWindow {
            parentWindow.removeChildWindow(menuPanel)
        }
        hide()
        parentWindow = nil
        anchorView = nil
        state = nil
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        self.resolvedAppearance = resolvedAppearance
        surfaceView.apply(resolvedAppearance: resolvedAppearance)
    }

    private func attach(to window: NSWindow) {
        guard parentWindow !== window else { return }
        if let parentWindow {
            parentWindow.removeChildWindow(menuPanel)
        }
        menuPanel.orderOut(nil)
        parentWindow = window
        window.addChildWindow(menuPanel, ordered: .above)
    }

    private func preferredPanelSize(for itemCount: Int) -> NSSize {
        NSSize(
            width: Self.preferredWidth,
            height: Self.contentPadding * 2 + CGFloat(itemCount) * Self.itemHeight
        )
    }

    private func screenPoint(
        cssX: CGFloat,
        cssY: CGFloat,
        relativeTo view: NSView,
        in window: NSWindow
    ) -> NSPoint {
        let localPoint = NSPoint(
            x: view.bounds.minX + cssX,
            y: view.isFlipped
                ? view.bounds.minY + cssY
                : view.bounds.maxY - cssY
        )
        let windowPoint = view.convert(localPoint, to: nil)
        return window.convertPoint(toScreen: windowPoint)
    }
}

@MainActor
private final class SlashCommandMenuPanel: NSPanel {
    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(
                    width: SlashCommandMenuController.preferredWidth,
                    height: SlashCommandMenuController.contentPadding * 2
                )
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = false
        self.contentView = contentView
        setAccessibilityLabel("Slash command menu")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class SlashCommandMenuSurface: NSView, AppearanceConsumer {
    var onChoose: ((String) -> Void)?

    private var buttons: [SlashCommandMenuButton] = []
    private var resolvedAppearance: ResolvedAppearance = .dark

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        apply(resolvedAppearance: resolvedAppearance)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Slash commands")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        items: [SlashCommandMenuItem],
        selectedIndex: Int,
        resolvedAppearance: ResolvedAppearance
    ) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = items.enumerated().map { index, item in
            let button = SlashCommandMenuButton(item: item)
            button.isMenuSelected = index == selectedIndex
            button.onChoose = { [weak self] identifier in
                self?.onChoose?(identifier)
            }
            button.apply(resolvedAppearance: resolvedAppearance)
            addSubview(button)
            return button
        }
        needsLayout = true
        setAccessibilityChildren(buttons)
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        self.resolvedAppearance = resolvedAppearance
        layer?.backgroundColor = MonochromePalette.windowBackground(
            for: resolvedAppearance
        ).cgColor
        layer?.borderColor = MonochromePalette.border(for: resolvedAppearance).cgColor
        layer?.borderWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1.5 : 1
        buttons.forEach { $0.apply(resolvedAppearance: resolvedAppearance) }
    }

    override func layout() {
        super.layout()
        let padding = SlashCommandMenuController.contentPadding
        let itemHeight = SlashCommandMenuController.itemHeight
        let width = max(0, bounds.width - padding * 2)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(
                x: padding,
                y: padding + CGFloat(index) * itemHeight,
                width: width,
                height: itemHeight
            )
        }
    }
}

@MainActor
private final class SlashCommandMenuButton: NSButton, AppearanceConsumer {
    let item: SlashCommandMenuItem
    var onChoose: ((String) -> Void)?
    var isMenuSelected = false {
        didSet {
            setAccessibilityValue(isMenuSelected ? "Selected" : "Not selected")
            updateBackground()
        }
    }

    private let commandTitleLabel = SlashCommandPassthroughLabel(labelWithString: "")
    private let commandDescriptionLabel = SlashCommandPassthroughLabel(labelWithString: "")
    private var resolvedAppearance: ResolvedAppearance = .dark
    private var trackingAreaReference: NSTrackingArea?
    private var isHovering = false
    private var isPressed = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(item: SlashCommandMenuItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        isBordered = false
        title = ""
        focusRingType = .none
        setButtonType(.momentaryChange)
        target = self
        action = #selector(choose(_:))

        commandTitleLabel.stringValue = item.title
        commandTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        commandTitleLabel.lineBreakMode = .byTruncatingTail
        commandDescriptionLabel.stringValue = item.description
        commandDescriptionLabel.font = .systemFont(ofSize: 11, weight: .regular)
        commandDescriptionLabel.lineBreakMode = .byTruncatingTail
        addSubview(commandTitleLabel)
        addSubview(commandDescriptionLabel)

        setAccessibilityLabel(
            item.description.isEmpty ? item.title : "\(item.title), \(item.description)"
        )
        toolTip = item.description.isEmpty ? item.title : "\(item.title) — \(item.description)"
        apply(resolvedAppearance: resolvedAppearance)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(resolvedAppearance: ResolvedAppearance) {
        self.resolvedAppearance = resolvedAppearance
        commandTitleLabel.textColor = MonochromePalette.primaryText(for: resolvedAppearance)
        commandDescriptionLabel.textColor = MonochromePalette.tertiaryText(
            for: resolvedAppearance
        )
        updateBackground()
    }

    override func layout() {
        super.layout()
        let horizontalInset: CGFloat = 10
        let width = max(0, bounds.width - horizontalInset * 2)
        commandTitleLabel.frame = NSRect(x: horizontalInset, y: 6, width: width, height: 16)
        commandDescriptionLabel.frame = NSRect(
            x: horizontalInset,
            y: 24,
            width: width,
            height: 14
        )
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
        isHovering = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateBackground()
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        isPressed = flag
        updateBackground()
    }

    @objc private func choose(_ sender: Any?) {
        onChoose?(item.id)
    }

    private func updateBackground() {
        let alpha: CGFloat
        if isPressed {
            alpha = 0.42
        } else if isMenuSelected {
            alpha = 0.32
        } else if isHovering {
            alpha = 0.18
        } else {
            alpha = 0
        }
        layer?.backgroundColor = MonochromePalette.selection(
            for: resolvedAppearance
        ).withAlphaComponent(alpha).cgColor
    }
}

@MainActor
private final class SlashCommandPassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
