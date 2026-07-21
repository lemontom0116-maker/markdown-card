import AppKit
import MarkdownCardCore
import QuartzCore

enum SeriesNavigationDirection: Hashable, Sendable {
    case newer
    case older

    var symbolName: String {
        switch self {
        case .newer: "chevron.backward.2"
        case .older: "chevron.forward.2"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .newer: "Newer card in series"
        case .older: "Older card in series"
        }
    }
}

@MainActor
final class BareSeriesNavigationControl: NSView, AppearanceConsumer {
    static let buttonSize = NSSize(width: 32, height: 44)
    static let spacing: CGFloat = 8

    var onNavigate: ((SeriesNavigationDirection) -> Void)?

    let newerButton = BareSeriesNavigationButton(direction: .newer)
    let olderButton = BareSeriesNavigationButton(direction: .older)

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: Self.buttonSize.width * 2 + Self.spacing,
            height: Self.buttonSize.height
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        newerButton.onNavigate = { [weak self] in self?.onNavigate?(.newer) }
        olderButton.onNavigate = { [weak self] in self?.onNavigate?(.older) }
        addSubview(newerButton)
        addSubview(olderButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(canNavigateNewer: Bool, canNavigateOlder: Bool) {
        newerButton.isEnabled = canNavigateNewer
        olderButton.isEnabled = canNavigateOlder
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        newerButton.apply(resolvedAppearance: resolvedAppearance)
        olderButton.apply(resolvedAppearance: resolvedAppearance)
    }

    override func layout() {
        super.layout()
        let y = floor((bounds.height - Self.buttonSize.height) / 2)
        newerButton.frame = NSRect(
            x: 0,
            y: y,
            width: Self.buttonSize.width,
            height: Self.buttonSize.height
        )
        olderButton.frame = NSRect(
            x: bounds.width - Self.buttonSize.width,
            y: y,
            width: Self.buttonSize.width,
            height: Self.buttonSize.height
        )
    }
}

@MainActor
final class BareSeriesNavigationButton: NSButton, AppearanceConsumer {
    static let defaultOpacity: CGFloat = 0.64
    static let hoverOpacity: CGFloat = 0.95
    static let pressedOpacity: CGFloat = 0.72
    static let disabledOpacity: CGFloat = 0.22

    let direction: SeriesNavigationDirection
    var onNavigate: (() -> Void)?

    private var resolvedAppearance: ResolvedAppearance = .dark
    private var trackingAreaReference: NSTrackingArea?
    private var isHovering = false
    private var isPressed = false

    override var intrinsicContentSize: NSSize { BareSeriesNavigationControl.buttonSize }

    override var isEnabled: Bool {
        didSet { updateOpacity() }
    }

    init(direction: SeriesNavigationDirection) {
        self.direction = direction
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        target = self
        action = #selector(navigate(_:))
        setAccessibilityLabel(direction.accessibilityLabel)
        toolTip = direction.accessibilityLabel
        image = NSImage(
            systemSymbolName: direction.symbolName,
            accessibilityDescription: direction.accessibilityLabel
        )
        image?.isTemplate = true
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        apply(resolvedAppearance: resolvedAppearance)
        updateOpacity()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func apply(resolvedAppearance: ResolvedAppearance) {
        self.resolvedAppearance = resolvedAppearance
        contentTintColor = MonochromePalette.secondaryText(for: resolvedAppearance)
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
        updateOpacity()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateOpacity()
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        isPressed = flag
        updateOpacity()
    }

    @objc private func navigate(_ sender: Any?) {
        guard isEnabled else { return }
        onNavigate?()
    }

    private func updateOpacity() {
        if !isEnabled {
            alphaValue = Self.disabledOpacity
        } else if isPressed {
            alphaValue = Self.pressedOpacity
        } else if isHovering {
            alphaValue = Self.hoverOpacity
        } else {
            alphaValue = Self.defaultOpacity
        }
    }
}

/// Owns the two transparent, non-activating child panels used beside a card.
/// Keeping this positioning concern separate lets the same bare button be used
/// by other card and library presentations.
@MainActor
final class ExternalSeriesNavigationController: AppearanceConsumer {
    static let gap: CGFloat = 8

    var onNavigate: ((SeriesNavigationDirection) -> Void)?

    private(set) weak var parentWindow: NSWindow?
    private let newerPanel: SeriesNavigationPanel
    private let olderPanel: SeriesNavigationPanel
    private var shouldBeVisible = false

    var panels: [NSPanel] { [newerPanel, olderPanel] }

    init() {
        newerPanel = SeriesNavigationPanel(direction: .newer)
        olderPanel = SeriesNavigationPanel(direction: .older)
        newerPanel.navigationButton.onNavigate = { [weak self] in
            self?.onNavigate?(.newer)
        }
        olderPanel.navigationButton.onNavigate = { [weak self] in
            self?.onNavigate?(.older)
        }
    }

    func attach(to parentWindow: NSWindow) {
        guard self.parentWindow !== parentWindow else {
            updateLayout()
            return
        }
        detach()
        self.parentWindow = parentWindow
        parentWindow.addChildWindow(newerPanel, ordered: .above)
        parentWindow.addChildWindow(olderPanel, ordered: .above)
        updateLayout()
        applyVisibility(animated: false)
    }

    func detach() {
        if let parentWindow {
            parentWindow.removeChildWindow(newerPanel)
            parentWindow.removeChildWindow(olderPanel)
        }
        newerPanel.orderOut(nil)
        olderPanel.orderOut(nil)
        parentWindow = nil
    }

    func update(canNavigateNewer: Bool, canNavigateOlder: Bool) {
        newerPanel.navigationButton.isEnabled = canNavigateNewer
        olderPanel.navigationButton.isEnabled = canNavigateOlder
    }

    func setVisible(_ visible: Bool, animated: Bool) {
        guard shouldBeVisible != visible else { return }
        shouldBeVisible = visible
        applyVisibility(animated: animated)
    }

    func updateLayout() {
        guard let parentWindow else { return }
        let parentFrame = parentWindow.frame
        let visibleFrame = parentWindow.screen?.visibleFrame
        let size = BareSeriesNavigationControl.buttonSize
        let y = parentFrame.midY - size.height / 2
        var leftX = parentFrame.minX - Self.gap - size.width
        var rightX = parentFrame.maxX + Self.gap

        // At a screen edge the symbols may overlap the card slightly; never
        // move the user's card merely to make room for navigation chrome.
        if let visibleFrame {
            leftX = max(visibleFrame.minX, leftX)
            rightX = min(visibleFrame.maxX - size.width, rightX)
        }
        newerPanel.setFrame(
            NSRect(x: leftX, y: y, width: size.width, height: size.height),
            display: false
        )
        olderPanel.setFrame(
            NSRect(x: rightX, y: y, width: size.width, height: size.height),
            display: false
        )
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        newerPanel.navigationButton.apply(resolvedAppearance: resolvedAppearance)
        olderPanel.navigationButton.apply(resolvedAppearance: resolvedAppearance)
    }

    private func applyVisibility(animated: Bool) {
        guard parentWindow != nil else { return }
        let targetAlpha: CGFloat = shouldBeVisible ? 1 : 0
        let duration = animated ? 0.14 : 0
        newerPanel.ignoresMouseEvents = !shouldBeVisible
        olderPanel.ignoresMouseEvents = !shouldBeVisible

        if shouldBeVisible {
            newerPanel.alphaValue = duration > 0 ? 0 : 1
            olderPanel.alphaValue = duration > 0 ? 0 : 1
            newerPanel.orderFront(nil)
            olderPanel.orderFront(nil)
        }

        let changes = { [newerPanel, olderPanel] in
            newerPanel.animator().alphaValue = targetAlpha
            olderPanel.animator().alphaValue = targetAlpha
        }
        guard duration > 0 else {
            newerPanel.alphaValue = targetAlpha
            olderPanel.alphaValue = targetAlpha
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            changes()
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.shouldBeVisible else { return }
                self.newerPanel.alphaValue = 0
                self.olderPanel.alphaValue = 0
            }
        }
    }
}

@MainActor
private final class SeriesNavigationPanel: NSPanel {
    let navigationButton: BareSeriesNavigationButton

    init(direction: SeriesNavigationDirection) {
        navigationButton = BareSeriesNavigationButton(direction: direction)
        super.init(
            contentRect: NSRect(origin: .zero, size: BareSeriesNavigationControl.buttonSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = false

        let surface = NSView(frame: NSRect(origin: .zero, size: BareSeriesNavigationControl.buttonSize))
        surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor.clear.cgColor
        navigationButton.frame = surface.bounds
        navigationButton.autoresizingMask = [.width, .height]
        surface.addSubview(navigationButton)
        contentView = surface
        setAccessibilityLabel(direction.accessibilityLabel)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
