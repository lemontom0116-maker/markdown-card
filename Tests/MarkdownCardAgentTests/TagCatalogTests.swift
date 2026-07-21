import Foundation
import XCTest
@testable import MarkdownCardAgent
@testable import MarkdownCardCore

final class TagCatalogSnapshotTests: XCTestCase {
    func testCatalogScalesAcrossEmptySmallAndLargeCardSets() throws {
        for count in [0, 1, 10, 100] {
            let cards = try (0 ..< count).map { index in
                CardRecord(
                    markdown: "# Card \(index)",
                    tags: [try CardTag(String(format: "Tag %03d", index))]
                )
            }

            let snapshot = TagCatalogSnapshot(cards: cards)

            XCTAssertEqual(snapshot.entries.count, count, "count=\(count)")
            XCTAssertEqual(snapshot.validTagIDs.count, count, "count=\(count)")
            XCTAssertEqual(
                snapshot.orderedCandidates(
                    activeTagID: nil,
                    preferences: .empty
                ).count,
                count,
                "count=\(count)"
            )
        }
    }

    func testCanonicalTagUsesOldestCardSpellingAndCountsEachCardOnce() throws {
        let fullWidth = try CardTag("ＡＩ")
        let lowercased = try CardTag("ai")
        XCTAssertEqual(fullWidth.id, lowercased.id)

        let newer = CardRecord(
            markdown: "Newer",
            createdAt: Date(timeIntervalSince1970: 20),
            tags: [lowercased]
        )
        var older = CardRecord(
            markdown: "Older",
            createdAt: Date(timeIntervalSince1970: 10),
            tags: [fullWidth]
        )
        // Defend catalog counts against malformed direct mutation.
        older.tags.append(lowercased)

        let snapshot = TagCatalogSnapshot(cards: [newer, older])
        let entry = try XCTUnwrap(snapshot.entry(tagID: fullWidth.id))

        XCTAssertEqual(entry.name, "ＡＩ")
        XCTAssertEqual(entry.cardCount, 2)
    }

    func testUnicodeTagsRemainDistinctWhenTheirNormalizedIDsDiffer() throws {
        let tags = try ["学习", "學習", "Cafe", "Café"].map { try CardTag($0) }
        let snapshot = TagCatalogSnapshot(cards: tags.map {
            CardRecord(markdown: $0.name, tags: [$0])
        })

        XCTAssertEqual(snapshot.entries.count, 4)
        XCTAssertEqual(snapshot.validTagIDs, Set(tags.map(\.id)))
    }

    func testCandidatePriorityIsActivePinnedRecentThenUsageFallback() throws {
        let names = ["Active", "Alpha", "Zebra", "Recent One", "Recent Two", "Popular", "Low"]
        let tags = try Dictionary(uniqueKeysWithValues: names.map {
            let tag = try CardTag($0)
            return ($0, tag)
        })
        var cards = names.map { CardRecord(markdown: $0, tags: [tags[$0]!]) }
        cards.append(CardRecord(markdown: "Popular 2", tags: [tags["Popular"]!]))
        cards.append(CardRecord(markdown: "Popular 3", tags: [tags["Popular"]!]))
        let snapshot = TagCatalogSnapshot(cards: cards)
        let preferences = TagCatalogPreferences(
            pinnedTagIDs: [tags["Zebra"]!.id, tags["Alpha"]!.id, tags["Active"]!.id],
            recentTagIDs: [tags["Recent Two"]!.id, tags["Active"]!.id, tags["Recent One"]!.id]
        )

        let candidates = snapshot.orderedCandidates(
            activeTagID: tags["Active"]!.id,
            preferences: preferences
        )

        XCTAssertEqual(
            candidates.map(\.name),
            ["Active", "Alpha", "Zebra", "Recent Two", "Recent One", "Popular", "Low"]
        )
        XCTAssertEqual(Set(candidates.map(\.id)).count, candidates.count)
    }

    func testUsageFallbackUsesStableNameOrderForTies() throws {
        let alpha = try CardTag("alpha")
        let beta = try CardTag("Beta")
        let popular = try CardTag("Popular")
        let cards = [
            CardRecord(markdown: "alpha", tags: [alpha]),
            CardRecord(markdown: "beta", tags: [beta]),
            CardRecord(markdown: "popular 1", tags: [popular]),
            CardRecord(markdown: "popular 2", tags: [popular]),
        ]

        let names = TagCatalogSnapshot(cards: cards)
            .orderedCandidates(activeTagID: nil, preferences: .empty)
            .map(\.name)

        XCTAssertEqual(names, ["Popular", "alpha", "Beta"])
    }
}

final class TagCatalogPreferencesStoreTests: XCTestCase {
    func testPinnedAndRecentPreferencesPersistWithMRUSemantics() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let alpha = try CardTag("Alpha")
        let beta = try CardTag("Beta")
        let valid = Set([alpha.id, beta.id])
        let store = TagCatalogPreferencesStore(defaults: context.defaults)

        _ = try store.setPinned(true, tagID: beta.id, validTagIDs: valid)
        _ = try store.recordRecent(tagID: alpha.id, validTagIDs: valid)
        _ = try store.recordRecent(tagID: beta.id, validTagIDs: valid)
        _ = try store.recordRecent(tagID: alpha.id, validTagIDs: valid)

        let reloaded = TagCatalogPreferencesStore(defaults: context.defaults)
            .load(validTagIDs: valid)
        XCTAssertEqual(reloaded.pinnedTagIDs, [beta.id])
        XCTAssertEqual(reloaded.recentTagIDs, [alpha.id, beta.id])
    }

    func testLoadPrunesStalePinnedAndRecentIDsAndPersistsCleanup() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let alpha = try CardTag("Alpha")
        let beta = try CardTag("Beta")
        let allIDs = Set([alpha.id, beta.id])
        let store = TagCatalogPreferencesStore(defaults: context.defaults)
        _ = try store.setPinned(true, tagID: alpha.id, validTagIDs: allIDs)
        _ = try store.setPinned(true, tagID: beta.id, validTagIDs: allIDs)
        _ = try store.recordRecent(tagID: alpha.id, validTagIDs: allIDs)
        _ = try store.recordRecent(tagID: beta.id, validTagIDs: allIDs)

        let pruned = store.load(validTagIDs: [alpha.id])
        XCTAssertEqual(pruned.pinnedTagIDs, [alpha.id])
        XCTAssertEqual(pruned.recentTagIDs, [alpha.id])

        let persisted = TagCatalogPreferencesStore(defaults: context.defaults)
            .load(validTagIDs: allIDs)
        XCTAssertEqual(persisted.pinnedTagIDs, [alpha.id])
        XCTAssertEqual(persisted.recentTagIDs, [alpha.id])
    }

    func testReadOnlyLoadSanitizesSnapshotWithoutWritingCleanup() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let alpha = try CardTag("Alpha")
        let beta = try CardTag("Beta")
        let allIDs = Set([alpha.id, beta.id])
        let store = TagCatalogPreferencesStore(defaults: context.defaults)
        _ = try store.setPinned(true, tagID: alpha.id, validTagIDs: allIDs)
        _ = try store.setPinned(true, tagID: beta.id, validTagIDs: allIDs)
        _ = try store.recordRecent(tagID: beta.id, validTagIDs: allIDs)

        let readOnly = store.load(
            validTagIDs: [alpha.id],
            persistCleanup: false
        )
        XCTAssertEqual(readOnly.pinnedTagIDs, [alpha.id])
        XCTAssertTrue(readOnly.recentTagIDs.isEmpty)

        let stillStored = TagCatalogPreferencesStore(defaults: context.defaults)
            .load(validTagIDs: allIDs, persistCleanup: false)
        XCTAssertEqual(stillStored.pinnedTagIDs, allIDs)
        XCTAssertEqual(stillStored.recentTagIDs, [beta.id])
    }

    func testRecentLimitAndInvalidIDsCannotPollutePreferences() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let tags = try (0 ..< 10).map { try CardTag("Tag \($0)") }
        let valid = Set(tags.map(\.id))
        let store = TagCatalogPreferencesStore(
            defaults: context.defaults,
            recentLimit: 3
        )
        for tag in tags.prefix(5) {
            _ = try store.recordRecent(tagID: tag.id, validTagIDs: valid)
        }
        _ = try store.recordRecent(tagID: "missing", validTagIDs: valid)
        _ = try store.setPinned(true, tagID: "missing", validTagIDs: valid)

        let preferences = store.load(validTagIDs: valid)
        XCTAssertEqual(preferences.recentTagIDs, tags.prefix(5).reversed().prefix(3).map(\.id))
        XCTAssertFalse(preferences.pinnedTagIDs.contains("missing"))
    }

    func testUnsupportedVersionIsBackedUpAndIgnored() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let unsupported = Data(#"{"version":99,"pinnedTagIDs":["alpha"],"recentTagIDs":["alpha"]}"#.utf8)
        context.defaults.set(unsupported, forKey: TagCatalogPreferencesStore.defaultsKey)

        let preferences = TagCatalogPreferencesStore(defaults: context.defaults)
            .load(validTagIDs: ["alpha"])

        XCTAssertEqual(preferences, .empty)
        XCTAssertEqual(
            context.defaults.data(
                forKey: TagCatalogPreferencesStore.defaultsKey
                    + TagCatalogPreferencesStore.corruptBackupSuffix
            ),
            unsupported
        )
    }

    func testPinAndRecentWritesReportFailureInsteadOfPublishingOptimisticState() throws {
        let suite = "TagCatalogPreferencesStoreFailureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(RejectingUserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.rejectWrites = true
        let tag = try CardTag("Pinned")
        let store = TagCatalogPreferencesStore(defaults: defaults)

        XCTAssertThrowsError(
            try store.setPinned(true, tagID: tag.id, validTagIDs: [tag.id])
        ) { error in
            XCTAssertEqual(error as? TagCatalogPreferencesStoreError, .saveFailed)
        }
        XCTAssertThrowsError(
            try store.recordRecent(tagID: tag.id, validTagIDs: [tag.id])
        ) { error in
            XCTAssertEqual(error as? TagCatalogPreferencesStoreError, .saveFailed)
        }
        XCTAssertEqual(store.load(validTagIDs: [tag.id]), .empty)
    }

    func testMigrationCarriesPinAndRecentPositionThenSnapshotRestores() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let source = try CardTag("Source")
        let target = try CardTag("Target")
        let other = try CardTag("Other")
        let oldValid = Set([source.id, target.id, other.id])
        let newValid = Set([target.id, other.id])
        let store = TagCatalogPreferencesStore(defaults: context.defaults)
        _ = try store.setPinned(true, tagID: source.id, validTagIDs: oldValid)
        _ = try store.recordRecent(tagID: target.id, validTagIDs: oldValid)
        _ = try store.recordRecent(tagID: other.id, validTagIDs: oldValid)
        _ = try store.recordRecent(tagID: source.id, validTagIDs: oldValid)
        let snapshot = store.snapshot()

        XCTAssertTrue(store.migrateTag(
            fromID: source.id,
            toID: target.id,
            validTagIDs: newValid
        ))
        let migrated = store.load(validTagIDs: newValid)
        XCTAssertEqual(migrated.pinnedTagIDs, [target.id])
        XCTAssertEqual(migrated.recentTagIDs, [target.id, other.id])

        XCTAssertTrue(store.restore(snapshot))
        XCTAssertEqual(store.load(validTagIDs: oldValid).pinnedTagIDs, [source.id])
        XCTAssertEqual(
            store.load(validTagIDs: oldValid).recentTagIDs,
            [source.id, other.id, target.id]
        )
    }

    func testMigrationWithNilDestinationRemovesSourcePreferences() throws {
        let context = try makeDefaults()
        defer { context.defaults.removePersistentDomain(forName: context.suite) }
        let source = try CardTag("Source")
        let other = try CardTag("Other")
        let oldValid = Set([source.id, other.id])
        let store = TagCatalogPreferencesStore(defaults: context.defaults)
        _ = try store.setPinned(true, tagID: source.id, validTagIDs: oldValid)
        _ = try store.recordRecent(tagID: other.id, validTagIDs: oldValid)
        _ = try store.recordRecent(tagID: source.id, validTagIDs: oldValid)

        XCTAssertTrue(store.migrateTag(
            fromID: source.id,
            toID: nil,
            validTagIDs: [other.id]
        ))
        XCTAssertEqual(
            store.load(validTagIDs: [other.id]),
            TagCatalogPreferences(pinnedTagIDs: [], recentTagIDs: [other.id])
        )
    }

    private func makeDefaults() throws -> (defaults: UserDefaults, suite: String) {
        let suite = "TagCatalogPreferencesStoreTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }
}

private final class RejectingUserDefaults: UserDefaults {
    var rejectWrites = false

    override func set(_ value: Any?, forKey defaultName: String) {
        guard !rejectWrites else { return }
        super.set(value, forKey: defaultName)
    }
}
