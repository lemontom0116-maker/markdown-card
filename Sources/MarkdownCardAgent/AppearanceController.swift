import AppKit
import MarkdownCardCore

@MainActor
protocol AppearanceConsumer: AnyObject {
    func apply(resolvedAppearance: ResolvedAppearance)
}

@MainActor
final class AppearanceController: NSObject {
    static let defaultsKey = "appearanceMode"

    private final class WeakConsumer {
        weak var value: AppearanceConsumer?

        init(_ value: AppearanceConsumer) {
            self.value = value
        }
    }

    private let defaults: UserDefaults
    private var consumers: [WeakConsumer] = []

    private(set) var mode: AppearanceMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Self.defaultsKey)
        }
    }

    private(set) var resolvedAppearance: ResolvedAppearance

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedMode = defaults.string(forKey: Self.defaultsKey)
            .flatMap(AppearanceMode.init(rawValue:))
        mode = storedMode ?? .system
        resolvedAppearance = mode.resolve(systemIsDark: Self.systemIsDark())
        super.init()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(applicationAppearanceDidChange(_:)),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    func register(_ consumer: AppearanceConsumer) {
        compactConsumers()
        guard !consumers.contains(where: { $0.value === consumer }) else {
            consumer.apply(resolvedAppearance: resolvedAppearance)
            return
        }
        consumers.append(WeakConsumer(consumer))
        consumer.apply(resolvedAppearance: resolvedAppearance)
    }

    func unregister(_ consumer: AppearanceConsumer) {
        consumers.removeAll { $0.value == nil || $0.value === consumer }
    }

    func setMode(_ newMode: AppearanceMode) {
        mode = newMode
        refresh()
    }

    func refresh() {
        let next = mode.resolve(systemIsDark: Self.systemIsDark())
        resolvedAppearance = next
        compactConsumers()
        consumers.forEach { $0.value?.apply(resolvedAppearance: next) }
    }

    func applyMode(to window: NSWindow) {
        switch mode {
        case .system:
            window.appearance = nil
        case .light:
            window.appearance = NSAppearance(named: .aqua)
        case .dark:
            window.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func applyMode(to menu: NSMenu) {
        switch mode {
        case .system:
            menu.appearance = nil
        case .light:
            menu.appearance = NSAppearance(named: .aqua)
        case .dark:
            menu.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @objc private func applicationAppearanceDidChange(_ notification: Notification) {
        guard mode == .system else { return }
        refresh()
    }

    private func compactConsumers() {
        consumers.removeAll { $0.value == nil }
    }

    static func systemIsDark(appearance: NSAppearance? = nil) -> Bool {
        let effectiveAppearance = appearance ?? NSApplication.shared.effectiveAppearance
        return effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

enum MonochromePalette {
    static func windowBackground(for appearance: ResolvedAppearance) -> NSColor {
        // Match the dark window-server transition surface used while AppKit
        // animates an NSWindow frame. Keeping the native and Web canvas token
        // identical prevents a temporary strip from appearing as the backing
        // store grows.
        let component: CGFloat = appearance == .dark ? 30.0 / 255.0 : 251.0 / 255.0
        return NSColor(
            srgbRed: component,
            green: component,
            blue: component,
            alpha: 1
        )
    }

    static func primaryText(for appearance: ResolvedAppearance) -> NSColor {
        appearance == .dark
            ? NSColor(calibratedWhite: 0.95, alpha: 1)
            : NSColor(calibratedWhite: 0.08, alpha: 1)
    }

    static func secondaryText(for appearance: ResolvedAppearance) -> NSColor {
        appearance == .dark
            ? NSColor(calibratedWhite: 0.62, alpha: 1)
            : NSColor(calibratedWhite: 0.39, alpha: 1)
    }

    static func tertiaryText(for appearance: ResolvedAppearance) -> NSColor {
        appearance == .dark
            ? NSColor(calibratedWhite: 0.42, alpha: 1)
            : NSColor(calibratedWhite: 0.56, alpha: 1)
    }

    static func border(for appearance: ResolvedAppearance) -> NSColor {
        appearance == .dark
            ? NSColor(calibratedWhite: 0.29, alpha: 1)
            : NSColor(calibratedWhite: 0.78, alpha: 1)
    }

    static func separator(for appearance: ResolvedAppearance) -> NSColor {
        appearance == .dark
            ? NSColor(calibratedWhite: 0.22, alpha: 1)
            : NSColor(calibratedWhite: 0.86, alpha: 1)
    }

    static func controlFill(for appearance: ResolvedAppearance) -> NSColor {
        appearance == .dark
            ? NSColor(calibratedWhite: 0.12, alpha: 1)
            : NSColor(calibratedWhite: 0.94, alpha: 1)
    }

    static func selection(for appearance: ResolvedAppearance) -> NSColor {
        appearance == .dark
            ? NSColor(calibratedWhite: 0.31, alpha: 1)
            : NSColor(calibratedWhite: 0.80, alpha: 1)
    }
}
