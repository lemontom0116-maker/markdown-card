import AppKit
import MarkdownCardCore
import XCTest
@testable import MarkdownCardAgent

@MainActor
final class TagAndSeriesNavigationUITests: XCTestCase {
    func testOutlinedTagMetricsStayCompactAndAccentColorIsStable() throws {
        let shortTag = try CardTag("AI")
        let longTag = try CardTag("Transformer Reading Notes That Must Truncate")
        let equivalentTag = try CardTag("ai")

        XCTAssertEqual(CurtainTagMetrics.fontSize, 10)
        XCTAssertEqual(CurtainTagMetrics.horizontalPadding, 5)
        XCTAssertEqual(CurtainTagMetrics.spacing, 8)
        XCTAssertEqual(CurtainTagMetrics.hitHeight, 24)
        XCTAssertEqual(CurtainTagMetrics.chipHeight, 22)
        XCTAssertEqual(CurtainTagMetrics.underlineHeight, 2)
        XCTAssertEqual(CurtainTagMetrics.width(for: longTag.name), 96)
        XCTAssertGreaterThanOrEqual(CurtainTagMetrics.width(for: shortTag.name), 32)

        let first = try XCTUnwrap(
            CurtainTagPalette.color(for: shortTag, selected: false).usingColorSpace(.sRGB)
        )
        let equivalent = try XCTUnwrap(
            CurtainTagPalette.color(for: equivalentTag, selected: false).usingColorSpace(.sRGB)
        )
        XCTAssertEqual(first.redComponent, equivalent.redComponent, accuracy: 0.000_001)
        XCTAssertEqual(first.greenComponent, equivalent.greenComponent, accuracy: 0.000_001)
        XCTAssertEqual(first.blueComponent, equivalent.blueComponent, accuracy: 0.000_001)
        let components = [first.redComponent, first.greenComponent, first.blueComponent]
        XCTAssertGreaterThan(components.max()! - components.min()!, 0.10)
    }

    func testOutlinedTagStripShowsLabelsTogglesSelectionAndUsesEightPointSpacing() throws {
        let first = try CardTag("transformers")
        let second = try CardTag("research")
        let strip = CurtainTagStripView(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        var selections: [CardTag?] = []
        var removed: CardTag?
        strip.onSelectionChange = { selections.append($0) }
        strip.onRemoveTag = { removed = $0 }

        strip.update(tags: [first, second], activeTagID: first.id, animated: false)
        strip.layoutSubtreeIfNeeded()
        strip.tagButtons.forEach { $0.layoutSubtreeIfNeeded() }

        XCTAssertEqual(strip.intrinsicContentSize.height, 24)
        XCTAssertEqual(strip.tagButtons.count, 2)
        XCTAssertTrue(strip.tagButtons[0].isTagSelected)
        XCTAssertFalse(strip.tagButtons[1].isTagSelected)
        XCTAssertEqual(strip.tagButtons[0].tagLabel.stringValue, first.name)
        XCTAssertEqual(strip.tagButtons[1].tagLabel.stringValue, second.name)
        XCTAssertNil(strip.tagButtons[0].tagLabel.hitTest(.zero))
        XCTAssertNotNil(strip.tagButtons[0].outlineLayer.path)
        XCTAssertEqual(strip.tagButtons[0].underlineLayer.opacity, 1)
        XCTAssertEqual(strip.tagButtons[1].underlineLayer.opacity, 0)
        XCTAssertEqual(
            strip.tagButtons[0].frame.minY,
            strip.tagButtons[1].frame.minY,
            accuracy: 0.001
        )
        XCTAssertEqual(
            strip.tagButtons[1].frame.minX - strip.tagButtons[0].frame.maxX,
            8,
            accuracy: 0.001
        )

        strip.tagButtons[0].performClick(nil)
        XCTAssertNil(selections.last!)
        strip.tagButtons[1].performClick(nil)
        XCTAssertEqual(selections.last!, second)
        strip.tagButtons[0].menu?.performActionForItem(at: 0)
        XCTAssertEqual(removed, first)
    }

    func testHeaderReportsFortyEightOrSixtyEightPointPreferredHeight() throws {
        let tag = try CardTag("reading")
        let header = CardHeaderView(frame: NSRect(x: 0, y: 0, width: 360, height: 48))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 100))
        host.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            header.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        var changes: [(CGFloat, CGFloat, Bool)] = []
        header.onPreferredHeightChange = { changes.append(($0, $1, $2)) }

        XCTAssertEqual(CardHeaderView.titleRowHeight, 48)
        XCTAssertEqual(CardHeaderView.tagRailTop, 44)
        XCTAssertEqual(CardHeaderView.tagRailHeight, 24)
        XCTAssertEqual(CardHeaderView.expandedHeight, 68)
        XCTAssertEqual(CardContentLayoutMetrics.leadingInset(for: 360), 28)
        XCTAssertEqual(CardContentLayoutMetrics.leadingInset(for: 620), 28)
        XCTAssertEqual(CardContentLayoutMetrics.leadingInset(for: 621), 40)
        XCTAssertEqual(header.preferredHeight, 48)
        header.update(tags: [tag], activeTagID: tag.id, animated: false)
        host.layoutSubtreeIfNeeded()
        let tagStrip = try XCTUnwrap(
            header.subviews.compactMap { $0 as? CurtainTagStripView }.first
        )
        XCTAssertEqual(header.preferredHeight, 68)
        XCTAssertEqual(header.frame.height, 68, accuracy: 0.001)
        XCTAssertEqual(tagStrip.frame.minX, 28, accuracy: 0.001)
        XCTAssertEqual(tagStrip.frame.height, 24, accuracy: 0.001)

        host.setFrameSize(NSSize(width: 720, height: 100))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(header.frame.width, 720, accuracy: 0.001)
        XCTAssertEqual(tagStrip.frame.minX, 40, accuracy: 0.001)

        host.setFrameSize(NSSize(width: 360, height: 100))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(tagStrip.frame.minX, 28, accuracy: 0.001)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].0, 48)
        XCTAssertEqual(changes[0].1, 68)

        header.setMiniMode(true)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(header.preferredHeight, 48)
        XCTAssertEqual(header.frame.height, 48, accuracy: 0.001)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(changes[1].0, 68)
        XCTAssertEqual(changes[1].1, 48)

        header.setMiniMode(false)
        XCTAssertEqual(header.preferredHeight, 68)
        XCTAssertEqual(changes.count, 3)
    }

    func testStickyHeaderRemainsVisibleWhenWindowIsInactive() throws {
        let suiteName = "TagAndSeriesNavigationUITests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tag = try CardTag("reading")
        let controller = CardPanelController(
            card: CardRecord(markdown: "# Body", layoutMode: .sticky, tags: [tag]),
            appearanceController: AppearanceController(defaults: defaults),
            placementPreferences: CardPlacementPreferences(defaults: defaults)
        )
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)
        let header = try XCTUnwrap(
            root.subviews.compactMap { $0 as? CardHeaderView }.first
        )
        root.layoutSubtreeIfNeeded()

        XCTAssertFalse(window.isKeyWindow)
        XCTAssertFalse(header.isHidden)
        XCTAssertEqual(header.preferredHeight, CardHeaderView.expandedHeight)
        XCTAssertEqual(header.frame.height, CardHeaderView.expandedHeight, accuracy: 0.001)
        XCTAssertTrue(header.subviews.contains { !$0.isHidden })
        XCTAssertEqual(window.minSize.height, 240, accuracy: 0.001)

        controller.windowDidResignKey(
            Notification(name: NSWindow.didResignKeyNotification, object: window)
        )
        root.layoutSubtreeIfNeeded()
        XCTAssertFalse(header.isHidden)
        XCTAssertEqual(header.frame.height, CardHeaderView.expandedHeight, accuracy: 0.001)
        controller.hide(flushingPendingChanges: false)
    }

    func testBareSeriesNavigationUsesNakedDoubleChevronsAndBoundaryState() {
        let control = BareSeriesNavigationControl(
            frame: NSRect(x: 0, y: 0, width: 72, height: 44)
        )
        var directions: [SeriesNavigationDirection] = []
        control.onNavigate = { directions.append($0) }
        control.update(canNavigateNewer: false, canNavigateOlder: true)

        XCTAssertEqual(control.newerButton.direction.symbolName, "chevron.backward.2")
        XCTAssertEqual(control.olderButton.direction.symbolName, "chevron.forward.2")
        XCTAssertFalse(control.newerButton.isBordered)
        XCTAssertFalse(control.olderButton.isBordered)
        XCTAssertEqual(control.newerButton.alphaValue, 0.22, accuracy: 0.001)
        XCTAssertEqual(control.olderButton.alphaValue, 0.64, accuracy: 0.001)
        XCTAssertNotNil(control.olderButton.action)
        XCTAssertTrue(control.olderButton.target === control.olderButton)

        control.olderButton.onNavigate?()
        XCTAssertEqual(directions, [.older])
    }

    func testExternalNavigationUsesTransparentNonactivatingChildPanels() {
        let parent = NSWindow(
            contentRect: NSRect(x: 300, y: 240, width: 360, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let navigation = ExternalSeriesNavigationController()
        navigation.attach(to: parent)
        navigation.updateLayout()

        XCTAssertEqual(parent.childWindows?.count, 2)
        XCTAssertEqual(navigation.panels.count, 2)
        for panel in navigation.panels {
            XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
            XCTAssertFalse(panel.canBecomeKey)
            XCTAssertFalse(panel.canBecomeMain)
            XCTAssertFalse(panel.isOpaque)
            XCTAssertFalse(panel.hasShadow)
            XCTAssertEqual(panel.frame.size, NSSize(width: 32, height: 44))
        }
        XCTAssertEqual(navigation.panels[0].frame.maxX, parent.frame.minX - 8, accuracy: 0.001)
        XCTAssertEqual(navigation.panels[1].frame.minX, parent.frame.maxX + 8, accuracy: 0.001)

        navigation.detach()
        XCTAssertTrue(parent.childWindows?.isEmpty != false)
    }
}
