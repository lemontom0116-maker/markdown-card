import AppKit
import KeyboardShortcuts
import MarkdownCardCore
import XCTest
@testable import MarkdownCardAgent

@MainActor
final class FoldSettingsAndCommandTests: XCTestCase {
    func testFoldShortcutStartsUnsetAndParticipatesInConflictDetection() throws {
        let savedShortcut = KeyboardShortcuts.getShortcut(for: .toggleFoldedCards)
        defer { KeyboardShortcuts.setShortcut(savedShortcut, for: .toggleFoldedCards) }

        KeyboardShortcuts.reset(.toggleFoldedCards)
        XCTAssertNil(KeyboardShortcuts.getShortcut(for: .toggleFoldedCards))
        XCTAssertTrue(ShortcutConflictDetector.managedNames.contains(.toggleFoldedCards))

        let shortcut = KeyboardShortcuts.Shortcut(
            .f19,
            modifiers: [.command, .control, .option]
        )
        KeyboardShortcuts.setShortcut(shortcut, for: .toggleFoldedCards)

        XCTAssertTrue(
            ShortcutConflictDetector.conflicts(shortcut, excluding: .newCard)
        )
    }

    func testGeneralFoldOnLockSettingDefaultsOnPersistsAndInvokesCallback() throws {
        let suiteName = "FoldSettingsAndCommandTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            SettingsCenterWindowController.foldCardsWhenMacLocksDefaultsKey,
            "foldCardsWhenMacLocks"
        )
        XCTAssertNil(
            defaults.object(forKey: SettingsCenterWindowController.foldCardsWhenMacLocksDefaultsKey)
        )
        XCTAssertTrue(FoldPreferences.foldCardsWhenMacLocks(in: defaults))

        let controller = SettingsCenterWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            placementPreferences: CardPlacementPreferences(defaults: defaults),
            defaults: defaults
        )
        var changes: [Bool] = []
        controller.onFoldCardsWhenMacLocksChange = { changes.append($0) }
        controller.showSettings()
        defer { controller.window?.orderOut(nil) }

        let root = try XCTUnwrap(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let foldSwitch = try XCTUnwrap(descendants(of: NSSwitch.self, in: root).first {
            $0.identifier?.rawValue == "settings.foldCardsWhenMacLocks"
        })
        XCTAssertEqual(foldSwitch.state, .on)
        XCTAssertTrue(descendants(of: NSTextField.self, in: root).contains {
            $0.stringValue == "Fold cards when Mac locks"
        })
        XCTAssertTrue(descendants(of: NSTextField.self, in: root).contains {
            $0.stringValue.contains("stay folded after wake")
        })

        foldSwitch.performClick(nil)
        XCTAssertEqual(foldSwitch.state, .off)
        XCTAssertEqual(changes, [false])
        XCTAssertEqual(
            defaults.object(
                forKey: SettingsCenterWindowController.foldCardsWhenMacLocksDefaultsKey
            ) as? Bool,
            false
        )
        XCTAssertFalse(FoldPreferences.foldCardsWhenMacLocks(in: defaults))

        foldSwitch.performClick(nil)
        XCTAssertEqual(foldSwitch.state, .on)
        XCTAssertEqual(changes, [false, true])
        XCTAssertTrue(FoldPreferences.foldCardsWhenMacLocks(in: defaults))
    }

    func testShortcutsPageShowsCardFocusedFoldRecorderWithoutDefault() throws {
        let savedShortcut = KeyboardShortcuts.getShortcut(for: .toggleFoldedCards)
        defer { KeyboardShortcuts.setShortcut(savedShortcut, for: .toggleFoldedCards) }
        KeyboardShortcuts.reset(.toggleFoldedCards)

        let suiteName = "FoldSettingsAndCommandTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = SettingsCenterWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            placementPreferences: CardPlacementPreferences(defaults: defaults),
            defaults: defaults
        )

        controller.showShortcutsForTesting()
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 760, height: 520), display: false)
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()

        let labels = descendants(of: NSTextField.self, in: root).map(\.stringValue)
        XCTAssertTrue(labels.contains("Fold All Cards"))
        XCTAssertTrue(labels.contains("While a card is active"))
        XCTAssertEqual(labels.filter { $0 == "Global" }.count, 2)
        let recorders = descendants(of: ShortcutRecorderButton.self, in: root)
        XCTAssertEqual(recorders.count, 6)
        XCTAssertTrue(recorders.allSatisfy {
            NSContainsRect(root.bounds, $0.convert($0.bounds, to: root))
        })
        XCTAssertTrue(recorders.contains {
            ($0.accessibilityValue() as? String) == "Not Set"
        })
    }

    func testShortcutsPageExplainsPriorityAndShowsMigrationNotice() throws {
        let suiteName = "FoldSettingsAndCommandTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "Move Active Card used ⌘S, which is reserved for Save; it was changed to ⌘J.",
            forKey: ShortcutDefaultsMigration.reservedBindingsNoticeKey
        )
        let controller = SettingsCenterWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            placementPreferences: CardPlacementPreferences(defaults: defaults),
            defaults: defaults
        )

        controller.showShortcutsForTesting()
        let root = try XCTUnwrap(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let feedback = try XCTUnwrap(descendants(of: NSTextField.self, in: root).first {
            $0.identifier?.rawValue == "settings.shortcutFeedback"
        })

        XCTAssertTrue(feedback.stringValue.contains("reserved for Save"))
        XCTAssertTrue(feedback.stringValue.contains("Markdown shortcuts win"))
        XCTAssertTrue(feedback.stringValue.contains("Save As"))
        XCTAssertTrue(feedback.stringValue.contains("card layouts"))
        XCTAssertEqual(feedback.accessibilityLabel(), "Shortcut status")
        XCTAssertEqual(feedback.accessibilityValue() as? String, feedback.stringValue)
    }

    func testFoldShortcutIsHandledOnlyByCardWindowAndTracksRebinding() throws {
        let savedShortcut = KeyboardShortcuts.getShortcut(for: .toggleFoldedCards)
        defer { KeyboardShortcuts.setShortcut(savedShortcut, for: .toggleFoldedCards) }

        let suiteName = "FoldSettingsAndCommandTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = CardPanelController(
            card: CardRecord(markdown: "# Focused fold"),
            appearanceController: AppearanceController(defaults: defaults),
            placementPreferences: CardPlacementPreferences(defaults: defaults)
        )
        let window = try XCTUnwrap(controller.window)
        var foldRequests = 0
        controller.onRequestFoldAllCards = { foldRequests += 1 }

        KeyboardShortcuts.setShortcut(
            KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .option]),
            for: .toggleFoldedCards
        )
        XCTAssertTrue(window.performKeyEquivalent(with: try keyEvent(
            "k",
            keyCode: 40,
            modifiers: [.control, .option],
            window: window
        )))
        XCTAssertEqual(foldRequests, 1)

        KeyboardShortcuts.setShortcut(
            KeyboardShortcuts.Shortcut(.f, modifiers: [.command, .shift]),
            for: .toggleFoldedCards
        )
        XCTAssertFalse(window.performKeyEquivalent(with: try keyEvent(
            "k",
            keyCode: 40,
            modifiers: [.control, .option],
            window: window
        )))
        XCTAssertTrue(window.performKeyEquivalent(with: try keyEvent(
            "f",
            keyCode: 3,
            modifiers: [.command, .shift],
            window: window
        )))
        XCTAssertEqual(foldRequests, 2)

        KeyboardShortcuts.setShortcut(nil, for: .toggleFoldedCards)
        XCTAssertFalse(window.performKeyEquivalent(with: try keyEvent(
            "f",
            keyCode: 3,
            modifiers: [.command, .shift],
            window: window
        )))
        XCTAssertEqual(foldRequests, 2)
    }

    func testCommandCenterFoldCommandIsDynamicSearchableAndKeepsOrdering() throws {
        let suiteName = "FoldSettingsAndCommandTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = CommandCenterWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )

        XCTAssertEqual(
            controller.commands.map(\.id),
            [.newCard, .cardLibrary, .toggleFoldedCards, .settings, .quit]
        )
        XCTAssertEqual(
            controller.commands.first { $0.id == .toggleFoldedCards }?.title,
            "Fold All Cards"
        )
        for query in ["fold", "unfold", "sleep", "wake", "restore"] {
            XCTAssertEqual(
                CommandCenterSearch.commands(
                    matching: query,
                    in: controller.commands
                ).map(\.id),
                [.toggleFoldedCards]
            )
        }

        controller.applySnapshot([])
        controller.recordRecentForTesting(.command(.toggleFoldedCards))
        XCTAssertEqual(controller.recentItemTitlesForTesting().first, "Fold All Cards")

        controller.setFoldedState(true)
        XCTAssertEqual(
            controller.commands.first { $0.id == .toggleFoldedCards }?.title,
            "Restore All Cards"
        )
        XCTAssertEqual(controller.recentItemTitlesForTesting().first, "Restore All Cards")
        XCTAssertEqual(
            controller.commands.map(\.id),
            [.newCard, .cardLibrary, .toggleFoldedCards, .settings, .quit]
        )

        controller.setFoldedState(false)
        XCTAssertEqual(
            controller.commands.first { $0.id == .toggleFoldedCards }?.title,
            "Fold All Cards"
        )
    }

    private func descendants<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var matches: [T] = []
        if let match = root as? T { matches.append(match) }
        for subview in root.subviews {
            matches.append(contentsOf: descendants(of: type, in: subview))
        }
        return matches
    }

    private func keyEvent(
        _ characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
