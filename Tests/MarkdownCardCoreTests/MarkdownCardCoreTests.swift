import Darwin
import Foundation
import XCTest
@testable import MarkdownCardCore

final class AppearanceTests: XCTestCase {
    func testAppearanceResolution() {
        XCTAssertEqual(AppearanceMode.system.resolve(systemIsDark: true), .dark)
        XCTAssertEqual(AppearanceMode.system.resolve(systemIsDark: false), .light)
        XCTAssertEqual(AppearanceMode.light.resolve(systemIsDark: true), .light)
        XCTAssertEqual(AppearanceMode.dark.resolve(systemIsDark: false), .dark)
    }
}

final class CardRecordTests: XCTestCase {
    func testTitleUsesFirstNonEmptyLineInsteadOfLaterHeading() {
        let markdown = """
        intro line
        ## Secondary
        # **Primary** [Docs](https://example.com) ###
        """
        XCTAssertEqual(CardRecord.derivedTitle(from: markdown), "intro line")
    }

    func testTitleCleansMarkdownAndFallsBackToUntitled() {
        XCTAssertEqual(CardRecord.derivedTitle(from: "\n# **First** [Docs](https://example.com) ###\nbody"), "First Docs")
        XCTAssertEqual(CardRecord.derivedTitle(from: "\n- `first` line\nbody"), "first line")
        XCTAssertEqual(CardRecord.derivedTitle(from: " \n\n"), CardRecord.untitledTitle)
        XCTAssertEqual(CardRecord.untitledTitle, "Untitled")
    }

    func testUpdatingMarkdownUpdatesDerivedTitleAndTimestamp() {
        let start = Date(timeIntervalSince1970: 10)
        let end = Date(timeIntervalSince1970: 20)
        var card = CardRecord(markdown: "# Before", createdAt: start)

        card.updateMarkdown("# After", at: end)

        XCTAssertEqual(card.title, "After")
        XCTAssertEqual(card.updatedAt, end)
        XCTAssertEqual(card.createdAt, start)
    }

    func testUpdatingMarkdownPreservesExplicitTitle() {
        var card = CardRecord(title: "Pinned idea", markdown: "# Generated")
        card.updateMarkdown("# Changed")

        XCTAssertEqual(card.title, "Pinned idea")
        XCTAssertEqual(card.titleOverride, "Pinned idea")
    }

    func testLegacyTitleMigrationDistinguishesDerivedAndExplicitTitles() throws {
        func legacyRoundTrip(_ card: CardRecord) throws -> CardRecord {
            let encoded = try JSONEncoder().encode(card)
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            object.removeValue(forKey: "titleOverride")
            return try JSONDecoder().decode(
                CardRecord.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }

        var derived = try legacyRoundTrip(CardRecord(markdown: "# Before"))
        derived.updateMarkdown("# After")
        XCTAssertNil(derived.titleOverride)
        XCTAssertEqual(derived.title, "After")

        var explicit = try legacyRoundTrip(
            CardRecord(title: "Pinned idea", markdown: "# Before")
        )
        explicit.updateMarkdown("# After")
        XCTAssertEqual(explicit.titleOverride, "Pinned idea")
        XCTAssertEqual(explicit.title, "Pinned idea")
    }

    func testInvalidWindowFrameIsDiscarded() {
        let card = CardRecord(windowFrame: WindowFrame(x: 0, y: 0, width: -1, height: 20))
        XCTAssertNil(card.windowFrame)
    }

    func testNewCardsDefaultToStickyAndLegacyCardsMigrateToCustomWidth() throws {
        let fresh = CardRecord()
        XCTAssertEqual(fresh.layoutMode, .sticky)
        XCTAssertNil(fresh.customLayout)

        let encoded = try JSONEncoder().encode(
            CardRecord(windowFrame: WindowFrame(x: 10, y: 20, width: 760, height: 500))
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "layoutMode")
        object.removeValue(forKey: "customLayout")
        let legacy = try JSONDecoder().decode(
            CardRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(legacy.layoutMode, .custom)
        XCTAssertEqual(legacy.customLayout?.width, 760)
        XCTAssertEqual(legacy.customLayout?.minimumHeight, 240)
        XCTAssertEqual(legacy.customLayout?.maximumHeight, 840)
    }

    func testLegacyFullScreenDecodingNormalizesToMiddleAndDropsPlacementState() throws {
        let createdAt = Date(timeIntervalSince1970: 100)
        let updatedAt = Date(timeIntervalSince1970: 200)
        let original = CardRecord(
            title: "Pinned Legacy Title",
            markdown: "# Legacy Full Screen\n\nPreserve the body.",
            isQuick: true,
            isVisible: true,
            themeID: "paper",
            createdAt: createdAt,
            updatedAt: updatedAt,
            windowFrame: WindowFrame(x: 10, y: 20, width: 900, height: 640),
            screenID: "Legacy Display",
            layoutMode: .custom,
            customLayout: CustomCardLayout(width: 900, minimumHeight: 300, maximumHeight: 700),
            tags: [try CardTag("Research"), try CardTag("Reading")]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        object["layoutMode"] = "fullScreen"

        let decoded = try JSONDecoder().decode(
            CardRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.titleOverride, original.titleOverride)
        XCTAssertEqual(decoded.markdown, original.markdown)
        XCTAssertEqual(decoded.isQuick, original.isQuick)
        XCTAssertEqual(decoded.isVisible, original.isVisible)
        XCTAssertEqual(decoded.themeID, original.themeID)
        XCTAssertEqual(decoded.createdAt, createdAt)
        XCTAssertEqual(decoded.updatedAt, updatedAt)
        XCTAssertEqual(decoded.tags, original.tags)
        XCTAssertEqual(decoded.layoutMode, .middle)
        XCTAssertNil(decoded.windowFrame)
        XCTAssertNil(decoded.screenID)
        XCTAssertNil(decoded.customLayout)
    }

    func testCardLayoutModeDirectDecodeAcceptsOnlyLegacyFullScreenOrCurrentValues() throws {
        XCTAssertEqual(
            try JSONDecoder().decode(CardLayoutMode.self, from: Data(#""fullScreen""#.utf8)),
            .middle
        )
        XCTAssertEqual(
            try JSONDecoder().decode(CardLayoutMode.self, from: Data(#""middle""#.utf8)),
            .middle
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(CardLayoutMode.self, from: Data(#""futureLayout""#.utf8))
        ) { error in
            guard case DecodingError.dataCorrupted = error else {
                return XCTFail("Expected dataCorrupted, got \(error)")
            }
        }
        XCTAssertEqual(CardLayoutMode.allCases, [.mini, .sticky, .middle, .custom])
        XCTAssertNil(CardLayoutMode(rawValue: "fullScreen"))
    }

    func testTagsPreserveOrderDeduplicateByIdentityAndUpdateTimestamp() throws {
        let original = Date(timeIntervalSince1970: 10)
        let taggedAt = Date(timeIntervalSince1970: 20)
        let research = try CardTag("Research")
        let duplicate = try CardTag("ＲＥＳＥＡＲＣＨ")
        let reading = try CardTag("Reading")
        var card = CardRecord(
            markdown: "# Notes",
            createdAt: original,
            tags: [research, duplicate, reading]
        )

        XCTAssertEqual(card.tags.map(\.name), ["Research", "Reading"])
        XCTAssertFalse(card.addTag(duplicate, at: taggedAt))
        XCTAssertEqual(card.updatedAt, original)

        let transformers = try CardTag("Transformers")
        XCTAssertTrue(card.addTag(transformers, at: taggedAt))
        XCTAssertEqual(card.tags.map(\.name), ["Research", "Reading", "Transformers"])
        XCTAssertEqual(card.updatedAt, taggedAt)

        let removedAt = Date(timeIntervalSince1970: 30)
        XCTAssertTrue(card.removeTag(id: research.id, at: removedAt))
        XCTAssertEqual(card.tags.map(\.name), ["Reading", "Transformers"])
        XCTAssertEqual(card.updatedAt, removedAt)
        XCTAssertFalse(card.removeTag(id: research.id, at: Date(timeIntervalSince1970: 40)))
        XCTAssertEqual(card.updatedAt, removedAt)
    }

    func testLegacyRecordWithoutTagsDecodesWithEmptyTags() throws {
        let encoded = try JSONEncoder().encode(CardRecord(markdown: "# Legacy"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "tags")

        let decoded = try JSONDecoder().decode(
            CardRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertTrue(decoded.tags.isEmpty)
    }
}

final class CardTagTests: XCTestCase {
    func testNormalizesDisplayWhitespaceAndStableIdentity() throws {
        let fullWidth = try CardTag("  Ｒｅｓｅａｒｃｈ\u{3000} Notes  ")
        let plain = try CardTag("research notes")
        let decomposed = try CardTag("Cafe\u{301}")

        XCTAssertEqual(fullWidth.name, "Ｒｅｓｅａｒｃｈ Notes")
        XCTAssertEqual(fullWidth.id, plain.id)
        XCTAssertEqual(fullWidth, plain)
        XCTAssertEqual(fullWidth.stableHash, plain.stableHash)
        XCTAssertEqual(fullWidth.paletteIndex(paletteCount: 6), plain.paletteIndex(paletteCount: 6))
        XCTAssertNil(fullWidth.paletteIndex(paletteCount: 0))
        XCTAssertEqual(decomposed.name, "Café")
        XCTAssertNotEqual(decomposed.id, try CardTag("Cafe").id)
    }

    func testRejectsEmptyLineBreakControlAndLengthLimits() throws {
        XCTAssertThrowsError(try CardTag("   ")) { error in
            XCTAssertEqual(error as? CardTagValidationError, .empty)
        }
        XCTAssertThrowsError(try CardTag("one\ntwo")) { error in
            XCTAssertEqual(error as? CardTagValidationError, .containsLineBreak)
        }
        XCTAssertThrowsError(try CardTag("one\ttwo")) { error in
            XCTAssertEqual(error as? CardTagValidationError, .containsControlCharacter)
        }
        XCTAssertThrowsError(try CardTag(String(repeating: "a", count: 65))) { error in
            XCTAssertEqual(
                error as? CardTagValidationError,
                .tooLong(actual: 65, maximum: CardTag.maximumCharacterCount)
            )
        }

        let byteHeavy = String(repeating: "a\u{301}\u{301}\u{301}", count: 64)
        XCTAssertThrowsError(try CardTag(byteHeavy)) { error in
            guard case let .tooManyUTF8Bytes(actual, maximum) = error as? CardTagValidationError else {
                return XCTFail("Expected the UTF-8 byte limit, got \(error)")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, CardTag.maximumUTF8ByteCount)
        }
    }

    func testDecodingRecomputesIdentityInsteadOfTrustingStoredID() throws {
        let data = Data(#"{"id":"tampered","name":"Ｒｅａｄｉｎｇ"}"#.utf8)
        let decoded = try JSONDecoder().decode(CardTag.self, from: data)

        XCTAssertEqual(decoded.id, try CardTag("reading").id)
    }
}

final class CardSeriesIndexTests: XCTestCase {
    func testSeriesUsesCreationTimeThenUUIDAndProvidesDirectionalNeighbors() throws {
        let tag = try CardTag("Research")
        let otherTag = try CardTag("Reading")
        let lowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let highID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let newestID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003"))
        let unrelatedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000004"))
        let cards = [
            CardRecord(
                id: highID,
                markdown: "High",
                createdAt: Date(timeIntervalSince1970: 10),
                tags: [tag]
            ),
            CardRecord(
                id: unrelatedID,
                markdown: "Other",
                createdAt: Date(timeIntervalSince1970: 40),
                tags: [otherTag]
            ),
            CardRecord(
                id: newestID,
                markdown: "Newest",
                createdAt: Date(timeIntervalSince1970: 20),
                tags: [tag, otherTag]
            ),
            CardRecord(
                id: lowID,
                markdown: "Low",
                createdAt: Date(timeIntervalSince1970: 10),
                tags: [tag]
            ),
        ]

        let index = CardSeriesIndex(cards: cards)

        XCTAssertEqual(index.cardIDs(tagID: tag.id), [newestID, lowID, highID])
        XCTAssertEqual(index.series(for: otherTag).map(\.id), [unrelatedID, newestID])
        XCTAssertEqual(
            index.neighbors(of: lowID, tagID: tag.id),
            CardSeriesNeighbors(
                index: 1,
                count: 3,
                newerCardID: newestID,
                olderCardID: highID
            )
        )
        XCTAssertNil(index.neighbors(of: newestID, tagID: tag.id)?.newerCardID)
        XCTAssertNil(index.neighbors(of: highID, tagID: tag.id)?.olderCardID)
        XCTAssertNil(index.neighbors(of: unrelatedID, tagID: tag.id))
    }

    func testSeriesAppliesExplicitOrderAndAppendsNewCardsStably() throws {
        let tag = try CardTag("Course")
        let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000011"))
        let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000012"))
        let unlistedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000013"))
        let cards = [
            CardRecord(id: firstID, markdown: "First", createdAt: .init(timeIntervalSince1970: 10), tags: [tag]),
            CardRecord(id: secondID, markdown: "Second", createdAt: .init(timeIntervalSince1970: 20), tags: [tag]),
            CardRecord(id: unlistedID, markdown: "New", createdAt: .init(timeIntervalSince1970: 30), tags: [tag]),
        ]

        let index = CardSeriesIndex(
            cards: cards,
            preferredOrderByTagID: [tag.id: [firstID, secondID]]
        )

        XCTAssertEqual(index.cardIDs(tagID: tag.id), [firstID, secondID, unlistedID])
        XCTAssertEqual(index.neighbors(of: secondID, tagID: tag.id)?.newerCardID, firstID)
        XCTAssertEqual(index.neighbors(of: secondID, tagID: tag.id)?.olderCardID, unlistedID)
    }
}

final class AgentProtocolTests: XCTestCase {
    func testProtocolVersionIsFive() {
        XCTAssertEqual(markdownCardProtocolVersion, 5)
    }

    func testAllCommandsRoundTrip() throws {
        let id = UUID()
        let commands: [AgentCommand] = [
            .create(CreateOptions(
                markdown: "# Card",
                title: "Card",
                tags: ["Research", "CS 336"]
            )),
            .show(ShowOptions(cardID: id)),
            .hide(HideOptions(selector: .card(id))),
            .update(UpdateOptions(cardID: id, markdown: "new")),
            .tag(TagOptions(cardID: id, name: "Research")),
            .fold,
            .unfold,
            .list(ListOptions(includeHidden: false)),
            .delete(DeleteOptions(cardID: id, force: true)),
            .setAppearance(.dark),
            .quit,
        ]

        for command in commands {
            let request = AgentRequest(requestID: id, command: command)
            let data = try JSONEncoder().encode(request)
            let decoded = try JSONDecoder().decode(AgentRequest.self, from: data)
            XCTAssertEqual(decoded, request)
        }
    }

    func testTypedResponsePayloadRoundTrip() throws {
        let requestID = UUID()
        let card = CardRecord(id: UUID(), markdown: "# Hello")
        let response = try AgentResponse.success(
            requestID: requestID,
            encoding: CardMutationPayload(card: card)
        )
        let wire = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(AgentResponse.self, from: wire)

        XCTAssertEqual(try decoded.decodedPayload(CardMutationPayload.self).card, card)
    }

    func testCommandWireHasStableTypeDiscriminator() throws {
        let data = try JSONEncoder().encode(AgentCommand.setAppearance(.light))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(object?["type"], "setAppearance")
        XCTAssertEqual(object?["appearance"], "light")
    }

    func testTagCommandWireHasStableTypeDiscriminator() throws {
        let id = UUID()
        let data = try JSONEncoder().encode(
            AgentCommand.tag(TagOptions(cardID: id, name: "Research"))
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let options = try XCTUnwrap(object["options"] as? [String: String])

        XCTAssertEqual(object["type"] as? String, "tag")
        XCTAssertEqual(options["cardID"], id.uuidString)
        XCTAssertEqual(options["name"], "Research")
    }

    func testFoldCommandsHaveStableTypeDiscriminators() throws {
        let encoder = JSONEncoder()
        let fold = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(AgentCommand.fold))
                as? [String: String]
        )
        let unfold = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(AgentCommand.unfold))
                as? [String: String]
        )

        XCTAssertEqual(fold, ["type": "fold"])
        XCTAssertEqual(unfold, ["type": "unfold"])
    }

    func testCardListPayloadExposesFoldStateWithoutChangingCardVisibility() throws {
        let card = CardRecord(markdown: "# Visible", isVisible: true)
        let payload = CardListPayload(
            cards: [CardSummary(card: card)],
            appearance: .system,
            isFolded: true
        )
        let data = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let cards = try XCTUnwrap(object["cards"] as? [[String: Any]])

        XCTAssertEqual(object["isFolded"] as? Bool, true)
        XCTAssertEqual(cards.first?["isVisible"] as? Bool, true)
        XCTAssertFalse(
            CardListPayload(cards: [], appearance: .system).isFolded
        )

        var legacyObject = object
        legacyObject.removeValue(forKey: "isFolded")
        let decodedLegacy = try JSONDecoder().decode(
            CardListPayload.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        XCTAssertFalse(decodedLegacy.isFolded)
    }

    func testCardSummaryIncludesNormalizedTagDisplayNames() throws {
        let card = CardRecord(
            markdown: "# Card",
            tags: [
                try CardTag("  Research   Notes  "),
                try CardTag("Reading"),
            ]
        )

        XCTAssertEqual(CardSummary(card: card).tags, ["Research Notes", "Reading"])
    }

    func testUnknownCommandPreservesRequestIDInDecodingError() throws {
        let requestID = UUID()
        let json = """
        {
          "protocolVersion": 5,
          "requestID": "\(requestID.uuidString)",
          "command": { "type": "future-command" }
        }
        """

        XCTAssertThrowsError(try JSONDecoder().decode(AgentRequest.self, from: Data(json.utf8))) { error in
            XCTAssertEqual((error as? AgentRequestDecodingError)?.requestID, requestID)
        }
    }
}

final class IPCFrameTests: XCTestCase {
    func testDecoderHandlesPartialAndMultipleFrames() throws {
        let first = try IPCFrameCodec.frame(payload: Data("one".utf8))
        let second = try IPCFrameCodec.frame(payload: Data("two".utf8))
        let joined = first + second
        var decoder = IPCFrameDecoder()

        XCTAssertTrue(try decoder.append(joined.prefix(2)).isEmpty)
        XCTAssertTrue(try decoder.append(joined.dropFirst(2).prefix(4)).isEmpty)
        let frames = try decoder.append(joined.dropFirst(6))

        XCTAssertEqual(frames, [Data("one".utf8), Data("two".utf8)])
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testFourMiBIsAcceptedAndLargerPayloadIsRejected() throws {
        let maximum = IPCFrameCodec.maximumPayloadSize
        XCTAssertNoThrow(try IPCFrameCodec.frame(payload: Data(count: maximum)))
        XCTAssertThrowsError(try IPCFrameCodec.frame(payload: Data(count: maximum + 1))) { error in
            XCTAssertEqual(
                error as? IPCFrameError,
                .payloadTooLarge(actual: maximum + 1, maximum: maximum)
            )
        }
    }
}

final class JSONCardRepositoryTests: XCTestCase {
    func testSchemaThreeRoundTripsTagsAndLegacySchemaTwoDefaultsToEmptyTags() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownCardJSONTagTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("cards.json")
        let id = UUID()
        let legacyCard = CardRecord(id: id, markdown: "# Legacy")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(legacyCard)) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "tags")
        let legacyEnvelope: [String: Any] = [
            "schemaVersion": 2,
            "cards": [legacyObject],
        ]
        try JSONSerialization.data(withJSONObject: legacyEnvelope).write(to: url, options: .atomic)

        let repository = JSONCardRepository(fileURL: url)
        let loadedLegacy = try await repository.card(id: id)
        var restored = try XCTUnwrap(loadedLegacy)
        XCTAssertTrue(restored.tags.isEmpty)

        restored.tags = [try CardTag("Research"), try CardTag("Reading")]
        _ = try await repository.upsert(restored)
        let persistedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(persistedObject["schemaVersion"] as? Int, 3)

        let reloaded = JSONCardRepository(fileURL: url)
        let reloadedTags = try await reloaded.card(id: id)?.tags.map(\.name)
        XCTAssertEqual(reloadedTags, ["Research", "Reading"])
    }

    func testLegacyQuickCardsArePurgedTogether() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownCardTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cards.json")
        let repository = JSONCardRepository(fileURL: url)

        let older = CardRecord(id: UUID(), markdown: "# Older", isQuick: true)
        let newer = CardRecord(id: UUID(), markdown: "# Newer", isQuick: true)
        try await repository.replaceAll(with: [older, newer])

        let reloaded = JSONCardRepository(fileURL: url)
        let deletedCount = try await reloaded.deleteLegacyQuickCards()
        let remainingCards = try await reloaded.allCards()
        XCTAssertEqual(deletedCount, 2)
        XCTAssertTrue(remainingCards.isEmpty)

        var info = stat()
        XCTAssertEqual(Darwin.lstat(url.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testCorruptPrimaryFallsBackToLastBackup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownCardTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cards.json")
        let repository = JSONCardRepository(fileURL: url)
        let first = CardRecord(markdown: "# First")
        let second = CardRecord(markdown: "# Second")
        _ = try await repository.upsert(first)
        _ = try await repository.upsert(second)
        try Data("not-json".utf8).write(to: url, options: .atomic)

        let recovered = JSONCardRepository(fileURL: url)
        let cards = try await recovered.allCards()

        XCTAssertEqual(cards.map(\.id), [first.id])
    }

    func testLegacyFullScreenEnvelopeIsPersistedAtomicallyBeforeItIsReturned() async throws {
        try await assertLegacyFullScreenMigration(wrappedInEnvelope: true)
    }

    func testLegacyFullScreenArrayIsPersistedAtomicallyBeforeItIsReturned() async throws {
        try await assertLegacyFullScreenMigration(wrappedInEnvelope: false)
    }

    private func assertLegacyFullScreenMigration(wrappedInEnvelope: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MarkdownCardLegacyFullScreenJSON-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("cards.json")
        let createdAt = Date(timeIntervalSince1970: 100)
        let updatedAt = Date(timeIntervalSince1970: 200)
        let original = CardRecord(
            title: "Pinned Legacy Title",
            markdown: "# Legacy Full Screen\n\nPreserve the body.",
            isQuick: true,
            isVisible: true,
            themeID: "paper",
            createdAt: createdAt,
            updatedAt: updatedAt,
            windowFrame: WindowFrame(x: 10, y: 20, width: 900, height: 640),
            screenID: "Legacy Display",
            layoutMode: .custom,
            customLayout: CustomCardLayout(width: 900, minimumHeight: 300, maximumHeight: 700),
            tags: [try CardTag("Research"), try CardTag("Reading")]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any]
        )
        legacyObject["layoutMode"] = "fullScreen"
        let storeObject: Any = wrappedInEnvelope
            ? ["schemaVersion": JSONCardRepository.currentSchemaVersion, "cards": [legacyObject]]
            : [legacyObject]
        let legacyData = try JSONSerialization.data(withJSONObject: storeObject)
        try legacyData.write(to: url, options: .atomic)

        let repository = JSONCardRepository(fileURL: url)
        let loadedMigrated = try await repository.card(id: original.id)
        let migrated = try XCTUnwrap(loadedMigrated)

        XCTAssertEqual(migrated.title, original.title)
        XCTAssertEqual(migrated.titleOverride, original.titleOverride)
        XCTAssertEqual(migrated.markdown, original.markdown)
        XCTAssertEqual(migrated.isQuick, original.isQuick)
        XCTAssertEqual(migrated.isVisible, original.isVisible)
        XCTAssertEqual(migrated.themeID, original.themeID)
        XCTAssertEqual(migrated.createdAt, createdAt)
        XCTAssertEqual(migrated.updatedAt, updatedAt)
        XCTAssertEqual(migrated.tags, original.tags)
        XCTAssertEqual(migrated.layoutMode, .middle)
        XCTAssertNil(migrated.windowFrame)
        XCTAssertNil(migrated.screenID)
        XCTAssertNil(migrated.customLayout)

        let persistedData = try Data(contentsOf: url)
        let persistedEnvelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: persistedData) as? [String: Any]
        )
        XCTAssertEqual(
            persistedEnvelope["schemaVersion"] as? Int,
            JSONCardRepository.currentSchemaVersion
        )
        let persistedCards = try XCTUnwrap(persistedEnvelope["cards"] as? [[String: Any]])
        let persisted = try XCTUnwrap(persistedCards.first)
        XCTAssertEqual(persisted["layoutMode"] as? String, CardLayoutMode.middle.rawValue)
        XCTAssertNil(persisted["windowFrame"])
        XCTAssertNil(persisted["screenID"])
        XCTAssertNil(persisted["customLayout"])
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("backup")), legacyData)

        let reloaded = JSONCardRepository(fileURL: url)
        let loadedReloadedCard = try await reloaded.card(id: original.id)
        let reloadedCard = try XCTUnwrap(loadedReloadedCard)
        XCTAssertEqual(reloadedCard, migrated)
        XCTAssertEqual(try Data(contentsOf: url), persistedData)
    }
}

final class UnixDomainSocketTests: XCTestCase {
    func testClientAndServerExchangeFramedProtocol() async throws {
        let path = "/tmp/mdcard-tests-\(UUID().uuidString).sock"
        let server = UnixDomainSocketServer(path: path)
        try server.start()
        defer { server.stop() }
        let expectedRequest = AgentRequest(command: .setAppearance(.dark))

        let serverTask = Task.detached { () throws -> AgentRequest in
            let connection = try server.accept()
            defer { connection.close() }
            let request = try connection.receiveRequest()
            try connection.sendResponse(
                .success(requestID: request.requestID, payload: .string("accepted"))
            )
            return request
        }

        let response = try UnixDomainSocketClient(path: path).send(expectedRequest)
        let receivedRequest = try await serverTask.value

        XCTAssertEqual(receivedRequest, expectedRequest)
        XCTAssertEqual(response.payload, .string("accepted"))
        XCTAssertEqual(response.requestID, expectedRequest.requestID)
    }

    func testStartingSecondServerDoesNotReplaceActiveSocket() throws {
        let path = "/tmp/mdcard-active-socket-tests-\(UUID().uuidString).sock"
        let firstServer = UnixDomainSocketServer(path: path)
        try firstServer.start()
        defer { firstServer.stop() }

        var originalInfo = stat()
        XCTAssertEqual(Darwin.lstat(path, &originalInfo), 0)

        let secondServer = UnixDomainSocketServer(path: path)
        XCTAssertThrowsError(try secondServer.start()) { error in
            XCTAssertEqual(error as? UnixSocketError, .socketAlreadyActive(path))
        }
        secondServer.stop()

        var currentInfo = stat()
        XCTAssertEqual(Darwin.lstat(path, &currentInfo), 0)
        XCTAssertEqual(currentInfo.st_dev, originalInfo.st_dev)
        XCTAssertEqual(currentInfo.st_ino, originalInfo.st_ino)
    }

    func testStoppingServerDoesNotRemoveReplacementSocket() throws {
        let path = "/tmp/mdcard-replaced-socket-tests-\(UUID().uuidString).sock"
        let originalServer = UnixDomainSocketServer(path: path)
        try originalServer.start()
        defer { originalServer.stop() }

        // A Unix socket can remain open after its pathname is removed. Rebinding the
        // pathname simulates another process taking ownership before the old server stops.
        XCTAssertEqual(Darwin.unlink(path), 0)
        let replacementServer = UnixDomainSocketServer(path: path)
        try replacementServer.start()
        defer { replacementServer.stop() }

        var replacementInfo = stat()
        XCTAssertEqual(Darwin.lstat(path, &replacementInfo), 0)

        originalServer.stop()

        var currentInfo = stat()
        XCTAssertEqual(Darwin.lstat(path, &currentInfo), 0)
        XCTAssertEqual(currentInfo.st_dev, replacementInfo.st_dev)
        XCTAssertEqual(currentInfo.st_ino, replacementInfo.st_ino)
    }
}

final class MDCardCLIIntegrationTests: XCTestCase {
    func testFoldAndUnfoldCommandsSendDedicatedRequests() async throws {
        for (subcommand, expectedCommand) in [
            ("fold", AgentCommand.fold),
            ("unfold", AgentCommand.unfold),
        ] {
            let exchange = try await runCLI(arguments: [subcommand])

            XCTAssertEqual(exchange.status, 0, exchange.stderr)
            XCTAssertEqual(exchange.stdout, "ok\n")
            XCTAssertEqual(exchange.request.command, expectedCommand)
            XCTAssertEqual(exchange.request.protocolVersion, 5)
        }
    }

    func testTextListReportsGlobalFoldWithoutMarkingVisibleCardsHidden() async throws {
        let cardID = UUID()
        let card = CardRecord(
            id: cardID,
            markdown: "# Visible",
            isVisible: true
        )
        let payload = CardListPayload(
            cards: [CardSummary(card: card)],
            appearance: .system,
            isFolded: true
        )

        let exchange = try await runCLI(arguments: ["list"], payload: payload)

        XCTAssertEqual(exchange.status, 0, exchange.stderr)
        XCTAssertEqual(
            exchange.stdout,
            "Cards are folded.\n\(cardID.uuidString)\t[visible,sticky]\tVisible\n"
        )
        XCTAssertEqual(exchange.request.command, .list(ListOptions()))
    }

    func testThemeCommandSendsSetAppearanceRequest() async throws {
        let executable = try mdcardExecutableURL()
        let path = "/tmp/mdcard-cli-tests-\(UUID().uuidString).sock"
        let server = UnixDomainSocketServer(path: path)
        try server.start()
        defer { server.stop() }

        let serverTask = Task.detached { () throws -> AgentRequest in
            let connection = try server.accept()
            defer { connection.close() }
            let request = try connection.receiveRequest()
            try connection.sendResponse(.success(requestID: request.requestID))
            return request
        }

        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["theme", "dark"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "MDCARD_SOCKET_PATH": path,
        ]) { _, testValue in testValue }
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        let request = try await serverTask.value
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        XCTAssertEqual(stdout, "dark\n")
        XCTAssertEqual(request.command, .setAppearance(.dark))
    }

    private struct CLIExchange {
        var request: AgentRequest
        var stdout: String
        var stderr: String
        var status: Int32
    }

    private func runCLI(
        arguments: [String],
        payload: CardListPayload? = nil
    ) async throws -> CLIExchange {
        let executable = try mdcardExecutableURL()
        let path = "/tmp/mdcard-cli-tests-\(UUID().uuidString).sock"
        let server = UnixDomainSocketServer(path: path)
        try server.start()
        defer { server.stop() }

        let serverTask = Task.detached { () throws -> AgentRequest in
            let connection = try server.accept()
            defer { connection.close() }
            let request = try connection.receiveRequest()
            if let payload {
                try connection.sendResponse(
                    try .success(requestID: request.requestID, encoding: payload)
                )
            } else {
                try connection.sendResponse(.success(requestID: request.requestID))
            }
            return request
        }

        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "MDCARD_SOCKET_PATH": path,
        ]) { _, testValue in testValue }
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()

        return try await CLIExchange(
            request: serverTask.value,
            stdout: String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            stderr: String(
                decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            status: process.terminationStatus
        )
    }

    private func mdcardExecutableURL() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            root.appendingPathComponent(".build/debug/mdcard"),
            root.appendingPathComponent(".build/arm64-apple-macosx/debug/mdcard"),
            root.appendingPathComponent(".build/x86_64-apple-macosx/debug/mdcard"),
        ]
        if let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            return executable
        }
        throw XCTSkip("mdcard executable is not available in the SwiftPM build directory")
    }
}
