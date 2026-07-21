import AppKit
import Foundation
import KeyboardShortcuts
import MarkdownCardCore
import SwiftData
import XCTest
@testable import MarkdownCardAgent

final class SwiftDataCardRepositoryTests: XCTestCase {
    func testPurgesEveryLegacyQuickCard() async throws {
        let repository = try SwiftDataCardRepository(inMemory: true)
        let first = CardRecord(
            title: "First",
            markdown: "# First",
            isQuick: true,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let second = CardRecord(
            title: "Second",
            markdown: "# Second",
            isQuick: true,
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        _ = try await repository.upsert(first)
        _ = try await repository.upsert(second)

        let deletedCount = try await repository.deleteLegacyQuickCards()
        let remainingCards = try await repository.allCards()
        XCTAssertEqual(deletedCount, 2)
        XCTAssertTrue(remainingCards.isEmpty)
    }

    func testUpsertRoundTripsContentVisibilityAndWindowFrame() async throws {
        let repository = try SwiftDataCardRepository(inMemory: true)
        let frame = WindowFrame(x: 140, y: 220, width: 900, height: 640)
        var card = CardRecord(
            markdown: "# Windowed Card\n\nBody",
            isVisible: true,
            windowFrame: frame,
            screenID: "Studio Display",
            layoutMode: .custom,
            customLayout: CustomCardLayout(width: 900, minimumHeight: 240, maximumHeight: 700),
            tags: [try CardTag("Research"), try CardTag("Reading")]
        )

        _ = try await repository.upsert(card)
        card.updateMarkdown("# Updated\n\nNew body")
        card.isVisible = false
        _ = try await repository.upsert(card)

        let storedCard = try await repository.card(id: card.id)
        let restored = try XCTUnwrap(storedCard)
        XCTAssertEqual(restored.title, "Updated")
        XCTAssertEqual(restored.markdown, "# Updated\n\nNew body")
        XCTAssertFalse(restored.isVisible)
        XCTAssertEqual(restored.windowFrame, frame)
        XCTAssertEqual(restored.screenID, "Studio Display")
        XCTAssertEqual(restored.layoutMode, .custom)
        XCTAssertEqual(restored.customLayout?.maximumHeight, 700)
        XCTAssertEqual(restored.tags.map(\.name), ["Research", "Reading"])
    }

    func testReplaceAllPreservesLegacyQuickFlagsUntilExplicitMigration() async throws {
        let repository = try SwiftDataCardRepository(inMemory: true)
        let older = CardRecord(
            title: "Older",
            isQuick: true,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = CardRecord(
            title: "Newer",
            isQuick: true,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let visible = CardRecord(title: "Visible", isVisible: true)

        try await repository.replaceAll(with: [older, visible, newer])

        let stored = try await repository.allCards()
        XCTAssertEqual(stored.count, 3)
        XCTAssertEqual(Set(stored.filter(\.isQuick).map(\.id)), Set([older.id, newer.id]))
        let restoredVisible = try await repository.card(id: visible.id)
        XCTAssertEqual(restoredVisible?.isVisible, true)
    }

    func testReplaceAllRejectsDuplicateIdentifiersWithoutReplacingExistingData() async throws {
        let repository = try SwiftDataCardRepository(inMemory: true)
        let existing = CardRecord(title: "Existing", markdown: "Keep me")
        _ = try await repository.upsert(existing)

        var duplicate = CardRecord(title: "Duplicate A")
        let duplicateID = duplicate.id
        let secondCopy = CardRecord(id: duplicateID, title: "Duplicate B")

        do {
            try await repository.replaceAll(with: [duplicate, secondCopy])
            XCTFail("Expected duplicateCardID")
        } catch let error as CardRepositoryError {
            XCTAssertEqual(error, .duplicateCardID(duplicateID))
        }

        duplicate.title = "Unused"
        let stored = try await repository.allCards()
        XCTAssertEqual(stored, [existing])
    }

    func testDeleteIsIdempotent() async throws {
        let repository = try SwiftDataCardRepository(inMemory: true)
        let card = CardRecord(title: "Disposable")
        _ = try await repository.upsert(card)

        let firstDelete = try await repository.delete(id: card.id)
        let secondDelete = try await repository.delete(id: card.id)
        let restored = try await repository.card(id: card.id)
        XCTAssertTrue(firstDelete)
        XCTAssertFalse(secondDelete)
        XCTAssertNil(restored)
    }

    func testProtocolV3MigrationPreservesLegacyCardsAndCreatesBackup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownCardMigrationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("cards.store")
        let id = UUID()

        do {
            let schema = Schema(versionedSchema: MarkdownCardSchemaV2.self)
            let configuration = ModelConfiguration(
                "MarkdownCard",
                schema: schema,
                url: storeURL,
                allowsSave: true
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(
                MarkdownCardSchemaV2.StoredCard(
                    id: id,
                    title: "Legacy Card",
                    titleOverride: nil,
                    markdown: "# Legacy Card\n\nPreserve me.",
                    isQuick: false,
                    isPinned: false,
                    isVisible: true,
                    themeID: CardRecord.defaultThemeID,
                    createdAt: Date(timeIntervalSince1970: 10),
                    updatedAt: Date(timeIntervalSince1970: 20)
                )
            )
            try context.save()
        }

        let repository = try SwiftDataCardRepository(storeURL: storeURL)
        let restored = try await repository.card(id: id)
        XCTAssertEqual(restored?.title, "Legacy Card")
        XCTAssertEqual(restored?.markdown, "# Legacy Card\n\nPreserve me.")
        XCTAssertEqual(restored?.isVisible, true)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("protocol-v3-migration.backed-up").path
            )
        )
    }

    func testTagV4MigrationDefaultsV3CardsToEmptyTagsAndCreatesIndependentBackup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownCardTagV4MigrationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("cards.store")
        let legacy = CardRecord(
            markdown: "# Before Tags\n\nPreserve me.",
            isVisible: true,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        do {
            let schema = Schema(versionedSchema: MarkdownCardSchemaV3.self)
            let configuration = ModelConfiguration(
                "MarkdownCard",
                schema: schema,
                url: storeURL,
                allowsSave: true
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            context.insert(MarkdownCardSchemaV3.StoredCard(card: legacy))
            try context.save()
        }
        try Data("protocol-v3\n".utf8).write(
            to: root.appendingPathComponent("protocol-v3-migration.backed-up"),
            options: .atomic
        )

        let repository = try SwiftDataCardRepository(storeURL: storeURL)
        let restored = try await repository.card(id: legacy.id)

        XCTAssertEqual(restored?.markdown, legacy.markdown)
        XCTAssertEqual(restored?.isVisible, true)
        XCTAssertEqual(restored?.tags, [])
        let v4Marker = root.appendingPathComponent("tag-v4-migration.backed-up")
        XCTAssertTrue(FileManager.default.fileExists(atPath: v4Marker.path))
        XCTAssertEqual(try String(contentsOf: v4Marker, encoding: .utf8), "tag-v4\n")
    }

    func testCorruptNonNilTagMetadataThrowsInsteadOfBecomingEmptyTags() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownCardCorruptTagTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("cards.store")
        let card = CardRecord(markdown: "# Preserve Tags")

        do {
            let schema = Schema(versionedSchema: MarkdownCardSchemaV4.self)
            let configuration = ModelConfiguration(
                "MarkdownCard",
                schema: schema,
                url: storeURL,
                allowsSave: true
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let stored = MarkdownCardSchemaV4.StoredCard(card: card)
            stored.tagsData = Data("not-valid-tag-json".utf8)
            context.insert(stored)
            try context.save()
        }

        let repository = try SwiftDataCardRepository(storeURL: storeURL)
        do {
            _ = try await repository.allCards()
            XCTFail("Expected corrupt Tag metadata to fail the read")
        } catch let error as CardRepositoryError {
            guard case let .corruptStore(details) = error else {
                return XCTFail("Expected corruptStore, got \(error)")
            }
            XCTAssertTrue(details.contains(card.id.uuidString))
            XCTAssertTrue(details.contains("Invalid Tag metadata"))
        }
    }

    func testLegacyFullScreenRawValueMigratesBeforeCardAndAllCardsReturn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MarkdownCardFullScreenMigrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("cards.store")
        let first = CardRecord(
            title: "Pinned First",
            markdown: "# First\n\nPreserve me.",
            isQuick: true,
            isVisible: true,
            themeID: "paper",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            windowFrame: WindowFrame(x: 10, y: 20, width: 900, height: 640),
            screenID: "Legacy Display",
            layoutMode: .custom,
            customLayout: CustomCardLayout(width: 900, minimumHeight: 300, maximumHeight: 700),
            tags: [try CardTag("Research")]
        )
        let second = CardRecord(
            markdown: "# Second",
            isVisible: false,
            createdAt: Date(timeIntervalSince1970: 30),
            updatedAt: Date(timeIntervalSince1970: 40),
            windowFrame: WindowFrame(x: 30, y: 40, width: 800, height: 600),
            screenID: "Other Display",
            layoutMode: .custom,
            customLayout: CustomCardLayout(width: 800, minimumHeight: 280, maximumHeight: 650),
            tags: [try CardTag("Reading")]
        )
        try writeLegacyFullScreenStore([first, second], to: storeURL)

        do {
            let repository = try SwiftDataCardRepository(storeURL: storeURL)
            let loadedFirst = try await repository.card(id: first.id)
            let migratedFirst = try XCTUnwrap(loadedFirst)
            assertLegacyFullScreenRecord(migratedFirst, preserves: first)
        }

        var snapshots = try storedCardSnapshots(at: storeURL)
        XCTAssertEqual(snapshots[first.id]?.layoutModeRaw, CardLayoutMode.middle.rawValue)
        XCTAssertNil(snapshots[first.id]?.windowX)
        XCTAssertNil(snapshots[first.id]?.windowY)
        XCTAssertNil(snapshots[first.id]?.windowWidth)
        XCTAssertNil(snapshots[first.id]?.windowHeight)
        XCTAssertNil(snapshots[first.id]?.screenID)
        XCTAssertNil(snapshots[first.id]?.customWidth)
        XCTAssertNil(snapshots[first.id]?.customMinimumHeight)
        XCTAssertNil(snapshots[first.id]?.customMaximumHeight)
        XCTAssertEqual(snapshots[first.id]?.updatedAt, first.updatedAt)
        XCTAssertEqual(snapshots[second.id]?.layoutModeRaw, "fullScreen")

        do {
            let repository = try SwiftDataCardRepository(storeURL: storeURL)
            let migrated = try await repository.allCards()
            XCTAssertEqual(Set(migrated.map(\.id)), Set([first.id, second.id]))
            assertLegacyFullScreenRecord(
                try XCTUnwrap(migrated.first { $0.id == second.id }),
                preserves: second
            )
        }

        snapshots = try storedCardSnapshots(at: storeURL)
        for original in [first, second] {
            XCTAssertEqual(snapshots[original.id]?.layoutModeRaw, CardLayoutMode.middle.rawValue)
            XCTAssertNil(snapshots[original.id]?.windowX)
            XCTAssertNil(snapshots[original.id]?.windowY)
            XCTAssertNil(snapshots[original.id]?.windowWidth)
            XCTAssertNil(snapshots[original.id]?.windowHeight)
            XCTAssertNil(snapshots[original.id]?.screenID)
            XCTAssertNil(snapshots[original.id]?.customWidth)
            XCTAssertNil(snapshots[original.id]?.customMinimumHeight)
            XCTAssertNil(snapshots[original.id]?.customMaximumHeight)
            XCTAssertEqual(snapshots[original.id]?.updatedAt, original.updatedAt)
        }

        do {
            let repository = try SwiftDataCardRepository(storeURL: storeURL)
            _ = try await repository.allCards()
        }
        XCTAssertEqual(try storedCardSnapshots(at: storeURL), snapshots)
    }

    func testAllCardsDoesNotPartiallyMigrateWhenAnotherStoredCardCannotDecode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MarkdownCardAtomicFullScreenMigrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("cards.store")
        let legacy = CardRecord(
            markdown: "# Legacy",
            updatedAt: Date(timeIntervalSince1970: 20),
            windowFrame: WindowFrame(x: 10, y: 20, width: 900, height: 640),
            screenID: "Legacy Display",
            layoutMode: .custom,
            customLayout: CustomCardLayout(width: 900, minimumHeight: 300, maximumHeight: 700)
        )
        let corrupt = CardRecord(markdown: "# Corrupt")

        do {
            let schema = Schema(versionedSchema: MarkdownCardSchemaV4.self)
            let configuration = ModelConfiguration(
                "MarkdownCard",
                schema: schema,
                url: storeURL,
                allowsSave: true
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let legacyStored = MarkdownCardSchemaV4.StoredCard(card: legacy)
            legacyStored.layoutModeRaw = "fullScreen"
            context.insert(legacyStored)
            let corruptStored = MarkdownCardSchemaV4.StoredCard(card: corrupt)
            corruptStored.tagsData = Data("not-valid-tag-json".utf8)
            context.insert(corruptStored)
            try context.save()
        }

        do {
            let repository = try SwiftDataCardRepository(storeURL: storeURL)
            do {
                _ = try await repository.allCards()
                XCTFail("Expected corrupt Tag metadata to prevent migration")
            } catch let error as CardRepositoryError {
                guard case let .corruptStore(details) = error else {
                    return XCTFail("Expected corruptStore, got \(error)")
                }
                XCTAssertTrue(details.contains(corrupt.id.uuidString))
            }
        }

        let snapshot = try XCTUnwrap(storedCardSnapshots(at: storeURL)[legacy.id])
        XCTAssertEqual(snapshot.layoutModeRaw, "fullScreen")
        XCTAssertEqual(snapshot.windowX, legacy.windowFrame?.x)
        XCTAssertEqual(snapshot.windowY, legacy.windowFrame?.y)
        XCTAssertEqual(snapshot.windowWidth, legacy.windowFrame?.width)
        XCTAssertEqual(snapshot.windowHeight, legacy.windowFrame?.height)
        XCTAssertEqual(snapshot.screenID, legacy.screenID)
        XCTAssertEqual(snapshot.customWidth, legacy.customLayout?.width)
        XCTAssertEqual(snapshot.customMinimumHeight, legacy.customLayout?.minimumHeight)
        XCTAssertEqual(snapshot.customMaximumHeight, legacy.customLayout?.maximumHeight)
        XCTAssertEqual(snapshot.updatedAt, legacy.updatedAt)
    }

    func testUnknownSwiftDataLayoutRawValueFailsInsteadOfFallingBackToCustom() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MarkdownCardUnknownLayoutTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("cards.store")
        let card = CardRecord(markdown: "# Unknown Layout")

        do {
            let schema = Schema(versionedSchema: MarkdownCardSchemaV4.self)
            let configuration = ModelConfiguration(
                "MarkdownCard",
                schema: schema,
                url: storeURL,
                allowsSave: true
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let stored = MarkdownCardSchemaV4.StoredCard(card: card)
            stored.layoutModeRaw = "futureLayout"
            context.insert(stored)
            try context.save()
        }

        let repository = try SwiftDataCardRepository(storeURL: storeURL)
        do {
            _ = try await repository.card(id: card.id)
            XCTFail("Expected an invalid stored layout to fail")
        } catch let error as CardRepositoryError {
            guard case let .corruptStore(details) = error else {
                return XCTFail("Expected corruptStore, got \(error)")
            }
            XCTAssertTrue(details.contains(card.id.uuidString))
            XCTAssertTrue(details.contains("futureLayout"))
        }
    }

    private struct StoredCardSnapshot: Equatable {
        var layoutModeRaw: String?
        var windowX: Double?
        var windowY: Double?
        var windowWidth: Double?
        var windowHeight: Double?
        var screenID: String?
        var customWidth: Double?
        var customMinimumHeight: Double?
        var customMaximumHeight: Double?
        var updatedAt: Date
    }

    private func writeLegacyFullScreenStore(_ cards: [CardRecord], to storeURL: URL) throws {
        let schema = Schema(versionedSchema: MarkdownCardSchemaV4.self)
        let configuration = ModelConfiguration(
            "MarkdownCard",
            schema: schema,
            url: storeURL,
            allowsSave: true
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        for card in cards {
            let stored = MarkdownCardSchemaV4.StoredCard(card: card)
            stored.layoutModeRaw = "fullScreen"
            context.insert(stored)
        }
        try context.save()
    }

    private func storedCardSnapshots(at storeURL: URL) throws -> [UUID: StoredCardSnapshot] {
        let schema = Schema(versionedSchema: MarkdownCardSchemaV4.self)
        let configuration = ModelConfiguration(
            "MarkdownCard",
            schema: schema,
            url: storeURL,
            allowsSave: true
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        return try Dictionary(
            uniqueKeysWithValues: context.fetch(
                FetchDescriptor<MarkdownCardSchemaV4.StoredCard>()
            ).map { stored in
                (
                    stored.id,
                    StoredCardSnapshot(
                        layoutModeRaw: stored.layoutModeRaw,
                        windowX: stored.windowX,
                        windowY: stored.windowY,
                        windowWidth: stored.windowWidth,
                        windowHeight: stored.windowHeight,
                        screenID: stored.screenID,
                        customWidth: stored.customWidth,
                        customMinimumHeight: stored.customMinimumHeight,
                        customMaximumHeight: stored.customMaximumHeight,
                        updatedAt: stored.updatedAt
                    )
                )
            }
        )
    }

    private func assertLegacyFullScreenRecord(
        _ migrated: CardRecord,
        preserves original: CardRecord,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(migrated.id, original.id, file: file, line: line)
        XCTAssertEqual(migrated.title, original.title, file: file, line: line)
        XCTAssertEqual(migrated.titleOverride, original.titleOverride, file: file, line: line)
        XCTAssertEqual(migrated.markdown, original.markdown, file: file, line: line)
        XCTAssertEqual(migrated.isQuick, original.isQuick, file: file, line: line)
        XCTAssertEqual(migrated.isVisible, original.isVisible, file: file, line: line)
        XCTAssertEqual(migrated.themeID, original.themeID, file: file, line: line)
        XCTAssertEqual(migrated.createdAt, original.createdAt, file: file, line: line)
        XCTAssertEqual(migrated.updatedAt, original.updatedAt, file: file, line: line)
        XCTAssertEqual(migrated.tags, original.tags, file: file, line: line)
        XCTAssertEqual(migrated.layoutMode, .middle, file: file, line: line)
        XCTAssertNil(migrated.windowFrame, file: file, line: line)
        XCTAssertNil(migrated.screenID, file: file, line: line)
        XCTAssertNil(migrated.customLayout, file: file, line: line)
    }
}

@MainActor
final class AppearanceControllerTests: XCTestCase {
    func testAppearanceModePersistsAndReloadsFromDefaults() {
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AppearanceController(defaults: defaults)
        XCTAssertEqual(first.mode, .system)
        first.setMode(.dark)
        XCTAssertEqual(defaults.string(forKey: AppearanceController.defaultsKey), "dark")

        let restored = AppearanceController(defaults: defaults)
        XCTAssertEqual(restored.mode, .dark)
        XCTAssertEqual(restored.resolvedAppearance, .dark)
    }

    func testInvalidStoredAppearanceFallsBackToSystem() {
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("sepia", forKey: AppearanceController.defaultsKey)

        let controller = AppearanceController(defaults: defaults)

        XCTAssertEqual(controller.mode, .system)
    }

    func testConsumersReceiveForcedAppearanceChanges() {
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AppearanceController(defaults: defaults)
        let consumer = RecordingAppearanceConsumer()

        controller.register(consumer)
        controller.setMode(.light)
        controller.setMode(.dark)

        XCTAssertEqual(Array(consumer.values.suffix(2)), [.light, .dark])
    }

    func testSystemAppearanceResolutionIsDeterministicForExplicitAppearances() {
        XCTAssertFalse(
            AppearanceController.systemIsDark(appearance: NSAppearance(named: .aqua))
        )
        XCTAssertTrue(
            AppearanceController.systemIsDark(appearance: NSAppearance(named: .darkAqua))
        )
    }

    func testForcedAppearanceAppliesToStatusMenu() {
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AppearanceController(defaults: defaults)
        let menu = NSMenu(title: "Appearance Test")

        controller.setMode(.light)
        controller.applyMode(to: menu)
        XCTAssertEqual(menu.appearance?.bestMatch(from: [.aqua, .darkAqua]), .aqua)

        controller.setMode(.dark)
        controller.applyMode(to: menu)
        XCTAssertEqual(menu.appearance?.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)

        controller.setMode(.system)
        controller.applyMode(to: menu)
        XCTAssertNil(menu.appearance)
    }
}

@MainActor
private final class RecordingAppearanceConsumer: AppearanceConsumer {
    private(set) var values: [ResolvedAppearance] = []

    func apply(resolvedAppearance: ResolvedAppearance) {
        values.append(resolvedAppearance)
    }
}

@MainActor
final class CardPanelStateTests: XCTestCase {
    func testLocalAttachmentStoreNormalizesAndLoadsClipboardImage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Markdown Card Attachment Tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAttachmentStore(directory: root)
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 8,
                pixelsHigh: 8,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        bitmap.setColor(
            NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1),
            atX: 0,
            y: 0
        )
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let source = try store.saveClipboardImage(data: png, mimeType: "image/png")
        let attachmentID = try XCTUnwrap(LocalAttachmentStore.attachmentID(fromMarkdownSource: source))
        let saved = try XCTUnwrap(store.data(forAttachmentID: attachmentID))

        XCTAssertTrue(source.hasPrefix("attachments/"))
        XCTAssertTrue(store.standardizedDirectoryFileURL.isFileURL)
        XCTAssertTrue(store.standardizedDirectoryFileURL.absoluteString.hasPrefix("file://"))
        XCTAssertTrue(store.standardizedDirectoryFileURL.absoluteString.contains("Markdown%20Card"))
        XCTAssertNotNil(NSImage(data: saved))
        XCTAssertThrowsError(
            try store.saveClipboardImage(data: Data("not an image".utf8), mimeType: "image/png")
        )
        XCTAssertThrowsError(
            try store.saveClipboardImage(data: png, mimeType: "application/octet-stream")
        )
    }

    func testCardHeaderAndTitleAreDragRegionsButControlsRemainButtons() throws {
        let defaults = UserDefaults(suiteName: "MarkdownCardAgentTests.\(UUID().uuidString)")!
        let appearance = AppearanceController(defaults: defaults)
        let controller = CardPanelController(
            card: CardRecord(markdown: "Drag me", layoutMode: .sticky),
            appearanceController: appearance
        )
        let root = try XCTUnwrap(controller.window?.contentView)
        let header = try XCTUnwrap(root.subviews.first as? CardHeaderView)
        let title = try XCTUnwrap(header.subviews.compactMap { $0 as? NSTextField }.first)
        let buttons = header.subviews.compactMap { $0 as? NSButton }
        let closeButton = try XCTUnwrap(buttons.first { $0.toolTip == "Hide Card (Esc)" })
        let layoutButton = try XCTUnwrap(buttons.first { $0.toolTip == "Card Layout" })
        let copyButton = try XCTUnwrap(buttons.first { $0.toolTip == "Copy Markdown" })
        let exportButton = try XCTUnwrap(
            buttons.first { $0.toolTip?.hasPrefix("Export Markdown") == true }
        )
        var closeCount = 0
        var layoutCount = 0
        var copyCount = 0
        var exportCount = 0
        var dragCalls: [(NSWindow, NSEvent)] = []
        header.windowDragHandler = { window, event in
            dragCalls.append((window, event))
        }
        header.onClose = { closeCount += 1 }
        header.onShowLayoutMenu = { _ in layoutCount += 1 }
        header.onCopyMarkdown = { copyCount += 1 }
        header.onExportMarkdown = { exportCount += 1 }

        let window = try XCTUnwrap(controller.window)
        let mouseDown = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: NSPoint(x: header.bounds.midX, y: header.bounds.midY),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 7,
                clickCount: 1,
                pressure: 1
            )
        )

        XCTAssertFalse(header.mouseDownCanMoveWindow)
        XCTAssertTrue(header.acceptsFirstMouse(for: nil))
        XCTAssertFalse(title.mouseDownCanMoveWindow)
        XCTAssertTrue(title.acceptsFirstMouse(for: nil))
        XCTAssertFalse(buttons.isEmpty)
        XCTAssertTrue(buttons.allSatisfy { !$0.mouseDownCanMoveWindow })
        header.mouseDown(with: mouseDown)
        title.mouseDown(with: mouseDown)
        XCTAssertEqual(dragCalls.count, 2)
        XCTAssertTrue(dragCalls.allSatisfy { $0.0 === window })
        XCTAssertTrue(dragCalls.allSatisfy { $0.1.eventNumber == mouseDown.eventNumber })

        closeButton.performClick(nil)
        layoutButton.performClick(nil)
        copyButton.performClick(nil)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(layoutCount, 1)
        XCTAssertEqual(copyCount, 1)
        XCTAssertEqual(dragCalls.count, 2)
        XCTAssertFalse(exportButton.isHidden)
        XCTAssertEqual(exportButton.alphaValue, 1)
        XCTAssertEqual(exportButton.toolTip, "Export Markdown")
        header.setManagedAttachmentsPresent(true, animated: false)
        XCTAssertFalse(exportButton.isHidden)
        XCTAssertEqual(exportButton.alphaValue, 1)
        XCTAssertEqual(exportButton.toolTip, "Export Markdown with Attachments")
        exportButton.performClick(nil)
        XCTAssertEqual(exportCount, 1)
        header.setMiniMode(true)
        XCTAssertTrue(exportButton.isHidden)
    }

    func testWindowDidChangeScreenPreservesFrameLayoutAndPersistsScreenIdentity() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = CardPanelController(
            card: CardRecord(markdown: "# Across displays", layoutMode: .sticky),
            appearanceController: AppearanceController(defaults: defaults)
        )
        let window = try XCTUnwrap(controller.window)
        let initialFrame = NSRect(
            x: screen.visibleFrame.midX - 180,
            y: screen.visibleFrame.midY - 150,
            width: 360,
            height: 300
        )
        window.setFrame(initialFrame, display: false)
        let frameBeforeScreenChange = window.frame
        let initialLayout = controller.card.layoutMode
        var savedFrame: WindowFrame?
        var savedScreenID: String?
        controller.onFrameChange = { _, frame, screenID in
            savedFrame = frame
            savedScreenID = screenID
        }

        controller.windowDidChangeScreen(
            Notification(name: NSWindow.didChangeScreenNotification, object: window)
        )
        controller.flushPendingChanges()

        XCTAssertEqual(window.frame, frameBeforeScreenChange)
        XCTAssertEqual(controller.card.layoutMode, initialLayout)
        XCTAssertEqual(savedFrame?.x, frameBeforeScreenChange.origin.x)
        XCTAssertEqual(savedFrame?.y, frameBeforeScreenChange.origin.y)
        XCTAssertEqual(savedFrame?.width, frameBeforeScreenChange.width)
        XCTAssertEqual(savedFrame?.height, frameBeforeScreenChange.height)
        XCTAssertEqual(savedScreenID, window.screen?.localizedName)
    }

    func testPresentationScreenUsesCurrentScreenOnlyForCardsWithoutStoredFrame() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let newCard = CardRecord(markdown: "New")
        let restoredCard = CardRecord(
            markdown: "Restored",
            windowFrame: WindowFrame(x: 100, y: 100, width: 360, height: 300),
            screenID: screen.localizedName
        )

        XCTAssertTrue(
            AgentApplicationController.presentationScreen(
                for: newCard,
                currentScreen: screen
            ) === screen
        )
        XCTAssertNil(
            AgentApplicationController.presentationScreen(
                for: restoredCard,
                currentScreen: screen
            )
        )

        let migratedPresentation = AgentApplicationController.startupPresentation(
            for: newCard,
            currentScreen: screen
        )
        XCTAssertTrue(migratedPresentation.screen === screen)
        XCTAssertTrue(migratedPresentation.centerIfNeeded)

        let restoredPresentation = AgentApplicationController.startupPresentation(
            for: restoredCard,
            currentScreen: screen
        )
        XCTAssertNil(restoredPresentation.screen)
        XCTAssertFalse(restoredPresentation.centerIfNeeded)
    }

    func testMarkdownExportWritesRelativeBundleAndPreservesUnrelatedAttachments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Markdown Export Tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDirectory = root.appendingPathComponent("Managed Attachments")
        let store = LocalAttachmentStore(directory: sourceDirectory)
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 4,
                pixelsHigh: 4,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let source = try store.saveClipboardImage(data: png, mimeType: "image/png")
        let identifier = try XCTUnwrap(LocalAttachmentStore.attachmentID(fromMarkdownSource: source))
        let exportDirectory = root.appendingPathComponent("Workspace")
        let attachmentDirectory = exportDirectory.appendingPathComponent("attachments")
        try FileManager.default.createDirectory(at: attachmentDirectory, withIntermediateDirectories: true)
        let unrelated = attachmentDirectory.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        let markdownURL = exportDirectory.appendingPathComponent("Card.md")
        let markdown = "![Screenshot](attachments/\(identifier).png)"

        let writer = MarkdownExportWriter(attachmentStore: store)
        try writer.write(
            MarkdownExportBundle(
                markdown: markdown,
                attachmentIDs: [identifier, identifier]
            ),
            to: markdownURL
        )

        XCTAssertEqual(try String(contentsOf: markdownURL, encoding: .utf8), markdown)
        XCTAssertNotNil(
            NSImage(contentsOf: attachmentDirectory.appendingPathComponent("\(identifier).png"))
        )
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep")
        XCTAssertEqual(MarkdownExportService.suggestedFilename(for: "A/B: C"), "A-B- C.md")
    }

    func testMarkdownExportMissingAttachmentDoesNotOverwriteMarkdown() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Markdown Export Failure Tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let markdownURL = root.appendingPathComponent("Existing.md")
        try Data("original".utf8).write(to: markdownURL)
        let missing = "34d1880c-35d5-4c7e-9620-40c3140b003c"
        let writer = MarkdownExportWriter(
            attachmentStore: LocalAttachmentStore(directory: root.appendingPathComponent("source"))
        )

        XCTAssertThrowsError(
            try writer.write(
                MarkdownExportBundle(
                    markdown: "![Missing](attachments/\(missing).png)",
                    attachmentIDs: [missing]
                ),
                to: markdownURL
            )
        ) { error in
            XCTAssertEqual(error as? MarkdownExportError, .missingAttachment(missing))
        }
        XCTAssertEqual(try String(contentsOf: markdownURL, encoding: .utf8), "original")
    }

    func testCardsUseFloatingWindowLevelAcrossSpaces() throws {
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appearance = AppearanceController(defaults: defaults)

        let controller = CardPanelController(
            card: CardRecord(markdown: "Always on top"),
            appearanceController: appearance
        )
        let panel = try XCTUnwrap(controller.window as? NSPanel)
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertEqual(panel.level, NSWindow.Level.floating)
        XCTAssertTrue(panel.collectionBehavior.contains(NSWindow.CollectionBehavior.canJoinAllSpaces))
    }

    func testWindowBackingSurfaceMatchesCanvasAcrossAppearances() throws {
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appearance = AppearanceController(defaults: defaults)
        let controller = CardPanelController(
            card: CardRecord(markdown: "# Surface", layoutMode: .sticky),
            appearanceController: appearance
        )
        let panel = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(panel.contentView)
        let frameHost = try XCTUnwrap(root.superview)

        for mode in [AppearanceMode.light, .dark] {
            appearance.setMode(mode)
            let resolved: ResolvedAppearance = mode == .dark ? .dark : .light
            let nativeBackground = MonochromePalette.windowBackground(for: resolved)
            let background = nativeBackground.cgColor
            let expectedComponent: CGFloat = mode == .dark ? 30.0 / 255.0 : 251.0 / 255.0
            let sRGB = try XCTUnwrap(nativeBackground.usingColorSpace(.sRGB))
            XCTAssertEqual(sRGB.redComponent, expectedComponent, accuracy: 0.000_001)
            XCTAssertEqual(sRGB.greenComponent, expectedComponent, accuracy: 0.000_001)
            XCTAssertEqual(sRGB.blueComponent, expectedComponent, accuracy: 0.000_001)
            XCTAssertEqual(panel.backgroundColor.cgColor, background)
            XCTAssertFalse(panel.isOpaque)
            XCTAssertEqual(root.layer?.backgroundColor, background)
            XCTAssertTrue(root.isOpaque)
            XCTAssertEqual(root.layerContentsRedrawPolicy, .duringViewResize)
            XCTAssertEqual(frameHost.layerContentsRedrawPolicy, .duringViewResize)
            XCTAssertEqual(frameHost.layer?.cornerRadius, 10)
            XCTAssertEqual(frameHost.layer?.cornerCurve, .continuous)
            XCTAssertTrue(frameHost.layer?.masksToBounds == true)
        }
    }

    func testLayoutGeometryCentersAndClampsAutoHeight() {
        let visible = NSRect(x: 100, y: 50, width: 1_000, height: 900)
        XCTAssertEqual(
            CardLayoutGeometry.centeredFrame(
                for: .middle,
                contentHeight: 100,
                custom: nil,
                visibleFrame: visible
            ),
            NSRect(x: 240, y: 320, width: 720, height: 360)
        )
        XCTAssertEqual(
            CardLayoutGeometry.centeredFrame(
                for: .sticky,
                contentHeight: 900,
                custom: nil,
                visibleFrame: visible
            ),
            NSRect(x: 420, y: 220, width: 360, height: 560)
        )
        XCTAssertEqual(
            CardLayoutGeometry.centeredFrame(
                for: .mini,
                contentHeight: 900,
                custom: nil,
                visibleFrame: visible
            ),
            NSRect(x: 486, y: 476, width: 228, height: 48)
        )
        XCTAssertEqual(
            CardLayoutGeometry.totalHeight(
                for: .custom,
                contentHeight: 500,
                custom: CustomCardLayout(width: 640, minimumHeight: 300, maximumHeight: 420),
                visibleFrame: visible
            ),
            420
        )

        let oldFrame = NSRect(x: 300, y: 300, width: 360, height: 240)
        let grown = CardLayoutGeometry.topAnchoredFrame(
            from: oldFrame,
            mode: .sticky,
            contentHeight: 400,
            custom: nil,
            visibleFrame: visible
        )
        XCTAssertEqual(grown.maxY, oldFrame.maxY)
        XCTAssertEqual(grown.height, 448)
    }

    func testLayoutShortcutsUseNearestTopEdgeAndLeaveControlFourUnassigned() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let visible = screen.visibleFrame
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appearance = AppearanceController(defaults: defaults)
        appearance.setMode(.light)
        let controller = CardPanelController(
            card: CardRecord(markdown: "# Anchor", layoutMode: .sticky),
            appearanceController: appearance
        )
        let window = try XCTUnwrap(controller.window)
        controller.show(on: screen, activate: false)
        defer { controller.hide(flushingPendingChanges: false) }
        let rootView = try XCTUnwrap(window.contentView)
        let startingTop = visible.maxY - 72
        let startingFrame = NSRect(
            x: visible.midX - 180,
            y: startingTop - 300,
            width: 360,
            height: 300
        )
        window.setFrame(startingFrame, display: false)
        XCTAssertEqual(rootView.frame.size, window.contentLayoutRect.size)
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue((window as? NSPanel)?.isFloatingPanel == true)
        XCTAssertTrue(rootView.autoresizingMask.contains(.width))
        XCTAssertTrue(rootView.autoresizingMask.contains(.height))
        XCTAssertEqual(
            rootView.layer?.backgroundColor,
            MonochromePalette.windowBackground(for: .light).cgColor
        )

        XCTAssertFalse(window.performKeyEquivalent(with: try commandEvent(
            "1",
            keyCode: 18,
            window: window,
            modifiers: [.command, .option]
        )))
        XCTAssertEqual(controller.card.layoutMode, .sticky)
        XCTAssertFalse(window.performKeyEquivalent(with: try commandEvent(
            "1",
            keyCode: 18,
            window: window,
            modifiers: [.command]
        )))
        XCTAssertEqual(controller.card.layoutMode, .sticky)

        XCTAssertTrue(window.performKeyEquivalent(with: try commandEvent("3", keyCode: 20, window: window)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        let middleFrame = window.frame
        XCTAssertEqual(rootView.frame.size, window.contentLayoutRect.size)
        XCTAssertEqual(controller.card.layoutMode, .middle)
        XCTAssertEqual(middleFrame.minX, startingFrame.minX, accuracy: 1)
        XCTAssertEqual(middleFrame.maxY, startingFrame.maxY, accuracy: 1)

        XCTAssertFalse(window.performKeyEquivalent(with: try commandEvent("4", keyCode: 21, window: window)))
        XCTAssertEqual(controller.card.layoutMode, .middle)
        XCTAssertEqual(window.frame, middleFrame)
        XCTAssertEqual(rootView.frame.size, window.contentLayoutRect.size)
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue((window as? NSPanel)?.isFloatingPanel == true)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))

        XCTAssertTrue(window.performKeyEquivalent(with: try commandEvent("2", keyCode: 19, window: window)))
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(controller.card.layoutMode, .sticky)
        XCTAssertEqual(window.frame.maxX, middleFrame.maxX, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, middleFrame.maxY, accuracy: 1)
        XCTAssertEqual(rootView.frame.size, window.contentLayoutRect.size)
        XCTAssertEqual(window.level, .floating)
        XCTAssertTrue((window as? NSPanel)?.isFloatingPanel == true)
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces))
    }

    func testSingleCanvasHideRequestsImmediately() {
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = CardPanelController(
            card: CardRecord(title: "State Test", markdown: "# State Test"),
            appearanceController: AppearanceController(defaults: defaults)
        )
        var hideRequests = 0
        controller.onRequestHide = { _ in hideRequests += 1 }

        controller.requestHide()
        XCTAssertEqual(hideRequests, 1)
    }

    func testShortcutDisplayFormatterDoesNotRequireLocalizedResourceBundle() {
        XCTAssertEqual(
            ShortcutDisplayFormatter.string(
                for: KeyboardShortcuts.Shortcut(.space, modifiers: [.option])
            ),
            "⌥ Space"
        )
        XCTAssertEqual(
            ShortcutDisplayFormatter.string(
                for: KeyboardShortcuts.Shortcut(.leftArrow, modifiers: [.control, .option])
            ),
            "⌃⌥←"
        )
        XCTAssertEqual(
            ShortcutDisplayFormatter.string(
                for: KeyboardShortcuts.Shortcut(.n, modifiers: [.option, .command])
            ),
            "⌥⌘N"
        )
        XCTAssertEqual(
            ShortcutDisplayFormatter.string(
                for: KeyboardShortcuts.Shortcut(.l, modifiers: [.command])
            ),
            "⌘L"
        )
        XCTAssertEqual(
            ShortcutDisplayFormatter.string(
                for: KeyboardShortcuts.Shortcut(.comma, modifiers: [.command])
            ),
            "⌘,"
        )
    }

    func testCommandNRequestsAnIndependentCard() throws {
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = CardPanelController(
            card: CardRecord(markdown: "# Current"),
            appearanceController: AppearanceController(defaults: defaults)
        )
        var createRequests = 0
        controller.onCreateCard = { createRequests += 1 }
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: .command,
                timestamp: 0,
                windowNumber: controller.window?.windowNumber ?? 0,
                context: nil,
                characters: "n",
                charactersIgnoringModifiers: "n",
                isARepeat: false,
                keyCode: 45
            )
        )

        XCTAssertTrue(try XCTUnwrap(controller.window).performKeyEquivalent(with: event))
        XCTAssertEqual(createRequests, 1)
    }

    func testMiniLayoutHidesBodyAndKeepsLayoutControlVisible() throws {
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appearance = AppearanceController(defaults: defaults)
        let requestedAppearance = ProcessInfo.processInfo.environment["MARKDOWN_CARD_QA_APPEARANCE"]
            .flatMap(AppearanceMode.init(rawValue:)) ?? .dark
        appearance.setMode(requestedAppearance)
        let controller = CardPanelController(
            card: CardRecord(
                markdown: "RESEARCH NOTE / 014",
                isVisible: true,
                layoutMode: .mini
            ),
            appearanceController: appearance
        )
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()

        XCTAssertEqual(window.frame.size, NSSize(width: 228, height: 48))
        let header = try XCTUnwrap(root.subviews.first)
        let preview = try XCTUnwrap(root.subviews.last)
        XCTAssertTrue(preview.isHidden)

        let buttons = header.subviews.compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.filter { !$0.isHidden && $0.alphaValue > 0.01 }.count, 2)
        let layoutButton = try XCTUnwrap(
            buttons.first { $0.accessibilityLabel() == "Card layout" }
        )
        XCTAssertEqual(
            layoutButton.toolTip,
            "Choose Card Layout — Restore from Mini (⌃2 for Sticky Note)"
        )
        XCTAssertEqual(
            layoutButton.accessibilityHelp(),
            "Choose another card layout to restore the editor. "
                + "Press Control-2 for Sticky Note."
        )
        XCTAssertTrue(layoutButton.acceptsFirstResponder)

        if let path = ProcessInfo.processInfo.environment["MARKDOWN_CARD_QA_MINI_PATH"] {
            try writeSnapshot(of: root, to: path)
        }

        if let path = ProcessInfo.processInfo.environment["MARKDOWN_CARD_QA_MINI_HOVER_PATH"] {
            try writeSnapshot(of: root, to: path)
        }
    }

    private func writeSnapshot(of view: NSView, to path: String) throws {
        view.displayIfNeeded()
        let representation = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func commandEvent(
        _ key: String,
        keyCode: UInt16,
        window: NSWindow,
        modifiers: NSEvent.ModifierFlags = [.control]
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: key,
                charactersIgnoringModifiers: key,
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }
}

@MainActor
final class YouTubeThumbnailTests: XCTestCase {
    func testSchemeOnlyAcceptsYouTubeVideoIDs() {
        XCTAssertEqual(
            YouTubeThumbnailSchemeHandler.videoID(
                from: URL(string: "mdcard-asset://youtube/dQw4w9WgXcQ")
            ),
            "dQw4w9WgXcQ"
        )
        XCTAssertNil(
            YouTubeThumbnailSchemeHandler.videoID(
                from: URL(string: "mdcard-asset://other/dQw4w9WgXcQ")
            )
        )
        XCTAssertNil(
            YouTubeThumbnailSchemeHandler.videoID(
                from: URL(string: "https://youtube/dQw4w9WgXcQ")
            )
        )
        XCTAssertNil(
            YouTubeThumbnailSchemeHandler.videoID(
                from: URL(string: "mdcard-asset://youtube/../../secret")
            )
        )

        let attachmentID = "34d1880c-35d5-4c7e-9620-40c3140b003c"
        XCTAssertEqual(
            YouTubeThumbnailSchemeHandler.attachmentID(
                from: URL(string: "mdcard-asset://attachment/\(attachmentID).png")
            ),
            attachmentID
        )
        XCTAssertNil(
            YouTubeThumbnailSchemeHandler.attachmentID(
                from: URL(string: "mdcard-asset://attachment/../../private.png")
            )
        )
    }

    func testImageValidationTranscodesAndRejectsInvalidData() throws {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 2,
                pixelsHigh: 2,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        bitmap.setColor(
            NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1),
            atX: 0,
            y: 0
        )
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let jpeg = try XCTUnwrap(YouTubeThumbnailLoader.validatedJPEG(from: png))

        XCTAssertTrue(jpeg.starts(with: Data([0xFF, 0xD8])))
        XCTAssertNil(YouTubeThumbnailLoader.validatedJPEG(from: Data("not an image".utf8)))
        XCTAssertNil(
            YouTubeThumbnailLoader.validatedJPEG(
                from: Data(repeating: 0, count: YouTubeThumbnailLoader.maximumDownloadSize + 1)
            )
        )
    }

    func testValidCachedThumbnailCompletesWithoutNetworkTask() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownCardThumbnailTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let videoID = "dQw4w9WgXcQ"
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 2,
                pixelsHigh: 2,
                bitsPerSample: 8,
                samplesPerPixel: 3,
                hasAlpha: false,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        let cached = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
        try cached.write(to: root.appendingPathComponent("\(videoID).jpg"))
        let loader = YouTubeThumbnailLoader(cacheDirectory: root)
        let result = LockedBox<Result<Data, Error>>()

        let task = loader.load(videoID: videoID) { loaded in result.set(loaded) }

        XCTAssertNil(task)
        let loaded = try XCTUnwrap(result.value).get()
        XCTAssertTrue(loaded.starts(with: Data([0xFF, 0xD8])))
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value?

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

private actor RecordingCardRepository: CardRepository {
    private var cardsByID: [UUID: CardRecord] = [:]
    private var upserted: [CardRecord] = []
    private var shouldBlockNextTaggedUpsert = false
    private var blockedTaggedUpsertStarted = false
    private var blockedStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedRelease: CheckedContinuation<Void, Never>?

    func allCards() async throws -> [CardRecord] {
        Array(cardsByID.values)
    }

    func card(id: UUID) async throws -> CardRecord? {
        cardsByID[id]
    }

    func upsert(_ card: CardRecord) async throws -> CardRecord {
        upserted.append(card)
        if shouldBlockNextTaggedUpsert, !card.tags.isEmpty {
            shouldBlockNextTaggedUpsert = false
            blockedTaggedUpsertStarted = true
            let waiters = blockedStartWaiters
            blockedStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                blockedRelease = continuation
            }
        }
        cardsByID[card.id] = card
        return card
    }

    func delete(id: UUID) async throws -> Bool {
        cardsByID.removeValue(forKey: id) != nil
    }

    func deleteLegacyQuickCards() async throws -> Int {
        let legacyIDs = cardsByID.values.filter(\.isQuick).map(\.id)
        legacyIDs.forEach { cardsByID[$0] = nil }
        return legacyIDs.count
    }

    func replaceAll(with cards: [CardRecord]) async throws {
        let replacement = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        guard replacement.count == cards.count else {
            let duplicate = cards.first { card in
                cards.filter { $0.id == card.id }.count > 1
            }!
            throw CardRepositoryError.duplicateCardID(duplicate.id)
        }
        cardsByID = replacement
    }

    func upsertCount() -> Int {
        upserted.count
    }

    func upsertSnapshots() -> [CardRecord] {
        upserted
    }

    func blockNextTaggedUpsert() {
        shouldBlockNextTaggedUpsert = true
        blockedTaggedUpsertStarted = false
    }

    func waitUntilTaggedUpsertIsBlocked() async {
        guard !blockedTaggedUpsertStarted else { return }
        await withCheckedContinuation { continuation in
            blockedStartWaiters.append(continuation)
        }
    }

    func releaseBlockedTaggedUpsert() {
        blockedRelease?.resume()
        blockedRelease = nil
    }
}

@MainActor
final class NewCardTests: XCTestCase {
    func testNewCardDefaultsToVisibleStickyAndPersistsRecentID() async throws {
        let repository = try SwiftDataCardRepository(inMemory: true)
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )

        let created = try await controller.createIndependentCard(
            markdown: "# Created",
            title: nil,
            show: false
        )
        let stored = try await repository.allCards()

        XCTAssertFalse(created.isQuick)
        XCTAssertTrue(created.isVisible)
        XCTAssertEqual(created.layoutMode, .sticky)
        XCTAssertEqual(created.title, "Created")
        XCTAssertEqual(
            defaults.string(forKey: AgentApplicationController.lastActiveCardDefaultsKey),
            created.id.uuidString
        )
        XCTAssertTrue(stored.contains { $0.id == created.id })
    }

    func testUntitledEmptyUICardRemainsTransient() async throws {
        let repository = try SwiftDataCardRepository(inMemory: true)
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )

        let created = try await controller.createIndependentCard(
            markdown: "",
            title: nil,
            show: false,
            persistEmpty: false
        )

        XCTAssertEqual(created.title, CardRecord.untitledTitle)
        XCTAssertTrue(created.markdown.isEmpty)
        let stored = try await repository.allCards()
        XCTAssertTrue(stored.isEmpty)
    }

    func testTagCommandPersistsMetadataButRemovesCommandFromMarkdown() async throws {
        let repository = try SwiftDataCardRepository(inMemory: true)
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )

        let created = try await controller.createIndependentCard(
            markdown: "/tag   Research Notes",
            show: false
        )
        controller.stageTagCommand(
            id: created.id,
            tagName: "  Research   Notes  ",
            markdown: "",
            incomingRevision: 1,
            source: .commandLine
        )
        try await controller.prepareForTermination()

        let persisted = try await repository.card(id: created.id)
        let stored = try XCTUnwrap(persisted)
        XCTAssertEqual(stored.markdown, "")
        XCTAssertEqual(stored.tags.map(\.name), ["Research Notes"])
        XCTAssertEqual(stored.title, CardRecord.untitledTitle)
    }

    func testCreateRequestRejectsAllTagsAtomicallyWhenOneIsInvalid() async throws {
        let repository = RecordingCardRepository()
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )

        let response = await controller.handle(
            AgentRequest(
                command: .create(
                    CreateOptions(
                        markdown: "# Must not be created",
                        tags: ["Research", "invalid\ntag"]
                    )
                )
            )
        )
        let stored = try await repository.allCards()
        let writes = await repository.upsertCount()

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "command_failed")
        XCTAssertTrue(response.error?.message.contains("line breaks") == true)
        XCTAssertTrue(stored.isEmpty)
        XCTAssertEqual(writes, 0)
    }

    func testTagOnlyCreatePersistsNormalizedTagsAndPreservesFirstSpelling() async throws {
        let repository = RecordingCardRepository()
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )
        let tags = try [
            CardTag("  Research   Notes "),
            CardTag("research notes"),
            CardTag("Reading"),
        ]

        let created = try await controller.createIndependentCard(
            tags: tags,
            show: false,
            persistEmpty: false
        )
        let stored = try await repository.card(id: created.id)
        let writes = await repository.upsertCount()

        XCTAssertEqual(created.tags.map(\.name), ["Research Notes", "Reading"])
        XCTAssertEqual(stored?.tags.map(\.name), ["Research Notes", "Reading"])
        XCTAssertEqual(writes, 1)
    }

    func testDirectTagPromotesTransientAndDuplicateIsAZeroWriteNoOp() async throws {
        let repository = RecordingCardRepository()
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )
        let transient = try await controller.createIndependentCard(
            show: false,
            persistEmpty: false
        )
        let initiallyStored = try await repository.card(id: transient.id)
        XCTAssertNil(initiallyStored)

        let tagged = try await controller.addTag(
            id: transient.id,
            name: "  Research   Notes "
        )
        let writesAfterFirstTag = await repository.upsertCount()
        let duplicate = try await controller.addTag(
            id: transient.id,
            name: "ＲＥＳＥＡＲＣＨ ＮＯＴＥＳ"
        )
        let writesAfterDuplicate = await repository.upsertCount()
        let stored = try await repository.card(id: transient.id)

        XCTAssertEqual(tagged.tags.map(\.name), ["Research Notes"])
        XCTAssertEqual(duplicate.tags.map(\.name), ["Research Notes"])
        XCTAssertEqual(duplicate.updatedAt, tagged.updatedAt)
        XCTAssertEqual(writesAfterFirstTag, 1)
        XCTAssertEqual(writesAfterDuplicate, writesAfterFirstTag)
        XCTAssertEqual(stored, tagged)
    }

    func testDirectTagReportsUnknownCardAndInvalidNameWithoutWriting() async throws {
        let repository = RecordingCardRepository()
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )
        let existing = try await controller.createIndependentCard(
            markdown: "# Existing",
            show: false
        )
        let writesBeforeErrors = await repository.upsertCount()
        let missingID = UUID()

        let missingResponse = await controller.handle(
            AgentRequest(
                command: .tag(TagOptions(cardID: missingID, name: "Research"))
            )
        )
        let invalidResponse = await controller.handle(
            AgentRequest(
                command: .tag(TagOptions(cardID: existing.id, name: "invalid\ntag"))
            )
        )
        let writesAfterErrors = await repository.upsertCount()

        XCTAssertFalse(missingResponse.ok)
        XCTAssertEqual(missingResponse.error?.code, "command_failed")
        XCTAssertTrue(
            missingResponse.error?.message.contains(missingID.uuidString) == true
        )
        XCTAssertFalse(invalidResponse.ok)
        XCTAssertEqual(invalidResponse.error?.code, "command_failed")
        XCTAssertTrue(invalidResponse.error?.message.contains("line breaks") == true)
        XCTAssertEqual(writesAfterErrors, writesBeforeErrors)
    }

    func testDirectTagKeepsHiddenCardHiddenAndPreservesMarkdown() async throws {
        let repository = RecordingCardRepository()
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )
        let created = try await controller.createIndependentCard(
            markdown: "# Hidden\n\nKeep this body.",
            show: false
        )

        let hideResponse = await controller.handle(
            AgentRequest(command: .hide(HideOptions(selector: .card(created.id))))
        )
        let tagResponse = await controller.handle(
            AgentRequest(
                command: .tag(TagOptions(cardID: created.id, name: "Research"))
            )
        )
        let tagged = try tagResponse.decodedPayload(CardMutationPayload.self).card
        let stored = try await repository.card(id: created.id)

        XCTAssertTrue(hideResponse.ok)
        XCTAssertTrue(tagResponse.ok)
        XCTAssertFalse(tagged.isVisible)
        XCTAssertEqual(tagged.markdown, created.markdown)
        XCTAssertEqual(tagged.tags.map(\.name), ["Research"])
        XCTAssertEqual(stored, tagged)
    }

    func testDirectTagFlushesPendingMarkdownAndRetainsEditsDuringSynchronousWrite() async throws {
        let repository = RecordingCardRepository()
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )
        let created = try await controller.createIndependentCard(
            markdown: "# Initial",
            show: false
        )
        controller.stageMarkdownUpdate(
            id: created.id,
            markdown: "# Pending before Tag",
            incomingRevision: 1,
            source: EditorSourceID()
        )
        await repository.blockNextTaggedUpsert()

        let addTask = Task { @MainActor in
            try await controller.addTag(id: created.id, name: "Research")
        }
        await repository.waitUntilTaggedUpsertIsBlocked()
        controller.stageMarkdownUpdate(
            id: created.id,
            markdown: "# Edited during Tag write",
            incomingRevision: 2,
            source: EditorSourceID()
        )
        await repository.releaseBlockedTaggedUpsert()

        let tagged = try await addTask.value
        XCTAssertEqual(tagged.markdown, "# Edited during Tag write")
        XCTAssertEqual(tagged.tags.map(\.name), ["Research"])

        try await controller.prepareForTermination()
        let stored = try await repository.card(id: created.id)
        let snapshots = await repository.upsertSnapshots()

        XCTAssertEqual(stored?.markdown, "# Edited during Tag write")
        XCTAssertEqual(stored?.tags.map(\.name), ["Research"])
        XCTAssertTrue(
            snapshots.contains {
                $0.markdown == "# Pending before Tag" && $0.tags.isEmpty
            }
        )
        XCTAssertTrue(
            snapshots.contains {
                $0.markdown == "# Pending before Tag"
                    && $0.tags.map(\.name) == ["Research"]
            }
        )
    }
}

@MainActor
final class CommandCenterAndDocumentSyncTests: XCTestCase {
    func testCardLibraryShowsDirectCopyExportAndDeleteActions() {
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = CardLibraryWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )
        controller.applySnapshot([CardRecord(title: "Actions", markdown: "Body")], revisions: [:])
        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { child in
                (child as? NSButton).map { [$0] } ?? buttons(in: child)
            }
        }
        let tooltips = Set(buttons(in: controller.window!.contentView!).compactMap(\.toolTip))
        XCTAssertTrue(tooltips.contains("Copy Markdown"))
        XCTAssertTrue(tooltips.contains("Export Markdown"))
        XCTAssertTrue(tooltips.contains("Delete Card"))
        XCTAssertFalse(tooltips.contains("More card actions"))
    }

    func testCommandCenterSearchRanksTitleBeforeBodyAndUsesRecencyForTies() {
        let now = Date()
        let exact = CardRecord(
            title: "Alpha",
            markdown: "body",
            updatedAt: now.addingTimeInterval(-100)
        )
        let prefix = CardRecord(
            title: "Alpha Notes",
            markdown: "body",
            updatedAt: now
        )
        let body = CardRecord(
            title: "Meeting",
            markdown: "Discuss Alpha tomorrow",
            updatedAt: now.addingTimeInterval(100)
        )

        XCTAssertEqual(
            CommandCenterSearch.cards(matching: "Alpha", in: [body, prefix, exact]).map(\.id),
            [exact.id, prefix.id, body.id]
        )
    }

    func testCommandCenterMaterialConfigurationUsesGlassFallbackAndAccessibilityModes() {
        let glass = CommandCenterMaterialConfiguration.resolve(
            appearance: .dark,
            nativeGlassAvailable: true,
            reduceTransparency: false,
            increaseContrast: false
        )
        XCTAssertEqual(glass.backdrop, .nativeGlass)
        XCTAssertEqual(glass.surfaceAlpha, 0)
        XCTAssertEqual(glass.borderWidth, 0)
        XCTAssertEqual(glass.selectionAlpha, 0.32)

        let fallback = CommandCenterMaterialConfiguration.resolve(
            appearance: .light,
            nativeGlassAvailable: false,
            reduceTransparency: false,
            increaseContrast: false
        )
        XCTAssertEqual(fallback.backdrop, .visualEffect)
        XCTAssertEqual(fallback.surfaceAlpha, 0.16)
        XCTAssertEqual(fallback.borderWidth, 1)
        XCTAssertEqual(fallback.borderAlpha, 0.55)

        let accessible = CommandCenterMaterialConfiguration.resolve(
            appearance: .dark,
            nativeGlassAvailable: true,
            reduceTransparency: true,
            increaseContrast: true
        )
        XCTAssertEqual(accessible.surfaceAlpha, 1)
        XCTAssertEqual(accessible.borderWidth, 1.5)
        XCTAssertEqual(accessible.borderAlpha, 1)
        XCTAssertEqual(accessible.selectionAlpha, 0.50)
    }

    func testCommandCenterMotionConfigurationRemovesScaleForReducedMotion() {
        let standard = CommandCenterMotionConfiguration.resolve(reduceMotion: false)
        XCTAssertEqual(standard.openingDuration, 0.14)
        XCTAssertEqual(standard.closingDuration, 0.09)
        XCTAssertTrue(standard.usesScale)

        let reduced = CommandCenterMotionConfiguration.resolve(reduceMotion: true)
        XCTAssertEqual(reduced.openingDuration, 0.07)
        XCTAssertEqual(reduced.closingDuration, 0.05)
        XCTAssertFalse(reduced.usesScale)
    }

    func testCommandCenterRefreshesAccessibilityMaterialWhenSystemOptionsChange() {
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var preferences = CommandCenterAccessibilityPreferences(
            reduceTransparency: false,
            increaseContrast: false,
            reduceMotion: false
        )
        let controller = CommandCenterWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults,
            accessibilityPreferencesProvider: { preferences }
        )
        let initialConfiguration = controller.materialConfigurationForTesting()
        XCTAssertEqual(
            initialConfiguration?.surfaceAlpha,
            initialConfiguration?.backdrop == .nativeGlass ? 0 : 0.22
        )

        preferences = CommandCenterAccessibilityPreferences(
            reduceTransparency: true,
            increaseContrast: true,
            reduceMotion: true
        )
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )

        XCTAssertEqual(controller.materialConfigurationForTesting()?.surfaceAlpha, 1)
        XCTAssertEqual(controller.materialConfigurationForTesting()?.borderWidth, 1.5)
        XCTAssertEqual(controller.materialConfigurationForTesting()?.selectionAlpha, 0.50)
    }

    func testCommandCenterRapidReopenCancelsPendingAnimatedClose() throws {
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = CommandCenterWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )
        let panel = try XCTUnwrap(controller.window)

        for _ in 0 ..< 4 {
            controller.show(cards: [], on: nil)
            controller.close(animated: true)
            XCTAssertTrue(controller.isClosingForTesting())
            controller.show(cards: [], on: nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))

            XCTAssertFalse(controller.isClosingForTesting())
            XCTAssertTrue(panel.isVisible)
            XCTAssertEqual(panel.alphaValue, 1, accuracy: 0.001)
            XCTAssertEqual(controller.materialOpacityForTesting(), 1, accuracy: 0.01)
            controller.close(animated: false)
        }
    }

    func testCommandCenterEmptyQueryShowsAtMostThreeRecentItems() {
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cards = (0 ..< 7).map { index in
            CardRecord(
                title: "Card \(index)",
                markdown: "",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let controller = CommandCenterWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )
        controller.applySnapshot(cards)
        XCTAssertEqual(controller.recentItemTitlesForTesting(), ["Card 6", "Card 5", "Card 4"])
        controller.recordRecentForTesting(.command(.settings))
        XCTAssertEqual(controller.recentItemTitlesForTesting().first, "Settings")
        XCTAssertEqual(controller.recentItemTitlesForTesting().count, 3)
    }

    func testCommandCenterEmptyQueryAppendsScrollableCardsAndCommands() {
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let older = CardRecord(
            title: "Older",
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = CardRecord(
            title: "Newer",
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let controller = CommandCenterWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )

        controller.applySnapshot([older, newer])

        XCTAssertEqual(
            controller.itemLabelsForTesting(),
            [
                "[Recent]", "Newer", "Older",
                "[Commands]", "New Card", "Card Library", "Fold All Cards", "Settings",
                "Quit Markdown Card",
            ]
        )
        XCTAssertTrue(controller.isResultScrollingEnabledForTesting())
    }

    func testCommandCenterEmptyLibraryHidesEmptyRecentSectionAndDoesNotDuplicateCommands() {
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = CommandCenterWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )

        controller.applySnapshot([])

        XCTAssertEqual(
            controller.itemLabelsForTesting(),
            [
                "[Commands]", "New Card", "Card Library", "Fold All Cards", "Settings",
                "Quit Markdown Card",
            ]
        )
    }

    func testCommandCenterShowsARealRecentCommandOnlyOnce() {
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = CommandCenterWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )

        controller.recordRecentForTesting(.command(.settings))

        let labels = controller.itemLabelsForTesting()
        XCTAssertEqual(Array(labels.prefix(2)), ["[Recent]", "Settings"])
        XCTAssertEqual(labels.filter { $0 == "Settings" }.count, 1)
    }

    func testCommandCenterCardsSectionShowsAtMostThreeCards() {
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cards = (0 ..< 7).map { index in
            CardRecord(
                title: "Limited \(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let controller = CommandCenterWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )
        controller.applySnapshot(cards)

        let labels = controller.itemLabelsForTesting()
        let cardsStart = try! XCTUnwrap(labels.firstIndex(of: "[Cards]")) + 1
        let commandsStart = try! XCTUnwrap(labels.firstIndex(of: "[Commands]"))
        XCTAssertEqual(
            Array(labels[cardsStart ..< commandsStart]),
            ["Limited 3", "Limited 2", "Limited 1"]
        )
        XCTAssertFalse(labels.contains("Limited 0"))
    }

    func testCardLibraryOrdersByCreationTimeWithoutUpdatedAtReordering() {
        let oldCreation = Date(timeIntervalSince1970: 10)
        let newCreation = Date(timeIntervalSince1970: 20)
        let olderButEdited = CardRecord(
            title: "Older but edited",
            createdAt: oldCreation,
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let newer = CardRecord(
            title: "Newer",
            createdAt: newCreation,
            updatedAt: Date(timeIntervalSince1970: 30)
        )

        XCTAssertEqual(
            CardLibraryWindowController.orderedByCreation([olderButEdited, newer]).map(\.id),
            [newer.id, olderButEdited.id]
        )
    }

    func testDocumentCoordinatorProducesMonotonicLastWriteWinsRevisions() {
        let coordinator = CardDocumentCoordinator()
        let card = CardRecord(markdown: "one")
        coordinator.register([card])
        let firstSource = EditorSourceID()
        let secondSource = EditorSourceID()

        let first = coordinator.accept(
            cardID: card.id,
            markdown: "two",
            incomingRevision: 1,
            source: firstSource
        )
        let second = coordinator.accept(
            cardID: card.id,
            markdown: "three",
            incomingRevision: 1,
            source: secondSource
        )

        XCTAssertGreaterThan(second.revision, first.revision)
        XCTAssertEqual(second.source, secondSource)
        XCTAssertEqual(coordinator.revision(for: card.id), second.revision)
    }

    func testResizeAnchorChoosesRightOnlyWhenItIsStrictlyCloser() {
        let visible = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        XCTAssertEqual(
            CardResizeAnchor.nearest(
                to: NSRect(x: 700, y: 400, width: 260, height: 240),
                in: visible
            ),
            .topRight
        )
        XCTAssertEqual(
            CardResizeAnchor.nearest(
                to: NSRect(x: 370, y: 400, width: 260, height: 240),
                in: visible
            ),
            .topLeft
        )
    }

    func testProgrammaticResizeDoesNotTurnStickyIntoCustom() throws {
        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = CardPanelController(
            card: CardRecord(markdown: "# Sticky", layoutMode: .sticky),
            appearanceController: AppearanceController(defaults: defaults)
        )
        let window = try XCTUnwrap(controller.window)
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        XCTAssertEqual(controller.card.layoutMode, .sticky)
    }

    func testCaptureAuxiliaryWindowsForVisualQA() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let commandPath = environment["MARKDOWN_CARD_QA_COMMAND_CENTER_PATH"],
              let libraryPath = environment["MARKDOWN_CARD_QA_LIBRARY_PATH"],
              let settingsPath = environment["MARKDOWN_CARD_QA_SETTINGS_PATH"]
        else { return }

        let suiteName = "MarkdownCardAgentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appearanceController = AppearanceController(defaults: defaults)
        appearanceController.setMode(
            environment["MARKDOWN_CARD_QA_APPEARANCE"]
                .flatMap(AppearanceMode.init(rawValue:)) ?? .dark
        )
        let now = Date()
        let showcase = CardRecord(
            title: "Markdown Syntax Showcase",
            markdown: "# Markdown Syntax Showcase\n\nThis note demonstrates **Markdown** editing.\n\n## Tasks\n\n- [x] Write the documentation\n- [ ] Ship the app\n\n```python\ndef add(a: int, b: int) -> int:\n    return a + b\n```\n\n$$E = mc^2$$",
            isVisible: true,
            updatedAt: now
        )
        let attention = CardRecord(
            title: "Self-Attention",
            markdown: "# Self-Attention\n\nSequence modeling notes.",
            updatedAt: now.addingTimeInterval(-700)
        )
        let sampleTag = try CardTag("sample")
        let meeting = CardRecord(
            title: "Meeting Notes",
            markdown: "# Meeting Notes\n\nDecisions and action items.",
            updatedAt: now.addingTimeInterval(-3_600),
            tags: [sampleTag]
        )
        let cards = [showcase, attention, meeting]

        let command = CommandCenterWindowController(
            appearanceController: appearanceController,
            defaults: defaults
        )
        command.applySnapshot(cards)
        command.recordRecentForTesting(.card(meeting.id))
        command.recordRecentForTesting(.command(.newCard))
        command.recordRecentForTesting(.card(showcase.id))
        command.show(cards: cards, on: NSScreen.main)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        let commandSnapshotView = command.snapshotContentViewForTesting
        let commandSnapshotBackground = commandSnapshotView.layer?.backgroundColor
        let opaqueSnapshotBackground = MonochromePalette.windowBackground(
            for: appearanceController.resolvedAppearance
        )
        commandSnapshotView.layer?.backgroundColor = opaqueSnapshotBackground.cgColor
        defer { commandSnapshotView.layer?.backgroundColor = commandSnapshotBackground }
        try writeSnapshot(
            of: commandSnapshotView,
            to: commandPath,
            requireContentDifferentFrom: opaqueSnapshotBackground
        )

        let library = CardLibraryWindowController(
            appearanceController: appearanceController,
            defaults: defaults
        )
        library.applySnapshot(cards, revisions: Dictionary(uniqueKeysWithValues: cards.map { ($0.id, 0) }))
        library.showLibrary()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        try writeSnapshot(of: try XCTUnwrap(library.window?.contentView), to: libraryPath)

        let settings = SettingsCenterWindowController(
            appearanceController: appearanceController,
            placementPreferences: CardPlacementPreferences(defaults: defaults),
            defaults: defaults
        )
        settings.showSettings()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        try writeSnapshot(of: try XCTUnwrap(settings.window?.contentView), to: settingsPath)
        if let shortcutsPath = environment["MARKDOWN_CARD_QA_SETTINGS_SHORTCUTS_PATH"] {
            settings.showShortcutsForTesting()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            try writeSnapshot(
                of: try XCTUnwrap(settings.window?.contentView),
                to: shortcutsPath
            )
        }
        if let placementPath = environment["MARKDOWN_CARD_QA_SETTINGS_PLACEMENT_PATH"] {
            settings.showPlacementForTesting()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            try writeSnapshot(
                of: try XCTUnwrap(settings.window?.contentView),
                to: placementPath
            )
        }

        command.window?.orderOut(nil)
        library.window?.orderOut(nil)
        settings.window?.orderOut(nil)
    }

    private func writeSnapshot(
        of view: NSView,
        to path: String,
        requireContentDifferentFrom backgroundColor: NSColor? = nil
    ) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            XCTFail("Unable to create snapshot bitmap")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let background = backgroundColor?.usingColorSpace(.sRGB) {
            var differingInteriorPixels = 0
            for y in stride(from: 20, to: max(21, bitmap.pixelsHigh - 20), by: 8) {
                for x in stride(from: 20, to: max(21, bitmap.pixelsWide - 20), by: 8) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                    else { continue }
                    guard color.alphaComponent > 0.9 else { continue }
                    let difference = abs(color.redComponent - background.redComponent)
                        + abs(color.greenComponent - background.greenComponent)
                        + abs(color.blueComponent - background.blueComponent)
                    if difference > 0.08 { differingInteriorPixels += 1 }
                }
            }
            XCTAssertGreaterThan(
                differingInteriorPixels,
                20,
                "Visual QA snapshot has no visible Command Center content"
            )
        }
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }
}
