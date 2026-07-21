import Foundation

public struct CardSeriesNeighbors: Equatable, Sendable {
    public let index: Int
    public let count: Int
    public let newerCardID: UUID?
    public let olderCardID: UUID?

    public init(
        index: Int,
        count: Int,
        newerCardID: UUID?,
        olderCardID: UUID?
    ) {
        self.index = index
        self.count = count
        self.newerCardID = newerCardID
        self.olderCardID = olderCardID
    }
}

/// An immutable snapshot of cards grouped by normalized Tag identity.
///
/// Series without an explicit order are newest-first by creation time. UUID
/// ascending is the stable tie-breaker, so navigation never changes when a
/// card is edited. Callers may supply a persisted per-Tag order; cards missing
/// from that order are appended in the stable creation order.
public struct CardSeriesIndex: Sendable {
    private let cardsByTagID: [String: [CardRecord]]

    public init(
        cards: [CardRecord],
        preferredOrderByTagID: [String: [UUID]] = [:]
    ) {
        var grouped: [String: [CardRecord]] = [:]
        for card in cards {
            for tag in card.tags {
                grouped[tag.id, default: []].append(card)
            }
        }
        cardsByTagID = Dictionary(uniqueKeysWithValues: grouped.map { tagID, cards in
            (
                tagID,
                Self.applyingPreferredOrder(
                    preferredOrderByTagID[tagID] ?? [],
                    to: cards
                )
            )
        })
    }

    public var isEmpty: Bool {
        cardsByTagID.isEmpty
    }

    public var tagIDs: [String] {
        cardsByTagID.keys.sorted()
    }

    public static func orderedByCreation(_ cards: [CardRecord]) -> [CardRecord] {
        cards.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public static func applyingPreferredOrder(
        _ preferredCardIDs: [UUID],
        to cards: [CardRecord]
    ) -> [CardRecord] {
        let fallback = orderedByCreation(cards)
        guard !preferredCardIDs.isEmpty else { return fallback }
        let cardsByID = Dictionary(uniqueKeysWithValues: fallback.map { ($0.id, $0) })
        var seen = Set<UUID>()
        var result: [CardRecord] = []
        result.reserveCapacity(fallback.count)
        for cardID in preferredCardIDs {
            guard let card = cardsByID[cardID], seen.insert(cardID).inserted else { continue }
            result.append(card)
        }
        result.append(contentsOf: fallback.filter { seen.insert($0.id).inserted })
        return result
    }

    public func series(for tag: CardTag) -> [CardRecord] {
        series(tagID: tag.id)
    }

    public func series(tagID: String) -> [CardRecord] {
        cardsByTagID[tagID] ?? []
    }

    public func cardIDs(tagID: String) -> [UUID] {
        series(tagID: tagID).map(\.id)
    }

    public func neighbors(of cardID: UUID, tagID: String) -> CardSeriesNeighbors? {
        let cards = series(tagID: tagID)
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return nil }
        return CardSeriesNeighbors(
            index: index,
            count: cards.count,
            newerCardID: index > cards.startIndex ? cards[index - 1].id : nil,
            olderCardID: cards.indices.contains(index + 1) ? cards[index + 1].id : nil
        )
    }
}
