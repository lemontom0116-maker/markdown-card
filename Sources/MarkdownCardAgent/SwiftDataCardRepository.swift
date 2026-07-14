import Foundation
import MarkdownCardCore
import SwiftData

enum MarkdownCardSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [StoredCard.self] }

    @Model
    final class StoredCard {
        @Attribute(.unique) var id: UUID
        var title: String
        var titleOverride: String?
        var markdown: String
        var isQuick: Bool
        var isPinned: Bool
        var isVisible: Bool
        var themeID: String
        var createdAt: Date
        var updatedAt: Date
        var windowX: Double?
        var windowY: Double?
        var windowWidth: Double?
        var windowHeight: Double?
        var screenID: String?
        var layoutModeRaw: String?
        var customWidth: Double?
        var customMinimumHeight: Double?
        var customMaximumHeight: Double?

        init(
            id: UUID,
            title: String,
            titleOverride: String?,
            markdown: String,
            isQuick: Bool,
            isPinned: Bool,
            isVisible: Bool,
            themeID: String,
            createdAt: Date,
            updatedAt: Date
        ) {
            self.id = id
            self.title = title
            self.titleOverride = titleOverride
            self.markdown = markdown
            self.isQuick = isQuick
            self.isPinned = isPinned
            self.isVisible = isVisible
            self.themeID = themeID
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }
}

enum MarkdownCardSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] { [StoredCard.self] }

    @Model
    final class StoredCard {
        @Attribute(.unique) var id: UUID
        var title: String
        var titleOverride: String?
        var markdown: String
        var isQuick: Bool
        var isVisible: Bool
        var themeID: String
        var createdAt: Date
        var updatedAt: Date
        var windowX: Double?
        var windowY: Double?
        var windowWidth: Double?
        var windowHeight: Double?
        var screenID: String?
        var layoutModeRaw: String?
        var customWidth: Double?
        var customMinimumHeight: Double?
        var customMaximumHeight: Double?

        init(card: CardRecord) {
            id = card.id
            title = card.title
            titleOverride = card.titleOverride
            markdown = card.markdown
            isQuick = card.isQuick
            isVisible = card.isVisible
            themeID = card.themeID
            createdAt = card.createdAt
            updatedAt = card.updatedAt
            screenID = card.screenID
            setLayout(card)
            setWindowFrame(card.windowFrame)
        }

        func update(from card: CardRecord) {
            title = card.title
            titleOverride = card.titleOverride
            markdown = card.markdown
            isQuick = card.isQuick
            isVisible = card.isVisible
            themeID = card.themeID
            createdAt = card.createdAt
            updatedAt = card.updatedAt
            screenID = card.screenID
            setLayout(card)
            setWindowFrame(card.windowFrame)
        }

        func cardRecord() -> CardRecord {
            let restoredOverride = titleOverride
                ?? (title == CardRecord.derivedTitle(from: markdown) ? nil : title)
            let frame = decodedWindowFrame()
            let storedLayoutMode = layoutModeRaw.flatMap(CardLayoutMode.init(rawValue:))
            let legacyCustom = CustomCardLayout(
                width: max(320, frame?.width ?? CustomCardLayout.legacyDefault.width),
                minimumHeight: CustomCardLayout.legacyDefault.minimumHeight,
                maximumHeight: CustomCardLayout.legacyDefault.maximumHeight
            )
            let storedCustom: CustomCardLayout? = customWidth.flatMap { width -> CustomCardLayout? in
                guard let customMinimumHeight, let customMaximumHeight else { return nil }
                let value = CustomCardLayout(
                    width: width,
                    minimumHeight: customMinimumHeight,
                    maximumHeight: customMaximumHeight
                )
                return value.isValid ? value : nil
            }
            return CardRecord(
                id: id,
                titleOverride: restoredOverride,
                markdown: markdown,
                isQuick: isQuick,
                isVisible: isVisible,
                themeID: themeID,
                createdAt: createdAt,
                updatedAt: updatedAt,
                windowFrame: frame,
                screenID: screenID,
                layoutMode: storedLayoutMode ?? .custom,
                customLayout: storedLayoutMode == nil ? legacyCustom : storedCustom
            )
        }

        private func setLayout(_ card: CardRecord) {
            layoutModeRaw = card.layoutMode.rawValue
            customWidth = card.customLayout?.width
            customMinimumHeight = card.customLayout?.minimumHeight
            customMaximumHeight = card.customLayout?.maximumHeight
        }

        private func setWindowFrame(_ frame: WindowFrame?) {
            guard let frame, frame.isValid else {
                windowX = nil
                windowY = nil
                windowWidth = nil
                windowHeight = nil
                return
            }
            windowX = frame.x
            windowY = frame.y
            windowWidth = frame.width
            windowHeight = frame.height
        }

        private func decodedWindowFrame() -> WindowFrame? {
            guard let windowX, let windowY, let windowWidth, let windowHeight else { return nil }
            let frame = WindowFrame(
                x: windowX,
                y: windowY,
                width: windowWidth,
                height: windowHeight
            )
            return frame.isValid ? frame : nil
        }
    }
}

enum MarkdownCardMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [MarkdownCardSchemaV2.self, MarkdownCardSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [
            .lightweight(
                fromVersion: MarkdownCardSchemaV2.self,
                toVersion: MarkdownCardSchemaV3.self
            ),
        ]
    }
}

private typealias StoredCard = MarkdownCardSchemaV3.StoredCard

actor SwiftDataCardRepository: CardRepository {
    nonisolated static var defaultStoreURL: URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return root
            .appendingPathComponent("MarkdownCard", isDirectory: true)
            .appendingPathComponent("cards.store", isDirectory: false)
    }

    nonisolated let storeURL: URL?
    private let container: ModelContainer
    private let context: ModelContext

    init(storeURL: URL = SwiftDataCardRepository.defaultStoreURL) throws {
        self.storeURL = storeURL
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.backUpLegacyStoreIfNeeded(at: storeURL)
        let schema = Schema(versionedSchema: MarkdownCardSchemaV3.self)
        let configuration = ModelConfiguration(
            "MarkdownCard",
            schema: schema,
            url: storeURL,
            allowsSave: true
        )
        container = try ModelContainer(
            for: schema,
            migrationPlan: MarkdownCardMigrationPlan.self,
            configurations: [configuration]
        )
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    init(inMemory: Bool) throws {
        storeURL = nil
        let schema = Schema(versionedSchema: MarkdownCardSchemaV3.self)
        let configuration = ModelConfiguration(
            "MarkdownCardTests",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            allowsSave: true
        )
        container = try ModelContainer(
            for: schema,
            migrationPlan: MarkdownCardMigrationPlan.self,
            configurations: [configuration]
        )
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    func allCards() throws -> [CardRecord] {
        try context.fetch(FetchDescriptor<StoredCard>())
            .map { $0.cardRecord() }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    func card(id: UUID) throws -> CardRecord? {
        try storedCard(id: id)?.cardRecord()
    }

    @discardableResult
    func upsert(_ card: CardRecord) throws -> CardRecord {
        var normalized = card
        if let frame = normalized.windowFrame, !frame.isValid {
            normalized.windowFrame = nil
        }
        if let existing = try storedCard(id: normalized.id) {
            existing.update(from: normalized)
        } else {
            context.insert(StoredCard(card: normalized))
        }
        try context.save()
        return normalized
    }

    @discardableResult
    func delete(id: UUID) throws -> Bool {
        guard let existing = try storedCard(id: id) else { return false }
        context.delete(existing)
        try context.save()
        return true
    }

    @discardableResult
    func deleteLegacyQuickCards() throws -> Int {
        let legacy = try context.fetch(FetchDescriptor<StoredCard>()).filter(\.isQuick)
        guard !legacy.isEmpty else { return 0 }
        legacy.forEach(context.delete)
        try context.save()
        return legacy.count
    }

    func replaceAll(with cards: [CardRecord]) throws {
        var seen = Set<UUID>()
        for card in cards {
            guard seen.insert(card.id).inserted else {
                throw CardRepositoryError.duplicateCardID(card.id)
            }
        }
        for existing in try context.fetch(FetchDescriptor<StoredCard>()) {
            context.delete(existing)
        }
        for card in cards {
            context.insert(StoredCard(card: card))
        }
        try context.save()
    }

    private func storedCard(id: UUID) throws -> StoredCard? {
        let records = try context.fetch(FetchDescriptor<StoredCard>())
        return records.first { $0.id == id }
    }

    private nonisolated static func backUpLegacyStoreIfNeeded(at storeURL: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storeURL.path) else { return }
        let marker = storeURL.deletingLastPathComponent()
            .appendingPathComponent("protocol-v3-migration.backed-up")
        guard !fileManager.fileExists(atPath: marker.path) else { return }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupDirectory = storeURL.deletingLastPathComponent()
            .appendingPathComponent("Migration Backups", isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        for suffix in ["", "-shm", "-wal"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.copyItem(
                at: source,
                to: backupDirectory.appendingPathComponent(source.lastPathComponent)
            )
        }
        try Data("protocol-v3\n".utf8).write(to: marker, options: .atomic)
    }
}
