import Foundation

struct MarkdownComparison {
    static let maximumRenderedCharacters = 240_000

    static func render(
        original: String,
        modified: String,
        originalLabel: String = "File on Disk",
        modifiedLabel: String = "Card"
    ) -> String {
        let oldLines = normalizedLines(original)
        let newLines = normalizedLines(modified)
        var prefix = 0
        while prefix < min(oldLines.count, newLines.count), oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(oldLines.count - prefix, newLines.count - prefix),
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }
        let contextStart = max(0, prefix - 3)
        let oldChangeEnd = max(prefix, oldLines.count - suffix)
        let newChangeEnd = max(prefix, newLines.count - suffix)
        let oldContextEnd = min(oldLines.count, oldChangeEnd + 3)
        let newContextEnd = min(newLines.count, newChangeEnd + 3)

        var output = ["--- \(originalLabel)", "+++ \(modifiedLabel)"]
        if original == modified {
            output.append("(No textual differences)")
            return output.joined(separator: "\n")
        }
        output.append("@@ around line \(prefix + 1) @@")
        output.append(contentsOf: oldLines[contextStart..<prefix].map { "  \($0)" })
        output.append(contentsOf: oldLines[prefix..<oldChangeEnd].map { "- \($0)" })
        output.append(contentsOf: newLines[prefix..<newChangeEnd].map { "+ \($0)" })
        let suffixContextCount = min(
            oldContextEnd - oldChangeEnd,
            newContextEnd - newChangeEnd
        )
        if suffixContextCount > 0 {
            output.append(contentsOf: oldLines[oldChangeEnd..<(oldChangeEnd + suffixContextCount)].map {
                "  \($0)"
            })
        }
        var rendered = output.joined(separator: "\n")
        if rendered.count > maximumRenderedCharacters {
            rendered = String(rendered.prefix(maximumRenderedCharacters))
                + "\n… comparison truncated …"
        }
        return rendered
    }

    private static func normalizedLines(_ markdown: String) -> [String] {
        markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }
}
