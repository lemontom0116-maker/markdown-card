import Foundation

struct TagCatalogPreferences: Codable, Equatable, Sendable {
    var pinnedTagIDs: Set<String>
    var recentTagIDs: [String]

    static let empty = TagCatalogPreferences(pinnedTagIDs: [], recentTagIDs: [])
}

enum TagCatalogPreferencesStoreError: LocalizedError, Equatable {
    case saveFailed

    var errorDescription: String? {
        "Tag preferences could not be saved. The previous pin and recent order were kept."
    }
}

/// Persists tag catalog presentation preferences independently from cards.
///
/// The payload carries its own version so future preference migrations do not
/// require changing Card metadata or the SwiftData schema. UserDefaults and the
/// key are injectable to keep behavior isolated in tests.
final class TagCatalogPreferencesStore: @unchecked Sendable {
    struct Snapshot: Codable, Equatable, Sendable {
        fileprivate let preferences: TagCatalogPreferences
    }

    private struct Envelope: Codable, Equatable {
        var version: Int
        var pinnedTagIDs: [String]
        var recentTagIDs: [String]
    }

    static let currentVersion = 1
    static let defaultsKey = "MarkdownCardTagCatalogPreferences.v1"
    static let corruptBackupSuffix = ".corrupt-backup"
    static let defaultRecentLimit = 24

    private let defaults: UserDefaults
    private let key: String
    private let recentLimit: Int
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        key: String = TagCatalogPreferencesStore.defaultsKey,
        recentLimit: Int = TagCatalogPreferencesStore.defaultRecentLimit
    ) {
        self.defaults = defaults
        self.key = key
        self.recentLimit = max(0, recentLimit)
    }

    /// Loads preferences and removes IDs that are absent from the current
    /// catalog. Any cleanup is persisted immediately.
    func load(
        validTagIDs: Set<String>,
        persistCleanup: Bool = true
    ) -> TagCatalogPreferences {
        lock.lock()
        defer { lock.unlock() }
        let loaded = loadUnlocked()
        let sanitized = sanitize(loaded, validTagIDs: validTagIDs)
        if persistCleanup, sanitized != loaded {
            _ = saveUnlocked(sanitized)
        }
        return Self.preferences(from: sanitized)
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(preferences: Self.preferences(from: loadUnlocked()))
    }

    @discardableResult
    func restore(_ snapshot: Snapshot) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return saveUnlocked(Self.envelope(from: snapshot.preferences))
    }

    /// Migrates or removes a Tag identity while retaining pin and MRU intent.
    /// Passing `nil` removes the source; passing a destination merges duplicate
    /// recent entries and carries a source pin to the destination.
    @discardableResult
    func migrateTag(
        fromID sourceID: String,
        toID destinationID: String?,
        validTagIDs: Set<String>
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var preferences = Self.preferences(from: loadUnlocked())

        if preferences.pinnedTagIDs.remove(sourceID) != nil,
           let destinationID,
           validTagIDs.contains(destinationID) {
            preferences.pinnedTagIDs.insert(destinationID)
        }

        var seenRecent = Set<String>()
        preferences.recentTagIDs = preferences.recentTagIDs.compactMap { tagID in
            let migrated = tagID == sourceID ? destinationID : tagID
            guard let migrated,
                  validTagIDs.contains(migrated),
                  seenRecent.insert(migrated).inserted
            else { return nil }
            return migrated
        }

        let sanitized = sanitize(
            Self.envelope(from: preferences),
            validTagIDs: validTagIDs
        )
        return saveUnlocked(sanitized)
    }

    @discardableResult
    func setPinned(
        _ isPinned: Bool,
        tagID: String,
        validTagIDs: Set<String>
    ) throws -> TagCatalogPreferences {
        lock.lock()
        defer { lock.unlock() }
        var envelope = sanitize(loadUnlocked(), validTagIDs: validTagIDs)
        var pinned = Set(envelope.pinnedTagIDs)
        if isPinned, validTagIDs.contains(tagID) {
            pinned.insert(tagID)
        } else {
            pinned.remove(tagID)
        }
        envelope.pinnedTagIDs = pinned.sorted()
        guard saveUnlocked(envelope) else {
            throw TagCatalogPreferencesStoreError.saveFailed
        }
        return Self.preferences(from: envelope)
    }

    /// Records one valid tag as most recently used. Existing occurrences are
    /// moved to the front and the bounded MRU list remains duplicate-free.
    @discardableResult
    func recordRecent(
        tagID: String,
        validTagIDs: Set<String>
    ) throws -> TagCatalogPreferences {
        lock.lock()
        defer { lock.unlock() }
        let loaded = loadUnlocked()
        var envelope = sanitize(loaded, validTagIDs: validTagIDs)
        guard validTagIDs.contains(tagID), recentLimit > 0 else {
            if envelope != loaded, !saveUnlocked(envelope) {
                throw TagCatalogPreferencesStoreError.saveFailed
            }
            return Self.preferences(from: envelope)
        }
        envelope.recentTagIDs.removeAll { $0 == tagID }
        envelope.recentTagIDs.insert(tagID, at: 0)
        envelope.recentTagIDs = Array(envelope.recentTagIDs.prefix(recentLimit))
        guard saveUnlocked(envelope) else {
            throw TagCatalogPreferencesStoreError.saveFailed
        }
        return Self.preferences(from: envelope)
    }

    private func loadUnlocked() -> Envelope {
        guard let data = defaults.data(forKey: key) else {
            return Self.emptyEnvelope
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == Self.currentVersion else {
            let backupKey = key + Self.corruptBackupSuffix
            if defaults.data(forKey: backupKey) == nil {
                defaults.set(data, forKey: backupKey)
            }
            return Self.emptyEnvelope
        }
        return envelope
    }

    private func sanitize(
        _ envelope: Envelope,
        validTagIDs: Set<String>
    ) -> Envelope {
        let pinned = Set(envelope.pinnedTagIDs)
            .intersection(validTagIDs)
            .sorted()
        var seenRecent = Set<String>()
        let recent = envelope.recentTagIDs.filter {
            validTagIDs.contains($0) && seenRecent.insert($0).inserted
        }
        return Envelope(
            version: Self.currentVersion,
            pinnedTagIDs: pinned,
            recentTagIDs: Array(recent.prefix(recentLimit))
        )
    }

    private func saveUnlocked(_ envelope: Envelope) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(envelope) else { return false }
        defaults.set(data, forKey: key)
        return defaults.data(forKey: key) == data
    }

    private static var emptyEnvelope: Envelope {
        Envelope(
            version: currentVersion,
            pinnedTagIDs: [],
            recentTagIDs: []
        )
    }

    private static func preferences(from envelope: Envelope) -> TagCatalogPreferences {
        TagCatalogPreferences(
            pinnedTagIDs: Set(envelope.pinnedTagIDs),
            recentTagIDs: envelope.recentTagIDs
        )
    }

    private static func envelope(from preferences: TagCatalogPreferences) -> Envelope {
        Envelope(
            version: currentVersion,
            pinnedTagIDs: preferences.pinnedTagIDs.sorted(),
            recentTagIDs: preferences.recentTagIDs
        )
    }
}
