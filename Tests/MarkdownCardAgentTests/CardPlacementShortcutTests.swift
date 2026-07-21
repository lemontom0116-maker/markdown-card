import AppKit
import KeyboardShortcuts
import MarkdownCardCore
import XCTest
@testable import MarkdownCardAgent

@MainActor
final class CardPlacementShortcutTests: XCTestCase {
    func testDefaultAndReboundShortcutsRequestPlacementForActiveCard() throws {
        let savedShortcut = KeyboardShortcuts.getShortcut(for: .moveActiveCard)
        defer { KeyboardShortcuts.setShortcut(savedShortcut, for: .moveActiveCard) }

        let suiteName = "CardPlacementShortcutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = CardPanelController(
            card: CardRecord(markdown: "# Shortcut"),
            appearanceController: AppearanceController(defaults: defaults),
            placementPreferences: CardPlacementPreferences(defaults: defaults)
        )
        let window = try XCTUnwrap(controller.window)
        var requestedCardIDs: [UUID] = []
        controller.onRequestPresetPlacement = { requestedCardIDs.append($0) }

        KeyboardShortcuts.reset(.moveActiveCard)
        let defaultShortcut = try XCTUnwrap(
            KeyboardShortcuts.getShortcut(for: .moveActiveCard)
        )
        XCTAssertEqual(defaultShortcut.key, .j)
        XCTAssertEqual(relevantModifiers(defaultShortcut.modifiers), [.command])
        XCTAssertTrue(window.performKeyEquivalent(with: try keyEvent(
            "j",
            keyCode: 38,
            modifiers: [.command],
            window: window
        )))
        XCTAssertEqual(requestedCardIDs, [controller.card.id])

        KeyboardShortcuts.setShortcut(
            KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .option]),
            for: .moveActiveCard
        )
        XCTAssertFalse(window.performKeyEquivalent(with: try keyEvent(
            "j",
            keyCode: 38,
            modifiers: [.command],
            window: window
        )))
        XCTAssertEqual(requestedCardIDs, [controller.card.id])
        XCTAssertTrue(window.performKeyEquivalent(with: try keyEvent(
            "k",
            keyCode: 40,
            modifiers: [.control, .option],
            window: window
        )))
        XCTAssertEqual(requestedCardIDs, [controller.card.id, controller.card.id])

        KeyboardShortcuts.setShortcut(nil, for: .moveActiveCard)
        XCTAssertNil(KeyboardShortcuts.getShortcut(for: .moveActiveCard))
        XCTAssertFalse(window.performKeyEquivalent(with: try keyEvent(
            "k",
            keyCode: 40,
            modifiers: [.control, .option],
            window: window
        )))
        XCTAssertEqual(requestedCardIDs, [controller.card.id, controller.card.id])
    }

    func testLegacyMoveBindingCannotStealFixedCardLayoutShortcut() throws {
        let savedShortcut = KeyboardShortcuts.getShortcut(for: .moveActiveCard)
        defer { KeyboardShortcuts.setShortcut(savedShortcut, for: .moveActiveCard) }
        KeyboardShortcuts.setShortcut(
            .init(.one, modifiers: [.control]),
            for: .moveActiveCard
        )

        let suiteName = "CardPlacementShortcutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = CardPanelController(
            card: CardRecord(markdown: "# Layout priority", layoutMode: .sticky),
            appearanceController: AppearanceController(defaults: defaults),
            placementPreferences: CardPlacementPreferences(defaults: defaults)
        )
        let window = try XCTUnwrap(controller.window)
        var moveRequests = 0
        controller.onRequestPresetPlacement = { _ in moveRequests += 1 }

        XCTAssertTrue(window.performKeyEquivalent(with: try keyEvent(
            "1",
            keyCode: 18,
            modifiers: [.control],
            window: window
        )))

        XCTAssertEqual(controller.card.layoutMode, .mini)
        XCTAssertEqual(moveRequests, 0)
    }

    func testPresetMoveStacksBelowOccupiedTopRightCardAndPreservesState() throws {
        let suiteName = "CardPlacementShortcutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = CardPlacementPreferences(defaults: defaults)
        preferences.set(.topRight, for: .sticky)

        let updatedAt = Date(timeIntervalSince1970: 1_710_000_000)
        let card = CardRecord(
            title: "Placement",
            markdown: "# Placement\n\nUnchanged content",
            isQuick: true,
            isVisible: true,
            updatedAt: updatedAt,
            layoutMode: .sticky
        )
        let controller = CardPanelController(
            card: card,
            appearanceController: AppearanceController(defaults: defaults),
            placementPreferences: preferences
        )
        let window = try XCTUnwrap(controller.window)
        let visibleFrame = try XCTUnwrap(window.screen?.visibleFrame)
        let startingFrame = NSRect(
            x: visibleFrame.midX - 180,
            y: visibleFrame.midY - 150,
            width: 360,
            height: 300
        )
        window.setFrame(startingFrame, display: false)
        let occupiedFrame = CardPlacementGeometry.frame(
            for: startingFrame,
            anchor: .topRight,
            visibleFrame: visibleFrame
        )
        let expectedFrame = try XCTUnwrap(CardPlacementGeometry.availableFrame(
            for: startingFrame,
            anchor: .topRight,
            visibleFrame: visibleFrame,
            avoiding: [occupiedFrame]
        ))
        XCTAssertEqual(expectedFrame.minX, occupiedFrame.minX, accuracy: 0.5)
        XCTAssertEqual(
            occupiedFrame.minY - expectedFrame.maxY,
            CardPlacementGeometry.cardSpacing,
            accuracy: 0.5
        )

        var savedFrame: WindowFrame?
        var frameSaveCount = 0
        controller.onFrameChange = { _, frame, _ in
            savedFrame = frame
            frameSaveCount += 1
        }
        controller.moveToPresetPlacement(avoiding: [occupiedFrame])
        runLoop(for: 0.4)

        XCTAssertEqual(window.frame.origin.x, expectedFrame.origin.x, accuracy: 0.5)
        XCTAssertEqual(window.frame.origin.y, expectedFrame.origin.y, accuracy: 0.5)
        XCTAssertEqual(window.frame.size, startingFrame.size)
        XCTAssertEqual(controller.card, card)
        XCTAssertEqual(controller.card.updatedAt, updatedAt)
        XCTAssertEqual(savedFrame?.x, Double(expectedFrame.origin.x))
        XCTAssertEqual(savedFrame?.y, Double(expectedFrame.origin.y))
        XCTAssertEqual(frameSaveCount, 1)

        controller.moveToPresetPlacement(avoiding: [occupiedFrame])
        runLoop(for: 0.4)
        XCTAssertEqual(window.frame.origin.x, expectedFrame.origin.x, accuracy: 0.5)
        XCTAssertEqual(window.frame.origin.y, expectedFrame.origin.y, accuracy: 0.5)
        XCTAssertEqual(controller.card, card)
        XCTAssertEqual(frameSaveCount, 1)
    }

    func testCustomLayoutUsesMiddlePlacementPreferenceAndPreservesCustomSize() throws {
        let savedShortcut = KeyboardShortcuts.getShortcut(for: .moveActiveCard)
        defer { KeyboardShortcuts.setShortcut(savedShortcut, for: .moveActiveCard) }
        KeyboardShortcuts.reset(.moveActiveCard)

        let suiteName = "CardPlacementShortcutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = CardPlacementPreferences(defaults: defaults)
        preferences.set(.bottomLeft, for: .middle)
        let customLayout = CustomCardLayout(
            width: 480,
            minimumHeight: 300,
            maximumHeight: 600
        )
        let card = CardRecord(
            markdown: "# Custom",
            layoutMode: .custom,
            customLayout: customLayout
        )
        let controller = CardPanelController(
            card: card,
            appearanceController: AppearanceController(defaults: defaults),
            placementPreferences: preferences
        )
        let window = try XCTUnwrap(controller.window)
        let visibleFrame = try XCTUnwrap(window.screen?.visibleFrame)
        let startingFrame = NSRect(
            x: visibleFrame.midX - 200,
            y: visibleFrame.midY - 160,
            width: 400,
            height: 320
        )
        window.setFrame(startingFrame, display: false)
        let expectedFrame = try XCTUnwrap(CardPlacementGeometry.availableFrame(
            for: startingFrame,
            anchor: .bottomLeft,
            visibleFrame: visibleFrame,
            avoiding: []
        ))
        controller.onRequestPresetPlacement = { _ in
            controller.moveToPresetPlacement(avoiding: [])
        }

        XCTAssertTrue(window.performKeyEquivalent(with: try keyEvent(
            "j",
            keyCode: 38,
            modifiers: [.command],
            window: window
        )))
        runLoop(for: 0.4)

        XCTAssertEqual(window.frame.origin.x, expectedFrame.origin.x, accuracy: 0.5)
        XCTAssertEqual(window.frame.origin.y, expectedFrame.origin.y, accuracy: 0.5)
        XCTAssertEqual(window.frame.size, startingFrame.size)
        XCTAssertEqual(controller.card, card)
        XCTAssertEqual(controller.card.customLayout, customLayout)
    }

    private func relevantModifiers(
        _ modifiers: NSEvent.ModifierFlags
    ) -> NSEvent.ModifierFlags {
        modifiers.intersection([.command, .option, .control, .shift])
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

    private func runLoop(for duration: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(duration))
    }
}
