import Foundation

public enum CardLayoutMode: String, Codable, CaseIterable, Hashable, Sendable {
    case mini
    case sticky
    case middle
    case fullScreen
    case custom
}

public struct CustomCardLayout: Codable, Equatable, Hashable, Sendable {
    public var width: Double
    public var minimumHeight: Double
    public var maximumHeight: Double

    public init(width: Double, minimumHeight: Double, maximumHeight: Double) {
        self.width = width
        self.minimumHeight = minimumHeight
        self.maximumHeight = maximumHeight
    }

    public static let legacyDefault = CustomCardLayout(
        width: 900,
        minimumHeight: 240,
        maximumHeight: 840
    )

    public var isValid: Bool {
        width.isFinite && minimumHeight.isFinite && maximumHeight.isFinite
            && width >= 320 && minimumHeight >= 240 && maximumHeight >= minimumHeight
    }
}

public struct WindowFrame: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
            && width > 0 && height > 0
    }
}

public struct CardRecord: Codable, Identifiable, Hashable, Sendable {
    public static let untitledTitle = "Untitled"
    public static let defaultThemeID = "mono"

    public var id: UUID
    public var title: String
    public var titleOverride: String?
    public var markdown: String
    public var isQuick: Bool
    public var isVisible: Bool
    public var themeID: String
    public var createdAt: Date
    public var updatedAt: Date
    public var windowFrame: WindowFrame?
    public var screenID: String?
    public var layoutMode: CardLayoutMode
    public var customLayout: CustomCardLayout?

    public init(
        id: UUID = UUID(),
        title: String? = nil,
        titleOverride: String? = nil,
        markdown: String = "",
        isQuick: Bool = false,
        isVisible: Bool = false,
        themeID: String = CardRecord.defaultThemeID,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        windowFrame: WindowFrame? = nil,
        screenID: String? = nil,
        layoutMode: CardLayoutMode = .sticky,
        customLayout: CustomCardLayout? = nil
    ) {
        self.id = id
        self.titleOverride = CardRecord.normalizedOverride(titleOverride ?? title)
        self.title = self.titleOverride ?? CardRecord.derivedTitle(from: markdown)
        self.markdown = markdown
        self.isQuick = isQuick
        self.isVisible = isVisible
        self.themeID = themeID
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.windowFrame = windowFrame?.isValid == true ? windowFrame : nil
        self.screenID = screenID
        self.layoutMode = layoutMode
        self.customLayout = customLayout?.isValid == true ? customLayout : nil
    }

    public mutating func updateMarkdown(
        _ markdown: String,
        explicitTitle: String? = nil,
        at date: Date = Date()
    ) {
        self.markdown = markdown
        if let explicitTitle {
            titleOverride = CardRecord.normalizedOverride(explicitTitle)
        }
        title = titleOverride ?? CardRecord.derivedTitle(from: markdown)
        updatedAt = date
    }

    public mutating func touch(at date: Date = Date()) {
        updatedAt = date
    }

    public static func derivedTitle(from markdown: String) -> String {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        if let first = lines.first(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return cleanedTitle(first)
        }

        return untitledTitle
    }

    private static func normalizedOverride(_ title: String?) -> String? {
        guard let title,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return cleanedTitle(title)
    }

    private static func cleanedTitle(_ source: String) -> String {
        var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(
            of: #"^\s*(?:>|[-+*]|\d+[.)])\s+"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"^#{1,6}\s+"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"^\[[ xX]\]\s+"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"!\[([^]]*)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\[([^]]+)\]\([^)]*\)"#,
            with: "$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"[*_~`]"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\s+#+\s*$"#,
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return untitledTitle }
        return String(value.prefix(100))
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case titleOverride
        case markdown
        case isQuick
        case isVisible
        case themeID
        case createdAt
        case updatedAt
        case windowFrame
        case screenID
        case layoutMode
        case customLayout
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        markdown = try container.decode(String.self, forKey: .markdown)
        let storedTitle = try container.decodeIfPresent(String.self, forKey: .title)
            ?? CardRecord.derivedTitle(from: markdown)
        if container.contains(.titleOverride) {
            titleOverride = CardRecord.normalizedOverride(
                try container.decodeIfPresent(String.self, forKey: .titleOverride)
            )
        } else {
            let normalizedStored = CardRecord.cleanedTitle(storedTitle)
            titleOverride = normalizedStored == CardRecord.derivedTitle(from: markdown)
                ? nil
                : normalizedStored
        }
        title = titleOverride ?? CardRecord.derivedTitle(from: markdown)
        isQuick = try container.decode(Bool.self, forKey: .isQuick)
        isVisible = try container.decode(Bool.self, forKey: .isVisible)
        themeID = try container.decodeIfPresent(String.self, forKey: .themeID)
            ?? CardRecord.defaultThemeID
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        let decodedFrame = try container.decodeIfPresent(WindowFrame.self, forKey: .windowFrame)
        windowFrame = decodedFrame?.isValid == true ? decodedFrame : nil
        screenID = try container.decodeIfPresent(String.self, forKey: .screenID)
        if container.contains(.layoutMode) {
            layoutMode = try container.decode(CardLayoutMode.self, forKey: .layoutMode)
            let decodedCustom = try container.decodeIfPresent(CustomCardLayout.self, forKey: .customLayout)
            customLayout = decodedCustom?.isValid == true ? decodedCustom : nil
        } else {
            // Pre-layout records become Custom so their saved width is not
            // unexpectedly replaced by a new preset during migration.
            layoutMode = .custom
            customLayout = CustomCardLayout(
                width: max(320, windowFrame?.width ?? CustomCardLayout.legacyDefault.width),
                minimumHeight: CustomCardLayout.legacyDefault.minimumHeight,
                maximumHeight: CustomCardLayout.legacyDefault.maximumHeight
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(titleOverride, forKey: .titleOverride)
        try container.encode(markdown, forKey: .markdown)
        try container.encode(isQuick, forKey: .isQuick)
        try container.encode(isVisible, forKey: .isVisible)
        try container.encode(themeID, forKey: .themeID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(windowFrame, forKey: .windowFrame)
        try container.encodeIfPresent(screenID, forKey: .screenID)
        try container.encode(layoutMode, forKey: .layoutMode)
        try container.encodeIfPresent(customLayout, forKey: .customLayout)
    }
}

public struct CardSummary: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var isVisible: Bool
    public var layoutMode: CardLayoutMode
    public var updatedAt: Date

    public init(card: CardRecord) {
        id = card.id
        title = card.title
        isVisible = card.isVisible
        layoutMode = card.layoutMode
        updatedAt = card.updatedAt
    }
}

public struct CardListPayload: Codable, Equatable, Sendable {
    public var cards: [CardSummary]
    public var appearance: AppearanceMode

    public init(cards: [CardSummary], appearance: AppearanceMode) {
        self.cards = cards
        self.appearance = appearance
    }
}

public struct CardMutationPayload: Codable, Equatable, Sendable {
    public var card: CardRecord

    public init(card: CardRecord) {
        self.card = card
    }
}

public struct RenderPayload: Codable, Equatable, Sendable {
    public var cardID: UUID
    public var markdown: String
    public var title: String
    public var resolvedAppearance: ResolvedAppearance
    public var revision: UInt64

    public init(
        cardID: UUID,
        markdown: String,
        title: String,
        resolvedAppearance: ResolvedAppearance,
        revision: UInt64
    ) {
        self.cardID = cardID
        self.markdown = markdown
        self.title = title
        self.resolvedAppearance = resolvedAppearance
        self.revision = revision
    }
}
