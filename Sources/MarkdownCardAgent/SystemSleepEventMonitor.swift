import AppKit
import CoreGraphics

/// Bridges login-session and sleep notifications into a single MainActor event stream.
///
/// The distributed lock notification and CoreGraphics dictionary key are
/// undocumented best-effort presentation signals. They must never be treated
/// as a security boundary; public NSWorkspace sleep/session events remain the
/// supported fallback path.
@MainActor
final class SystemSleepEventMonitor: NSObject {
    enum Event: Equatable, Sendable {
        case sessionDidResignActive
        case sessionDidBecomeActive
        case screensDidSleep
        case screensDidWake
        case willSleep
        case didWake
        case screenLocked
        case screenUnlocked
    }

    nonisolated static let screenLockedNotification = Notification.Name("com.apple.screenIsLocked")
    nonisolated static let screenUnlockedNotification = Notification.Name("com.apple.screenIsUnlocked")

    var onEvent: ((Event) -> Void)?

    private let workspaceNotificationCenter: NotificationCenter
    private let distributedNotificationCenter: NotificationCenter
    private let screenLockStateProvider: @Sendable () -> Bool
    private var isStarted = false

    init(
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        distributedNotificationCenter: NotificationCenter = DistributedNotificationCenter.default(),
        screenLockStateProvider: @escaping @Sendable () -> Bool = {
            SystemSleepEventMonitor.currentScreenIsLocked()
        }
    ) {
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.distributedNotificationCenter = distributedNotificationCenter
        self.screenLockStateProvider = screenLockStateProvider
        super.init()
    }

    deinit {
        workspaceNotificationCenter.removeObserver(self)
        distributedNotificationCenter.removeObserver(self)
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        Self.workspaceNotifications.forEach { name in
            workspaceNotificationCenter.addObserver(
                self,
                selector: #selector(receiveNotification(_:)),
                name: name,
                object: nil
            )
        }
        Self.distributedNotifications.forEach { name in
            distributedNotificationCenter.addObserver(
                self,
                selector: #selector(receiveNotification(_:)),
                name: name,
                object: nil
            )
        }
        if screenLockStateProvider() {
            deliver(.screenLocked)
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        workspaceNotificationCenter.removeObserver(self)
        distributedNotificationCenter.removeObserver(self)
    }

    @objc nonisolated private func receiveNotification(_ notification: Notification) {
        guard let event = Self.event(for: notification.name) else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { deliver(event) }
        } else {
            Task { @MainActor [weak self] in
                self?.deliver(event)
            }
        }
    }

    private func deliver(_ event: Event) {
        guard isStarted else { return }
        onEvent?(event)
    }

    private nonisolated static let workspaceNotifications: [Notification.Name] = [
        NSWorkspace.sessionDidResignActiveNotification,
        NSWorkspace.sessionDidBecomeActiveNotification,
        NSWorkspace.screensDidSleepNotification,
        NSWorkspace.screensDidWakeNotification,
        NSWorkspace.willSleepNotification,
        NSWorkspace.didWakeNotification,
    ]

    private nonisolated static let distributedNotifications: [Notification.Name] = [
        screenLockedNotification,
        screenUnlockedNotification,
    ]

    private nonisolated static func event(for name: Notification.Name) -> Event? {
        switch name {
        case NSWorkspace.sessionDidResignActiveNotification: .sessionDidResignActive
        case NSWorkspace.sessionDidBecomeActiveNotification: .sessionDidBecomeActive
        case NSWorkspace.screensDidSleepNotification: .screensDidSleep
        case NSWorkspace.screensDidWakeNotification: .screensDidWake
        case NSWorkspace.willSleepNotification: .willSleep
        case NSWorkspace.didWakeNotification: .didWake
        case screenLockedNotification: .screenLocked
        case screenUnlockedNotification: .screenUnlocked
        default: nil
        }
    }

    private nonisolated static func currentScreenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let value = session["CGSSessionScreenIsLocked"] as? NSNumber
        else { return false }
        return value.boolValue
    }
}
