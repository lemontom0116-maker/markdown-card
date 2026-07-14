import Foundation
import MarkdownCardCore

struct EditorSourceID: Hashable, Sendable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    static let commandLine = EditorSourceID(
        UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    )
}

@MainActor
final class CardDocumentCoordinator {
    struct Transaction: Equatable {
        let cardID: UUID
        let markdown: String
        let revision: UInt64
        let source: EditorSourceID
    }

    private var revisions: [UUID: UInt64] = [:]

    func register(_ cards: some Sequence<CardRecord>) {
        for card in cards where revisions[card.id] == nil {
            revisions[card.id] = 0
        }
    }

    func revision(for cardID: UUID) -> UInt64 {
        revisions[cardID, default: 0]
    }

    func accept(
        cardID: UUID,
        markdown: String,
        incomingRevision: UInt64,
        source: EditorSourceID
    ) -> Transaction {
        let revision = max(revisions[cardID, default: 0] &+ 1, incomingRevision)
        revisions[cardID] = revision
        return Transaction(
            cardID: cardID,
            markdown: markdown,
            revision: revision,
            source: source
        )
    }

    func remove(_ cardID: UUID) {
        revisions[cardID] = nil
    }

    func snapshot() -> [UUID: UInt64] {
        revisions
    }
}
