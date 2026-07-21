import Foundation
import MarkdownCardCore

enum CardSeriesMoveDirection: Sendable {
    case earlier
    case later
}

/// Persists explicit chapter order separately from Markdown and Tag metadata.
/// This keeps ordering app-owned and backward compatible with the existing
/// SwiftData schema while letting new cards fall back to stable creation order.
final class CardSeriesOrderStore: @unchecked Sendable {
    struct Snapshot: Codable, Equatable, Sendable {
        fileprivate let orders: [String: [UUID]]
    }

    private struct Envelope: Codable {
        var version: Int
        var orders: [String: [UUID]]
    }

    static let defaultsKey = "MarkdownCardSeriesOrders.v1"
    static let corruptBackupSuffix = ".corrupt-backup"

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = CardSeriesOrderStore.defaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    func allOrders() -> [String: [UUID]] {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked().orders
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(orders: loadUnlocked().orders)
    }

    @discardableResult
    func restore(_ snapshot: Snapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return saveUnlocked(Envelope(version: 1, orders: snapshot.orders))
    }

    func order(tagID: String) -> [UUID] {
        allOrders()[tagID] ?? []
    }

    func orderedCards(tagID: String, cards: [CardRecord]) -> [CardRecord] {
        CardSeriesIndex(
            cards: cards,
            preferredOrderByTagID: [tagID: order(tagID: tagID)]
        ).series(tagID: tagID)
    }

    @discardableResult
    func move(
        cardID: UUID,
        tagID: String,
        direction: CardSeriesMoveDirection,
        cards: [CardRecord]
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var envelope = loadUnlocked()
        var orderedIDs = CardSeriesIndex(
            cards: cards,
            preferredOrderByTagID: [tagID: envelope.orders[tagID] ?? []]
        ).cardIDs(tagID: tagID)
        guard let index = orderedIDs.firstIndex(of: cardID) else { return false }
        let target = direction == .earlier ? index - 1 : index + 1
        guard orderedIDs.indices.contains(target) else { return false }
        orderedIDs.swapAt(index, target)
        envelope.orders[tagID] = orderedIDs
        return saveUnlocked(envelope)
    }

    @discardableResult
    func setOrder(_ cardIDs: [UUID], tagID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var envelope = loadUnlocked()
        var seen = Set<UUID>()
        envelope.orders[tagID] = cardIDs.filter { seen.insert($0).inserted }
        return saveUnlocked(envelope)
    }

    @discardableResult
    func removeCard(_ cardID: UUID, fromTagID tagID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var envelope = loadUnlocked()
        guard let existing = envelope.orders[tagID] else { return false }
        let filtered = existing.filter { $0 != cardID }
        guard filtered != existing || filtered.isEmpty else { return false }
        if filtered.isEmpty {
            envelope.orders.removeValue(forKey: tagID)
        } else {
            envelope.orders[tagID] = filtered
        }
        return saveUnlocked(envelope)
    }

    @discardableResult
    func removeTag(_ tagID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var envelope = loadUnlocked()
        guard envelope.orders.removeValue(forKey: tagID) != nil else { return false }
        return saveUnlocked(envelope)
    }

    /// Moves an order to a new Tag identity without overwriting an existing
    /// destination. Call `mergeTag(sourceID:targetID:)` for identity collisions.
    @discardableResult
    func renameTag(fromID: String, toID: String) -> Bool {
        guard fromID != toID else { return false }
        lock.lock()
        defer { lock.unlock() }
        var envelope = loadUnlocked()
        guard let sourceOrder = envelope.orders[fromID], envelope.orders[toID] == nil else {
            return false
        }
        envelope.orders.removeValue(forKey: fromID)
        if !sourceOrder.isEmpty {
            envelope.orders[toID] = sourceOrder
        }
        return saveUnlocked(envelope)
    }

    /// Merges two Tag identities while preserving the destination's explicit
    /// order first, then appending source-only cards in their source order.
    @discardableResult
    func mergeTag(sourceID: String, targetID: String) -> Bool {
        guard sourceID != targetID else { return false }
        lock.lock()
        defer { lock.unlock() }
        var envelope = loadUnlocked()
        guard let sourceOrder = envelope.orders[sourceID] else { return false }
        let targetOrder = envelope.orders[targetID] ?? []
        var seen = Set<UUID>()
        let merged = (targetOrder + sourceOrder).filter { seen.insert($0).inserted }
        envelope.orders.removeValue(forKey: sourceID)
        if merged.isEmpty {
            envelope.orders.removeValue(forKey: targetID)
        } else {
            envelope.orders[targetID] = merged
        }
        return saveUnlocked(envelope)
    }

    /// Replaces a merged series with fully materialized pre-mutation orders.
    /// This preserves the target series first even when either series had no
    /// explicit UserDefaults entry and was relying on creation-order fallback.
    @discardableResult
    func mergeTag(
        sourceID: String,
        targetID: String,
        targetCardIDs: [UUID],
        sourceCardIDs: [UUID]
    ) -> Bool {
        guard sourceID != targetID else { return false }
        lock.lock()
        defer { lock.unlock() }
        var envelope = loadUnlocked()
        var seen = Set<UUID>()
        let merged = (targetCardIDs + sourceCardIDs).filter {
            seen.insert($0).inserted
        }
        envelope.orders.removeValue(forKey: sourceID)
        if merged.isEmpty {
            envelope.orders.removeValue(forKey: targetID)
        } else {
            envelope.orders[targetID] = merged
        }
        return saveUnlocked(envelope)
    }

    func removeCard(_ cardID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        var envelope = loadUnlocked()
        var changed = false
        for tagID in Array(envelope.orders.keys) {
            let existing = envelope.orders[tagID, default: []]
            let filtered = existing.filter { $0 != cardID }
            if filtered.isEmpty {
                changed = true
                envelope.orders.removeValue(forKey: tagID)
            } else if filtered != existing {
                changed = true
                envelope.orders[tagID] = filtered
            }
        }
        if changed { _ = saveUnlocked(envelope) }
    }

    private func loadUnlocked() -> Envelope {
        guard let data = defaults.data(forKey: key) else {
            return Envelope(version: 1, orders: [:])
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 1 else {
            let backupKey = key + Self.corruptBackupSuffix
            if defaults.data(forKey: backupKey) == nil {
                defaults.set(data, forKey: backupKey)
            }
            return Envelope(version: 1, orders: [:])
        }
        return envelope
    }

    private func saveUnlocked(_ envelope: Envelope) -> Bool {
        guard let data = try? JSONEncoder().encode(envelope) else { return false }
        defaults.set(data, forKey: key)
        return defaults.data(forKey: key) == data
    }
}
