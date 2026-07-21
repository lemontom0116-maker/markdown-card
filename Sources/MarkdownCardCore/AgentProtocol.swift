import Foundation

public let markdownCardProtocolVersion = 5

public enum CardSelector: Equatable, Sendable {
    case card(UUID)
    case all
}

extension CardSelector: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case id
    }

    private enum SelectorType: String, Codable {
        case card
        case all
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(SelectorType.self, forKey: .type) {
        case .card:
            self = .card(try container.decode(UUID.self, forKey: .id))
        case .all:
            self = .all
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .card(id):
            try container.encode(SelectorType.card, forKey: .type)
            try container.encode(id, forKey: .id)
        case .all:
            try container.encode(SelectorType.all, forKey: .type)
        }
    }
}

public struct CreateOptions: Codable, Equatable, Sendable {
    public var markdown: String
    public var title: String?
    public var tags: [String]

    public init(markdown: String = "", title: String? = nil, tags: [String] = []) {
        self.markdown = markdown
        self.title = title
        self.tags = tags
    }
}

public struct ShowOptions: Codable, Equatable, Sendable {
    public var cardID: UUID

    public init(cardID: UUID) {
        self.cardID = cardID
    }
}

public struct HideOptions: Codable, Equatable, Sendable {
    public var selector: CardSelector

    public init(selector: CardSelector) {
        self.selector = selector
    }
}

public struct UpdateOptions: Codable, Equatable, Sendable {
    public var cardID: UUID
    public var markdown: String

    public init(cardID: UUID, markdown: String) {
        self.cardID = cardID
        self.markdown = markdown
    }
}

public struct TagOptions: Codable, Equatable, Sendable {
    public var cardID: UUID
    public var name: String

    public init(cardID: UUID, name: String) {
        self.cardID = cardID
        self.name = name
    }
}

public struct ListOptions: Codable, Equatable, Sendable {
    public var includeHidden: Bool

    public init(includeHidden: Bool = true) {
        self.includeHidden = includeHidden
    }
}

public struct DeleteOptions: Codable, Equatable, Sendable {
    public var cardID: UUID
    public var force: Bool

    public init(cardID: UUID, force: Bool = false) {
        self.cardID = cardID
        self.force = force
    }
}

public enum AgentCommand: Equatable, Sendable {
    case create(CreateOptions)
    case show(ShowOptions)
    case hide(HideOptions)
    case update(UpdateOptions)
    case tag(TagOptions)
    case fold
    case unfold
    case list(ListOptions)
    case delete(DeleteOptions)
    case setAppearance(AppearanceMode)
    case quit
}

extension AgentCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case options
        case appearance
    }

    private enum CommandType: String, Codable {
        case create
        case show
        case hide
        case update
        case tag
        case fold
        case unfold
        case list
        case delete
        case setAppearance
        case quit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(CommandType.self, forKey: .type) {
        case .create:
            self = .create(try container.decode(CreateOptions.self, forKey: .options))
        case .show:
            self = .show(try container.decode(ShowOptions.self, forKey: .options))
        case .hide:
            self = .hide(try container.decode(HideOptions.self, forKey: .options))
        case .update:
            self = .update(try container.decode(UpdateOptions.self, forKey: .options))
        case .tag:
            self = .tag(try container.decode(TagOptions.self, forKey: .options))
        case .fold:
            self = .fold
        case .unfold:
            self = .unfold
        case .list:
            self = .list(try container.decode(ListOptions.self, forKey: .options))
        case .delete:
            self = .delete(try container.decode(DeleteOptions.self, forKey: .options))
        case .setAppearance:
            self = .setAppearance(try container.decode(AppearanceMode.self, forKey: .appearance))
        case .quit:
            self = .quit
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .create(options):
            try container.encode(CommandType.create, forKey: .type)
            try container.encode(options, forKey: .options)
        case let .show(options):
            try container.encode(CommandType.show, forKey: .type)
            try container.encode(options, forKey: .options)
        case let .hide(options):
            try container.encode(CommandType.hide, forKey: .type)
            try container.encode(options, forKey: .options)
        case let .update(options):
            try container.encode(CommandType.update, forKey: .type)
            try container.encode(options, forKey: .options)
        case let .tag(options):
            try container.encode(CommandType.tag, forKey: .type)
            try container.encode(options, forKey: .options)
        case .fold:
            try container.encode(CommandType.fold, forKey: .type)
        case .unfold:
            try container.encode(CommandType.unfold, forKey: .type)
        case let .list(options):
            try container.encode(CommandType.list, forKey: .type)
            try container.encode(options, forKey: .options)
        case let .delete(options):
            try container.encode(CommandType.delete, forKey: .type)
            try container.encode(options, forKey: .options)
        case let .setAppearance(appearance):
            try container.encode(CommandType.setAppearance, forKey: .type)
            try container.encode(appearance, forKey: .appearance)
        case .quit:
            try container.encode(CommandType.quit, forKey: .type)
        }
    }
}

public struct AgentRequest: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var requestID: UUID
    public var command: AgentCommand

    public init(
        protocolVersion: Int = markdownCardProtocolVersion,
        requestID: UUID = UUID(),
        command: AgentCommand
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.command = command
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case requestID
        case command
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        requestID = try container.decode(UUID.self, forKey: .requestID)
        do {
            command = try container.decode(AgentCommand.self, forKey: .command)
        } catch {
            throw AgentRequestDecodingError(
                requestID: requestID,
                message: "Invalid or unknown command: \(error.localizedDescription)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(requestID, forKey: .requestID)
        try container.encode(command, forKey: .command)
    }
}

public struct AgentRequestDecodingError: Error, Equatable, Sendable, LocalizedError {
    public var requestID: UUID
    public var message: String

    public init(requestID: UUID, message: String) {
        self.requestID = requestID
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct AgentProtocolError: Codable, Error, Equatable, Sendable, LocalizedError {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

public struct AgentResponse: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var ok: Bool
    public var payload: JSONValue?
    public var error: AgentProtocolError?

    public init(
        requestID: UUID,
        ok: Bool,
        payload: JSONValue? = nil,
        error: AgentProtocolError? = nil
    ) {
        self.requestID = requestID
        self.ok = ok
        self.payload = payload
        self.error = error
    }

    public static func success(requestID: UUID, payload: JSONValue? = nil) -> AgentResponse {
        AgentResponse(requestID: requestID, ok: true, payload: payload)
    }

    public static func success<T: Encodable>(
        requestID: UUID,
        encoding payload: T
    ) throws -> AgentResponse {
        AgentResponse(
            requestID: requestID,
            ok: true,
            payload: try JSONValue(encoding: payload)
        )
    }

    public static func failure(requestID: UUID, code: String, message: String) -> AgentResponse {
        AgentResponse(
            requestID: requestID,
            ok: false,
            error: AgentProtocolError(code: code, message: message)
        )
    }

    public func decodedPayload<T: Decodable>(_ type: T.Type) throws -> T {
        guard let payload else {
            throw AgentProtocolError(code: "missing_payload", message: "The agent response has no payload.")
        }
        return try payload.decode(type)
    }
}
