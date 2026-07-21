import CryptoKit
import Foundation
import MarkdownCardCore

struct CardVersionSnapshot: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let cardID: UUID
    let capturedAt: Date
    let title: String
    let titleOverride: String?
    let markdown: String
    let digest: String

    init(card: CardRecord, capturedAt: Date = Date()) {
        id = UUID()
        cardID = card.id
        self.capturedAt = capturedAt
        title = card.title
        titleOverride = card.titleOverride
        markdown = card.markdown
        digest = Self.digest(card.markdown)
    }

    static func digest(_ markdown: String) -> String {
        SHA256.hash(data: Data(markdown.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum CardVersionStoreError: LocalizedError, Equatable {
    case unableToRead
    case unableToWrite

    var errorDescription: String? {
        switch self {
        case .unableToRead:
            "Markdown Card could not read this card's version history."
        case .unableToWrite:
            "Markdown Card could not save this card's recovery snapshot."
        }
    }
}

final class CardVersionStore: @unchecked Sendable {
    private struct EnvelopeVersion: Decodable {
        let version: Int
    }

    private struct Envelope: Codable {
        var version: Int
        var snapshots: [CardVersionSnapshot]
    }

    private static let currentEnvelopeVersion = 2
    static let maximumSnapshotsPerCard = 50

    private let rootURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(
        rootURL: URL = CardVersionStore.defaultRootURL,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    static var defaultRootURL: URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return root
            .appendingPathComponent("MarkdownCard", isDirectory: true)
            .appendingPathComponent("Versions", isDirectory: true)
    }

    @discardableResult
    func record(_ card: CardRecord, capturedAt: Date = Date()) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var snapshots = try loadUnlocked(cardID: card.id)
        let snapshot = CardVersionSnapshot(card: card, capturedAt: capturedAt)
        guard snapshots.first?.digest != snapshot.digest
                || snapshots.first?.titleOverride != snapshot.titleOverride
        else { return false }
        snapshots.insert(snapshot, at: 0)
        if snapshots.count > Self.maximumSnapshotsPerCard {
            snapshots.removeLast(snapshots.count - Self.maximumSnapshotsPerCard)
        }
        try writeUnlocked(snapshots, cardID: card.id)
        return true
    }

    func snapshots(cardID: UUID) throws -> [CardVersionSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked(cardID: cardID)
    }

    func recoverableSnapshot(for card: CardRecord) throws -> CardVersionSnapshot? {
        try snapshots(cardID: card.id).first { snapshot in
            snapshot.capturedAt > card.updatedAt
                && (snapshot.markdown != card.markdown
                    || snapshot.titleOverride != card.titleOverride)
        }
    }

    func delete(cardID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: fileURL(cardID: cardID))
    }

    private func loadUnlocked(cardID: UUID) throws -> [CardVersionSnapshot] {
        let url = fileURL(cardID: cardID)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let version = try JSONDecoder().decode(EnvelopeVersion.self, from: data).version
            guard version == 1 || version == Self.currentEnvelopeVersion else {
                throw CardVersionStoreError.unableToRead
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = version == 1 ? .iso8601 : .secondsSince1970
            let envelope = try decoder.decode(Envelope.self, from: data)
            return envelope.snapshots
                .filter { $0.cardID == cardID }
                .sorted { $0.capturedAt > $1.capturedAt }
        } catch let error as CardVersionStoreError {
            throw error
        } catch {
            throw CardVersionStoreError.unableToRead
        }
    }

    private func writeUnlocked(_ snapshots: [CardVersionSnapshot], cardID: UUID) throws {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: rootURL.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            // JSONEncoder's ISO-8601 strategy truncates fractional seconds on
            // supported macOS releases. A numeric timestamp preserves the
            // sub-second ordering needed to distinguish a persisted card from
            // a newer crash-recovery draft created during the same second.
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(Envelope(
                version: Self.currentEnvelopeVersion,
                snapshots: snapshots
            ))
            let destination = fileURL(cardID: cardID)
            try data.write(to: destination, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            throw CardVersionStoreError.unableToWrite
        }
    }

    private func fileURL(cardID: UUID) -> URL {
        rootURL.appendingPathComponent(
            cardID.uuidString.lowercased() + ".json",
            isDirectory: false
        )
    }
}
