import ArgumentParser
import Darwin
import Foundation
import MarkdownCardCore

@main
struct MDCardCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mdcard",
        abstract: "Show and control native Markdown cards.",
        version: "0.1.0",
        subcommands: [
            Create.self,
            Show.self,
            Hide.self,
            Update.self,
            List.self,
            Delete.self,
            Theme.self,
            Quit.self,
        ]
    )
}

private struct Create: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create and show an always-on-top Sticky Note card."
    )

    @Argument(help: "Markdown file, or '-' to read standard input.")
    var file: String?

    @Option(name: .long, help: "Override the title derived from Markdown.")
    var title: String?

    func run() throws {
        let markdown = try InputReader.optionalSnapshot(from: file) ?? ""
        let response = try AgentBridge.send(.create(CreateOptions(markdown: markdown, title: title)))
        try Console.printMutationOrAcknowledgement(response)
    }
}

private struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show an existing card."
    )

    @Argument(help: "Card UUID.")
    var cardID: String

    func run() throws {
        guard let id = UUID(uuidString: cardID) else {
            throw ValidationError("Invalid card UUID: \(cardID)")
        }
        let response = try AgentBridge.send(.show(ShowOptions(cardID: id)))
        try Console.printMutationOrAcknowledgement(response)
    }
}

private struct Hide: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Hide one card or all cards."
    )

    @Argument(help: "Card UUID.")
    var target: String?

    @Flag(name: .long, help: "Hide every card.")
    var all = false

    func validate() throws {
        if all, target != nil {
            throw ValidationError("Use either a target or --all, not both.")
        }
        if !all, target == nil {
            throw ValidationError("Provide a card UUID or use --all.")
        }
    }

    func run() throws {
        let selector = try all ? CardSelector.all : SelectorParser.parseCard(target!)
        let response = try AgentBridge.send(.hide(HideOptions(selector: selector)))
        try Console.printMutationOrAcknowledgement(response)
    }
}

private struct Update: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Replace a card's Markdown with a file or stdin snapshot."
    )

    @Argument(help: "Card UUID.")
    var cardID: String

    @Argument(help: "Markdown file, or '-' to read standard input.")
    var file: String?

    func run() throws {
        guard let id = UUID(uuidString: cardID) else {
            throw ValidationError("Invalid card UUID: \(cardID)")
        }
        let markdown = try InputReader.requiredSnapshot(from: file)
        let response = try AgentBridge.send(
            .update(UpdateOptions(cardID: id, markdown: markdown))
        )
        try Console.printMutationOrAcknowledgement(response)
    }
}

private struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List cards known to the running agent."
    )

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    func run() throws {
        let response = try AgentBridge.send(.list(ListOptions()))
        try Console.requireSuccess(response)
        guard let payload = response.payload else {
            if json { print("{\"cards\":[]}") }
            return
        }

        if json {
            FileHandle.standardOutput.write(try payload.encodedData(prettyPrinted: true))
            FileHandle.standardOutput.write(Data("\n".utf8))
            return
        }

        if let list = try? response.decodedPayload(CardListPayload.self) {
            if list.cards.isEmpty {
                print("No cards.")
                return
            }
            for card in list.cards {
                let flags = [
                    card.isVisible ? "visible" : "hidden",
                    card.layoutMode.rawValue,
                ].compactMap { $0 }.joined(separator: ",")
                print("\(card.id.uuidString)\t[\(flags)]\t\(card.title)")
            }
        } else {
            FileHandle.standardOutput.write(try payload.encodedData(prettyPrinted: true))
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
}

private struct Delete: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete a card from the local library."
    )

    @Argument(help: "Card UUID.")
    var cardID: String

    @Flag(name: .long, help: "Delete a visible card without confirmation.")
    var force = false

    func run() throws {
        guard let id = UUID(uuidString: cardID) else {
            throw ValidationError("Invalid card UUID: \(cardID)")
        }
        let response = try AgentBridge.send(.delete(DeleteOptions(cardID: id, force: force)))
        try Console.printMutationOrAcknowledgement(response)
    }
}

private struct Theme: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read or set the global System, Light, or Dark appearance."
    )

    @Argument(help: "system, light, or dark. Omit to print the current mode.")
    var mode: String?

    func run() throws {
        if let mode {
            guard let appearance = AppearanceMode(rawValue: mode.lowercased()) else {
                throw ValidationError("Theme must be one of: system, light, dark.")
            }
            let response = try AgentBridge.send(.setAppearance(appearance))
            try Console.requireSuccess(response)
            print(appearance.rawValue)
        } else {
            let response = try AgentBridge.send(.list(ListOptions()))
            try Console.requireSuccess(response)
            let payload = try response.decodedPayload(CardListPayload.self)
            print(payload.appearance.rawValue)
        }
    }
}

private struct Quit: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Terminate the Easy Card agent."
    )

    func run() throws {
        let response = try AgentBridge.send(.quit, launchIfNeeded: false)
        try Console.requireSuccess(response)
        print("ok")
    }
}

private enum SelectorParser {
    static func parseCard(_ argument: String) throws -> CardSelector {
        guard let id = UUID(uuidString: argument) else {
            throw ValidationError("Expected a card UUID, got: \(argument)")
        }
        return .card(id)
    }
}

private enum InputReader {
    static func optionalSnapshot(from source: String?) throws -> String? {
        guard let source else { return nil }
        return try snapshot(from: source)
    }

    static func requiredSnapshot(from source: String?) throws -> String {
        if let source { return try snapshot(from: source) }
        guard Darwin.isatty(STDIN_FILENO) == 0 else {
            throw ValidationError("Provide a Markdown file or '-' for standard input.")
        }
        return try readStandardInput()
    }

    private static func snapshot(from source: String) throws -> String {
        if source == "-" { return try readStandardInput() }
        let expanded = NSString(string: source).expandingTildeInPath
        do {
            return try String(contentsOfFile: expanded, encoding: .utf8)
        } catch {
            throw ValidationError("Unable to read \(source) as UTF-8: \(error.localizedDescription)")
        }
    }

    private static func readStandardInput() throws -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            throw ValidationError("Standard input is not valid UTF-8.")
        }
        return text
    }
}

private enum AgentBridge {
    static let bundleIdentifier = "com.garden100.MarkdownCard"

    static func send(_ command: AgentCommand, launchIfNeeded: Bool = true) throws -> AgentResponse {
        let request = AgentRequest(command: command)
        let socketPath = ProcessInfo.processInfo.environment["MDCARD_SOCKET_PATH"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? IPCSocketPath.defaultPath
        let client = UnixDomainSocketClient(path: socketPath, timeout: 0.5)

        do {
            return try client.send(request)
        } catch {
            guard launchIfNeeded, shouldLaunch(after: error) else {
                throw ValidationError(error.localizedDescription)
            }
        }

        try launchAgent()
        let deadline = Date().addingTimeInterval(2)
        var lastError: Error?
        repeat {
            do {
                return try client.send(request)
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.05)
            }
        } while Date() < deadline

        throw ValidationError(
            "Easy Card did not start within 2 seconds: \(lastError?.localizedDescription ?? "unknown error")"
        )
    }

    private static func shouldLaunch(after error: Error) -> Bool {
        guard case let UnixSocketError.systemCall(operation, code) = error,
              operation == "connect" else {
            return false
        }
        return code == ENOENT || code == ECONNREFUSED || code == ETIMEDOUT
    }

    private static func launchAgent() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        if let appPath = ProcessInfo.processInfo.environment["MDCARD_APP_PATH"], !appPath.isEmpty {
            process.arguments = ["-gj", NSString(string: appPath).expandingTildeInPath]
        } else {
            process.arguments = ["-gj", "-b", bundleIdentifier]
        }
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ValidationError("Unable to launch Easy Card: \(error.localizedDescription)")
        }
        guard process.terminationStatus == 0 else {
            throw ValidationError(
                "Unable to locate the Easy Card app (bundle ID \(bundleIdentifier))."
            )
        }
    }
}

private enum Console {
    static func requireSuccess(_ response: AgentResponse) throws {
        guard response.ok else {
            throw ValidationError(response.error?.message ?? "The agent rejected the request.")
        }
    }

    static func printMutationOrAcknowledgement(_ response: AgentResponse) throws {
        try requireSuccess(response)
        if let mutation = try? response.decodedPayload(CardMutationPayload.self) {
            print(mutation.card.id.uuidString)
        } else if let payload = response.payload {
            FileHandle.standardOutput.write(try payload.encodedData(prettyPrinted: true))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print("ok")
        }
    }
}
