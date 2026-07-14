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
}

final class AgentProtocolTests: XCTestCase {
    func testAllCommandsRoundTrip() throws {
        let id = UUID()
        let commands: [AgentCommand] = [
            .create(CreateOptions(markdown: "# Card", title: "Card")),
            .show(ShowOptions(cardID: id)),
            .hide(HideOptions(selector: .card(id))),
            .update(UpdateOptions(cardID: id, markdown: "new")),
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

    func testUnknownCommandPreservesRequestIDInDecodingError() throws {
        let requestID = UUID()
        let json = """
        {
          "protocolVersion": 3,
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
