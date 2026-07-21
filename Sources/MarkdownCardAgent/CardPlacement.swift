import AppKit
import MarkdownCardCore

enum CardPlacementAnchor: String, CaseIterable {
    case topLeft
    case topCenter
    case topRight
    case centerLeft
    case center
    case centerRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    var displayName: String {
        switch self {
        case .topLeft: "Top Left"
        case .topCenter: "Top Center"
        case .topRight: "Top Right"
        case .centerLeft: "Center Left"
        case .center: "Center"
        case .centerRight: "Center Right"
        case .bottomLeft: "Bottom Left"
        case .bottomCenter: "Bottom Center"
        case .bottomRight: "Bottom Right"
        }
    }
}

enum CardPlacementGeometry {
    static let edgeInset: CGFloat = 16
    static let cardSpacing: CGFloat = 8

    static func frame(
        for currentFrame: NSRect,
        anchor: CardPlacementAnchor,
        visibleFrame: NSRect
    ) -> NSRect {
        let insetX = effectiveInset(
            availableLength: visibleFrame.width,
            frameLength: currentFrame.width
        )
        let insetY = effectiveInset(
            availableLength: visibleFrame.height,
            frameLength: currentFrame.height
        )

        let proposedX: CGFloat
        switch anchor {
        case .topLeft, .centerLeft, .bottomLeft:
            proposedX = visibleFrame.minX + insetX
        case .topCenter, .center, .bottomCenter:
            proposedX = visibleFrame.midX - currentFrame.width / 2
        case .topRight, .centerRight, .bottomRight:
            proposedX = visibleFrame.maxX - insetX - currentFrame.width
        }

        let proposedY: CGFloat
        switch anchor {
        case .topLeft, .topCenter, .topRight:
            proposedY = visibleFrame.maxY - insetY - currentFrame.height
        case .centerLeft, .center, .centerRight:
            proposedY = visibleFrame.midY - currentFrame.height / 2
        case .bottomLeft, .bottomCenter, .bottomRight:
            proposedY = visibleFrame.minY + insetY
        }

        return NSRect(
            origin: NSPoint(
                x: constrainedOrigin(
                    proposedX,
                    visibleMinimum: visibleFrame.minX,
                    visibleMaximum: visibleFrame.maxX,
                    frameLength: currentFrame.width
                ),
                y: constrainedOrigin(
                    proposedY,
                    visibleMinimum: visibleFrame.minY,
                    visibleMaximum: visibleFrame.maxY,
                    frameLength: currentFrame.height
                )
            ),
            size: currentFrame.size
        )
    }

    static func availableFrame(
        for currentFrame: NSRect,
        anchor: CardPlacementAnchor,
        visibleFrame: NSRect,
        avoiding occupiedFrames: [NSRect]
    ) -> NSRect? {
        let preferredFrame = frame(
            for: currentFrame,
            anchor: anchor,
            visibleFrame: visibleFrame
        )
        let insetX = effectiveInset(
            availableLength: visibleFrame.width,
            frameLength: currentFrame.width
        )
        let insetY = effectiveInset(
            availableLength: visibleFrame.height,
            frameLength: currentFrame.height
        )
        let leadingX = visibleFrame.minX + insetX
        let trailingX = visibleFrame.maxX - insetX - currentFrame.width
        let minimumX = min(leadingX, trailingX)
        let maximumX = max(leadingX, trailingX)
        let bottomY = visibleFrame.minY + insetY
        let topY = visibleFrame.maxY - insetY - currentFrame.height
        let minimumY = min(bottomY, topY)
        let maximumY = max(bottomY, topY)

        var candidateXs = [preferredFrame.minX]
        var candidateYs = [preferredFrame.minY]
        for occupiedFrame in occupiedFrames {
            appendUnique(
                occupiedFrame.minX - cardSpacing - currentFrame.width,
                to: &candidateXs
            )
            appendUnique(occupiedFrame.maxX + cardSpacing, to: &candidateXs)
            appendUnique(
                occupiedFrame.minY - cardSpacing - currentFrame.height,
                to: &candidateYs
            )
            appendUnique(occupiedFrame.maxY + cardSpacing, to: &candidateYs)
        }
        appendUnique(minimumX, to: &candidateXs)
        appendUnique(maximumX, to: &candidateXs)
        appendUnique(minimumY, to: &candidateYs)
        appendUnique(maximumY, to: &candidateYs)

        var bestCandidate: (frame: NSRect, rank: CandidateRank, order: Int)?
        var order = 0
        for x in candidateXs {
            for y in candidateYs {
                defer { order += 1 }
                guard x >= minimumX, x <= maximumX,
                      y >= minimumY, y <= maximumY
                else { continue }

                let candidate = NSRect(
                    origin: NSPoint(x: x, y: y),
                    size: currentFrame.size
                )
                guard occupiedFrames.allSatisfy({
                    hasRequiredSpacing(candidate, from: $0)
                }) else { continue }

                let rank = candidateRank(
                    for: candidate,
                    preferredFrame: preferredFrame,
                    anchor: anchor
                )
                if let bestCandidate,
                   !rank.precedes(bestCandidate.rank)
                       && !(rank == bestCandidate.rank && order < bestCandidate.order)
                {
                    continue
                }
                bestCandidate = (candidate, rank, order)
            }
        }
        return bestCandidate?.frame
    }

    private static func effectiveInset(
        availableLength: CGFloat,
        frameLength: CGFloat
    ) -> CGFloat {
        min(edgeInset, max(0, (availableLength - frameLength) / 2))
    }

    private static func constrainedOrigin(
        _ origin: CGFloat,
        visibleMinimum: CGFloat,
        visibleMaximum: CGFloat,
        frameLength: CGFloat
    ) -> CGFloat {
        let oppositeEdgeOrigin = visibleMaximum - frameLength
        let lowerBound = min(visibleMinimum, oppositeEdgeOrigin)
        let upperBound = max(visibleMinimum, oppositeEdgeOrigin)
        return min(max(origin, lowerBound), upperBound)
    }

    private static func appendUnique(_ value: CGFloat, to values: inout [CGFloat]) {
        guard !values.contains(value) else { return }
        values.append(value)
    }

    private static func hasRequiredSpacing(_ lhs: NSRect, from rhs: NSRect) -> Bool {
        lhs.maxX + cardSpacing <= rhs.minX
            || rhs.maxX + cardSpacing <= lhs.minX
            || lhs.maxY + cardSpacing <= rhs.minY
            || rhs.maxY + cardSpacing <= lhs.minY
    }

    private static func candidateRank(
        for candidate: NSRect,
        preferredFrame: NSRect,
        anchor: CardPlacementAnchor
    ) -> CandidateRank {
        let dx = candidate.minX - preferredFrame.minX
        let dy = candidate.minY - preferredFrame.minY
        switch anchor {
        case .topLeft, .topCenter, .topRight:
            return CandidateRank(
                score: abs(dy) + 3 * abs(dx),
                crossAxisDistance: abs(dx),
                directionalPenalty: dy <= 0 ? 0 : 1
            )
        case .bottomLeft, .bottomCenter, .bottomRight:
            return CandidateRank(
                score: abs(dy) + 3 * abs(dx),
                crossAxisDistance: abs(dx),
                directionalPenalty: dy >= 0 ? 0 : 1
            )
        case .centerLeft:
            return CandidateRank(
                score: abs(dx) + 3 * abs(dy),
                crossAxisDistance: abs(dy),
                directionalPenalty: dx >= 0 ? 0 : 1
            )
        case .centerRight:
            return CandidateRank(
                score: abs(dx) + 3 * abs(dy),
                crossAxisDistance: abs(dy),
                directionalPenalty: dx <= 0 ? 0 : 1
            )
        case .center:
            return CandidateRank(
                score: abs(dx) + abs(dy),
                crossAxisDistance: abs(dx),
                directionalPenalty: dy <= 0 ? 0 : 1
            )
        }
    }

    private struct CandidateRank: Equatable {
        let score: CGFloat
        let crossAxisDistance: CGFloat
        let directionalPenalty: Int

        func precedes(_ other: CandidateRank) -> Bool {
            if score != other.score { return score < other.score }
            if directionalPenalty != other.directionalPenalty {
                return directionalPenalty < other.directionalPenalty
            }
            return crossAxisDistance < other.crossAxisDistance
        }
    }
}

@MainActor
final class CardPlacementPreferences {
    private static let keys: [CardLayoutMode: String] = [
        .mini: "cardPlacement.mini.v1",
        .sticky: "cardPlacement.sticky.v1",
        .middle: "cardPlacement.middle.v1",
    ]

    private static let defaultAnchors: [CardLayoutMode: CardPlacementAnchor] = [
        .mini: .topRight,
        .sticky: .topRight,
        .middle: .center,
    ]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func anchor(for mode: CardLayoutMode) -> CardPlacementAnchor? {
        let preferenceMode: CardLayoutMode = mode == .custom ? .middle : mode
        guard let key = Self.keys[preferenceMode],
              let defaultAnchor = Self.defaultAnchors[preferenceMode]
        else { return nil }

        guard let rawValue = defaults.string(forKey: key),
              let storedAnchor = CardPlacementAnchor(rawValue: rawValue)
        else { return defaultAnchor }
        return storedAnchor
    }

    func set(_ anchor: CardPlacementAnchor, for mode: CardLayoutMode) {
        guard let key = Self.keys[mode] else { return }
        defaults.set(anchor.rawValue, forKey: key)
    }

    func restoreDefaults() {
        for key in Self.keys.values {
            defaults.removeObject(forKey: key)
        }
    }
}
