import AppKit
import MarkdownCardCore
import XCTest
@testable import MarkdownCardAgent

@MainActor
final class PlainMarkdownExportAndMiniAccessibilityTests: XCTestCase {
    func testNonMiniCardAlwaysShowsExportWithOrWithoutAttachments() throws {
        let (suiteName, defaults) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = CardPanelController(
            card: CardRecord(markdown: "# Plain Markdown", layoutMode: .sticky),
            appearanceController: AppearanceController(defaults: defaults)
        )
        let header = try XCTUnwrap(controller.window?.contentView?.subviews.first as? CardHeaderView)
        let exportButton = try XCTUnwrap(
            buttons(in: header).first { $0.toolTip?.hasPrefix("Export Markdown") == true }
        )
        var exportRequests = 0
        header.onExportMarkdown = { exportRequests += 1 }

        XCTAssertFalse(exportButton.isHidden)
        XCTAssertEqual(exportButton.alphaValue, 1)
        XCTAssertEqual(exportButton.toolTip, "Export Markdown")
        exportButton.performClick(nil)
        XCTAssertEqual(exportRequests, 1)

        header.setManagedAttachmentsPresent(true, animated: false)
        XCTAssertFalse(exportButton.isHidden)
        XCTAssertEqual(exportButton.toolTip, "Export Markdown with Attachments")

        header.setManagedAttachmentsPresent(false, animated: false)
        XCTAssertFalse(exportButton.isHidden)
        XCTAssertEqual(exportButton.toolTip, "Export Markdown")

        header.setMiniMode(true)
        XCTAssertTrue(exportButton.isHidden)
        header.setMiniMode(false)
        XCTAssertFalse(exportButton.isHidden)
    }

    func testLibrarySelectedPlainMarkdownCardShowsExport() throws {
        let (suiteName, defaults) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = CardLibraryWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )
        let card = CardRecord(title: "Plain", markdown: "No attachments")

        controller.applySnapshot([card], revisions: [card.id: 0])

        let root = try XCTUnwrap(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let exportButton = try XCTUnwrap(
            buttons(in: root).first { $0.toolTip == "Export Markdown" }
        )
        XCTAssertTrue(exportButton.isEnabled)
        XCTAssertFalse(exportButton.isHidden)
        XCTAssertEqual(exportButton.alphaValue, 1)
        XCTAssertTrue(exportButton.target === controller)
        XCTAssertNotNil(exportButton.action)
    }

    func testPlainMarkdownExportWritesOnlyMarkdownFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Plain Markdown Export Tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Plain.md")
        let writer = MarkdownExportWriter(
            attachmentStore: LocalAttachmentStore(
                directory: root.appendingPathComponent("Managed Attachments")
            )
        )

        try writer.write(
            MarkdownExportBundle(markdown: "# Plain\n\nBody", attachmentIDs: []),
            to: destination
        )

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "# Plain\n\nBody")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(LocalAttachmentStore.markdownDirectory).path
            )
        )
    }

    func testMiniLayoutControlIsKeyboardFocusableVisibleAndOperable() throws {
        let (suiteName, defaults) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = CardPanelController(
            card: CardRecord(markdown: "Mini", layoutMode: .mini),
            appearanceController: AppearanceController(defaults: defaults)
        )
        let window = try XCTUnwrap(controller.window)
        let header = try XCTUnwrap(window.contentView?.subviews.first as? CardHeaderView)
        let layoutButton = try XCTUnwrap(
            buttons(in: header).first { $0.accessibilityLabel() == "Card layout" }
        )
        var layoutRequests = 0
        header.onShowLayoutMenu = { _ in layoutRequests += 1 }

        XCTAssertTrue(layoutButton.isEnabled)
        XCTAssertTrue(layoutButton.acceptsFirstResponder)
        XCTAssertEqual(layoutButton.alphaValue, 1)
        XCTAssertTrue(layoutButton.toolTip?.contains("Restore from Mini") == true)

        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.makeFirstResponder(layoutButton))
        XCTAssertTrue(window.firstResponder === layoutButton)
        XCTAssertEqual(layoutButton.alphaValue, 1)

        layoutButton.performClick(nil)
        XCTAssertEqual(layoutRequests, 1)

        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertEqual(layoutButton.alphaValue, 1)
    }

    func testStickyLayoutFollowedByMiniIsNotPollutedByRecoveryOverlayFittingSize() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("A window-server display is required for card sizing")
        }
        let (suiteName, defaults) = testDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var card = CardRecord(markdown: "# Layout sequence", layoutMode: .sticky)
        let controller = CardPanelController(
            card: card,
            appearanceController: AppearanceController(defaults: defaults)
        )
        let window = try XCTUnwrap(controller.window)
        let stickyFrame = NSRect(
            x: screen.visibleFrame.midX - CardLayoutGeometry.stickyWidth / 2,
            y: screen.visibleFrame.midY - 150,
            width: CardLayoutGeometry.stickyWidth,
            height: 300
        )
        window.setFrame(stickyFrame, display: false)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            window.frame.width,
            CardLayoutGeometry.stickyWidth,
            "min=\(window.minSize) contentMin=\(window.contentMinSize) fitting=\(window.contentView?.fittingSize ?? .zero)"
        )

        card.layoutMode = .mini
        controller.update(card: card)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.frame.size, CardLayoutGeometry.miniSize)
    }

    private func buttons(in root: NSView) -> [NSButton] {
        root.subviews.flatMap { subview in
            (subview as? NSButton).map { [$0] } ?? buttons(in: subview)
        }
    }

    private func testDefaults() -> (String, UserDefaults) {
        let suiteName = "PlainMarkdownExportAndMiniAccessibilityTests.\(UUID().uuidString)"
        return (suiteName, UserDefaults(suiteName: suiteName)!)
    }
}
