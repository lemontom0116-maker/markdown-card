import AppKit
import Foundation
import MarkdownCardCore
import UniformTypeIdentifiers

struct CardSeriesLinkIssue: Equatable, Sendable {
    let cardID: UUID
    let cardTitle: String
    let destination: String
    let reason: String
}

struct CardSeriesDocument: Equatable, Sendable {
    let markdown: String
    let issues: [CardSeriesLinkIssue]
}

struct CardSeriesExportResult: Equatable, Sendable {
    let fileURL: URL
    let copiedResourcePaths: [String]
    let unresolvedResourcePaths: [String]
}

enum CardSeriesExportError: LocalizedError, Equatable {
    case emptySeries
    case documentTooLarge
    case unableToWrite

    var errorDescription: String? {
        switch self {
        case .emptySeries:
            "The selected Tag does not contain any cards."
        case .documentTooLarge:
            "The combined Markdown document is larger than the 4 MiB limit."
        case .unableToWrite:
            "Markdown Card could not write the combined series."
        }
    }
}

struct CardSeriesDocumentBuilder {
    private struct PreparedChapter {
        let card: CardRecord
        let number: Int
        let anchor: String
        let markdown: String
    }

    private struct MarkdownFence {
        let marker: Character
        let length: Int
    }

    private static let inlineFragmentLinkExpression = try! NSRegularExpression(
        pattern: #"(?<!!)(?<!\\)\[(?:\\.|[^\]\r\n])+\]\(\s*(?:<(#[^>\r\n]+)>|(#[^\s)\r\n]+))"#
    )
    private static let referenceFragmentLinkExpression = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]{0,3}\[(?:\\.|[^\]\r\n])+\]:[ \t]*(?:<(#[^>\r\n]+)>|(#[^\s\r\n]+))"#
    )

    static func build(
        tag: CardTag,
        cards: [CardRecord],
        fileURLsByCardID: [UUID: URL] = [:],
        fileManager: FileManager = .default
    ) throws -> CardSeriesDocument {
        guard !cards.isEmpty else { throw CardSeriesExportError.emptySeries }
        var globalSlugCounts: [String: Int] = [:]
        _ = registerHeading(tag.name, counts: &globalSlugCounts)
        _ = registerHeading("Contents", counts: &globalSlugCounts)
        var chapters: [PreparedChapter] = []
        for (index, card) in cards.enumerated() {
            let number = index + 1
            let anchor = registerHeading(
                "Chapter \(number): \(card.title)",
                counts: &globalSlugCounts
            )
            chapters.append(PreparedChapter(
                card: card,
                number: number,
                anchor: anchor,
                markdown: rebasingInternalHeadingLinks(
                    in: card.markdown,
                    globalSlugCounts: &globalSlugCounts
                )
            ))
        }
        var parts = ["# \(tag.name)", "", "## Contents", ""]
        parts.append(contentsOf: chapters.map {
            "\($0.number). [\(escapedLinkLabel($0.card.title))](#\($0.anchor))"
        })
        for chapter in chapters {
            parts.append("")
            parts.append("---")
            parts.append("")
            parts.append("## Chapter \(chapter.number): \(chapter.card.title)")
            parts.append("<!-- markdown-card-chapter: \(chapter.card.id.uuidString.lowercased()) -->")
            parts.append("")
            parts.append(chapter.markdown)
        }
        var markdown = parts.joined(separator: "\n")
        if !markdown.hasSuffix("\n") { markdown.append("\n") }
        guard markdown.lengthOfBytes(using: .utf8) <= IPCFrameCodec.maximumPayloadSize else {
            throw CardSeriesExportError.documentTooLarge
        }
        return CardSeriesDocument(
            markdown: markdown,
            issues: validateLinks(
                cards: cards,
                fileURLsByCardID: fileURLsByCardID,
                fileManager: fileManager
            )
        )
    }

    static func validateLinks(
        cards: [CardRecord],
        fileURLsByCardID: [UUID: URL],
        fileManager: FileManager = .default
    ) -> [CardSeriesLinkIssue] {
        var issues: [CardSeriesLinkIssue] = []
        var cardsByFilePath: [String: CardRecord] = [:]
        for (cardID, url) in fileURLsByCardID {
            guard let card = cards.first(where: { $0.id == cardID }) else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            if cardsByFilePath[path] == nil { cardsByFilePath[path] = card }
        }
        let expression = try? NSRegularExpression(
            pattern: #"(?<!!)\[[^\]]+\]\(([^\s)]+)(?:\s+[\"'][^\"']*[\"'])?\)"#
        )
        for card in cards {
            let source = card.markdown as NSString
            let matches = expression?.matches(
                in: card.markdown,
                range: NSRange(location: 0, length: source.length)
            ) ?? []
            for match in matches where match.numberOfRanges > 1 {
                let destination = source.substring(with: match.range(at: 1))
                if destination.hasPrefix("#") {
                    if !headingFragments(in: card.markdown).contains(decodedFragment(destination)) {
                        issues.append(issue(card, destination, "Heading fragment was not found in this card"))
                    }
                    continue
                }
                guard !destination.hasPrefix("http://"),
                      !destination.hasPrefix("https://"),
                      !destination.hasPrefix("mailto:")
                else { continue }
                guard let sourceURL = fileURLsByCardID[card.id] else {
                    issues.append(issue(
                        card,
                        destination,
                        "Relative link cannot be verified because this card has no linked source file"
                    ))
                    continue
                }
                let rawPath = destination.split(separator: "#", maxSplits: 1).first.map(String.init)
                    ?? destination
                guard !rawPath.isEmpty,
                      let decodedPath = rawPath.removingPercentEncoding,
                      !decodedPath.hasPrefix("/")
                else {
                    issues.append(issue(card, destination, "Unsupported or absolute local path"))
                    continue
                }
                let root = sourceURL.deletingLastPathComponent()
                    .standardizedFileURL.resolvingSymlinksInPath()
                let candidate = root.appendingPathComponent(decodedPath)
                    .standardizedFileURL.resolvingSymlinksInPath()
                guard isDescendant(candidate, of: root) else {
                    issues.append(issue(card, destination, "Path escapes the linked document directory"))
                    continue
                }
                guard fileManager.fileExists(atPath: candidate.path) else {
                    issues.append(issue(card, destination, "Linked file does not exist"))
                    continue
                }
                let pieces = destination.split(
                    separator: "#",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                if pieces.count == 2,
                   let targetCard = cardsByFilePath[candidate.path],
                   !headingFragments(in: targetCard.markdown).contains(
                    decodedFragment("#" + String(pieces[1]))
                   )
                {
                    issues.append(issue(
                        card,
                        destination,
                        "Heading fragment was not found in \(targetCard.title)"
                    ))
                } else {
                    issues.append(issue(
                        card,
                        destination,
                        "Relative file link is valid at its source but is not bundled by series export"
                    ))
                }
            }
        }
        return issues
    }

    static func chapterAnchor(index: Int, title: String) -> String {
        markdownHeadingSlug("Chapter \(index + 1): \(title)")
    }

    private static func escapedLinkLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "]", with: "\\]")
    }

    private static func headingFragments(in markdown: String) -> Set<String> {
        var counts: [String: Int] = [:]
        var fragments = Set<String>()
        for heading in headingTexts(in: markdown) {
            let base = markdownHeadingSlug(heading)
            guard !base.isEmpty else { continue }
            let occurrence = counts[base, default: 0]
            counts[base] = occurrence + 1
            fragments.insert(occurrence == 0 ? base : "\(base)-\(occurrence)")
        }
        return fragments
    }

    private static func rebasingInternalHeadingLinks(
        in markdown: String,
        globalSlugCounts: inout [String: Int]
    ) -> String {
        var localSlugCounts: [String: Int] = [:]
        var globalSlugByLocalSlug: [String: String] = [:]
        for heading in headingTexts(in: markdown) {
            let base = markdownHeadingSlug(heading)
            guard !base.isEmpty else { continue }
            let localOccurrence = localSlugCounts[base, default: 0]
            localSlugCounts[base] = localOccurrence + 1
            let localSlug = localOccurrence == 0 ? base : "\(base)-\(localOccurrence)"
            globalSlugByLocalSlug[localSlug] = registerHeading(
                heading,
                counts: &globalSlugCounts
            )
        }
        guard !globalSlugByLocalSlug.isEmpty else { return markdown }

        let source = markdown as NSString
        let wholeRange = NSRange(location: 0, length: source.length)
        let ignoredRanges = markdownCodeRanges(in: source)
        var replacementsByRange: [String: (range: NSRange, destination: String)] = [:]
        for expression in [inlineFragmentLinkExpression, referenceFragmentLinkExpression] {
            for match in expression.matches(in: markdown, range: wholeRange) {
                guard !ignoredRanges.contains(where: {
                    NSIntersectionRange($0, match.range).length > 0
                }) else { continue }
                guard let destinationRange = [match.range(at: 1), match.range(at: 2)]
                    .first(where: { $0.location != NSNotFound })
                else { continue }
                let rawDestination = source.substring(with: destinationRange)
                guard let rebased = globalSlugByLocalSlug[decodedFragment(rawDestination)] else {
                    continue
                }
                replacementsByRange["\(destinationRange.location):\(destinationRange.length)"] = (
                    destinationRange,
                    "#\(rebased)"
                )
            }
        }
        let rewritten = NSMutableString(string: markdown)
        for replacement in replacementsByRange.values.sorted(
            by: { $0.range.location > $1.range.location }
        ) {
            rewritten.replaceCharacters(in: replacement.range, with: replacement.destination)
        }
        return rewritten as String
    }

    private static func registerHeading(
        _ heading: String,
        counts: inout [String: Int]
    ) -> String {
        let base = markdownHeadingSlug(heading)
        guard !base.isEmpty else { return "" }
        let occurrence = counts[base, default: 0]
        counts[base] = occurrence + 1
        return occurrence == 0 ? base : "\(base)-\(occurrence)"
    }

    private static func headingTexts(in markdown: String) -> [String] {
        var headings: [String] = []
        var activeFence: MarkdownFence?
        for rawLine in markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        {
            let line = String(rawLine)
            if let fence = activeFence {
                if isClosingFence(line, matching: fence) { activeFence = nil }
                continue
            }
            if let fence = openingFence(in: line) {
                activeFence = fence
                continue
            }
            if line.hasPrefix("    ") || line.hasPrefix("\t") { continue }
            guard let prefix = line.range(
                of: #"^[ \t]{0,3}#{1,6}[ \t]+"#,
                options: .regularExpression
            ) else { continue }
            headings.append(String(line[prefix.upperBound...])
                .replacingOccurrences(
                    of: #"[ \t]+#+[ \t]*$"#,
                    with: "",
                    options: .regularExpression
                ))
        }
        return headings
    }

    private static func markdownCodeRanges(in source: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var activeFence: MarkdownFence?
        var location = 0
        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let line = source.substring(with: lineRange).trimmingCharacters(in: .newlines)
            if let fence = activeFence {
                ranges.append(lineRange)
                if isClosingFence(line, matching: fence) { activeFence = nil }
            } else if let fence = openingFence(in: line) {
                activeFence = fence
                ranges.append(lineRange)
            } else if line.hasPrefix("    ") || line.hasPrefix("\t") {
                ranges.append(lineRange)
            } else {
                ranges.append(contentsOf: inlineCodeRanges(in: source, lineRange: lineRange))
            }
            location = NSMaxRange(lineRange)
        }
        return ranges
    }

    private static func openingFence(in line: String) -> MarkdownFence? {
        let characters = Array(line)
        var index = 0
        while index < characters.count, characters[index] == " ", index < 4 {
            index += 1
        }
        guard index <= 3,
              index < characters.count,
              characters[index] == "`" || characters[index] == "~"
        else { return nil }
        let marker = characters[index]
        var end = index
        while end < characters.count, characters[end] == marker { end += 1 }
        guard end - index >= 3 else { return nil }
        if marker == "`", characters[end...].contains("`") { return nil }
        return MarkdownFence(marker: marker, length: end - index)
    }

    private static func isClosingFence(
        _ line: String,
        matching fence: MarkdownFence
    ) -> Bool {
        let characters = Array(line)
        var index = 0
        while index < characters.count, characters[index] == " ", index < 4 {
            index += 1
        }
        guard index <= 3, index < characters.count, characters[index] == fence.marker else {
            return false
        }
        var end = index
        while end < characters.count, characters[end] == fence.marker { end += 1 }
        guard end - index >= fence.length else { return false }
        return characters[end...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func inlineCodeRanges(
        in source: NSString,
        lineRange: NSRange
    ) -> [NSRange] {
        var ranges: [NSRange] = []
        let lineEnd = NSMaxRange(lineRange)
        var cursor = lineRange.location
        while cursor < lineEnd {
            guard source.character(at: cursor) == 96 else {
                cursor += 1
                continue
            }
            let openingStart = cursor
            while cursor < lineEnd, source.character(at: cursor) == 96 { cursor += 1 }
            let delimiterLength = cursor - openingStart
            var search = cursor
            var closingEnd: Int?
            while search < lineEnd {
                guard source.character(at: search) == 96 else {
                    search += 1
                    continue
                }
                let runStart = search
                while search < lineEnd, source.character(at: search) == 96 { search += 1 }
                if search - runStart == delimiterLength {
                    closingEnd = search
                    break
                }
            }
            guard let closingEnd else { continue }
            ranges.append(NSRange(
                location: openingStart,
                length: closingEnd - openingStart
            ))
            cursor = closingEnd
        }
        return ranges
    }

    private static func markdownHeadingSlug(_ source: String) -> String {
        source
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s_-]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func decodedFragment(_ destination: String) -> String {
        String(destination.drop(while: { $0 == "#" })).removingPercentEncoding
            ?? String(destination.drop(while: { $0 == "#" }))
    }

    private static func issue(
        _ card: CardRecord,
        _ destination: String,
        _ reason: String
    ) -> CardSeriesLinkIssue {
        CardSeriesLinkIssue(
            cardID: card.id,
            cardTitle: card.title,
            destination: destination,
            reason: reason
        )
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
    }
}

final class CardSeriesExportWriter: @unchecked Sendable {
    private let fileManager: FileManager
    private let externalMarkdownService: ExternalMarkdownDocumentService

    init(
        fileManager: FileManager = .default,
        externalMarkdownService: ExternalMarkdownDocumentService = ExternalMarkdownDocumentService()
    ) {
        self.fileManager = fileManager
        self.externalMarkdownService = externalMarkdownService
    }

    @discardableResult
    func write(_ document: CardSeriesDocument, to destinationURL: URL) throws -> URL {
        let destination = destinationURL.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path) else {
            throw CardSeriesExportError.unableToWrite
        }
        do {
            try Data(document.markdown.utf8).write(to: destination, options: .atomic)
            return destination
        } catch {
            throw CardSeriesExportError.unableToWrite
        }
    }

    /// Writes one combined tutorial while staging each chapter's portable image
    /// resources in a distinct sibling directory. A chapter namespace prevents
    /// identically named diagrams from silently replacing each other.
    func writePortable(
        _ document: CardSeriesDocument,
        tag: CardTag,
        cards: [CardRecord],
        fileURLsByCardID: [UUID: URL],
        to destinationURL: URL
    ) throws -> CardSeriesExportResult {
        guard !cards.isEmpty else { throw CardSeriesExportError.emptySeries }
        let destination = destinationURL.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        guard isExistingDirectory(parent) else { throw CardSeriesExportError.unableToWrite }

        let assetDirectoryName = Self.portableAssetDirectoryName(for: destination)
        let assetRoot = parent.appendingPathComponent(assetDirectoryName, isDirectory: true)
        var portableCards = cards
        var createdDirectories: [URL] = []
        var createdResourceURLs: [URL] = []
        var copiedResourcePaths: [String] = []
        var unresolvedResourcePaths: [String] = []

        do {
            try ensureDirectory(assetRoot, createdDirectories: &createdDirectories)
            for index in portableCards.indices {
                let card = portableCards[index]
                let shortID = card.id.uuidString.lowercased().prefix(8)
                let chapterDirectoryName = "chapter-\(index + 1)-\(shortID)"
                let chapterRelativeDirectory = "\(assetDirectoryName)/\(chapterDirectoryName)"
                let chapterRoot = assetRoot.appendingPathComponent(
                    chapterDirectoryName,
                    isDirectory: true
                )
                try ensureDirectory(chapterRoot, createdDirectories: &createdDirectories)

                let scratchURL = chapterRoot.appendingPathComponent(
                    ".markdown-card-series-\(UUID().uuidString.lowercased()).md",
                    isDirectory: false
                )
                let saveResult = try externalMarkdownService.saveAs(
                    MarkdownExportBundle(markdown: card.markdown, attachmentIDs: []),
                    sourceDocumentRoot: fileURLsByCardID[card.id]?.deletingLastPathComponent(),
                    to: scratchURL
                )
                try? fileManager.removeItem(at: scratchURL)

                let unresolved = Set(saveResult.unresolvedResourcePaths)
                portableCards[index].markdown = try externalMarkdownService
                    .markdownByPrefixingPortableImageReferences(
                        saveResult.markdown,
                        relativeDirectory: chapterRelativeDirectory,
                        excluding: unresolved
                    )
                for path in saveResult.copiedResourcePaths {
                    let resourceURL = chapterRoot.appendingPathComponent(path).standardizedFileURL
                    createdResourceURLs.append(resourceURL)
                    copiedResourcePaths.append("\(chapterRelativeDirectory)/\(path)")
                }
                unresolvedResourcePaths.append(contentsOf: saveResult.unresolvedResourcePaths.map {
                    "\(card.title): \($0)"
                })
            }

            let rebuilt = try CardSeriesDocumentBuilder.build(tag: tag, cards: portableCards)
            let portableDocument = CardSeriesDocument(
                markdown: rebuilt.markdown,
                issues: document.issues
            )
            let outputURL = try write(portableDocument, to: destination)
            removeCreatedDirectoriesIfEmpty(createdDirectories)
            return CardSeriesExportResult(
                fileURL: outputURL,
                copiedResourcePaths: copiedResourcePaths,
                unresolvedResourcePaths: Array(Set(unresolvedResourcePaths)).sorted()
            )
        } catch {
            for resourceURL in createdResourceURLs.reversed() {
                try? fileManager.removeItem(at: resourceURL)
            }
            removeCreatedDirectoriesIfEmpty(createdDirectories)
            throw error
        }
    }

    private func isExistingDirectory(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeDirectory
    }

    static func portableAssetDirectoryName(for destinationURL: URL) -> String {
        let rawStem = destinationURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = rawStem.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar == "_" || scalar == "-"
            {
                return Character(String(scalar))
            }
            return "-"
        }
        let sanitized = String(scalars)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(sanitized.isEmpty ? "Tutorial" : sanitized)-assets"
    }

    private func ensureDirectory(
        _ url: URL,
        createdDirectories: inout [URL]
    ) throws {
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw CardSeriesExportError.unableToWrite
            }
            return
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            createdDirectories.append(url)
        } catch {
            throw CardSeriesExportError.unableToWrite
        }
    }

    private func removeCreatedDirectoriesIfEmpty(_ directories: [URL]) {
        for directory in directories.reversed() {
            removeDirectoryTreeIfEmpty(directory)
        }
    }

    private func removeDirectoryTreeIfEmpty(_ directory: URL) {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let item as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return }
        }
        try? fileManager.removeItem(at: directory)
    }
}

@MainActor
final class CardSeriesExportService {
    private let writer: CardSeriesExportWriter
    private var savePanel: NSSavePanel?
    private(set) var isExporting = false

    var isBusy: Bool { savePanel != nil || isExporting }

    init(writer: CardSeriesExportWriter = CardSeriesExportWriter()) {
        self.writer = writer
    }

    func present(
        document: CardSeriesDocument,
        tag: CardTag,
        cards: [CardRecord],
        fileURLsByCardID: [UUID: URL],
        from window: NSWindow?,
        completion: @escaping (Result<CardSeriesExportResult, Error>?) -> Void
    ) {
        guard !isBusy else { return }
        let panel = NSSavePanel()
        panel.title = "Export Card Series"
        panel.message = document.issues.isEmpty
            ? "Save the ordered cards as one Markdown tutorial with a generated table of contents."
            : "Save the tutorial. \(document.issues.count) local link issue(s) should be reviewed."
        panel.prompt = "Export Series"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = MarkdownExportService.suggestedFilename(for: tag.name)
        savePanel = panel
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard let self else { return }
            savePanel = nil
            guard response == .OK, let destination = panel?.url else {
                completion(nil)
                return
            }
            isExporting = true
            let writer = writer
            Task {
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try writer.writePortable(
                            document,
                            tag: tag,
                            cards: cards,
                            fileURLsByCardID: fileURLsByCardID,
                            to: destination
                        )
                    }.value
                    isExporting = false
                    completion(.success(result))
                } catch {
                    isExporting = false
                    completion(.failure(error))
                }
            }
        }
        if let window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}
