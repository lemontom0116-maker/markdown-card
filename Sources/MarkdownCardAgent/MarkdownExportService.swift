import AppKit
import Foundation
import MarkdownCardCore
import UniformTypeIdentifiers

struct MarkdownExportBundle: Equatable, Sendable {
    let markdown: String
    let attachmentIDs: [String]
}

enum MarkdownExportError: LocalizedError, Equatable {
    case markdownTooLarge
    case invalidAttachmentID
    case missingAttachment(String)
    case unableToWrite

    var errorDescription: String? {
        switch self {
        case .markdownTooLarge:
            "The Markdown document is larger than the 4 MiB export limit."
        case .invalidAttachmentID:
            "The document contains an invalid managed attachment reference."
        case let .missingAttachment(identifier):
            "The attachment \(identifier).png is missing or invalid."
        case .unableToWrite:
            "Markdown Card could not write the Markdown export."
        }
    }
}

enum MarkdownExportOutcome {
    case cancelled
    case success(URL)
    case failure(Error)
}

final class MarkdownExportWriter: @unchecked Sendable {
    private let fileManager: FileManager
    private let attachmentStore: LocalAttachmentStore

    init(
        fileManager: FileManager = .default,
        attachmentStore: LocalAttachmentStore = LocalAttachmentStore()
    ) {
        self.fileManager = fileManager
        self.attachmentStore = attachmentStore
    }

    @discardableResult
    func write(_ bundle: MarkdownExportBundle, to markdownURL: URL) throws -> URL {
        guard bundle.markdown.lengthOfBytes(using: .utf8) <= IPCFrameCodec.maximumPayloadSize else {
            throw MarkdownExportError.markdownTooLarge
        }

        var seen = Set<String>()
        let identifiers = try bundle.attachmentIDs.compactMap { rawIdentifier -> String? in
            let identifier = rawIdentifier.lowercased()
            guard LocalAttachmentStore.isValidAttachmentID(identifier) else {
                throw MarkdownExportError.invalidAttachmentID
            }
            return seen.insert(identifier).inserted ? identifier : nil
        }
        let attachments = try identifiers.map { identifier -> (String, Data) in
            guard let data = attachmentStore.data(forAttachmentID: identifier) else {
                throw MarkdownExportError.missingAttachment(identifier)
            }
            return (identifier, data)
        }

        let destination = markdownURL.standardizedFileURL
        let parent = destination.deletingLastPathComponent()
        let attachmentDirectory = parent.appendingPathComponent(
            LocalAttachmentStore.markdownDirectory,
            isDirectory: true
        )
        var createdAttachments: [URL] = []
        let createdAttachmentDirectory = !fileManager.fileExists(atPath: attachmentDirectory.path)

        do {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            if !attachments.isEmpty {
                try fileManager.createDirectory(
                    at: attachmentDirectory,
                    withIntermediateDirectories: true
                )
            }
            for (identifier, data) in attachments {
                let outputURL = attachmentDirectory.appendingPathComponent(
                    "\(identifier).png",
                    isDirectory: false
                )
                let existed = fileManager.fileExists(atPath: outputURL.path)
                try data.write(to: outputURL, options: .atomic)
                if !existed { createdAttachments.append(outputURL) }
            }
            try Data(bundle.markdown.utf8).write(to: destination, options: .atomic)
            return destination
        } catch let error as MarkdownExportError {
            rollback(createdAttachments, directory: createdAttachmentDirectory ? attachmentDirectory : nil)
            throw error
        } catch {
            rollback(createdAttachments, directory: createdAttachmentDirectory ? attachmentDirectory : nil)
            throw MarkdownExportError.unableToWrite
        }
    }

    private func rollback(_ attachments: [URL], directory: URL?) {
        attachments.forEach { try? fileManager.removeItem(at: $0) }
        if let directory,
           (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true
        {
            try? fileManager.removeItem(at: directory)
        }
    }
}

@MainActor
final class MarkdownExportService {
    private let writer: MarkdownExportWriter
    private var savePanel: NSSavePanel?

    init(writer: MarkdownExportWriter = MarkdownExportWriter()) {
        self.writer = writer
    }

    func present(
        bundle: MarkdownExportBundle,
        title: String,
        from window: NSWindow,
        completion: @escaping (MarkdownExportOutcome) -> Void
    ) {
        guard savePanel == nil else { return }
        let panel = NSSavePanel()
        panel.title = "Export Markdown"
        panel.message = "Save the Markdown file beside its managed attachments."
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = Self.suggestedFilename(for: title)
        savePanel = panel

        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self else { return }
            savePanel = nil
            guard response == .OK, let destination = panel?.url else {
                completion(.cancelled)
                return
            }
            let writer = writer
            Task {
                do {
                    let exportedURL = try await Task.detached(priority: .userInitiated) {
                        try writer.write(bundle, to: destination)
                    }.value
                    completion(.success(exportedURL))
                } catch {
                    NSSound.beep()
                    let alert = NSAlert(error: error)
                    alert.messageText = "Unable to Export Markdown"
                    alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: window) { _ in }
                    completion(.failure(error))
                }
            }
        }
    }

    static func suggestedFilename(for title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:").union(.controlCharacters)
        let normalized = title
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = normalized.isEmpty ? CardRecord.untitledTitle : String(normalized.prefix(100))
        return "\(base).md"
    }
}
