import AppKit
import MarkdownCardCore
import XCTest
@testable import MarkdownCardAgent

@MainActor
final class OperationWindowPresentationTests: XCTestCase {
    func testEveryCardLayoutUsesFloatingCrossSpacePresentation() throws {
        let suiteName = "OperationWindowPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appearance = AppearanceController(defaults: defaults)

        for mode in CardLayoutMode.allCases {
            let controller = CardPanelController(
                card: CardRecord(markdown: "# Floating card", layoutMode: mode),
                appearanceController: appearance,
                placementPreferences: CardPlacementPreferences(defaults: defaults)
            )
            let panel = try XCTUnwrap(controller.window as? NSPanel)
            XCTAssertTrue(panel.isFloatingPanel, "\(mode) must remain an accessory card panel")
            XCTAssertEqual(panel.level, .floating)
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertFalse(panel.collectionBehavior.contains(.moveToActiveSpace))
        }
    }

    func testSettingsAndLibraryShareFloatingOperationWindowPresentation() throws {
        let suiteName = "OperationWindowPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appearance = AppearanceController(defaults: defaults)

        let card = CardPanelController(
            card: CardRecord(markdown: "# Floating card"),
            appearanceController: appearance,
            placementPreferences: CardPlacementPreferences(defaults: defaults)
        )
        let settings = SettingsCenterWindowController(
            appearanceController: appearance,
            placementPreferences: CardPlacementPreferences(defaults: defaults),
            defaults: defaults
        )
        let library = CardLibraryWindowController(
            appearanceController: appearance,
            defaults: defaults
        )

        let cardWindow = try XCTUnwrap(card.window)
        let settingsWindow = try XCTUnwrap(settings.window)
        let libraryWindow = try XCTUnwrap(library.window)
        XCTAssertEqual(cardWindow.level, .floating)
        XCTAssertTrue((cardWindow as? NSPanel)?.isFloatingPanel == true)

        for operationWindow in [settingsWindow, libraryWindow] {
            XCTAssertEqual(operationWindow.level, cardWindow.level)
            XCTAssertTrue(operationWindow.collectionBehavior.contains(.moveToActiveSpace))
            XCTAssertTrue(operationWindow.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertTrue(operationWindow.hidesOnDeactivate)
        }
    }

    func testMostRecentlyOrderedOperationWindowStaysAheadOfFloatingCard() throws {
        guard NSScreen.main != nil else {
            throw XCTSkip("A WindowServer display is required for z-order testing")
        }
        let suiteName = "OperationWindowPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appearance = AppearanceController(defaults: defaults)
        let cardWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        cardWindow.level = .floating
        let settings = SettingsCenterWindowController(
            appearanceController: appearance,
            placementPreferences: CardPlacementPreferences(defaults: defaults),
            defaults: defaults
        )
        let library = CardLibraryWindowController(
            appearanceController: appearance,
            defaults: defaults
        )
        let settingsWindow = try XCTUnwrap(settings.window)
        let libraryWindow = try XCTUnwrap(library.window)
        // XCTest is not guaranteed to be active. Disable auto-hiding only for
        // this ordering assertion; the separate configuration test verifies
        // the production value remains true.
        settingsWindow.hidesOnDeactivate = false
        libraryWindow.hidesOnDeactivate = false
        defer {
            cardWindow.orderOut(nil)
            settingsWindow.orderOut(nil)
            libraryWindow.orderOut(nil)
        }

        // `orderFrontRegardless` makes the level ordering deterministic even
        // when the XCTest host itself is not the active application.
        cardWindow.orderFrontRegardless()
        settingsWindow.orderFrontRegardless()
        XCTAssertLessThan(
            try orderedIndex(of: settingsWindow),
            try orderedIndex(of: cardWindow)
        )

        libraryWindow.orderFrontRegardless()
        XCTAssertLessThan(
            try orderedIndex(of: libraryWindow),
            try orderedIndex(of: cardWindow)
        )
        XCTAssertLessThan(
            try orderedIndex(of: libraryWindow),
            try orderedIndex(of: settingsWindow)
        )
    }

    private func orderedIndex(of window: NSWindow) throws -> Int {
        try XCTUnwrap(NSApp.orderedWindows.firstIndex(where: { $0 === window }))
    }
}
