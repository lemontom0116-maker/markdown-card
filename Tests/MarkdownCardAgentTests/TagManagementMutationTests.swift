import Foundation
import MarkdownCardCore
import XCTest
@testable import MarkdownCardAgent

final class TagManagementMutationTests: XCTestCase {
    func testCaseOnlyRenameKeepsIdentityPositionAndDocumentFields() throws {
        let source = try CardTag("Research")
        let other = try CardTag("Reading")
        let replacement = try CardTag("RESEARCH")
        let createdAt = Date(timeIntervalSince1970: 10)
        let changedAt = Date(timeIntervalSince1970: 30)
        let card = CardRecord(
            markdown: "# Notes",
            createdAt: createdAt,
            tags: [other, source]
        )

        let mutation = try XCTUnwrap(
            TagManagementMutation(
                cards: [card.id: card],
                transientCardIDs: [],
                operation: .rename(sourceID: source.id, replacement: replacement),
                changedAt: changedAt
            )
        )
        let renamed = try XCTUnwrap(mutation.cards[card.id])

        XCTAssertEqual(renamed.tags.map(\.name), ["Reading", "RESEARCH"])
        XCTAssertEqual(renamed.tags.map(\.id), [other.id, source.id])
        XCTAssertEqual(renamed.markdown, card.markdown)
        XCTAssertEqual(renamed.createdAt, createdAt)
        XCTAssertEqual(renamed.updatedAt, changedAt)
    }

    func testRenameToNewIdentityReplacesEveryReference() throws {
        let source = try CardTag("Research")
        let replacement = try CardTag("Ideas")
        let first = CardRecord(markdown: "first", tags: [source])
        let second = CardRecord(markdown: "second", tags: [source])

        let mutation = try XCTUnwrap(
            TagManagementMutation(
                cards: [first.id: first, second.id: second],
                transientCardIDs: [],
                operation: .rename(sourceID: source.id, replacement: replacement)
            )
        )

        XCTAssertEqual(mutation.affectedCardIDs, Set([first.id, second.id]))
        XCTAssertTrue(mutation.cards.values.allSatisfy { $0.tags == [replacement] })
    }

    func testMergePreservesExistingTargetPositionAndDeduplicates() throws {
        let source = try CardTag("Source")
        let target = try CardTag("Target")
        let other = try CardTag("Other")
        let overlap = CardRecord(tags: [source, other, target])
        let sourceOnly = CardRecord(tags: [other, source])

        let mutation = try XCTUnwrap(
            TagManagementMutation(
                cards: [overlap.id: overlap, sourceOnly.id: sourceOnly],
                transientCardIDs: [],
                operation: .merge(sourceID: source.id, target: target)
            )
        )

        XCTAssertEqual(mutation.cards[overlap.id]?.tags, [other, target])
        XCTAssertEqual(mutation.cards[sourceOnly.id]?.tags, [other, target])
    }

    func testDeleteRemovesOnlyMetadataAndExcludesTransientCardsFromPersistence() throws {
        let tag = try CardTag("Course")
        let persistent = CardRecord(markdown: "keep", tags: [tag])
        let transient = CardRecord(markdown: "", tags: [tag])

        let mutation = try XCTUnwrap(
            TagManagementMutation(
                cards: [persistent.id: persistent, transient.id: transient],
                transientCardIDs: [transient.id],
                operation: .delete(tagID: tag.id)
            )
        )

        XCTAssertEqual(mutation.cards[persistent.id]?.markdown, "keep")
        XCTAssertEqual(mutation.cards[persistent.id]?.tags, [])
        XCTAssertEqual(mutation.cards[transient.id]?.tags, [])
        XCTAssertEqual(mutation.persistentCards.map(\.id), [persistent.id])
    }

    func testRepositoryFailureDoesNotFallBackToPartialUpserts() async throws {
        let tag = try CardTag("Course")
        let card = CardRecord(markdown: "keep", tags: [tag])
        let repository = FailingTagMutationRepository(cards: [card])
        let mutation = try XCTUnwrap(
            TagManagementMutation(
                cards: [card.id: card],
                transientCardIDs: [],
                operation: .delete(tagID: tag.id)
            )
        )

        do {
            try await mutation.persist(to: repository)
            XCTFail("Expected injected replacement failure")
        } catch FailingTagMutationRepository.ProbeError.injected {
            // Expected.
        }

        let stored = await repository.snapshot()
        let replaceCalls = await repository.replaceCallCount()
        let upsertCalls = await repository.upsertCallCount()
        XCTAssertEqual(stored, [card.id: card])
        XCTAssertEqual(replaceCalls, 1)
        XCTAssertEqual(upsertCalls, 0)
    }

    func testSingleCardRemovalPreservesDocumentAndOtherCards() throws {
        let removed = try CardTag("Removed")
        let kept = try CardTag("Kept")
        let changedAt = Date(timeIntervalSince1970: 90)
        let card = CardRecord(markdown: "# Keep", tags: [kept, removed])
        let other = CardRecord(markdown: "Other", tags: [removed])

        let mutation = try XCTUnwrap(
            CardTagRemovalMutation(
                cards: [card.id: card, other.id: other],
                transientCardIDs: [],
                cardID: card.id,
                tagID: removed.id,
                changedAt: changedAt
            )
        )

        XCTAssertEqual(mutation.updatedCard.tags, [kept])
        XCTAssertEqual(mutation.updatedCard.markdown, card.markdown)
        XCTAssertEqual(mutation.updatedCard.createdAt, card.createdAt)
        XCTAssertEqual(mutation.updatedCard.updatedAt, changedAt)
        XCTAssertEqual(mutation.cards[other.id], other)
    }

    func testDeferredOldIdentityMapsToRenameMergeOrDeleteSemantics() throws {
        let source = try CardTag("Source")
        let renamed = try CardTag("Renamed")
        let target = try CardTag("Target")

        XCTAssertEqual(
            AgentApplicationController.resolvedDeferredTagName(
                "SOURCE",
                after: .rename(sourceID: source.id, replacement: renamed)
            ),
            renamed.name
        )
        XCTAssertEqual(
            AgentApplicationController.resolvedDeferredRemovalTagID(
                source.id,
                after: .merge(sourceID: source.id, target: target)
            ),
            target.id
        )
        XCTAssertNil(
            AgentApplicationController.resolvedDeferredTagName(
                source.name,
                after: .delete(tagID: source.id)
            )
        )
        XCTAssertNil(
            AgentApplicationController.resolvedDeferredRemovalTagID(
                source.id,
                after: .delete(tagID: source.id)
            )
        )
        XCTAssertEqual(
            AgentApplicationController.resolvedDeferredTagName(
                target.name,
                after: .delete(tagID: source.id)
            ),
            target.name
        )
    }
}

private actor FailingTagMutationRepository: CardRepository {
    enum ProbeError: Error { case injected }

    private var cards: [UUID: CardRecord]
    private var replaceCalls = 0
    private var upsertCalls = 0

    init(cards: [CardRecord]) {
        self.cards = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
    }

    func allCards() -> [CardRecord] { Array(cards.values) }
    func card(id: UUID) -> CardRecord? { cards[id] }
    func upsert(_ card: CardRecord) -> CardRecord {
        upsertCalls += 1
        cards[card.id] = card
        return card
    }
    func delete(id: UUID) -> Bool { cards.removeValue(forKey: id) != nil }
    func deleteLegacyQuickCards() -> Int { 0 }
    func replaceAll(with cards: [CardRecord]) throws {
        replaceCalls += 1
        throw ProbeError.injected
    }
    func snapshot() -> [UUID: CardRecord] { cards }
    func replaceCallCount() -> Int { replaceCalls }
    func upsertCallCount() -> Int { upsertCalls }
}
