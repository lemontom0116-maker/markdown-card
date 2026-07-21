import AppKit
import XCTest
@testable import MarkdownCardAgent

@MainActor
final class SystemSleepEventMonitorTests: XCTestCase {
    func testMapsEveryWorkspaceAndDistributedNotification() {
        let workspaceCenter = NotificationCenter()
        let distributedCenter = NotificationCenter()
        let monitor = SystemSleepEventMonitor(
            workspaceNotificationCenter: workspaceCenter,
            distributedNotificationCenter: distributedCenter,
            screenLockStateProvider: { false }
        )
        var received: [SystemSleepEventMonitor.Event] = []
        monitor.onEvent = { event in
            XCTAssertTrue(Thread.isMainThread)
            received.append(event)
        }
        monitor.start()

        workspaceCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        distributedCenter.post(
            name: SystemSleepEventMonitor.screenLockedNotification,
            object: nil
        )
        distributedCenter.post(
            name: SystemSleepEventMonitor.screenUnlockedNotification,
            object: nil
        )

        XCTAssertEqual(received, [
            .sessionDidResignActive,
            .sessionDidBecomeActive,
            .screensDidSleep,
            .screensDidWake,
            .willSleep,
            .didWake,
            .screenLocked,
            .screenUnlocked,
        ])
    }

    func testStartAndStopAreIdempotent() {
        let workspaceCenter = NotificationCenter()
        let distributedCenter = NotificationCenter()
        let monitor = SystemSleepEventMonitor(
            workspaceNotificationCenter: workspaceCenter,
            distributedNotificationCenter: distributedCenter,
            screenLockStateProvider: { false }
        )
        var received: [SystemSleepEventMonitor.Event] = []
        monitor.onEvent = { received.append($0) }

        monitor.start()
        monitor.start()
        workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(received, [.willSleep])

        monitor.stop()
        monitor.stop()
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        distributedCenter.post(
            name: SystemSleepEventMonitor.screenUnlockedNotification,
            object: nil
        )
        XCTAssertEqual(received, [.willSleep])
    }

    func testCanRestartAfterStopping() {
        let workspaceCenter = NotificationCenter()
        let monitor = SystemSleepEventMonitor(
            workspaceNotificationCenter: workspaceCenter,
            distributedNotificationCenter: NotificationCenter(),
            screenLockStateProvider: { false }
        )
        var received: [SystemSleepEventMonitor.Event] = []
        monitor.onEvent = { received.append($0) }

        monitor.start()
        monitor.stop()
        monitor.start()
        workspaceCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)

        XCTAssertEqual(received, [.screensDidSleep])
    }

    func testStartEmitsCurrentLockedSessionState() {
        let monitor = SystemSleepEventMonitor(
            workspaceNotificationCenter: NotificationCenter(),
            distributedNotificationCenter: NotificationCenter(),
            screenLockStateProvider: { true }
        )
        var received: [SystemSleepEventMonitor.Event] = []
        monitor.onEvent = { received.append($0) }

        monitor.start()

        XCTAssertEqual(received, [.screenLocked])
    }
}
