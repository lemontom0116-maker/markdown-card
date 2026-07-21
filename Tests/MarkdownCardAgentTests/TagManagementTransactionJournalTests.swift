import Foundation
import MarkdownCardCore
import XCTest
@testable import MarkdownCardAgent

@MainActor
final class TagManagementTransactionJournalTests: XCTestCase {
    func testJournalAtomicallyRoundTripsExactSnapshotAndRefusesOverwrite() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = try CardTag("Research")
        let card = CardRecord(markdown: "# Notes", tags: [source])
        XCTAssertTrue(fixture.seriesStore.setOrder([card.id], tagID: source.id))
        _ = try fixture.preferencesStore.setPinned(
            true,
            tagID: source.id,
            validTagIDs: [source.id]
        )
        let entry = TagManagementTransactionJournal.Entry(
            previousCards: [card],
            previousSeries: fixture.seriesStore.snapshot(),
            previousPreferences: fixture.preferencesStore.snapshot()
        )

        try fixture.journal.write(entry)

        let loaded = try XCTUnwrap(fixture.journal.load())
        XCTAssertEqual(loaded.previousCards.first?.tags.first?.name, "Research")
        XCTAssertEqual(loaded.previousSeries, entry.previousSeries)
        XCTAssertEqual(loaded.previousPreferences, entry.previousPreferences)
        XCTAssertThrowsError(try fixture.journal.write(entry)) { error in
            XCTAssertEqual(
                error as? TagManagementTransactionJournal.JournalError,
                .transactionAlreadyPending
            )
        }

        try fixture.journal.clear()
        XCTAssertFalse(fixture.journal.hasPendingTransaction)
        XCTAssertNil(try fixture.journal.load())
    }

    func testSuccessfulGlobalRenameClearsJournalAfterAllStoresCommit() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let repository = ScriptedTagManagementRepository()
        let controller = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: fixture.defaults),
            defaults: fixture.defaults,
            seriesOrderStore: fixture.seriesStore,
            tagPreferencesStore: fixture.preferencesStore,
            tagManagementJournal: fixture.journal
        )
        let source = try CardTag("Research")
        let destination = try CardTag("Ideas")
        let card = try await controller.createIndependentCard(
            markdown: "# Notes",
            tags: [source],
            show: false
        )
        XCTAssertTrue(fixture.seriesStore.setOrder([card.id], tagID: source.id))
        _ = try fixture.preferencesStore.setPinned(
            true,
            tagID: source.id,
            validTagIDs: [source.id]
        )
        _ = try fixture.preferencesStore.recordRecent(
            tagID: source.id,
            validTagIDs: [source.id]
        )

        try await controller.performTagManagementOperationForTesting(
            .rename(sourceID: source.id, replacement: destination)
        )

        let storedSnapshot = await repository.card(id: card.id)
        let stored = try XCTUnwrap(storedSnapshot)
        XCTAssertEqual(stored.tags.map(\.name), [destination.name])
        XCTAssertEqual(fixture.seriesStore.order(tagID: destination.id), [card.id])
        let preferences = fixture.preferencesStore.load(validTagIDs: [destination.id])
        XCTAssertEqual(preferences.pinnedTagIDs, [destination.id])
        XCTAssertEqual(preferences.recentTagIDs, [destination.id])
        XCTAssertFalse(fixture.journal.hasPendingTransaction)
        XCTAssertFalse(controller.isTagManagementRecoveryRequiredForTesting)
    }

    func testCommitFailureWithVerifiedRollbackClearsJournal() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let repository = ScriptedTagManagementRepository()
        let controller = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: fixture.defaults),
            defaults: fixture.defaults,
            seriesOrderStore: fixture.seriesStore,
            tagPreferencesStore: fixture.preferencesStore,
            tagManagementJournal: fixture.journal
        )
        let source = try CardTag("Research")
        let destination = try CardTag("Ideas")
        let card = try await controller.createIndependentCard(
            markdown: "# Notes",
            tags: [source],
            show: false
        )
        XCTAssertTrue(fixture.seriesStore.setOrder([card.id], tagID: source.id))
        await repository.setReplaceBehaviors([.applyThenThrow, .succeed])

        do {
            try await controller.performTagManagementOperationForTesting(
                .rename(sourceID: source.id, replacement: destination)
            )
            XCTFail("Expected injected commit failure")
        } catch ScriptedTagManagementRepository.ProbeError.injected {
            // The first replace changed repository state and then failed. The
            // journal-backed compensation must restore and verify the old card.
        }

        let restoredSnapshot = await repository.card(id: card.id)
        let restored = try XCTUnwrap(restoredSnapshot)
        XCTAssertEqual(restored.tags.map(\.name), [source.name])
        XCTAssertEqual(fixture.seriesStore.order(tagID: source.id), [card.id])
        XCTAssertFalse(fixture.journal.hasPendingTransaction)
        XCTAssertFalse(controller.isTagManagementRecoveryRequiredForTesting)
        let replaceCalls = await repository.replaceCallCount()
        XCTAssertEqual(replaceCalls, 2)
    }

    func testRollbackFailureRetainsJournalAndStartupRecoveryIsIdempotent() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let repository = ScriptedTagManagementRepository()
        let firstController = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: fixture.defaults),
            defaults: fixture.defaults,
            seriesOrderStore: fixture.seriesStore,
            tagPreferencesStore: fixture.preferencesStore,
            tagManagementJournal: fixture.journal
        )
        let source = try CardTag("Research")
        let destination = try CardTag("Ideas")
        let card = try await firstController.createIndependentCard(
            markdown: "# Notes",
            tags: [source],
            show: false
        )
        XCTAssertTrue(fixture.seriesStore.setOrder([card.id], tagID: source.id))
        _ = try fixture.preferencesStore.setPinned(
            true,
            tagID: source.id,
            validTagIDs: [source.id]
        )
        await repository.setReplaceBehaviors([.applyThenThrow, .throwBeforeWrite])

        do {
            try await firstController.performTagManagementOperationForTesting(
                .rename(sourceID: source.id, replacement: destination)
            )
            XCTFail("Expected recovery-required failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("recovery journal"))
        }

        XCTAssertTrue(firstController.isTagManagementRecoveryRequiredForTesting)
        XCTAssertTrue(fixture.journal.hasPendingTransaction)
        let pending = try XCTUnwrap(fixture.journal.load())
        XCTAssertEqual(pending.previousCards.first?.tags.map(\.name), [source.name])
        let callsBeforeRejectedRetry = await repository.replaceCallCount()
        do {
            try await firstController.performTagManagementOperationForTesting(
                .delete(tagID: source.id)
            )
            XCTFail("Expected Tag management to remain blocked")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Saving is paused"))
        }
        let callsAfterRejectedRetry = await repository.replaceCallCount()
        XCTAssertEqual(callsAfterRejectedRetry, callsBeforeRejectedRetry)

        let recoveryController = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: fixture.defaults),
            defaults: fixture.defaults,
            seriesOrderStore: fixture.seriesStore,
            tagPreferencesStore: fixture.preferencesStore,
            tagManagementJournal: fixture.journal
        )
        await repository.setReplaceBehaviors([.throwBeforeWrite])
        do {
            try await recoveryController.recoverPendingTagManagementTransactionForTesting()
            XCTFail("Expected first startup recovery attempt to fail")
        } catch {
            XCTAssertTrue(recoveryController.isTagManagementRecoveryRequiredForTesting)
            XCTAssertTrue(fixture.journal.hasPendingTransaction)
        }

        await repository.setReplaceBehaviors([.succeed])
        try await recoveryController.recoverPendingTagManagementTransactionForTesting()

        let recoveredSnapshot = await repository.card(id: card.id)
        let recovered = try XCTUnwrap(recoveredSnapshot)
        XCTAssertEqual(recovered.tags.map(\.name), [source.name])
        XCTAssertEqual(fixture.seriesStore.order(tagID: source.id), [card.id])
        let preferences = fixture.preferencesStore.load(validTagIDs: [source.id])
        XCTAssertEqual(preferences.pinnedTagIDs, [source.id])
        XCTAssertFalse(fixture.journal.hasPendingTransaction)
        XCTAssertFalse(recoveryController.isTagManagementRecoveryRequiredForTesting)
    }

    func testSingleCardTagRemovalCommitsCardAndExplicitSeriesPositionTogether() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let repository = ScriptedTagManagementRepository()
        let controller = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: fixture.defaults),
            defaults: fixture.defaults,
            seriesOrderStore: fixture.seriesStore,
            tagPreferencesStore: fixture.preferencesStore,
            tagManagementJournal: fixture.journal
        )
        let tag = try CardTag("Series")
        let card = try await controller.createIndependentCard(
            markdown: "# Chapter",
            tags: [tag],
            show: false
        )
        XCTAssertTrue(fixture.seriesStore.setOrder([card.id], tagID: tag.id))

        try await controller.performCardTagRemovalForTesting(cardID: card.id, tagID: tag.id)

        let storedSnapshot = await repository.card(id: card.id)
        let stored = try XCTUnwrap(storedSnapshot)
        XCTAssertTrue(stored.tags.isEmpty)
        XCTAssertNil(fixture.seriesStore.allOrders()[tag.id])
        XCTAssertFalse(fixture.journal.hasPendingTransaction)
    }

    func testSingleCardTagRemovalFailureRestoresTagAndSeriesPosition() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let repository = ScriptedTagManagementRepository()
        let controller = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: fixture.defaults),
            defaults: fixture.defaults,
            seriesOrderStore: fixture.seriesStore,
            tagPreferencesStore: fixture.preferencesStore,
            tagManagementJournal: fixture.journal
        )
        let tag = try CardTag("Series")
        let card = try await controller.createIndependentCard(
            markdown: "# Chapter",
            tags: [tag],
            show: false
        )
        XCTAssertTrue(fixture.seriesStore.setOrder([card.id], tagID: tag.id))
        await repository.setReplaceBehaviors([.applyThenThrow, .succeed])

        do {
            try await controller.performCardTagRemovalForTesting(cardID: card.id, tagID: tag.id)
            XCTFail("Expected injected removal failure")
        } catch ScriptedTagManagementRepository.ProbeError.injected {}

        let storedSnapshot = await repository.card(id: card.id)
        let stored = try XCTUnwrap(storedSnapshot)
        XCTAssertEqual(stored.tags.map(\.name), [tag.name])
        XCTAssertEqual(fixture.seriesStore.order(tagID: tag.id), [card.id])
        XCTAssertFalse(fixture.journal.hasPendingTransaction)
    }

    func testSeriesOrderSaveFailureRollsBackAllThreeStores() async throws {
        let (fixture, defaults) = try makeOneShotRejectingFixture()
        defer { fixture.cleanup() }
        let repository = ScriptedTagManagementRepository()
        let controller = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults,
            seriesOrderStore: fixture.seriesStore,
            tagPreferencesStore: fixture.preferencesStore,
            tagManagementJournal: fixture.journal
        )
        let source = try CardTag("Source")
        let replacement = try CardTag("Replacement")
        let card = try await controller.createIndependentCard(
            markdown: "# Chapter",
            tags: [source],
            show: false
        )
        XCTAssertTrue(fixture.seriesStore.setOrder([card.id], tagID: source.id))
        defaults.rejectedWritesRemaining = 1

        do {
            try await controller.performTagManagementOperationForTesting(
                .rename(sourceID: source.id, replacement: replacement)
            )
            XCTFail("Expected series order write failure")
        } catch {}

        let storedSnapshot = await repository.card(id: card.id)
        XCTAssertEqual(storedSnapshot?.tags.map(\.name), [source.name])
        XCTAssertEqual(fixture.seriesStore.order(tagID: source.id), [card.id])
        XCTAssertNil(fixture.seriesStore.allOrders()[replacement.id])
        XCTAssertFalse(fixture.journal.hasPendingTransaction)
        XCTAssertFalse(controller.isTagManagementRecoveryRequiredForTesting)
    }

    func testPreferenceSaveFailureRollsBackCardsAndKeepsPinAndRecent() async throws {
        let (fixture, defaults) = try makeOneShotRejectingFixture()
        defer { fixture.cleanup() }
        let repository = ScriptedTagManagementRepository()
        let controller = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults,
            seriesOrderStore: fixture.seriesStore,
            tagPreferencesStore: fixture.preferencesStore,
            tagManagementJournal: fixture.journal
        )
        let source = try CardTag("Source")
        let replacement = try CardTag("Replacement")
        let card = try await controller.createIndependentCard(
            markdown: "# Chapter",
            tags: [source],
            show: false
        )
        _ = try fixture.preferencesStore.setPinned(
            true,
            tagID: source.id,
            validTagIDs: [source.id]
        )
        _ = try fixture.preferencesStore.recordRecent(
            tagID: source.id,
            validTagIDs: [source.id]
        )
        defaults.rejectedWritesRemaining = 1

        do {
            try await controller.performTagManagementOperationForTesting(
                .rename(sourceID: source.id, replacement: replacement)
            )
            XCTFail("Expected Tag preference write failure")
        } catch {}

        let storedSnapshot = await repository.card(id: card.id)
        XCTAssertEqual(storedSnapshot?.tags.map(\.name), [source.name])
        let preferences = fixture.preferencesStore.load(validTagIDs: [source.id])
        XCTAssertEqual(preferences.pinnedTagIDs, [source.id])
        XCTAssertEqual(preferences.recentTagIDs, [source.id])
        XCTAssertFalse(fixture.journal.hasPendingTransaction)
        XCTAssertFalse(controller.isTagManagementRecoveryRequiredForTesting)
    }

    func testDeferredRemoveThenAddReplaysInOriginalOrderAfterGlobalRename() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let repository = ScriptedTagManagementRepository()
        let controller = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: fixture.defaults),
            defaults: fixture.defaults,
            seriesOrderStore: fixture.seriesStore,
            tagPreferencesStore: fixture.preferencesStore,
            tagManagementJournal: fixture.journal
        )
        let source = try CardTag("Source")
        let destination = try CardTag("Destination")
        let card = try await controller.createIndependentCard(
            markdown: "# Chapter",
            tags: [source],
            show: false
        )
        await repository.blockNextReplace()

        let renameTask = Task { @MainActor in
            try await controller.performTagManagementOperationForTesting(
                .rename(sourceID: source.id, replacement: destination)
            )
        }
        await repository.waitUntilReplaceIsBlocked()
        controller.stageCardTagRemovalForTesting(cardID: card.id, tagID: source.id)
        controller.stageTagCommand(
            id: card.id,
            tagName: source.name,
            markdown: card.markdown,
            incomingRevision: 1,
            source: .commandLine
        )
        await repository.releaseBlockedReplace()

        try await renameTask.value
        await controller.waitForDeferredSeriesReplayForTesting()
        try await controller.prepareForTermination()

        let storedSnapshot = await repository.card(id: card.id)
        let stored = try XCTUnwrap(storedSnapshot)
        XCTAssertEqual(stored.tags.map(\.name), [destination.name])
        XCTAssertFalse(fixture.journal.hasPendingTransaction)
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "TagManagementTransactionJournalTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TagManagementTransactionJournalTests-\(UUID().uuidString)",
                isDirectory: true
            )
        return Fixture(
            suiteName: suiteName,
            defaults: defaults,
            rootURL: rootURL,
            seriesStore: CardSeriesOrderStore(defaults: defaults),
            preferencesStore: TagCatalogPreferencesStore(defaults: defaults),
            journal: TagManagementTransactionJournal(
                fileURL: rootURL.appendingPathComponent(
                    TagManagementTransactionJournal.fileName
                )
            )
        )
    }

    private func makeOneShotRejectingFixture() throws
        -> (Fixture, OneShotRejectingUserDefaults)
    {
        let suiteName = "TagManagementTransactionJournalFailureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(OneShotRejectingUserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TagManagementTransactionJournalFailureTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let fixture = Fixture(
            suiteName: suiteName,
            defaults: defaults,
            rootURL: rootURL,
            seriesStore: CardSeriesOrderStore(defaults: defaults),
            preferencesStore: TagCatalogPreferencesStore(defaults: defaults),
            journal: TagManagementTransactionJournal(
                fileURL: rootURL.appendingPathComponent(
                    TagManagementTransactionJournal.fileName
                )
            )
        )
        return (fixture, defaults)
    }
}

private struct Fixture {
    let suiteName: String
    let defaults: UserDefaults
    let rootURL: URL
    let seriesStore: CardSeriesOrderStore
    let preferencesStore: TagCatalogPreferencesStore
    let journal: TagManagementTransactionJournal

    func cleanup() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private actor ScriptedTagManagementRepository: CardRepository {
    enum ProbeError: Error {
        case injected
    }

    enum ReplaceBehavior: Sendable {
        case succeed
        case throwBeforeWrite
        case applyThenThrow
    }

    private var cardsByID: [UUID: CardRecord] = [:]
    private var replaceBehaviors: [ReplaceBehavior] = []
    private var replaceCalls = 0
    private var shouldPauseNextReplace = false
    private var isReplacePaused = false
    private var replacePausedWaiters: [CheckedContinuation<Void, Never>] = []
    private var replaceReleaseContinuation: CheckedContinuation<Void, Never>?

    func allCards() -> [CardRecord] {
        Array(cardsByID.values)
    }

    func card(id: UUID) -> CardRecord? {
        cardsByID[id]
    }

    func upsert(_ card: CardRecord) -> CardRecord {
        cardsByID[card.id] = card
        return card
    }

    func delete(id: UUID) -> Bool {
        cardsByID.removeValue(forKey: id) != nil
    }

    func deleteLegacyQuickCards() -> Int {
        let ids = cardsByID.values.filter(\.isQuick).map(\.id)
        ids.forEach { cardsByID[$0] = nil }
        return ids.count
    }

    func replaceAll(with cards: [CardRecord]) async throws {
        replaceCalls += 1
        if shouldPauseNextReplace {
            shouldPauseNextReplace = false
            isReplacePaused = true
            let waiters = replacePausedWaiters
            replacePausedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                replaceReleaseContinuation = continuation
            }
            isReplacePaused = false
        }
        let behavior = replaceBehaviors.isEmpty ? .succeed : replaceBehaviors.removeFirst()
        switch behavior {
        case .succeed:
            cardsByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        case .throwBeforeWrite:
            throw ProbeError.injected
        case .applyThenThrow:
            cardsByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
            throw ProbeError.injected
        }
    }

    func setReplaceBehaviors(_ behaviors: [ReplaceBehavior]) {
        replaceBehaviors = behaviors
    }

    func replaceCallCount() -> Int {
        replaceCalls
    }

    func blockNextReplace() {
        shouldPauseNextReplace = true
    }

    func waitUntilReplaceIsBlocked() async {
        guard !isReplacePaused else { return }
        await withCheckedContinuation { continuation in
            replacePausedWaiters.append(continuation)
        }
    }

    func releaseBlockedReplace() {
        replaceReleaseContinuation?.resume()
        replaceReleaseContinuation = nil
    }
}

private final class OneShotRejectingUserDefaults: UserDefaults {
    var rejectedWritesRemaining = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        if rejectedWritesRemaining > 0 {
            rejectedWritesRemaining -= 1
            return
        }
        super.set(value, forKey: defaultName)
    }
}
