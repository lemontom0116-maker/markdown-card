import AppKit
import Darwin
import Foundation

struct ResolvedDocumentLink: Equatable, Sendable {
    let fileURL: URL
    let fragment: String?
}

enum DocumentLinkError: LocalizedError, Equatable {
    case invalidLink
    case pathEscapesDocumentRoot
    case missingFile
    case notRegularFile

    var errorDescription: String? {
        switch self {
        case .invalidLink:
            "This relative document link is not valid."
        case .pathEscapesDocumentRoot:
            "This link points outside the linked Markdown document directory."
        case .missingFile:
            "The linked file no longer exists."
        case .notRegularFile:
            "The linked destination is not a regular file."
        }
    }
}

struct DocumentLinkResolver {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func resolve(_ href: String, documentRoot: URL) throws -> ResolvedDocumentLink {
        guard !href.isEmpty, href.utf8.count <= 4_096,
              !href.contains("\0"), !href.contains("\\")
        else { throw DocumentLinkError.invalidLink }
        let pieces = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(pieces[0])
        guard !rawPath.isEmpty, !rawPath.contains("?"),
              let decodedPath = rawPath.removingPercentEncoding,
              !decodedPath.isEmpty,
              !decodedPath.hasPrefix("/"),
              !decodedPath.hasPrefix("~"),
              decodedPath.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) == nil
        else { throw DocumentLinkError.invalidLink }

        let root = documentRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(decodedPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isDescendant(candidate, of: root) else {
            throw DocumentLinkError.pathEscapesDocumentRoot
        }
        guard fileManager.fileExists(atPath: candidate.path) else {
            throw DocumentLinkError.missingFile
        }
        let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { throw DocumentLinkError.notRegularFile }
        let fragment = pieces.count == 2
            ? String(pieces[1]).removingPercentEncoding?.trimmingCharacters(in: .whitespaces)
            : nil
        guard fragment?.utf8.count ?? 0 <= 512 else { throw DocumentLinkError.invalidLink }
        return ResolvedDocumentLink(
            fileURL: candidate,
            fragment: fragment?.isEmpty == false ? fragment : nil
        )
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path == root.path || candidate.path.hasPrefix(prefix)
    }
}

@MainActor
final class DocumentLinkCoordinator: NSObject, NSWindowDelegate {
    nonisolated static let maximumSourcePreviewSize = 4 * 1_024 * 1_024

    private let resolver: DocumentLinkResolver
    private var sourceWindows: [ObjectIdentifier: NSWindowController] = [:]

    init(resolver: DocumentLinkResolver = DocumentLinkResolver()) {
        self.resolver = resolver
    }

    func open(_ href: String, documentRoot: URL) throws {
        let link = try resolver.resolve(href, documentRoot: documentRoot)
        guard Self.requiresSourcePreview(for: link) else {
            NSWorkspace.shared.open(link.fileURL)
            return
        }

        let fileURL = link.fileURL
        let fragment = link.fragment
        Task { [weak self] in
            let source = await Task.detached(priority: .userInitiated) {
                Self.readSourceText(fileURL: fileURL, documentRoot: documentRoot)
            }.value
            guard let source,
                  let targetLine = Self.targetLine(fragment: fragment, markdown: source)
            else {
                NSWorkspace.shared.open(fileURL)
                return
            }
            self?.showSource(source, url: fileURL, targetLine: targetLine)
        }
    }

    /// A plain relative link behaves like a normal file link. Source bytes are
    /// only needed when a line or heading fragment asks for an in-app preview.
    nonisolated static func requiresSourcePreview(for link: ResolvedDocumentLink) -> Bool {
        link.fragment?.isEmpty == false
    }

    /// Reads from one descriptor after checking its type and size. Walking the
    /// canonical path with `openat(..., O_NOFOLLOW)` prevents a component from
    /// being swapped to a symlink between path validation and the read.
    nonisolated static func readSourceText(fileURL: URL, documentRoot: URL) -> String? {
        guard let descriptor = secureDescriptor(
            fileURL: fileURL,
            documentRoot: documentRoot
        ) else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0,
              status.st_size <= off_t(maximumSourcePreviewSize)
        else { return nil }

        var source = Data()
        source.reserveCapacity(Int(status.st_size))
        do {
            while source.count <= maximumSourcePreviewSize {
                let remaining = maximumSourcePreviewSize + 1 - source.count
                guard remaining > 0,
                      let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                      !chunk.isEmpty
                else { break }
                source.append(chunk)
            }
        } catch {
            return nil
        }
        guard source.count <= maximumSourcePreviewSize else { return nil }
        return String(data: source, encoding: .utf8)
    }

    nonisolated private static func secureDescriptor(
        fileURL: URL,
        documentRoot: URL
    ) -> Int32? {
        let root = documentRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }

        var descriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { return nil }

        let relativeComponents = candidateComponents.dropFirst(rootComponents.count)
        for (index, component) in relativeComponents.enumerated() {
            let isFinal = index == relativeComponents.count - 1
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (isFinal ? 0 : O_DIRECTORY)
            let next = component.withCString { pointer in
                Darwin.openat(descriptor, pointer, flags)
            }
            Darwin.close(descriptor)
            guard next >= 0 else { return nil }
            descriptor = next
        }
        return descriptor
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        sourceWindows.removeValue(forKey: ObjectIdentifier(window))
    }

    private func showSource(_ source: String, url: URL, targetLine: Int) {
        let splitLines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let lines = splitLines.isEmpty ? [""] : splitLines
        let width = max(3, String(max(1, lines.count)).count)
        let numbered = lines.enumerated().map { index, line in
            String(format: "%0*d │ %@", width, index + 1, line)
        }.joined(separator: "\n")
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.string = numbered
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.setAccessibilityLabel("Source file \(url.lastPathComponent), line \(targetLine)")
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(url.lastPathComponent) — Line \(targetLine)"
        window.contentView = scrollView
        window.delegate = self
        window.center()
        let controller = NSWindowController(window: window)
        sourceWindows[ObjectIdentifier(window)] = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        let targetIndex = min(max(0, targetLine - 1), max(0, lines.count - 1))
        let prefix = lines.prefix(targetIndex).enumerated().map { index, line in
            String(format: "%0*d │ %@\n", width, index + 1, line)
        }.joined()
        let target = String(format: "%0*d │ %@", width, targetIndex + 1, lines[targetIndex])
        let range = NSRange(location: (prefix as NSString).length, length: (target as NSString).length)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    private static func targetLine(fragment: String?, markdown: String) -> Int? {
        guard let fragment, !fragment.isEmpty else { return nil }
        if let match = fragment.firstMatch(of: /^L(\d+)(?:-L\d+)?$/),
           let line = Int(match.1), line > 0 {
            return line
        }
        let wanted = slug(fragment)
        guard !wanted.isEmpty else { return nil }
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let text = String(line)
            guard let range = text.range(of: #"^#{1,6}\s+"#, options: .regularExpression) else {
                continue
            }
            if slug(String(text[range.upperBound...])) == wanted { return index + 1 }
        }
        return nil
    }

    private static func slug(_ source: String) -> String {
        source
            .folding(options: [.widthInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s-]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
