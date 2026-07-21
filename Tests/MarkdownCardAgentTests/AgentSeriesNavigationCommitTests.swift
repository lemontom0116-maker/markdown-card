import Foundation
import MarkdownCardCore
import XCTest
@testable import MarkdownCardAgent

final class AgentSeriesNavigationCommitTests: XCTestCase {
    func testCommitPreservesLatestContentAndChangesOnlyWindowPageState() throws {
        let tag = try CardTag("reading")
        var source = CardRecord(
            markdown: "latest source Markdown",
            isVisible: true,
            tags: [tag]
        )
        source.touch(at: Date(timeIntervalSince1970: 70))
        let target = CardRecord(
            markdown: "latest target Markdown",
            isVisible: false,
            layoutMode: .sticky,
            tags: [tag]
        )
        let transient = CardRecord(markdown: "")
        let frame = WindowFrame(x: 12, y: 34, width: 720, height: 520)

        let commit = try XCTUnwrap(
            AgentSeriesNavigationCommit(
                cards: [
                    source.id: source,
                    target.id: target,
                    transient.id: transient,
                ],
                transientCardIDs: [transient.id],
                sourceID: source.id,
                targetID: target.id,
                frame: frame,
                screenID: "Studio Display",
                layoutMode: .middle,
                customLayout: nil,
                transitionDate: Date(timeIntervalSince1970: 100)
            )
        )

        XCTAssertEqual(commit.sourceCard.markdown, "latest source Markdown")
        XCTAssertEqual(commit.sourceCard.tags, [tag])
        XCTAssertFalse(commit.sourceCard.isVisible)
        XCTAssertEqual(commit.targetCard.markdown, "latest target Markdown")
        XCTAssertEqual(commit.targetCard.tags, [tag])
        XCTAssertTrue(commit.targetCard.isVisible)
        XCTAssertEqual(commit.targetCard.layoutMode, .middle)
        XCTAssertEqual(commit.targetCard.windowFrame, frame)
        XCTAssertEqual(Set(commit.persistentCards.map(\.id)), Set([source.id, target.id]))
        XCTAssertEqual(commit.cards[transient.id], transient)
    }

    func testAtomicPersistenceFailureNeverFallsBackToIndependentUpserts() async throws {
        let source = CardRecord(markdown: "source", isVisible: true)
        let target = CardRecord(markdown: "target", isVisible: false)
        let repository = AtomicNavigationProbeRepository(cards: [source, target])
        let commit = try XCTUnwrap(
            AgentSeriesNavigationCommit(
                cards: [source.id: source, target.id: target],
                transientCardIDs: [],
                sourceID: source.id,
                targetID: target.id,
                frame: nil,
                screenID: nil,
                layoutMode: .sticky,
                customLayout: nil,
                transitionDate: Date(timeIntervalSince1970: 100)
            )
        )

        await repository.setReplaceFailureEnabled(true)
        do {
            try await commit.persist(to: repository)
            XCTFail("Expected injected atomic replacement failure")
        } catch AtomicNavigationProbeRepository.ProbeError.injected {
            // Expected.
        }

        let failedSnapshot = await repository.snapshot()
        let failedUpsertCalls = await repository.upsertCallCount()
        let failedReplaceCalls = await repository.replaceCallCount()
        XCTAssertEqual(failedSnapshot, [source.id: source, target.id: target])
        XCTAssertEqual(failedUpsertCalls, 0)
        XCTAssertEqual(failedReplaceCalls, 1)

        await repository.setReplaceFailureEnabled(false)
        try await commit.persist(to: repository)
        let stored = await repository.snapshot()
        let successfulUpsertCalls = await repository.upsertCallCount()
        let successfulReplaceCalls = await repository.replaceCallCount()
        XCTAssertEqual(stored[source.id]?.isVisible, false)
        XCTAssertEqual(stored[target.id]?.isVisible, true)
        XCTAssertEqual(successfulUpsertCalls, 0)
        XCTAssertEqual(successfulReplaceCalls, 2)
    }
}

private actor AtomicNavigationProbeRepository: CardRepository {
    enum ProbeError: Error {
        case injected
    }

    private var cards: [UUID: CardRecord]
    private var shouldFailReplace = false
    private var upsertCalls = 0
    private var replaceCalls = 0

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
        if shouldFailReplace { throw ProbeError.injected }
        self.cards = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
    }

    func setReplaceFailureEnabled(_ enabled: Bool) { shouldFailReplace = enabled }
    func snapshot() -> [UUID: CardRecord] { cards }
    func upsertCallCount() -> Int { upsertCalls }
    func replaceCallCount() -> Int { replaceCalls }
}
