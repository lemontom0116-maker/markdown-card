import AppKit
import MarkdownCardCore

/// Owns the small, non-activating affordance shown while all card windows are folded.
///
/// The controller intentionally knows nothing about the fold session itself. Its only
/// responsibility is presenting the current count and returning a restore request to
/// the application controller.
@MainActor
final class FoldedCardStackWindowController: NSWindowController, AppearanceConsumer {
    nonisolated static let placementDefaultsKey = "foldedCardStack.placement.v1"

    var onRestore: (() -> Void)?

    private enum Constants {
        static let size = NSSize(width: 48, height: 48)
        static let screenInset: CGFloat = 16
        static let dragThreshold: CGFloat = 6
        static let standardAnimationDuration: TimeInterval = 0.13
        static let reducedMotionAnimationDuration: TimeInterval = 0.06
    }

    private let appearanceController: AppearanceController
    private let defaults: UserDefaults
    private let stackView = FoldedCardStackContentView()
    private var cardCount = 0
    private var animationGeneration = 0
    private var hasResolvedInitialPlacement = false

    init(appearanceController: AppearanceController, defaults: UserDefaults = .standard) {
        self.appearanceController = appearanceController
        self.defaults = defaults

        let panel = FoldedCardStackPanel(
            contentRect: NSRect(origin: .zero, size: Constants.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)

        configure(panel)
        appearanceController.register(self)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    /// Shows the stack on its persisted display, or on `screen` the first time.
    func show(count: Int, on screen: NSScreen?, animated: Bool) {
        updateCount(count)
        guard cardCount > 0 else {
            hide(animated: animated)
            return
        }

        resolvePlacementIfNeeded(preferredScreen: screen)
        reveal(animated: animated)
    }

    /// Hides the affordance without discarding its count or placement.
    func hide(animated: Bool) {
        guard let panel = window, panel.isVisible else { return }
        animationGeneration &+= 1
        let generation = animationGeneration
        let duration = transitionDuration(animated: animated)

        guard duration > 0 else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, animationGeneration == generation else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        }
    }

    /// Updates the visible badge, tooltip, and accessibility value.
    func updateCount(_ count: Int) {
        cardCount = max(0, count)
        stackView.updateCount(cardCount)
        window?.setAccessibilityValue(stackView.accessibilityValue())
        if cardCount == 0, window?.isVisible == true {
            hide(animated: true)
        }
    }

    /// Re-shows a previously hidden stack, for example after the login session unlocks.
    func reveal() {
        guard cardCount > 0 else { return }
        resolvePlacementIfNeeded(preferredScreen: nil)
        reveal(animated: true)
    }

    /// Keeps the stack reachable after a display is removed or its geometry changes.
    func constrainToAvailableScreens() {
        guard hasResolvedInitialPlacement, let panel = window else { return }
        let screens = NSScreen.screens
        guard let target = Self.bestScreen(for: panel.frame, in: screens) ?? NSScreen.main else {
            return
        }
        let constrained = Self.constrained(panel.frame, to: target.visibleFrame)
        panel.setFrame(constrained, display: panel.isVisible)
        persist(frame: constrained, screen: target)
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        guard let panel = window else { return }
        appearanceController.applyMode(to: panel)
        stackView.apply(resolvedAppearance: resolvedAppearance)
    }

    static func defaultFrame(in visibleFrame: NSRect) -> NSRect {
        constrained(
            NSRect(
                x: visibleFrame.maxX - Constants.screenInset - Constants.size.width,
                y: visibleFrame.minY + Constants.screenInset,
                width: Constants.size.width,
                height: Constants.size.height
            ),
            to: visibleFrame
        )
    }

    static func constrained(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        var result = NSRect(origin: frame.origin, size: Constants.size)
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - result.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - result.height)
        result.origin.x = min(max(result.minX, visibleFrame.minX), maximumX)
        result.origin.y = min(max(result.minY, visibleFrame.minY), maximumY)
        return result
    }

    static func exceededDragThreshold(from start: NSPoint, to end: NSPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) >= Constants.dragThreshold
    }

    private func configure(_ panel: FoldedCardStackPanel) {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
        panel.contentView = stackView
        panel.setAccessibilityRole(.window)
        panel.setAccessibilityLabel("Folded card stack")

        stackView.onActivate = { [weak self] in self?.onRestore?() }
        stackView.onDragEnded = { [weak self] in
            self?.constrainToAvailableScreens()
        }
        apply(resolvedAppearance: appearanceController.resolvedAppearance)
        updateCount(0)
    }

    private func reveal(animated: Bool) {
        guard let panel = window, cardCount > 0 else { return }
        animationGeneration &+= 1
        let generation = animationGeneration
        let duration = transitionDuration(animated: animated)

        appearanceController.applyMode(to: panel)
        constrainToAvailableScreens()
        if !panel.isVisible {
            panel.alphaValue = duration > 0 ? 0 : 1
            panel.orderFrontRegardless()
        }

        guard duration > 0 else {
            panel.alphaValue = 1
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, animationGeneration == generation else { return }
                panel.alphaValue = 1
            }
        }
    }

    private func resolvePlacementIfNeeded(preferredScreen: NSScreen?) {
        guard !hasResolvedInitialPlacement, let panel = window else { return }
        hasResolvedInitialPlacement = true

        if let placement = StoredPlacement(defaults: defaults),
           let storedScreen = NSScreen.screens.first(where: {
               $0.localizedName == placement.screenID
           })
        {
            panel.setFrame(Self.constrained(placement.frame, to: storedScreen.visibleFrame), display: false)
            return
        }

        if let placement = StoredPlacement(defaults: defaults),
           let mainScreen = NSScreen.main
        {
            let frame = Self.constrained(placement.frame, to: mainScreen.visibleFrame)
            panel.setFrame(frame, display: false)
            persist(frame: frame, screen: mainScreen)
            return
        }

        guard let target = preferredScreen ?? NSScreen.main else { return }
        panel.setFrame(Self.defaultFrame(in: target.visibleFrame), display: false)
    }

    private func persist(frame: NSRect, screen: NSScreen) {
        StoredPlacement(frame: frame, screenID: screen.localizedName).write(to: defaults)
    }

    private func transitionDuration(animated: Bool) -> TimeInterval {
        guard animated else { return 0 }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? Constants.reducedMotionAnimationDuration
            : Constants.standardAnimationDuration
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        apply(resolvedAppearance: appearanceController.resolvedAppearance)
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        constrainToAvailableScreens()
    }

    private static func bestScreen(for frame: NSRect, in screens: [NSScreen]) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let containing = screens.first(where: { NSMouseInRect(center, $0.frame, false) }) {
            return containing
        }
        return screens.max { first, second in
            intersectionArea(frame, first.frame) < intersectionArea(frame, second.frame)
        }.flatMap { intersectionArea(frame, $0.frame) > 0 ? $0 : nil }
    }

    private static func intersectionArea(_ first: NSRect, _ second: NSRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}

@MainActor
private final class FoldedCardStackPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class FoldedCardStackContentView: NSVisualEffectView {
    var onActivate: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private let markdownStackIconView = NSImageView()
    private let badgeView = NSView()
    private let countLabel = NSTextField(labelWithString: "0")
    private var badgeWidthConstraint: NSLayoutConstraint?
    private var mouseDownLocation: NSPoint?
    private var windowOriginOnMouseDown: NSPoint?
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = NSEvent.mouseLocation
        windowOriginOnMouseDown = window?.frame.origin
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation,
              let initialOrigin = windowOriginOnMouseDown,
              let window
        else { return }

        let current = NSEvent.mouseLocation
        if !isDragging {
            isDragging = FoldedCardStackWindowController.exceededDragThreshold(
                from: start,
                to: current
            )
        }
        guard isDragging else { return }

        window.setFrameOrigin(NSPoint(
            x: initialOrigin.x + current.x - start.x,
            y: initialOrigin.y + current.y - start.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            windowOriginOnMouseDown = nil
            isDragging = false
        }

        if isDragging {
            onDragEnded?()
        } else {
            onActivate?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onActivate?()
        return true
    }

    func updateCount(_ count: Int) {
        let displayCount = count > 99 ? "99+" : String(count)
        countLabel.stringValue = displayCount
        badgeWidthConstraint?.constant = count > 99 ? 23 : 17

        let noun = count == 1 ? "card" : "cards"
        let summary = "Restore \(count) folded \(noun)"
        toolTip = summary
        setAccessibilityLabel("Folded cards")
        setAccessibilityValue("\(count) folded \(noun)")
        setAccessibilityHelp(summary)
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast

        state = reduceTransparency ? .inactive : .active
        layer?.backgroundColor = MonochromePalette.windowBackground(for: resolvedAppearance)
            .withAlphaComponent(reduceTransparency ? 1 : 0.76).cgColor
        layer?.borderColor = MonochromePalette.border(for: resolvedAppearance)
            .withAlphaComponent(increaseContrast ? 1 : 0.82).cgColor
        layer?.borderWidth = increaseContrast ? 1.5 : 1
        badgeView.layer?.backgroundColor = MonochromePalette.primaryText(
            for: resolvedAppearance
        ).cgColor
        badgeView.layer?.borderColor = MonochromePalette.windowBackground(
            for: resolvedAppearance
        ).cgColor
        badgeView.layer?.borderWidth = 1
        countLabel.textColor = resolvedAppearance == .dark
            ? NSColor(calibratedWhite: 0.08, alpha: 1)
            : NSColor(calibratedWhite: 0.97, alpha: 1)
    }

    private func configure() {
        material = .hudWindow
        blendingMode = .behindWindow
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        markdownStackIconView.translatesAutoresizingMaskIntoConstraints = false
        markdownStackIconView.identifier = .init("folded.markdownCardStackIcon")
        markdownStackIconView.image = NSApplication.shared.applicationIconImage
        markdownStackIconView.imageAlignment = .alignCenter
        markdownStackIconView.imageScaling = .scaleProportionallyUpOrDown
        markdownStackIconView.setAccessibilityElement(false)

        badgeView.translatesAutoresizingMaskIntoConstraints = false
        badgeView.wantsLayer = true
        badgeView.layer?.cornerRadius = 8.5
        badgeView.layer?.cornerCurve = .continuous
        badgeView.setAccessibilityElement(false)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .bold)
        countLabel.alignment = .center
        countLabel.setAccessibilityElement(false)

        addSubview(markdownStackIconView)
        addSubview(badgeView)
        badgeView.addSubview(countLabel)
        let badgeWidth = badgeView.widthAnchor.constraint(equalToConstant: 17)
        badgeWidthConstraint = badgeWidth
        NSLayoutConstraint.activate([
            markdownStackIconView.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -1),
            markdownStackIconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            markdownStackIconView.widthAnchor.constraint(equalToConstant: 36),
            markdownStackIconView.heightAnchor.constraint(equalToConstant: 36),
            badgeView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            badgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            badgeWidth,
            badgeView.heightAnchor.constraint(equalToConstant: 17),
            countLabel.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 2),
            countLabel.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -2),
            countLabel.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
        ])

        setAccessibilityRole(.button)
        setAccessibilitySubrole(.toggle)
    }
}

private struct StoredPlacement {
    let frame: NSRect
    let screenID: String

    init(frame: NSRect, screenID: String) {
        self.frame = frame
        self.screenID = screenID
    }

    init?(defaults: UserDefaults) {
        guard let value = defaults.dictionary(
            forKey: FoldedCardStackWindowController.placementDefaultsKey
        ),
            let x = (value["x"] as? NSNumber)?.doubleValue,
            let y = (value["y"] as? NSNumber)?.doubleValue,
            let width = (value["width"] as? NSNumber)?.doubleValue,
            let height = (value["height"] as? NSNumber)?.doubleValue,
            let screenID = value["screenID"] as? String,
            x.isFinite,
            y.isFinite,
            width.isFinite,
            height.isFinite,
            width > 0,
            height > 0
        else { return nil }

        frame = NSRect(x: x, y: y, width: width, height: height)
        self.screenID = screenID
    }

    func write(to defaults: UserDefaults) {
        defaults.set(
            [
                "x": Double(frame.minX),
                "y": Double(frame.minY),
                "width": Double(frame.width),
                "height": Double(frame.height),
                "screenID": screenID,
            ] as [String: Any],
            forKey: FoldedCardStackWindowController.placementDefaultsKey
        )
    }
}
