import AppKit
import MarkdownCardCore
import XCTest
@testable import MarkdownCardAgent

@MainActor
final class CommandCenterWorkspaceTests: XCTestCase {
    func testRoutesReuseOneHostAndEmbeddedControllersCreateNoWindows() throws {
        let suiteName = "CommandCenterWorkspaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appearance = AppearanceController(defaults: defaults)
        let library = CardLibraryWindowController(
            appearanceController: appearance,
            defaults: defaults,
            presentationMode: .embedded
        )
        let settings = SettingsCenterWindowController(
            appearanceController: appearance,
            placementPreferences: CardPlacementPreferences(defaults: defaults),
            defaults: defaults,
            presentationMode: .embedded
        )
        let commandCenter = CommandCenterWindowController(
            appearanceController: appearance,
            defaults: defaults,
            accessibilityPreferencesProvider: {
                .init(reduceTransparency: false, increaseContrast: false, reduceMotion: true)
            }
        )
        commandCenter.configureWorkspace(library: library, settings: settings)

        XCTAssertNil(library.window)
        XCTAssertNil(settings.window)
        let hostWindow = try XCTUnwrap(commandCenter.window)
        var transitions: [(CommandCenterRoute, CommandCenterRoute)] = []
        commandCenter.onRouteChange = { transitions.append(($0, $1)) }

        commandCenter.navigate(to: .library)
        XCTAssertEqual(commandCenter.activeRoute, .library)
        XCTAssertTrue(library.rootViewForEmbedding.window === hostWindow || !hostWindow.isVisible)
        XCTAssertTrue(hostWindow.backgroundColor.isEqual(NSColor.clear))

        commandCenter.navigate(to: .settings(.shortcuts))
        XCTAssertEqual(commandCenter.activeRoute, .settings(.shortcuts))
        XCTAssertEqual(settings.activeSection, .shortcuts)
        XCTAssertTrue(hostWindow.backgroundColor.isEqual(NSColor.clear))

        commandCenter.goBack()
        XCTAssertEqual(commandCenter.activeRoute, .home)
        XCTAssertEqual(transitions.map(\.0), [.home, .library, .settings(.shortcuts)])
        XCTAssertEqual(transitions.map(\.1), [.library, .settings(.shortcuts), .home])
    }

    func testAttachedSheetPreventsWorkspaceTeardown() throws {
        let suiteName = "CommandCenterWorkspaceSheet.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appearance = AppearanceController(defaults: defaults)
        let library = CardLibraryWindowController(
            appearanceController: appearance,
            defaults: defaults,
            presentationMode: .embedded
        )
        let settings = SettingsCenterWindowController(
            appearanceController: appearance,
            placementPreferences: CardPlacementPreferences(defaults: defaults),
            defaults: defaults,
            presentationMode: .embedded
        )
        let commandCenter = CommandCenterWindowController(
            appearanceController: appearance,
            defaults: defaults,
            accessibilityPreferencesProvider: {
                .init(reduceTransparency: false, increaseContrast: false, reduceMotion: true)
            }
        )
        commandCenter.configureWorkspace(library: library, settings: settings)
        commandCenter.show(route: .library, cards: [], on: nil)
        let host = try XCTUnwrap(commandCenter.window)
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        host.beginSheet(sheet)

        commandCenter.close(animated: false)
        XCTAssertEqual(commandCenter.activeRoute, .library)
        XCTAssertTrue(host.isVisible)

        host.endSheet(sheet)
        commandCenter.close(animated: false)
        XCTAssertEqual(commandCenter.activeRoute, .home)
        XCTAssertFalse(host.isVisible)
    }

    func testRouteFramesUseCompactHomeAndConstrainedWorkspaceSizes() throws {
        let suiteName = "CommandCenterWorkspaceFrames.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = CommandCenterWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )
        let standardScreen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let home = controller.targetFrameForTesting(route: .home, visibleFrame: standardScreen)
        let workspace = controller.targetFrameForTesting(route: .library, visibleFrame: standardScreen)

        XCTAssertEqual(home.size, NSSize(width: 720, height: 360))
        XCTAssertEqual(workspace.size, NSSize(width: 1180, height: 760))

        let smallScreen = NSRect(x: 0, y: 0, width: 900, height: 600)
        let constrained = controller.targetFrameForTesting(
            route: .settings(nil),
            visibleFrame: smallScreen
        )
        let constrainedMinimum = controller.routeMinimumSize(
            for: .library,
            visibleFrame: smallScreen
        )
        XCTAssertLessThanOrEqual(constrained.width, 852)
        XCTAssertLessThanOrEqual(constrained.height, 552)
        XCTAssertEqual(constrainedMinimum, constrained.size)
        XCTAssertTrue(smallScreen.contains(constrained))
    }

    func testRouteTransitionGenerationRejectsStaleAnimationCompletion() {
        var state = CommandCenterRouteTransitionState()
        let firstGeneration = state.begin(applyingFrame: true)
        let secondGeneration = state.begin(applyingFrame: true)

        XCTAssertFalse(state.complete(generation: firstGeneration))
        XCTAssertTrue(state.isApplyingFrame)
        XCTAssertTrue(state.complete(generation: secondGeneration))
        XCTAssertFalse(state.isApplyingFrame)

        let invalidatedGeneration = state.begin(applyingFrame: true)
        state.invalidate()
        XCTAssertFalse(state.complete(generation: invalidatedGeneration))
        XCTAssertFalse(state.isApplyingFrame)
    }

    func testRouteChromeAndSettingsPrimaryActionFollowNavigationContext() throws {
        let suiteName = "CommandCenterWorkspaceChrome.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = CommandCenterWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults,
            accessibilityPreferencesProvider: {
                .init(reduceTransparency: false, increaseContrast: false, reduceMotion: true)
            }
        )

        let home = controller.chromeStateForTesting()
        XCTAssertFalse(home.isBackVisible)
        XCTAssertTrue(home.isMagnifierVisible)
        XCTAssertTrue(home.isPrimaryVisible)
        XCTAssertTrue(home.isPrimaryEnabled)
        XCTAssertEqual(home.primaryTitle, "Open  ↩")
        XCTAssertFalse(home.primaryUsesFooterTrailing)
        XCTAssertTrue(home.isActionsVisible)
        XCTAssertTrue(home.usesVerticallyCenteredSearchCell)
        XCTAssertTrue(home.isSearchEditable)
        XCTAssertTrue(home.isSearchSelectable)

        controller.navigate(to: .settings(nil))
        let emptySettings = controller.chromeStateForTesting()
        XCTAssertTrue(emptySettings.isBackVisible)
        XCTAssertFalse(emptySettings.isMagnifierVisible)
        XCTAssertFalse(emptySettings.isPrimaryVisible)
        XCTAssertFalse(emptySettings.isPrimaryEnabled)
        XCTAssertTrue(emptySettings.primaryUsesFooterTrailing)
        XCTAssertFalse(emptySettings.isActionsVisible)

        controller.performPrimaryActionForTesting()
        XCTAssertEqual(controller.activeRoute, .settings(nil), "Return must be a no-op for empty Settings search")

        controller.setSearchQueryForTesting("keyboard")
        let searchedSettings = controller.chromeStateForTesting()
        XCTAssertTrue(searchedSettings.isPrimaryVisible)
        XCTAssertTrue(searchedSettings.isPrimaryEnabled)
        XCTAssertEqual(searchedSettings.primaryTitle, "Open Setting  ↩")
        XCTAssertTrue(searchedSettings.primaryUsesFooterTrailing)

        controller.goBack()
        let restoredHome = controller.chromeStateForTesting()
        XCTAssertEqual(controller.activeRoute, .home)
        XCTAssertTrue(restoredHome.isMagnifierVisible)
        XCTAssertFalse(restoredHome.isBackVisible)
        XCTAssertTrue(restoredHome.isPrimaryVisible)
        XCTAssertTrue(restoredHome.isActionsVisible)

        controller.navigate(to: .library)
        let library = controller.chromeStateForTesting()
        XCTAssertTrue(library.isBackVisible)
        XCTAssertFalse(library.isMagnifierVisible)
        XCTAssertTrue(library.isPrimaryVisible)
        XCTAssertTrue(library.isPrimaryEnabled)
        XCTAssertEqual(library.primaryTitle, "Open Card  ↩")
        XCTAssertTrue(library.primaryUsesFooterTrailing)
        XCTAssertFalse(library.isActionsVisible)
    }

    func testSettingsBackDoesNotScheduleDelayedHomeClose() throws {
        let suiteName = "CommandCenterWorkspaceBackLifecycle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = CommandCenterWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults,
            accessibilityPreferencesProvider: {
                .init(reduceTransparency: false, increaseContrast: false, reduceMotion: true)
            }
        )
        controller.show(route: .settings(nil), cards: [], on: nil)
        let host = try XCTUnwrap(controller.window)

        controller.goBack()
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))

        XCTAssertEqual(controller.activeRoute, .home)
        XCTAssertTrue(host.isVisible)
        XCTAssertFalse(controller.isClosingForTesting())
        controller.close(animated: false)
    }

    func testHomeResignClosesWhileWorkspaceResignPreservesRoute() throws {
        let suiteName = "CommandCenterWorkspaceResignLifecycle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = CommandCenterWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults,
            accessibilityPreferencesProvider: {
                .init(reduceTransparency: false, increaseContrast: false, reduceMotion: true)
            }
        )
        controller.show(route: .home, cards: [], on: nil)
        let host = try XCTUnwrap(controller.window)

        controller.windowDidResignKey(
            Notification(name: NSWindow.didResignKeyNotification, object: host)
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        XCTAssertEqual(controller.activeRoute, .home)
        XCTAssertFalse(host.isVisible)

        controller.show(route: .settings(nil), cards: [], on: nil)
        controller.windowDidResignKey(
            Notification(name: NSWindow.didResignKeyNotification, object: host)
        )
        XCTAssertEqual(controller.activeRoute, .settings(nil))
        XCTAssertTrue(host.isVisible)
        XCTAssertFalse(controller.isClosingForTesting())

        controller.navigate(to: .library)
        controller.windowDidResignKey(
            Notification(name: NSWindow.didResignKeyNotification, object: host)
        )
        XCTAssertEqual(controller.activeRoute, .library)
        XCTAssertTrue(host.isVisible)
        XCTAssertFalse(controller.isClosingForTesting())
        controller.close(animated: false)
    }

    func testEmbeddedLibraryGroupsWithoutReorderingAndPublishesInformation() throws {
        let suiteName = "CommandCenterWorkspaceLibrary.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appearance = AppearanceController(defaults: defaults)
        let library = CardLibraryWindowController(
            appearanceController: appearance,
            defaults: defaults,
            presentationMode: .embedded
        )
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [], backing: .buffered, defer: false)
        host.contentView = library.prepareForEmbedding { host }
        let tag = try CardTag("project")
        let now = Date()
        let calendar = Calendar.current
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: now))
        let earlier = try XCTUnwrap(calendar.date(byAdding: .month, value: -2, to: now))
        let cards = [
            CardRecord(title: "Today Card", markdown: "hello world", createdAt: now, tags: [tag]),
            CardRecord(title: "Yesterday Card", markdown: "second", createdAt: yesterday),
            CardRecord(title: "Earlier Card", markdown: "third", createdAt: earlier),
        ]
        library.applySnapshot(cards, revisions: [:])

        let labels = library.listRowLabelsForTesting()
        XCTAssertEqual(
            labels,
            ["[Today]", "Today Card", "[Yesterday]", "Yesterday Card", "[Earlier]", "Earlier Card"]
        )
        let information = library.informationValuesForTesting()
        XCTAssertEqual(information["Title"], "Today Card")
        XCTAssertEqual(information["Characters"], "11")
        XCTAssertEqual(information["Words"], "2")
        XCTAssertEqual(information["Tags"], "project")
    }

    func testEmbeddedLibraryKeepsCompactDefaultSidebarDuringWorkspaceExpansion() throws {
        let suiteName = "CommandCenterWorkspaceLibrarySidebar.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(CGFloat(590), forKey: "cardLibraryDividerPosition")
        let library = CardLibraryWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults,
            presentationMode: .embedded
        )
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        host.contentView = library.prepareForEmbedding { host }
        library.activate()
        host.contentView?.layoutSubtreeIfNeeded()

        let splitView = try XCTUnwrap(host.contentView as? NSSplitView)
        XCTAssertEqual(splitView.subviews[0].frame.width, 280, accuracy: 1)

        host.setContentSize(NSSize(width: 1180, height: 760))
        host.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            splitView.subviews[0].frame.width,
            280,
            accuracy: 1,
            "Expanding the Command Center workspace must not grow the Library sidebar"
        )
    }

    func testEmbeddedLibraryRestoresValidUserSidebarWidth() throws {
        let suiteName = "CommandCenterWorkspaceLibrarySavedSidebar.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(CGFloat(336), forKey: "cardLibraryDividerPosition")
        let library = CardLibraryWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults,
            presentationMode: .embedded
        )
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        host.contentView = library.prepareForEmbedding { host }
        library.activate()
        host.contentView?.layoutSubtreeIfNeeded()

        let splitView = try XCTUnwrap(host.contentView as? NSSplitView)
        XCTAssertEqual(splitView.subviews[0].frame.width, 336, accuracy: 1)
    }

    func testSettingsSearchNavigatesToMatchingSectionWithoutReplacingControls() throws {
        let suiteName = "CommandCenterWorkspaceSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = SettingsCenterWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            placementPreferences: CardPlacementPreferences(defaults: defaults),
            defaults: defaults,
            presentationMode: .embedded
        )

        controller.setExternalSearchQuery("keyboard")
        XCTAssertEqual(controller.activeSection, .shortcuts)
        controller.setExternalSearchQuery("mdcard")
        XCTAssertEqual(controller.activeSection, .cli)
        controller.setExternalSearchQuery("")
        XCTAssertEqual(controller.activeSection, .cli)
    }
}
