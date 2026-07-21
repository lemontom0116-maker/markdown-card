import Foundation
import MarkdownCardCore

/// A durable prepare record for a cross-store Tag catalog mutation.
///
/// The journal always contains the complete pre-mutation state. If the process
/// exits before the journal is removed, startup restores this snapshot before
/// loading any cards. Replaying the restore is safe because every store is
/// replaced with the same value each time.
struct TagManagementTransactionJournal: Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let previousCards: [CardRecord]
        let previousSeries: CardSeriesOrderStore.Snapshot
        let previousPreferences: TagCatalogPreferencesStore.Snapshot

        init(
            previousCards: [CardRecord],
            previousSeries: CardSeriesOrderStore.Snapshot,
            previousPreferences: TagCatalogPreferencesStore.Snapshot
        ) {
            self.previousCards = previousCards.sorted {
                $0.id.uuidString < $1.id.uuidString
            }
            self.previousSeries = previousSeries
            self.previousPreferences = previousPreferences
        }
    }

    enum JournalError: LocalizedError, Equatable {
        case transactionAlreadyPending
        case unsupportedVersion(Int)
        case verificationFailed
        case removalFailed

        var errorDescription: String? {
            switch self {
            case .transactionAlreadyPending:
                "A Tag management recovery journal is already pending."
            case let .unsupportedVersion(version):
                "The Tag management recovery journal uses unsupported version \(version)."
            case .verificationFailed:
                "The Tag management recovery journal could not be verified after writing."
            case .removalFailed:
                "The Tag management recovery journal could not be removed."
            }
        }
    }

    private struct Envelope: Codable, Equatable {
        let version: Int
        let entry: Entry
    }

    static let currentVersion = 1
    static let fileName = "tag-management-transaction.v1.json"

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var hasPendingTransaction: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    func load() throws -> Entry? {
        guard hasPendingTransaction else { return nil }
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.version == Self.currentVersion else {
            throw JournalError.unsupportedVersion(envelope.version)
        }
        return envelope.entry
    }

    /// Writes through Foundation's same-volume temporary-file + rename path.
    /// The byte-for-byte read-back check prevents the application from mutating
    /// any store unless the complete recovery payload was atomically installed.
    func write(_ entry: Entry) throws {
        guard !hasPendingTransaction else {
            throw JournalError.transactionAlreadyPending
        }
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            Envelope(version: Self.currentVersion, entry: entry)
        )
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        guard try Data(contentsOf: fileURL, options: [.mappedIfSafe]) == data else {
            throw JournalError.verificationFailed
        }
        _ = try load()
    }

    func clear() throws {
        let fileManager = FileManager.default
        if hasPendingTransaction {
            try fileManager.removeItem(at: fileURL)
        }
        guard !hasPendingTransaction else {
            throw JournalError.removalFailed
        }
    }
}
