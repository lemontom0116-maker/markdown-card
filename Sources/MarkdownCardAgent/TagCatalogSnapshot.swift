import Foundation
import MarkdownCardCore

/// A canonical, derived view of one tag across all cards.
///
/// Tags remain card-owned metadata. The catalog deliberately contains no
/// mutable global tag entity, so it can be rebuilt whenever cards change.
struct TagCatalogEntry: Identifiable, Equatable, Sendable {
    let tag: CardTag
    let cardCount: Int

    var id: String { tag.id }
    var name: String { tag.name }
}

/// A deterministic tag catalog derived from the current cards.
///
/// When cards contain different display spellings for the same normalized tag
/// ID, the spelling from the oldest card wins. UUID is the stable tie-breaker
/// for cards with the same creation date. A card contributes at most once to a
/// tag's usage count, even if malformed input contains duplicate tag IDs.
struct TagCatalogSnapshot: Equatable, Sendable {
    let entries: [TagCatalogEntry]

    init(cards: [CardRecord]) {
        struct Accumulator {
            let tag: CardTag
            var cardCount: Int
        }

        let orderedCards = cards.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        var byID: [String: Accumulator] = [:]
        for card in orderedCards {
            var seenOnCard = Set<String>()
            for tag in card.tags where seenOnCard.insert(tag.id).inserted {
                if var existing = byID[tag.id] {
                    existing.cardCount += 1
                    byID[tag.id] = existing
                } else {
                    byID[tag.id] = Accumulator(tag: tag, cardCount: 1)
                }
            }
        }

        entries = byID.values
            .map { TagCatalogEntry(tag: $0.tag, cardCount: $0.cardCount) }
            .sorted(by: Self.namePrecedes)
    }

    var validTagIDs: Set<String> {
        Set(entries.map(\.id))
    }

    func entry(tagID: String) -> TagCatalogEntry? {
        entries.first { $0.id == tagID }
    }

    /// Returns pinned entries in a deterministic, locale-independent name
    /// order. Persisted pinned ID order is intentionally not presentation
    /// order, which keeps pinning simple while canonical names evolve.
    func pinnedEntries(preferences: TagCatalogPreferences) -> [TagCatalogEntry] {
        entries
            .filter { preferences.pinnedTagIDs.contains($0.id) }
            .sorted(by: Self.namePrecedes)
    }

    /// Produces the quick-access catalog order used by compact tag surfaces.
    ///
    /// Priority is active, pinned, recent MRU, then usage. Every valid tag is
    /// returned exactly once. Unknown preference IDs are ignored here and are
    /// removed persistently by `TagCatalogPreferencesStore.load(validTagIDs:)`.
    func orderedCandidates(
        activeTagID: String?,
        preferences: TagCatalogPreferences
    ) -> [TagCatalogEntry] {
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var emitted = Set<String>()
        var result: [TagCatalogEntry] = []

        if let activeTagID,
           let active = entriesByID[activeTagID],
           emitted.insert(activeTagID).inserted {
            result.append(active)
        }

        for pinned in pinnedEntries(preferences: preferences)
        where emitted.insert(pinned.id).inserted {
            result.append(pinned)
        }

        for tagID in preferences.recentTagIDs
        where emitted.insert(tagID).inserted {
            if let recent = entriesByID[tagID] {
                result.append(recent)
            } else {
                emitted.remove(tagID)
            }
        }

        let fallback = entries
            .filter { !emitted.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.cardCount != rhs.cardCount {
                    return lhs.cardCount > rhs.cardCount
                }
                return Self.namePrecedes(lhs, rhs)
            }
        result.append(contentsOf: fallback)
        return result
    }

    private static func namePrecedes(
        _ lhs: TagCatalogEntry,
        _ rhs: TagCatalogEntry
    ) -> Bool {
        let locale = Locale(identifier: "en_US_POSIX")
        let options: String.CompareOptions = [
            .caseInsensitive,
            .diacriticInsensitive,
            .widthInsensitive,
        ]
        let lhsKey = lhs.name
            .folding(options: options, locale: locale)
            .precomposedStringWithCanonicalMapping
        let rhsKey = rhs.name
            .folding(options: options, locale: locale)
            .precomposedStringWithCanonicalMapping
        if lhsKey != rhsKey {
            return lhsKey < rhsKey
        }
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }
        return lhs.id < rhs.id
    }
}

enum TagCatalogSearch {
    static func matches(tagName: String, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let tagKey = CardTag.normalizedID(forDisplayName: tagName)
        let queryKey = CardTag.normalizedID(forDisplayName: query)
        return tagKey.contains(queryKey)
    }
}
