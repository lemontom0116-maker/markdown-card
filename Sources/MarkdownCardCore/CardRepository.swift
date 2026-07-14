import Foundation

public protocol CardRepository: Sendable {
    func allCards() async throws -> [CardRecord]
    func card(id: UUID) async throws -> CardRecord?
    @discardableResult
    func upsert(_ card: CardRecord) async throws -> CardRecord
    @discardableResult
    func delete(id: UUID) async throws -> Bool
    @discardableResult
    func deleteLegacyQuickCards() async throws -> Int
    func replaceAll(with cards: [CardRecord]) async throws
}

public enum CardRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case corruptStore(String)
    case duplicateCardID(UUID)

    public var errorDescription: String? {
        switch self {
        case let .corruptStore(details):
            "The card store is corrupt: \(details)"
        case let .duplicateCardID(id):
            "The card store contains duplicate ID \(id.uuidString)."
        }
    }
}

public actor JSONCardRepository: CardRepository {
    private struct StoreEnvelope: Codable, Sendable {
        var schemaVersion: Int
        var cards: [CardRecord]
    }

    public static let currentSchemaVersion = 2

    public nonisolated let fileURL: URL
    private let backupURL: URL
    private let fileManager: FileManager
    private var cardsByID: [UUID: CardRecord] = [:]
    private var isLoaded = false
    private var loadedFromBackup = false

    public init(fileURL: URL = JSONCardRepository.defaultStoreURL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        backupURL = fileURL.appendingPathExtension("backup")
        self.fileManager = fileManager
    }

    public static var defaultStoreURL: URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return root
            .appendingPathComponent("MarkdownCard", isDirectory: true)
            .appendingPathComponent("cards.json", isDirectory: false)
    }

    public func allCards() throws -> [CardRecord] {
        try ensureLoaded()
        return cardsByID.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func card(id: UUID) throws -> CardRecord? {
        try ensureLoaded()
        return cardsByID[id]
    }

    @discardableResult
    public func upsert(_ card: CardRecord) throws -> CardRecord {
        try ensureLoaded()
        var card = card
        if let frame = card.windowFrame, !frame.isValid {
            card.windowFrame = nil
        }
        if card.isQuick {
            for id in Array(cardsByID.keys) where id != card.id {
                cardsByID[id]?.isQuick = false
            }
        }
        cardsByID[card.id] = card
        try persist()
        return card
    }

    @discardableResult
    public func delete(id: UUID) throws -> Bool {
        try ensureLoaded()
        guard cardsByID.removeValue(forKey: id) != nil else { return false }
        try persist()
        return true
    }

    @discardableResult
    public func deleteLegacyQuickCards() throws -> Int {
        try ensureLoaded()
        let ids = cardsByID.values.filter(\.isQuick).map(\.id)
        guard !ids.isEmpty else { return 0 }
        ids.forEach { cardsByID.removeValue(forKey: $0) }
        try persist()
        return ids.count
    }

    public func replaceAll(with cards: [CardRecord]) throws {
        var replacement: [UUID: CardRecord] = [:]
        for card in cards {
            guard replacement[card.id] == nil else {
                throw CardRepositoryError.duplicateCardID(card.id)
            }
            replacement[card.id] = card
        }
        cardsByID = replacement
        isLoaded = true
        try persist()
    }

    private func ensureLoaded() throws {
        guard !isLoaded else { return }

        guard fileManager.fileExists(atPath: fileURL.path) else {
            cardsByID = [:]
            isLoaded = true
            return
        }

        do {
            cardsByID = try loadStore(at: fileURL)
            loadedFromBackup = false
        } catch {
            guard fileManager.fileExists(atPath: backupURL.path) else {
                throw CardRepositoryError.corruptStore(error.localizedDescription)
            }
            do {
                cardsByID = try loadStore(at: backupURL)
                loadedFromBackup = true
            } catch {
                throw CardRepositoryError.corruptStore(error.localizedDescription)
            }
        }
        isLoaded = true
    }

    private func loadStore(at url: URL) throws -> [UUID: CardRecord] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let records: [CardRecord]
        if let envelope = try? decoder.decode(StoreEnvelope.self, from: data) {
            guard envelope.schemaVersion <= Self.currentSchemaVersion else {
                throw CardRepositoryError.corruptStore(
                    "Unsupported schema version \(envelope.schemaVersion)."
                )
            }
            records = envelope.cards
        } else {
            // v0 development builds wrote a top-level array. Keeping this decoder makes
            // the JSON fallback safe to use while the native persistence layer evolves.
            records = try decoder.decode([CardRecord].self, from: data)
        }

        var result: [UUID: CardRecord] = [:]
        for var record in records {
            guard result[record.id] == nil else {
                throw CardRepositoryError.duplicateCardID(record.id)
            }
            if let frame = record.windowFrame, !frame.isValid {
                record.windowFrame = nil
            }
            result[record.id] = record
        }
        return result
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        if !loadedFromBackup, fileManager.fileExists(atPath: fileURL.path) {
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: fileURL, to: backupURL)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        }

        let envelope = StoreEnvelope(
            schemaVersion: Self.currentSchemaVersion,
            cards: cardsByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        loadedFromBackup = false
    }

}
