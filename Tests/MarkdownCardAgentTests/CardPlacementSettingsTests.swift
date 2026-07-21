import AppKit
import KeyboardShortcuts
import XCTest
@testable import MarkdownCardAgent

@MainActor
final class CardPlacementSettingsTests: XCTestCase {
    func testPlacementPageExposesIndependentAccessiblePickersAndRestoresDefaults() throws {
        let suiteName = "CardPlacementSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = CardPlacementPreferences(defaults: defaults)
        let controller = SettingsCenterWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            placementPreferences: preferences
        )

        controller.showPlacementForTesting()
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 0, y: 0, width: 760, height: 520), display: false)
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()

        let buttons = descendants(of: NSButton.self, in: root)
        let restoreButton = try XCTUnwrap(buttons.first { $0.title == "Restore Defaults" })
        let positionNote = try XCTUnwrap(descendants(of: NSTextField.self, in: root).first {
            $0.stringValue == "Custom Size follows the Middle Note preset."
        })
        XCTAssertFalse(descendants(of: NSTextField.self, in: root).contains {
            $0.stringValue.localizedCaseInsensitiveContains("Full Screen")
        })
        let placementButtons = buttons.filter {
            $0.accessibilityIdentifier().hasPrefix("card-placement.")
        }
        XCTAssertEqual(placementButtons.count, 27)
        XCTAssertTrue(placementButtons.allSatisfy {
            $0.accessibilityLabel() != nil
                && ["Selected", "Not selected"].contains($0.accessibilityValue() as? String)
                && NSContainsRect(root.bounds, $0.convert($0.bounds, to: root))
        })
        XCTAssertTrue(NSContainsRect(root.bounds, restoreButton.convert(restoreButton.bounds, to: root)))
        XCTAssertTrue(NSContainsRect(root.bounds, positionNote.convert(positionNote.bounds, to: root)))
        XCTAssertEqual(
            selectedIdentifiers(in: placementButtons),
            Set([
                "card-placement.mini.topRight",
                "card-placement.sticky.topRight",
                "card-placement.middle.center",
            ])
        )

        let miniBottomLeft = try XCTUnwrap(placementButtons.first {
            $0.accessibilityIdentifier() == "card-placement.mini.bottomLeft"
        })
        miniBottomLeft.performClick(nil)
        XCTAssertEqual(preferences.anchor(for: .mini), .bottomLeft)
        XCTAssertEqual(
            selectedIdentifiers(in: placementButtons),
            Set([
                "card-placement.mini.bottomLeft",
                "card-placement.sticky.topRight",
                "card-placement.middle.center",
            ])
        )

        let middleBottomRight = try XCTUnwrap(placementButtons.first {
            $0.accessibilityIdentifier() == "card-placement.middle.bottomRight"
        })
        middleBottomRight.performClick(nil)
        XCTAssertEqual(preferences.anchor(for: .middle), .bottomRight)
        XCTAssertEqual(preferences.anchor(for: .custom), .bottomRight)
        XCTAssertEqual(
            selectedIdentifiers(in: placementButtons),
            Set([
                "card-placement.mini.bottomLeft",
                "card-placement.sticky.topRight",
                "card-placement.middle.bottomRight",
            ])
        )

        restoreButton.performClick(nil)
        XCTAssertEqual(preferences.anchor(for: .mini), .topRight)
        XCTAssertEqual(preferences.anchor(for: .sticky), .topRight)
        XCTAssertEqual(preferences.anchor(for: .middle), .center)
        XCTAssertEqual(preferences.anchor(for: .custom), .center)
        XCTAssertEqual(
            selectedIdentifiers(in: placementButtons),
            Set([
                "card-placement.mini.topRight",
                "card-placement.sticky.topRight",
                "card-placement.middle.center",
            ])
        )
    }

    func testShortcutsPageIncludesMoveActiveCardRecorderWithCommandJDefault() throws {
        let savedShortcut = KeyboardShortcuts.getShortcut(for: .moveActiveCard)
        defer { KeyboardShortcuts.setShortcut(savedShortcut, for: .moveActiveCard) }
        KeyboardShortcuts.reset(.moveActiveCard)

        let suiteName = "CardPlacementSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = SettingsCenterWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            placementPreferences: CardPlacementPreferences(defaults: defaults)
        )

        controller.showShortcutsForTesting()
        let root = try XCTUnwrap(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let recorders = descendants(of: ShortcutRecorderButton.self, in: root)

        XCTAssertEqual(recorders.count, 6)
        XCTAssertTrue(recorders.contains {
            ($0.accessibilityValue() as? String) == "⌘J"
        })
    }

    private func selectedIdentifiers(in buttons: [NSButton]) -> Set<String> {
        Set(buttons.compactMap { button in
            guard button.state == .on else { return nil }
            return button.accessibilityIdentifier()
        })
    }

    private func descendants<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        var matches: [T] = []
        if let match = root as? T { matches.append(match) }
        for subview in root.subviews {
            matches.append(contentsOf: descendants(of: type, in: subview))
        }
        return matches
    }
}
