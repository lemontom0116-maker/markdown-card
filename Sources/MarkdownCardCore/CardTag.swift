import Foundation

public enum CardTagValidationError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case containsLineBreak
    case containsControlCharacter
    case tooLong(actual: Int, maximum: Int)
    case tooManyUTF8Bytes(actual: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .empty:
            "Tag names cannot be empty."
        case .containsLineBreak:
            "Tag names cannot contain line breaks."
        case .containsControlCharacter:
            "Tag names cannot contain control characters."
        case let .tooLong(actual, maximum):
            "Tag names can contain at most \(maximum) characters (received \(actual))."
        case let .tooManyUTF8Bytes(actual, maximum):
            "Tag names can contain at most \(maximum) UTF-8 bytes (received \(actual))."
        }
    }
}

/// App-owned metadata that groups cards without changing their Markdown.
///
/// `name` preserves the first accepted display spelling. `id` is a stable,
/// locale-independent identity that ignores case and full-width/half-width
/// differences while retaining diacritics.
public struct CardTag: Codable, Identifiable, Hashable, Sendable {
    public static let maximumCharacterCount = 64
    public static let maximumUTF8ByteCount = 256

    public let id: String
    public let name: String

    public init(_ name: String) throws {
        let normalizedName = try Self.normalizedDisplayName(name)
        self.name = normalizedName
        id = Self.normalizedID(forDisplayName: normalizedName)
    }

    public init(name: String) throws {
        try self.init(name)
    }

    /// A deterministic FNV-1a hash suitable for assigning a palette entry.
    /// Unlike Swift's `hashValue`, this value is stable between processes.
    public var stableHash: UInt64 {
        id.utf8.reduce(14_695_981_039_346_656_037) { partial, byte in
            (partial ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    public func paletteIndex(paletteCount: Int) -> Int? {
        guard paletteCount > 0 else { return nil }
        return Int(stableHash % UInt64(paletteCount))
    }

    public static func == (lhs: CardTag, rhs: CardTag) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func normalizedDisplayName(_ source: String) throws -> String {
        let source = source.precomposedStringWithCanonicalMapping
        guard source.rangeOfCharacter(from: .newlines) == nil else {
            throw CardTagValidationError.containsLineBreak
        }
        guard source.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0)
        }) else {
            throw CardTagValidationError.containsControlCharacter
        }

        var result = ""
        var hasPendingSpace = false
        for scalar in source.unicodeScalars {
            if CharacterSet.whitespaces.contains(scalar) {
                hasPendingSpace = !result.isEmpty
                continue
            }
            if hasPendingSpace {
                result.append(" ")
                hasPendingSpace = false
            }
            result.unicodeScalars.append(scalar)
        }
        result = result.precomposedStringWithCanonicalMapping

        guard !result.isEmpty else {
            throw CardTagValidationError.empty
        }
        guard result.count <= maximumCharacterCount else {
            throw CardTagValidationError.tooLong(
                actual: result.count,
                maximum: maximumCharacterCount
            )
        }
        guard result.utf8.count <= maximumUTF8ByteCount else {
            throw CardTagValidationError.tooManyUTF8Bytes(
                actual: result.utf8.count,
                maximum: maximumUTF8ByteCount
            )
        }
        return result
    }

    public static func normalizedID(forDisplayName displayName: String) -> String {
        displayName
            .folding(
                options: [.caseInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .precomposedStringWithCanonicalMapping
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
    }

    public init(from decoder: Decoder) throws {
        let decodedName: String
        if let container = try? decoder.singleValueContainer(),
           let legacyName = try? container.decode(String.self) {
            decodedName = legacyName
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            decodedName = try container.decode(String.self, forKey: .name)
        }

        do {
            try self.init(decodedName)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid card tag: \(error.localizedDescription)",
                    underlyingError: error
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
    }
}
