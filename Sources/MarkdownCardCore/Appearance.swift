import Foundation

public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark

    public static let defaultsKey = "appearanceMode"

    public func resolve(systemIsDark: Bool) -> ResolvedAppearance {
        switch self {
        case .system:
            systemIsDark ? .dark : .light
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

public enum ResolvedAppearance: String, Codable, CaseIterable, Sendable {
    case light
    case dark
}
