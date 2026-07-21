import AppKit
import MarkdownCardCore
import XCTest
@testable import MarkdownCardAgent

final class CardPlacementAnchorTests: XCTestCase {
    func testEveryAnchorHasAnEnglishDisplayName() {
        XCTAssertEqual(
            CardPlacementAnchor.allCases.map { "\($0.rawValue):\($0.displayName)" },
            [
                "topLeft:Top Left",
                "topCenter:Top Center",
                "topRight:Top Right",
                "centerLeft:Center Left",
                "center:Center",
                "centerRight:Center Right",
                "bottomLeft:Bottom Left",
                "bottomCenter:Bottom Center",
                "bottomRight:Bottom Right",
            ]
        )
    }
}

final class CardPlacementGeometryTests: XCTestCase {
    func testEveryAnchorUsesTheExpectedInsetOriginAndPreservesSize() {
        let visibleFrame = NSRect(x: 100, y: 200, width: 400, height: 300)
        let currentFrame = NSRect(x: 900, y: 900, width: 100, height: 60)
        let expectedOrigins: [CardPlacementAnchor: NSPoint] = [
            .topLeft: NSPoint(x: 116, y: 424),
            .topCenter: NSPoint(x: 250, y: 424),
            .topRight: NSPoint(x: 384, y: 424),
            .centerLeft: NSPoint(x: 116, y: 320),
            .center: NSPoint(x: 250, y: 320),
            .centerRight: NSPoint(x: 384, y: 320),
            .bottomLeft: NSPoint(x: 116, y: 216),
            .bottomCenter: NSPoint(x: 250, y: 216),
            .bottomRight: NSPoint(x: 384, y: 216),
        ]

        for anchor in CardPlacementAnchor.allCases {
            let result = CardPlacementGeometry.frame(
                for: currentFrame,
                anchor: anchor,
                visibleFrame: visibleFrame
            )
            XCTAssertEqual(result.origin, expectedOrigins[anchor], "Unexpected origin for \(anchor)")
            XCTAssertEqual(result.size, currentFrame.size, "Changed size for \(anchor)")
        }
    }

    func testInsetShrinksOnlyOnAxisWithoutEnoughSpace() {
        let visibleFrame = NSRect(x: 10, y: 20, width: 100, height: 80)
        let currentFrame = NSRect(x: 400, y: 500, width: 90, height: 20)

        let result = CardPlacementGeometry.frame(
            for: currentFrame,
            anchor: .topRight,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(result.origin, NSPoint(x: 15, y: 64))
        XCTAssertEqual(result.size, currentFrame.size)
    }

    func testOversizedFrameIsNotShrunkAndOriginRemainsConstrained() {
        let visibleFrame = NSRect(x: 10, y: 20, width: 100, height: 80)
        let currentFrame = NSRect(x: 400, y: 500, width: 120, height: 90)

        let topRight = CardPlacementGeometry.frame(
            for: currentFrame,
            anchor: .topRight,
            visibleFrame: visibleFrame
        )
        let bottomLeft = CardPlacementGeometry.frame(
            for: currentFrame,
            anchor: .bottomLeft,
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(topRight, NSRect(x: -10, y: 10, width: 120, height: 90))
        XCTAssertEqual(bottomLeft, NSRect(x: 10, y: 20, width: 120, height: 90))
        XCTAssertEqual(topRight.size, currentFrame.size)
        XCTAssertEqual(bottomLeft.size, currentFrame.size)
    }

    func testAvailableFrameStillPositionsOversizedWindowWithoutObstacles() throws {
        let visibleFrame = NSRect(x: 10, y: 20, width: 100, height: 80)
        let currentFrame = NSRect(x: 400, y: 500, width: 120, height: 90)

        let result = try XCTUnwrap(CardPlacementGeometry.availableFrame(
            for: currentFrame,
            anchor: .topRight,
            visibleFrame: visibleFrame,
            avoiding: []
        ))

        XCTAssertEqual(result, NSRect(x: -10, y: 10, width: 120, height: 90))
        XCTAssertEqual(result.size, currentFrame.size)
    }

    func testTopRightCardsStackInwardVerticallyWithRequiredSpacing() throws {
        let visibleFrame = NSRect(x: 0, y: 0, width: 600, height: 500)
        let miniFrame = NSRect(x: 80, y: 80, width: 200, height: 80)
        let stickyFrame = NSRect(x: 60, y: 60, width: 200, height: 120)
        let miniPlacement = try XCTUnwrap(
            CardPlacementGeometry.availableFrame(
                for: miniFrame,
                anchor: .topRight,
                visibleFrame: visibleFrame,
                avoiding: []
            )
        )

        let stickyPlacement = try XCTUnwrap(
            CardPlacementGeometry.availableFrame(
                for: stickyFrame,
                anchor: .topRight,
                visibleFrame: visibleFrame,
                avoiding: [miniPlacement]
            )
        )

        XCTAssertEqual(miniPlacement, NSRect(x: 384, y: 404, width: 200, height: 80))
        XCTAssertEqual(stickyPlacement, NSRect(x: 384, y: 276, width: 200, height: 120))
        XCTAssertEqual(miniPlacement.minY - stickyPlacement.maxY, CardPlacementGeometry.cardSpacing)
    }

    func testMultipleTopRightCardsContinueTheVerticalStack() throws {
        let visibleFrame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let currentFrame = NSRect(x: 0, y: 0, width: 120, height: 50)
        var occupiedFrames: [NSRect] = []

        for expectedY in [234, 176, 118] as [CGFloat] {
            let placement = try XCTUnwrap(
                CardPlacementGeometry.availableFrame(
                    for: currentFrame,
                    anchor: .topRight,
                    visibleFrame: visibleFrame,
                    avoiding: occupiedFrames
                )
            )
            XCTAssertEqual(placement, NSRect(x: 264, y: expectedY, width: 120, height: 50))
            occupiedFrames.append(placement)
        }
    }

    func testStackingWorksInVisibleFrameWithNegativeCoordinates() throws {
        let visibleFrame = NSRect(x: -800, y: -500, width: 600, height: 400)
        let currentFrame = NSRect(x: 0, y: 0, width: 160, height: 60)
        let first = try XCTUnwrap(
            CardPlacementGeometry.availableFrame(
                for: currentFrame,
                anchor: .topRight,
                visibleFrame: visibleFrame,
                avoiding: []
            )
        )
        let second = try XCTUnwrap(
            CardPlacementGeometry.availableFrame(
                for: currentFrame,
                anchor: .topRight,
                visibleFrame: visibleFrame,
                avoiding: [first]
            )
        )

        XCTAssertEqual(first, NSRect(x: -376, y: -176, width: 160, height: 60))
        XCTAssertEqual(second, NSRect(x: -376, y: -244, width: 160, height: 60))
    }

    func testReturnsNilWhenNoSpacedCandidateFits() throws {
        let visibleFrame = NSRect(x: 0, y: 0, width: 120, height: 60)
        let currentFrame = NSRect(x: 500, y: 500, width: 100, height: 40)
        let onlyPlacement = try XCTUnwrap(
            CardPlacementGeometry.availableFrame(
                for: currentFrame,
                anchor: .center,
                visibleFrame: visibleFrame,
                avoiding: []
            )
        )

        XCTAssertNil(
            CardPlacementGeometry.availableFrame(
                for: currentFrame,
                anchor: .center,
                visibleFrame: visibleFrame,
                avoiding: [onlyPlacement]
            )
        )
    }
}

@MainActor
final class CardPlacementPreferencesTests: XCTestCase {
    func testDefaultsMatchSupportedLayoutModes() {
        withDefaults { defaults in
            let preferences = CardPlacementPreferences(defaults: defaults)

            XCTAssertEqual(preferences.anchor(for: .mini), .topRight)
            XCTAssertEqual(preferences.anchor(for: .sticky), .topRight)
            XCTAssertEqual(preferences.anchor(for: .middle), .center)
            XCTAssertEqual(preferences.anchor(for: .custom), .center)
        }
    }

    func testSelectionsPersistUsingVersionedKeys() {
        withDefaults { defaults in
            let first = CardPlacementPreferences(defaults: defaults)
            first.set(.bottomLeft, for: .mini)
            first.set(.centerRight, for: .sticky)
            first.set(.topCenter, for: .middle)

            XCTAssertEqual(defaults.string(forKey: "cardPlacement.mini.v1"), "bottomLeft")
            XCTAssertEqual(defaults.string(forKey: "cardPlacement.sticky.v1"), "centerRight")
            XCTAssertEqual(defaults.string(forKey: "cardPlacement.middle.v1"), "topCenter")

            let reloaded = CardPlacementPreferences(defaults: defaults)
            XCTAssertEqual(reloaded.anchor(for: .mini), .bottomLeft)
            XCTAssertEqual(reloaded.anchor(for: .sticky), .centerRight)
            XCTAssertEqual(reloaded.anchor(for: .middle), .topCenter)
            XCTAssertEqual(reloaded.anchor(for: .custom), .topCenter)
        }
    }

    func testInvalidStoredValuesFallBackWithoutOverwritingStoredData() {
        withDefaults { defaults in
            defaults.set("upperStarboard", forKey: "cardPlacement.mini.v1")
            defaults.set(41, forKey: "cardPlacement.sticky.v1")
            defaults.set("", forKey: "cardPlacement.middle.v1")
            let preferences = CardPlacementPreferences(defaults: defaults)

            XCTAssertEqual(preferences.anchor(for: .mini), .topRight)
            XCTAssertEqual(preferences.anchor(for: .sticky), .topRight)
            XCTAssertEqual(preferences.anchor(for: .middle), .center)
            XCTAssertEqual(preferences.anchor(for: .custom), .center)
            XCTAssertEqual(defaults.string(forKey: "cardPlacement.mini.v1"), "upperStarboard")
            XCTAssertEqual(defaults.object(forKey: "cardPlacement.sticky.v1") as? Int, 41)
            XCTAssertEqual(defaults.string(forKey: "cardPlacement.middle.v1"), "")
        }
    }

    func testRestoreDefaultsClearsSelectionsAndRestoresFallbacks() {
        withDefaults { defaults in
            let preferences = CardPlacementPreferences(defaults: defaults)
            preferences.set(.bottomCenter, for: .mini)
            preferences.set(.bottomRight, for: .sticky)
            preferences.set(.topLeft, for: .middle)

            preferences.restoreDefaults()

            XCTAssertEqual(preferences.anchor(for: .mini), .topRight)
            XCTAssertEqual(preferences.anchor(for: .sticky), .topRight)
            XCTAssertEqual(preferences.anchor(for: .middle), .center)
            XCTAssertEqual(preferences.anchor(for: .custom), .center)
            XCTAssertNil(defaults.object(forKey: "cardPlacement.mini.v1"))
            XCTAssertNil(defaults.object(forKey: "cardPlacement.sticky.v1"))
            XCTAssertNil(defaults.object(forKey: "cardPlacement.middle.v1"))
        }
    }

    func testCustomFollowsMiddleAndUnsupportedCustomWritesRemainNoOps() {
        withDefaults { defaults in
            defaults.set("preserve", forKey: "sentinel")
            let preferences = CardPlacementPreferences(defaults: defaults)
            let before = defaults.dictionaryRepresentation() as NSDictionary

            preferences.set(.topLeft, for: .custom)

            XCTAssertEqual(preferences.anchor(for: .custom), .center)
            XCTAssertNil(defaults.object(forKey: "cardPlacement.custom.v1"))
            XCTAssertEqual(defaults.dictionaryRepresentation() as NSDictionary, before)
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "CardPlacementPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }
}
