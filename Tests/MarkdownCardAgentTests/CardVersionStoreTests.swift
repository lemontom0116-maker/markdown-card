import Foundation
import XCTest
@testable import MarkdownCardAgent
@testable import MarkdownCardCore

final class CardVersionStoreTests: XCTestCase {
    private struct LegacyEnvelope: Encodable {
        let version: Int
        let snapshots: [CardVersionSnapshot]
    }

    func testRecordsDistinctSnapshotsNewestFirstAndPersists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CardVersionStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CardVersionStore(rootURL: root)
        let cardID = UUID()
        var card = CardRecord(
            id: cardID,
            markdown: "# One",
            createdAt: .init(timeIntervalSince1970: 1),
            updatedAt: .init(timeIntervalSince1970: 1)
        )

        XCTAssertTrue(try store.record(card, capturedAt: .init(timeIntervalSince1970: 2)))
        XCTAssertFalse(try store.record(card, capturedAt: .init(timeIntervalSince1970: 3)))
        card.updateMarkdown("# Two", at: .init(timeIntervalSince1970: 4))
        XCTAssertTrue(try store.record(card, capturedAt: .init(timeIntervalSince1970: 5)))

        let reloaded = try CardVersionStore(rootURL: root).snapshots(cardID: cardID)
        XCTAssertEqual(reloaded.map(\.markdown), ["# Two", "# One"])
    }

    func testDetectsSnapshotNewerThanPersistedCardForCrashRecovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CardVersionRecoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CardVersionStore(rootURL: root)
        let persisted = CardRecord(
            markdown: "old",
            createdAt: .init(timeIntervalSince1970: 1),
            updatedAt: .init(timeIntervalSince1970: 10)
        )
        var draft = persisted
        draft.updateMarkdown("new draft", at: .init(timeIntervalSince1970: 20))
        _ = try store.record(draft, capturedAt: .init(timeIntervalSince1970: 21))

        XCTAssertEqual(try store.recoverableSnapshot(for: persisted)?.markdown, "new draft")
    }

    func testSnapshotTimestampRoundTripsWithSubsecondPrecision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CardVersionPrecisionTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let card = CardRecord(markdown: "draft")
        let capturedAt = Date(timeIntervalSince1970: 1_754_000_000.123_456)

        XCTAssertTrue(try CardVersionStore(rootURL: root).record(card, capturedAt: capturedAt))

        let reloaded = try CardVersionStore(rootURL: root).snapshots(cardID: card.id)
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(
            reloaded[0].capturedAt.timeIntervalSince1970,
            capturedAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        let data = try Data(contentsOf: root.appendingPathComponent(
            card.id.uuidString.lowercased() + ".json"
        ))
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(envelope["version"] as? Int, 2)
    }

    func testDetectsNewerSnapshotCreatedWithinSameSecondAfterReload() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CardVersionSameSecondTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let persisted = CardRecord(
            markdown: "old",
            createdAt: .init(timeIntervalSince1970: 10),
            updatedAt: .init(timeIntervalSince1970: 10.1)
        )
        var draft = persisted
        draft.updateMarkdown("same-second draft", at: .init(timeIntervalSince1970: 10.2))
        _ = try CardVersionStore(rootURL: root).record(
            draft,
            capturedAt: .init(timeIntervalSince1970: 10.2)
        )

        let recovered = try XCTUnwrap(
            CardVersionStore(rootURL: root).recoverableSnapshot(for: persisted)
        )

        XCTAssertEqual(recovered.markdown, "same-second draft")
        XCTAssertEqual(recovered.capturedAt.timeIntervalSince1970, 10.2, accuracy: 0.000_001)
    }

    func testDetectsTitleOnlyRecoverySnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CardVersionTitleRecoveryTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let persisted = CardRecord(
            markdown: "unchanged body",
            createdAt: .init(timeIntervalSince1970: 20),
            updatedAt: .init(timeIntervalSince1970: 20.1)
        )
        let renamedDraft = CardRecord(
            id: persisted.id,
            titleOverride: "Recovered title",
            markdown: persisted.markdown,
            createdAt: persisted.createdAt,
            updatedAt: .init(timeIntervalSince1970: 20.2)
        )
        _ = try CardVersionStore(rootURL: root).record(
            renamedDraft,
            capturedAt: .init(timeIntervalSince1970: 20.2)
        )

        let recovered = try CardVersionStore(rootURL: root).recoverableSnapshot(for: persisted)

        XCTAssertEqual(recovered?.markdown, persisted.markdown)
        XCTAssertEqual(recovered?.titleOverride, "Recovered title")
    }

    func testReadsLegacyVersionOneISO8601Envelope() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CardVersionLegacyTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let card = CardRecord(markdown: "legacy draft")
        let snapshot = CardVersionSnapshot(
            card: card,
            capturedAt: .init(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(LegacyEnvelope(version: 1, snapshots: [snapshot])).write(
            to: root.appendingPathComponent(card.id.uuidString.lowercased() + ".json")
        )

        let reloaded = try CardVersionStore(rootURL: root).snapshots(cardID: card.id)

        XCTAssertEqual(reloaded, [snapshot])
    }

    func testComparisonShowsChangedLinesAndTruncatesLargeOutput() {
        let diff = MarkdownComparison.render(
            original: "same\nold\ntail",
            modified: "same\nnew\ntail"
        )
        XCTAssertTrue(diff.contains("- old"))
        XCTAssertTrue(diff.contains("+ new"))
        XCTAssertTrue(diff.contains("  tail"))
    }
}
