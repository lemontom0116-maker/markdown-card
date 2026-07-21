import AppKit
import XCTest
@testable import MarkdownCardAgent

@MainActor
final class FoldedCardStackWindowControllerTests: XCTestCase {
    func testPanelIsNonActivatingFloatingAndAvailableAcrossSpaces() throws {
        try withController { controller, _ in
            let panel = try XCTUnwrap(controller.window as? NSPanel)

            XCTAssertEqual(panel.frame.size, NSSize(width: 48, height: 48))
            XCTAssertTrue(panel.styleMask.contains(.borderless))
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
            XCTAssertTrue(panel.isFloatingPanel)
            XCTAssertEqual(panel.level, .floating)
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertEqual(panel.accessibilityLabel(), "Folded card stack")
        }
    }

    func testShowPlacesStackAtBottomRightAndPublishesCountAccessibility() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("A window-server display is required for placement integration testing")
        }
        try withController { controller, _ in
            controller.show(count: 3, on: screen, animated: false)
            defer { controller.hide(animated: false) }

            let panel = try XCTUnwrap(controller.window)
            let contentView = try XCTUnwrap(panel.contentView)
            XCTAssertTrue(panel.isVisible)
            XCTAssertEqual(
                panel.frame,
                FoldedCardStackWindowController.defaultFrame(in: screen.visibleFrame)
            )
            XCTAssertEqual(contentView.toolTip, "Restore 3 folded cards")
            XCTAssertEqual(contentView.accessibilityLabel(), "Folded cards")
            XCTAssertEqual(contentView.accessibilityValue() as? String, "3 folded cards")

            controller.updateCount(1)
            XCTAssertEqual(contentView.toolTip, "Restore 1 folded card")
            XCTAssertEqual(contentView.accessibilityValue() as? String, "1 folded card")
        }
    }

    func testAccessibilityPressRequestsRestore() throws {
        try withController { controller, _ in
            var restoreCount = 0
            controller.onRestore = { restoreCount += 1 }
            let contentView = try XCTUnwrap(controller.window?.contentView)

            XCTAssertTrue(contentView.accessibilityPerformPress())
            XCTAssertEqual(restoreCount, 1)
        }
    }

    func testIndicatorUsesBrandedMarkdownCardStackIcon() throws {
        try withController { controller, _ in
            let contentView = try XCTUnwrap(controller.window?.contentView)
            let iconView = try XCTUnwrap(contentView.subviews.first(where: {
                $0.identifier?.rawValue == "folded.markdownCardStackIcon"
            }) as? NSImageView)

            XCTAssertNotNil(iconView.image)
            XCTAssertTrue(iconView.image === NSApplication.shared.applicationIconImage)
            XCTAssertEqual(iconView.imageAlignment, .alignCenter)
            XCTAssertEqual(iconView.imageScaling, .scaleProportionallyUpOrDown)
        }
    }

    func testDraggedPlacementPersistsFrameAndScreenIdentifier() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("A window-server display is required for placement persistence testing")
        }
        let suiteName = "FoldedCardStackWindowControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appearance = AppearanceController(defaults: defaults)
        var expectedFrame = NSRect(
            x: screen.visibleFrame.midX - 24,
            y: screen.visibleFrame.midY - 24,
            width: 48,
            height: 48
        )

        do {
            let first = FoldedCardStackWindowController(
                appearanceController: appearance,
                defaults: defaults
            )
            first.show(count: 2, on: screen, animated: false)
            first.window?.setFrame(expectedFrame, display: false)
            first.constrainToAvailableScreens()
            expectedFrame = try XCTUnwrap(first.window?.frame)
            first.hide(animated: false)
        }

        let stored = try XCTUnwrap(
            defaults.dictionary(forKey: FoldedCardStackWindowController.placementDefaultsKey)
        )
        XCTAssertEqual(stored["screenID"] as? String, screen.localizedName)

        let restored = FoldedCardStackWindowController(
            appearanceController: appearance,
            defaults: defaults
        )
        restored.show(count: 2, on: nil, animated: false)
        defer { restored.hide(animated: false) }
        XCTAssertEqual(restored.window?.frame, expectedFrame)
    }

    func testMissingStoredDisplayConstrainsPlacementToMainScreen() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("A window-server display is required for display fallback testing")
        }
        let suiteName = "FoldedCardStackWindowControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            [
                "x": -100_000.0,
                "y": 100_000.0,
                "width": 48.0,
                "height": 48.0,
                "screenID": "Disconnected Display",
            ] as [String: Any],
            forKey: FoldedCardStackWindowController.placementDefaultsKey
        )
        let appearance = AppearanceController(defaults: defaults)
        let controller = FoldedCardStackWindowController(
            appearanceController: appearance,
            defaults: defaults
        )

        controller.show(count: 1, on: nil, animated: false)
        defer { controller.hide(animated: false) }
        let frame = try XCTUnwrap(controller.window?.frame)
        XCTAssertTrue(screen.visibleFrame.contains(frame))
    }

    func testGeometrySupportsNegativeDisplayCoordinatesAndSixPointDragThreshold() {
        let visibleFrame = NSRect(x: -900, y: -500, width: 700, height: 400)
        let proposed = NSRect(x: -2_000, y: 1_000, width: 100, height: 100)
        let constrained = FoldedCardStackWindowController.constrained(
            proposed,
            to: visibleFrame
        )

        XCTAssertEqual(constrained.size, NSSize(width: 48, height: 48))
        XCTAssertTrue(visibleFrame.contains(constrained))
        XCTAssertFalse(FoldedCardStackWindowController.exceededDragThreshold(
            from: .zero,
            to: NSPoint(x: 3, y: 5)
        ))
        XCTAssertTrue(FoldedCardStackWindowController.exceededDragThreshold(
            from: .zero,
            to: NSPoint(x: 0, y: 6)
        ))
    }

    private func withController(
        _ body: (FoldedCardStackWindowController, UserDefaults) throws -> Void
    ) rethrows {
        let suiteName = "FoldedCardStackWindowControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appearance = AppearanceController(defaults: defaults)
        let controller = FoldedCardStackWindowController(
            appearanceController: appearance,
            defaults: defaults
        )
        try body(controller, defaults)
        controller.hide(animated: false)
    }
}
