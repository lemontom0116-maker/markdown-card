import Foundation
import MarkdownCardCore

enum TagManagementOperation: Sendable, Equatable {
    case rename(sourceID: String, replacement: CardTag)
    case merge(sourceID: String, target: CardTag)
    case delete(tagID: String)

    var sourceID: String {
        switch self {
        case let .rename(sourceID, _), let .merge(sourceID, _): sourceID
        case let .delete(tagID): tagID
        }
    }

    var destinationID: String? {
        switch self {
        case let .rename(_, replacement): replacement.id
        case let .merge(_, target): target.id
        case .delete: nil
        }
    }

    var destinationTag: CardTag? {
        switch self {
        case let .rename(_, replacement): replacement
        case let .merge(_, target): target
        case .delete: nil
        }
    }
}

/// A pure, fully validated value snapshot for a global Tag mutation.
///
/// The application persists `persistentCards` before publishing `cards`, so a
/// failed repository replacement cannot leave the Library showing metadata
/// that was never saved.
struct TagManagementMutation: Sendable {
    let operation: TagManagementOperation
    let cards: [UUID: CardRecord]
    let persistentCards: [CardRecord]
    let affectedCardIDs: Set<UUID>

    init?(
        cards currentCards: [UUID: CardRecord],
        transientCardIDs: Set<UUID>,
        operation: TagManagementOperation,
        changedAt: Date = Date()
    ) {
        guard operation.destinationID != operation.sourceID || {
            if case let .rename(_, replacement) = operation {
                return currentCards.values.contains { card in
                    card.tags.contains { $0.id == operation.sourceID && $0.name != replacement.name }
                }
            }
            return false
        }() else { return nil }

        var nextCards = currentCards
        var affected = Set<UUID>()

        for (id, currentCard) in currentCards {
            guard currentCard.tags.contains(where: { $0.id == operation.sourceID }) else {
                continue
            }

            var card = currentCard
            let nextTags = Self.replacingTags(in: card.tags, for: operation)
            guard !Self.hasSameTagMetadata(nextTags, card.tags) else { continue }
            card.tags = nextTags
            card.updatedAt = changedAt
            nextCards[id] = card
            affected.insert(id)
        }

        guard !affected.isEmpty else { return nil }
        self.operation = operation
        cards = nextCards
        affectedCardIDs = affected
        persistentCards = nextCards.values
            .filter { !transientCardIDs.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    func persist(to repository: any CardRepository) async throws {
        try await repository.replaceAll(with: persistentCards)
    }

    private static func hasSameTagMetadata(_ lhs: [CardTag], _ rhs: [CardTag]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { left, right in
            left.id == right.id && left.name == right.name
        }
    }

    private static func replacingTags(
        in tags: [CardTag],
        for operation: TagManagementOperation
    ) -> [CardTag] {
        switch operation {
        case let .delete(tagID):
            return tags.filter { $0.id != tagID }

        case let .rename(sourceID, replacement):
            return replacing(
                sourceID: sourceID,
                with: replacement,
                in: tags,
                preservesExistingTargetPosition: false
            )

        case let .merge(sourceID, target):
            return replacing(
                sourceID: sourceID,
                with: target,
                in: tags,
                preservesExistingTargetPosition: true
            )
        }
    }

    private static func replacing(
        sourceID: String,
        with replacement: CardTag,
        in tags: [CardTag],
        preservesExistingTargetPosition: Bool
    ) -> [CardTag] {
        let hasExistingTarget = sourceID != replacement.id
            && tags.contains(where: { $0.id == replacement.id })
        var seen = Set<String>()
        var result: [CardTag] = []

        for tag in tags {
            if tag.id == sourceID {
                if preservesExistingTargetPosition && hasExistingTarget {
                    continue
                }
                if seen.insert(replacement.id).inserted {
                    result.append(replacement)
                }
                continue
            }
            if tag.id == replacement.id {
                if seen.insert(replacement.id).inserted {
                    result.append(replacement)
                }
                continue
            }
            if seen.insert(tag.id).inserted {
                result.append(tag)
            }
        }
        return result
    }
}

struct CardTagRemovalMutation: Sendable {
    let cards: [UUID: CardRecord]
    let persistentCards: [CardRecord]
    let updatedCard: CardRecord

    init?(
        cards currentCards: [UUID: CardRecord],
        transientCardIDs: Set<UUID>,
        cardID: UUID,
        tagID: String,
        changedAt: Date = Date()
    ) {
        guard var card = currentCards[cardID],
              card.removeTag(id: tagID, at: changedAt)
        else { return nil }
        var nextCards = currentCards
        nextCards[cardID] = card
        cards = nextCards
        updatedCard = card
        persistentCards = nextCards.values
            .filter { !transientCardIDs.contains($0.id) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
