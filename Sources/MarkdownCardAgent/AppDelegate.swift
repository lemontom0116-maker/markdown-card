import AppKit
import MarkdownCardCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var applicationController: AgentApplicationController?
    private var terminationInProgress = false
    private var terminationReady = false
    private var controllerHasStarted = false
    private var openCommandCenterAfterStart = false
    private var systemSleepEventMonitor: SystemSleepEventMonitor?
    private var pendingSystemSleepEvents: [SystemSleepEventMonitor.Event] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["MARKDOWN_CARD_DISABLE_SYSTEM_SLEEP_MONITOR"] == "1" {
            return
        }
        let monitor = SystemSleepEventMonitor()
        monitor.onEvent = { [weak self] event in
            self?.handleSystemSleepEvent(event)
        }
        systemSleepEventMonitor = monitor
        monitor.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        ShortcutDefaultsMigration.migrateCardLibraryDefaultIfNeeded()

        let repository: any CardRepository
        do {
            if let rawStoreURL = ProcessInfo.processInfo.environment["MARKDOWN_CARD_STORE_URL"],
               !rawStoreURL.isEmpty
            {
                repository = try SwiftDataCardRepository(
                    storeURL: URL(fileURLWithPath: NSString(string: rawStoreURL).expandingTildeInPath)
                )
            } else {
                repository = try SwiftDataCardRepository()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Markdown Card could not open its card library."
            alert.informativeText = "The SwiftData store was left untouched. Resolve the storage problem and reopen the app.\n\n\(error.localizedDescription)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let defaults: UserDefaults
        if let suite = ProcessInfo.processInfo.environment["MARKDOWN_CARD_DEFAULTS_SUITE"],
           !suite.isEmpty,
           let isolatedDefaults = UserDefaults(suiteName: suite)
        {
            defaults = isolatedDefaults
        } else {
            defaults = .standard
        }

        let controller = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )
        applicationController = controller
        for event in pendingSystemSleepEvents {
            controller.handleSystemSleepEvent(event)
        }
        pendingSystemSleepEvents.removeAll(keepingCapacity: false)
        Task {
            do {
                try await controller.start()
                controllerHasStarted = true
                if (openCommandCenterAfterStart || NSApp.isActive),
                   !controller.isSystemUnavailable
                {
                    openCommandCenterAfterStart = false
                    controller.showCommandCenter()
                } else if controller.isSystemUnavailable {
                    openCommandCenterAfterStart = false
                }
            } catch {
                let alert = NSAlert(error: error)
                alert.alertStyle = .critical
                alert.messageText = "Markdown Card could not safely open its card library."
                alert.informativeText = "Startup stopped before the UI was published. Resolve the storage problem and reopen the app. If a recovery journal path is shown below, keep that file so recovery can be retried.\n\n\(error.localizedDescription)"
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        systemSleepEventMonitor?.stop()
        systemSleepEventMonitor = nil
        applicationController?.stop()
    }

    private func handleSystemSleepEvent(_ event: SystemSleepEventMonitor.Event) {
        if let applicationController {
            applicationController.handleSystemSleepEvent(event)
        } else {
            pendingSystemSleepEvents.append(event)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Only initial activation is interpreted as a manual Finder/Spotlight
        // launch. Later activations can be caused by a CLI-requested card.
        if !controllerHasStarted {
            openCommandCenterAfterStart = true
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag { return true }
        if controllerHasStarted {
            applicationController?.showCommandCenter()
        } else {
            openCommandCenterAfterStart = true
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationReady {
            return .terminateNow
        }
        guard !terminationInProgress else { return .terminateCancel }
        terminationInProgress = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await applicationController?.prepareForTermination()
                terminationReady = true
                sender.terminate(nil)
            } catch {
                terminationInProgress = false
                let alert = NSAlert(error: error)
                alert.messageText = "Markdown Card could not save the latest changes."
                alert.informativeText = "Cancel to keep the app open, or quit anyway after copying any unsaved Markdown.\n\n\(error.localizedDescription)"
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Quit Anyway")
                if alert.runModal() == .alertSecondButtonReturn {
                    terminationReady = true
                    sender.terminate(nil)
                }
            }
        }
        // Returning cancel lets AppKit unwind `terminate:` immediately. The
        // MainActor can then finish the async flush and issue a second
        // termination request, which returns `.terminateNow` above.
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
