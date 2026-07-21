import AppKit
import MarkdownCardCore
import WebKit
import XCTest
@testable import MarkdownCardAgent

@MainActor
final class CardPanelTagSeriesTests: XCTestCase {
    func testTagsStartInactiveRegardlessOfCount() throws {
        let first = try CardTag("reading")
        let second = try CardTag("research")
        let appearance = AppearanceController(
            defaults: UserDefaults(suiteName: "CardPanelTagSeriesTests.\(UUID())")!
        )

        let single = CardPanelController(
            card: CardRecord(markdown: "Single", tags: [first]),
            appearanceController: appearance
        )
        XCTAssertNil(single.activeTagID)

        let multiple = CardPanelController(
            card: CardRecord(markdown: "Multiple", tags: [first, second]),
            appearanceController: appearance
        )
        XCTAssertNil(multiple.activeTagID)
    }

    func testSingleTagStaysInactiveThroughRefreshUntilExplicitlyActivated() throws {
        let tag = try CardTag("reading")
        let appearance = AppearanceController(
            defaults: UserDefaults(suiteName: "CardPanelTagSeriesTests.\(UUID())")!
        )
        let card = CardRecord(markdown: "Single", tags: [tag])
        let controller = CardPanelController(card: card, appearanceController: appearance)

        XCTAssertNil(controller.activeTagID)

        controller.update(card: card)
        XCTAssertNil(controller.activeTagID)
        controller.applySeriesContext(
            activeTagID: nil,
            neighbors: nil,
            animated: false
        )
        XCTAssertNil(controller.activeTagID)

        controller.applySeriesContext(
            activeTagID: tag.id,
            neighbors: nil,
            animated: false
        )
        XCTAssertEqual(controller.activeTagID, tag.id)
    }

    func testMetadataOnlyUpdatePreservesEditorMarkdown() throws {
        let tag = try CardTag("series")
        let id = UUID()
        let appearance = AppearanceController(
            defaults: UserDefaults(suiteName: "CardPanelTagSeriesTests.\(UUID())")!
        )
        let controller = CardPanelController(
            card: CardRecord(id: id, markdown: "Local editor state"),
            appearanceController: appearance
        )
        let authoritative = CardRecord(
            id: id,
            title: "Authoritative title",
            markdown: "Must not replace local editor state",
            tags: [tag]
        )

        controller.applyTagMetadata(
            card: authoritative,
            activeTagID: tag.id,
            neighbors: CardSeriesNeighbors(
                index: 0,
                count: 1,
                newerCardID: nil,
                olderCardID: nil
            ),
            animated: false
        )

        XCTAssertEqual(controller.card.markdown, "Local editor state")
        XCTAssertEqual(controller.card.title, "Authoritative title")
        XCTAssertEqual(controller.card.tags, [tag])
        XCTAssertEqual(controller.activeTagID, tag.id)
    }

    func testRebindKeepsPhysicalFrameAndLayout() throws {
        let tag = try CardTag("reading queue")
        let appearance = AppearanceController(
            defaults: UserDefaults(suiteName: "CardPanelTagSeriesTests.\(UUID())")!
        )
        let controller = CardPanelController(
            card: CardRecord(markdown: "First", layoutMode: .middle, tags: [tag]),
            appearanceController: appearance
        )
        let window = try XCTUnwrap(controller.window)
        let frame = NSRect(x: 140, y: 180, width: 720, height: 520)
        window.setFrame(frame, display: false)
        let target = CardRecord(markdown: "Second", layoutMode: .sticky, tags: [tag])

        controller.rebind(
            card: target,
            revision: 3,
            activeTagID: tag.id,
            neighbors: CardSeriesNeighbors(
                index: 1,
                count: 2,
                newerCardID: UUID(),
                olderCardID: nil
            )
        )

        XCTAssertEqual(controller.card.id, target.id)
        XCTAssertEqual(controller.card.markdown, "Second")
        XCTAssertEqual(controller.card.layoutMode, .middle)
        XCTAssertEqual(window.frame, frame)
        XCTAssertEqual(controller.activeTagID, tag.id)
    }

    func testDynamicTagChromeParticipatesInAutoHeight() {
        let visible = NSRect(x: 0, y: 0, width: 1_000, height: 900)
        XCTAssertEqual(
            CardLayoutGeometry.totalHeight(
                for: .sticky,
                contentHeight: 220,
                custom: nil,
                visibleFrame: visible,
                chromeHeight: 68
            ),
            288
        )
    }

    func testCaptureTaggedCardForVisualQA() throws {
        guard let path = ProcessInfo.processInfo.environment["MARKDOWN_CARD_QA_TAGGED_CARD_PATH"]
        else { return }

        let course = try CardTag("CS 336")
        let architecture = try CardTag("architecture")
        let appearance = AppearanceController(
            defaults: UserDefaults(suiteName: "CardPanelTagSeriesTests.\(UUID())")!
        )
        appearance.setMode(.dark)
        let controller = CardPanelController(
            card: CardRecord(
                title: "Lecture 3: Architectures",
                markdown: """
                # Lecture 3: Architectures

                Question

                - What do all these models have in common

                /
                """,
                isVisible: true,
                layoutMode: .custom,
                customLayout: CustomCardLayout(
                    width: 360,
                    minimumHeight: 300,
                    maximumHeight: 300
                ),
                tags: [course, architecture]
            ),
            appearanceController: appearance
        )
        XCTAssertNil(controller.activeTagID)
        let window = try XCTUnwrap(controller.window)
        controller.show(centerIfNeeded: true, activate: true)

        let menuDeadline = Date().addingTimeInterval(4)
        var slashPanel: NSPanel?
        while Date() < menuDeadline, slashPanel == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            slashPanel = window.childWindows?.compactMap { $0 as? NSPanel }.first(where: {
                $0.accessibilityLabel() == "Slash command menu" && $0.isVisible
            })
        }
        let menu = try XCTUnwrap(slashPanel, "Expected the native slash menu to be visible")

        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        menu.contentView?.layoutSubtreeIfNeeded()
        menu.contentView?.displayIfNeeded()

        let webView = try XCTUnwrap(descendant(of: WKWebView.self, in: root))
        let parentFrame = window.frame
        let childFrame = menu.frame
        let webRectInWindow = webView.convert(webView.bounds, to: nil)
        let webScreenRect = NSRect(
            origin: window.convertPoint(toScreen: webRectInWindow.origin),
            size: webRectInWindow.size
        )
        let parentImage = try cachedImage(of: root)
        let childImage = try cachedImage(of: try XCTUnwrap(menu.contentView))
        var webSnapshot: NSImage?
        webView.takeSnapshot(with: nil) { image, _ in webSnapshot = image }
        let snapshotDeadline = Date().addingTimeInterval(4)
        while Date() < snapshotDeadline, webSnapshot == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let outputBitmap = try compositeCapture(
            parentFrame: parentFrame,
            parentImage: parentImage,
            childFrame: childFrame,
            childImage: childImage,
            webScreenRect: webScreenRect,
            webSnapshot: try XCTUnwrap(webSnapshot)
        )
        let data = try XCTUnwrap(outputBitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        controller.hide(flushingPendingChanges: false)
    }

    func testCaptureWideTaggedCardForVisualQA() throws {
        guard let path = ProcessInfo.processInfo.environment[
            "MARKDOWN_CARD_QA_WIDE_TAGGED_CARD_PATH"
        ] else { return }

        let exampleURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Examples/MarkdownSyntaxShowcase.md")
        let markdown = try String(contentsOf: exampleURL, encoding: .utf8)
        let sample = try CardTag("sample")
        let suiteName = "CardPanelTagSeriesTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appearance = AppearanceController(defaults: defaults)
        appearance.setMode(.dark)
        let controller = CardPanelController(
            card: CardRecord(
                title: "Markdown Syntax Showcase",
                markdown: markdown,
                isVisible: true,
                layoutMode: .custom,
                customLayout: CustomCardLayout(
                    width: 720,
                    minimumHeight: 840,
                    maximumHeight: 840
                ),
                tags: [sample]
            ),
            appearanceController: appearance
        )
        XCTAssertNil(controller.activeTagID)
        let window = try XCTUnwrap(controller.window)
        controller.show(centerIfNeeded: true, activate: true)
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        let webView = try XCTUnwrap(descendant(of: WKWebView.self, in: root))
        let webRectInWindow = webView.convert(webView.bounds, to: nil)
        let webScreenRect = NSRect(
            origin: window.convertPoint(toScreen: webRectInWindow.origin),
            size: webRectInWindow.size
        )
        let parentImage = try cachedImage(of: root)
        var webSnapshot: NSImage?
        webView.takeSnapshot(with: nil) { image, _ in webSnapshot = image }
        let snapshotDeadline = Date().addingTimeInterval(4)
        while Date() < snapshotDeadline, webSnapshot == nil {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let outputBitmap = try compositeCapture(
            parentFrame: window.frame,
            parentImage: parentImage,
            webScreenRect: webScreenRect,
            webSnapshot: try XCTUnwrap(webSnapshot)
        )
        let data = try XCTUnwrap(outputBitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        controller.hide(flushingPendingChanges: false)
    }

    private func descendant<View: NSView>(of type: View.Type, in root: NSView) -> View? {
        if let match = root as? View { return match }
        for subview in root.subviews {
            if let match = descendant(of: type, in: subview) { return match }
        }
        return nil
    }

    private func compositeCapture(
        parentFrame: NSRect,
        parentImage: NSImage,
        childFrame: NSRect? = nil,
        childImage: NSImage? = nil,
        webScreenRect: NSRect,
        webSnapshot: NSImage
    ) throws -> NSBitmapImageRep {
        var captureFrame = parentFrame
        if let childFrame {
            captureFrame = captureFrame.union(childFrame)
            captureFrame.origin.y -= 8
            captureFrame.size.height += 8
        }
        let scale: CGFloat = 2
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(ceil(captureFrame.width * scale)),
                pixelsHigh: Int(ceil(captureFrame.height * scale)),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        bitmap.size = captureFrame.size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: captureFrame.size).fill()

        parentImage.draw(in: offset(parentFrame, from: captureFrame))

        webSnapshot.draw(in: offset(webScreenRect, from: captureFrame))

        if let childFrame, let childImage {
            childImage.draw(in: offset(childFrame, from: captureFrame))
        }

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    private func cachedImage(of view: NSView) throws -> NSImage {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    private func offset(_ rect: NSRect, from unionFrame: NSRect) -> NSRect {
        NSRect(
            x: rect.minX - unionFrame.minX,
            y: rect.minY - unionFrame.minY,
            width: rect.width,
            height: rect.height
        )
    }
}
