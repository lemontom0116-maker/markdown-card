import Foundation
import XCTest
@testable import MarkdownCardAgent
@testable import MarkdownCardCore

final class CardSeriesOrderStoreTests: XCTestCase {
    func testMovesAndPersistsExplicitSeriesOrder() throws {
        let suite = "CardSeriesOrderStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tag = try CardTag("Course")
        let cards = [
            CardRecord(markdown: "# One", createdAt: .init(timeIntervalSince1970: 1), tags: [tag]),
            CardRecord(markdown: "# Two", createdAt: .init(timeIntervalSince1970: 2), tags: [tag]),
            CardRecord(markdown: "# Three", createdAt: .init(timeIntervalSince1970: 3), tags: [tag]),
        ]
        let store = CardSeriesOrderStore(defaults: defaults)
        let initial = store.orderedCards(tagID: tag.id, cards: cards)
        XCTAssertEqual(initial.map(\.title), ["Three", "Two", "One"])

        XCTAssertTrue(store.move(
            cardID: cards[0].id,
            tagID: tag.id,
            direction: .earlier,
            cards: cards
        ))
        XCTAssertEqual(store.orderedCards(tagID: tag.id, cards: cards).map(\.title), ["Three", "One", "Two"])
        XCTAssertEqual(
            CardSeriesOrderStore(defaults: defaults).order(tagID: tag.id),
            [cards[2].id, cards[0].id, cards[1].id]
        )
    }

    func testCorruptOrderDataIsBackedUpBeforeAReplacementIsSaved() throws {
        let suite = "CardSeriesOrderStoreCorruptTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: CardSeriesOrderStore.defaultsKey)
        let store = CardSeriesOrderStore(defaults: defaults)

        XCTAssertTrue(store.allOrders().isEmpty)
        XCTAssertEqual(
            defaults.data(
                forKey: CardSeriesOrderStore.defaultsKey
                    + CardSeriesOrderStore.corruptBackupSuffix
            ),
            corrupt
        )

        let id = UUID()
        XCTAssertTrue(store.setOrder([id], tagID: "course"))
        XCTAssertEqual(store.order(tagID: "course"), [id])
    }

    func testRemovingCardFromOneTagPreservesOtherTagsAndPrunesEmptyOrder() throws {
        let suite = "CardSeriesOrderStoreRemoveCardTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CardSeriesOrderStore(defaults: defaults)
        let shared = UUID()
        let remaining = UUID()

        XCTAssertTrue(store.setOrder([shared, remaining], tagID: "source"))
        XCTAssertTrue(store.setOrder([shared], tagID: "target"))
        XCTAssertTrue(store.removeCard(shared, fromTagID: "target"))
        XCTAssertNil(store.allOrders()["target"])
        XCTAssertEqual(store.order(tagID: "source"), [shared, remaining])
        XCTAssertFalse(store.removeCard(shared, fromTagID: "target"))

        let reopened = CardSeriesOrderStore(defaults: defaults)
        XCTAssertEqual(reopened.allOrders(), ["source": [shared, remaining]])
    }

    func testRemoveAndRenameTagPreserveUnrelatedOrdersAndRejectOverwrite() throws {
        let suite = "CardSeriesOrderStoreRenameTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CardSeriesOrderStore(defaults: defaults)
        let sourceOrder = [UUID(), UUID()]
        let existingTargetOrder = [UUID()]
        let unrelatedOrder = [UUID()]

        XCTAssertTrue(store.setOrder(sourceOrder, tagID: "source"))
        XCTAssertTrue(store.setOrder(unrelatedOrder, tagID: "unrelated"))
        XCTAssertTrue(store.renameTag(fromID: "source", toID: "renamed"))
        XCTAssertNil(store.allOrders()["source"])
        XCTAssertEqual(store.order(tagID: "renamed"), sourceOrder)
        XCTAssertEqual(store.order(tagID: "unrelated"), unrelatedOrder)

        XCTAssertTrue(store.setOrder(existingTargetOrder, tagID: "occupied"))
        XCTAssertFalse(store.renameTag(fromID: "renamed", toID: "occupied"))
        XCTAssertEqual(store.order(tagID: "renamed"), sourceOrder)
        XCTAssertEqual(store.order(tagID: "occupied"), existingTargetOrder)
        XCTAssertFalse(store.renameTag(fromID: "renamed", toID: "renamed"))

        XCTAssertTrue(store.removeTag("renamed"))
        XCTAssertNil(store.allOrders()["renamed"])
        XCTAssertFalse(store.removeTag("renamed"))
        XCTAssertEqual(store.order(tagID: "unrelated"), unrelatedOrder)
    }

    func testMergeTagKeepsTargetPriorityAppendsSourceOnlyCardsAndDeletesSource() throws {
        let suite = "CardSeriesOrderStoreMergeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CardSeriesOrderStore(defaults: defaults)
        let first = UUID()
        let shared = UUID()
        let sourceOnly = UUID()
        let last = UUID()

        XCTAssertTrue(store.setOrder([first, shared], tagID: "target"))
        XCTAssertTrue(store.setOrder([shared, sourceOnly, first, last], tagID: "source"))
        XCTAssertTrue(store.mergeTag(sourceID: "source", targetID: "target"))
        XCTAssertEqual(store.order(tagID: "target"), [first, shared, sourceOnly, last])
        XCTAssertNil(store.allOrders()["source"])
        XCTAssertFalse(store.mergeTag(sourceID: "missing", targetID: "target"))
        XCTAssertFalse(store.mergeTag(sourceID: "target", targetID: "target"))

        XCTAssertEqual(
            CardSeriesOrderStore(defaults: defaults).order(tagID: "target"),
            [first, shared, sourceOnly, last]
        )
    }

    func testMaterializedMergePreservesFallbackOrdersWithoutSourceStoreEntry() throws {
        let suite = "CardSeriesOrderStoreFallbackMergeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CardSeriesOrderStore(defaults: defaults)
        let targetFirst = UUID()
        let shared = UUID()
        let sourceFirst = UUID()
        let sourceLast = UUID()

        XCTAssertTrue(store.mergeTag(
            sourceID: "source",
            targetID: "target",
            targetCardIDs: [targetFirst, shared],
            sourceCardIDs: [shared, sourceFirst, sourceLast]
        ))

        XCTAssertEqual(
            store.order(tagID: "target"),
            [targetFirst, shared, sourceFirst, sourceLast]
        )
        XCTAssertNil(store.allOrders()["source"])
    }

    func testSnapshotRestoreRollsBackLifecycleMutationsAndPersistsVersionOne() throws {
        let suite = "CardSeriesOrderStoreSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CardSeriesOrderStore(defaults: defaults)
        let original: [String: [UUID]] = [
            "source": [UUID(), UUID()],
            "target": [UUID()],
        ]
        for (tagID, order) in original {
            XCTAssertTrue(store.setOrder(order, tagID: tagID))
        }
        let snapshot = store.snapshot()

        XCTAssertTrue(store.mergeTag(sourceID: "source", targetID: "target"))
        XCTAssertNotEqual(store.allOrders(), original)
        XCTAssertTrue(store.restore(snapshot))
        XCTAssertEqual(store.allOrders(), original)
        XCTAssertEqual(CardSeriesOrderStore(defaults: defaults).allOrders(), original)

        let data = try XCTUnwrap(defaults.data(forKey: CardSeriesOrderStore.defaultsKey))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
    }
}

final class CardSeriesDocumentBuilderTests: XCTestCase {
    func testBuildsOrderedTutorialWithContentsAndChapterMarkers() throws {
        let tag = try CardTag("CS Tutorial")
        let cards = [
            CardRecord(title: "Setup", markdown: "Install it." , tags: [tag]),
            CardRecord(title: "Attention", markdown: "## Masking\nDetails.", tags: [tag]),
        ]

        let document = try CardSeriesDocumentBuilder.build(tag: tag, cards: cards)

        XCTAssertTrue(document.markdown.contains("# CS Tutorial"))
        XCTAssertTrue(document.markdown.contains("1. [Setup](#chapter-1-setup)"))
        XCTAssertTrue(document.markdown.contains("## Chapter 2: Attention"))
        XCTAssertTrue(document.markdown.contains(cards[1].id.uuidString.lowercased()))
        XCTAssertTrue(document.issues.isEmpty)
    }

    func testChapterContentsAnchorUsesTheSameSlugRulesAsItsHeading() throws {
        let tag = try CardTag("CS Tutorial")
        let card = CardRecord(title: "Data.Model", markdown: "Body", tags: [tag])

        let document = try CardSeriesDocumentBuilder.build(tag: tag, cards: [card])

        XCTAssertTrue(document.markdown.contains(
            "1. [Data.Model](#chapter-1-datamodel)"
        ))
        XCTAssertEqual(
            CardSeriesDocumentBuilder.chapterAnchor(index: 0, title: "Data_Model"),
            "chapter-1-data_model"
        )
    }

    func testCombinedSeriesRebasesDuplicateChapterHeadingFragmentsWithoutChangingCode() throws {
        let tag = try CardTag("Course")
        let first = CardRecord(
            title: "First",
            markdown: "[First setup](#setup)\n\n## Setup",
            tags: [tag]
        )
        let second = CardRecord(
            title: "Second",
            markdown: """
            [Second setup](#setup)

            [setup-ref]: #setup

            ## Setup

            `example [link](#setup)`

            ```markdown
            [example](#setup)
            ## Setup
            ```
            """,
            tags: [tag]
        )

        let document = try CardSeriesDocumentBuilder.build(tag: tag, cards: [first, second])

        XCTAssertTrue(document.markdown.contains("[First setup](#setup)"))
        XCTAssertTrue(document.markdown.contains("[Second setup](#setup-1)"))
        XCTAssertTrue(document.markdown.contains("[setup-ref]: #setup-1"))
        XCTAssertTrue(document.markdown.contains("`example [link](#setup)`"))
        XCTAssertTrue(document.markdown.contains("[example](#setup)\n## Setup\n```"))
    }

    func testReportsMissingAndEscapingRelativeLinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CardSeriesDocumentBuilderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("chapter.md")
        try Data().write(to: sourceURL)
        let tag = try CardTag("Course")
        let card = CardRecord(
            markdown: "[Missing](./src/missing.py)\n[Escape](../secret.txt)",
            tags: [tag]
        )

        let issues = CardSeriesDocumentBuilder.validateLinks(
            cards: [card],
            fileURLsByCardID: [card.id: sourceURL]
        )

        XCTAssertEqual(issues.count, 2)
        XCTAssertTrue(issues.contains { $0.reason.contains("does not exist") })
        XCTAssertTrue(issues.contains { $0.reason.contains("escapes") })
    }

    func testValidatesInternalAndCrossCardHeadingFragments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CardSeriesFragmentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("first.md")
        let secondURL = root.appendingPathComponent("second.md")
        try Data().write(to: firstURL)
        try Data().write(to: secondURL)
        let tag = try CardTag("Course")
        let first = CardRecord(
            markdown: "# Intro\n[Good](#intro)\n[Bad](#missing)\n[Other](./second.md#details)",
            tags: [tag]
        )
        let second = CardRecord(markdown: "## Details", tags: [tag])

        let issues = CardSeriesDocumentBuilder.validateLinks(
            cards: [first, second],
            fileURLsByCardID: [first.id: firstURL, second.id: secondURL]
        )

        XCTAssertEqual(issues.count, 2)
        XCTAssertTrue(issues.contains { $0.destination == "#missing" })
        XCTAssertTrue(issues.contains {
            $0.destination == "./second.md#details" && $0.reason.contains("not bundled")
        })
    }

    func testUnboundRelativeLinkIsReportedAsUnverifiable() throws {
        let tag = try CardTag("Course")
        let card = CardRecord(markdown: "[Example](./examples/demo.py)", tags: [tag])

        let issues = CardSeriesDocumentBuilder.validateLinks(
            cards: [card],
            fileURLsByCardID: [:]
        )

        XCTAssertEqual(issues.count, 1)
        XCTAssertTrue(issues[0].reason.contains("no linked source file"))
    }

    func testPortableSeriesExportCopiesAndNamespacesChapterImages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CardSeriesPortableExportTests-\(UUID().uuidString)")
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let sourceAssets = sourceRoot.appendingPathComponent("assets", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("Export", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceAssets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z0b8AAAAASUVORK5CYII="
        ))
        try png.write(to: sourceAssets.appendingPathComponent("diagram.png"))
        let sourceMarkdownURL = sourceRoot.appendingPathComponent("chapter.md")
        try Data("# Source".utf8).write(to: sourceMarkdownURL)

        let tag = try CardTag("CS Course")
        let card = CardRecord(
            title: "Setup",
            markdown: "![Architecture](assets/diagram.png)",
            tags: [tag]
        )
        let document = try CardSeriesDocumentBuilder.build(
            tag: tag,
            cards: [card],
            fileURLsByCardID: [card.id: sourceMarkdownURL]
        )
        let destination = destinationRoot.appendingPathComponent("Course.md")

        let result = try CardSeriesExportWriter().writePortable(
            document,
            tag: tag,
            cards: [card],
            fileURLsByCardID: [card.id: sourceMarkdownURL],
            to: destination
        )

        let shortID = card.id.uuidString.lowercased().prefix(8)
        let relativeImage = "Course-assets/chapter-1-\(shortID)/assets/diagram.png"
        let exported = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(exported.contains("![Architecture](\(relativeImage))"))
        XCTAssertEqual(result.copiedResourcePaths, [relativeImage])
        XCTAssertTrue(result.unresolvedResourcePaths.isEmpty)
        XCTAssertEqual(
            try Data(contentsOf: destinationRoot.appendingPathComponent(relativeImage)),
            png
        )
    }

    func testPortableSeriesExportSanitizesTildeStemAndReopensEncodedImagePath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CardSeriesSafeStemTests-\(UUID().uuidString)")
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let sourceAssets = sourceRoot.appendingPathComponent("assets", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("Export", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceAssets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z0b8AAAAASUVORK5CYII="
        ))
        try png.write(to: sourceAssets.appendingPathComponent("attention flow.png"))
        let sourceMarkdownURL = sourceRoot.appendingPathComponent("chapter.md")
        try Data().write(to: sourceMarkdownURL)
        let tag = try CardTag("Course")
        let card = CardRecord(
            title: "Images",
            markdown: "![Flow](<assets/attention flow.png>)",
            tags: [tag]
        )
        let document = try CardSeriesDocumentBuilder.build(
            tag: tag,
            cards: [card],
            fileURLsByCardID: [card.id: sourceMarkdownURL]
        )
        let destination = destinationRoot.appendingPathComponent("~Course.md")

        _ = try CardSeriesExportWriter().writePortable(
            document,
            tag: tag,
            cards: [card],
            fileURLsByCardID: [card.id: sourceMarkdownURL],
            to: destination
        )

        let shortID = card.id.uuidString.lowercased().prefix(8)
        let relativeImage = "Course-assets/chapter-1-\(shortID)/assets/attention%20flow.png"
        let exported = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(exported.contains("![Flow](<\(relativeImage)>)"))
        let reopened = try DocumentImageResolver().load(
            relativePath: relativeImage,
            documentRoot: destinationRoot
        )
        XCTAssertEqual(reopened.data, png)
    }
}
