import CryptoKit
import Foundation
import MarkdownCardCore

struct ExternalMarkdownDocument: Equatable, Sendable {
    let fileURL: URL
    let markdown: String
    let digest: String
}

struct CardFileBinding: Codable, Equatable, Sendable {
    let path: String
    let baseDigest: String

    init(fileURL: URL, baseDigest: String) {
        path = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        self.baseDigest = baseDigest
    }

    var fileURL: URL {
        URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
    }
}

struct ExternalMarkdownConflict: Equatable, Sendable {
    let binding: CardFileBinding
    let diskDigest: String
    let localDigest: String

    var diskChanged: Bool { diskDigest != binding.baseDigest }
    var localChanged: Bool { localDigest != binding.baseDigest }
}

struct ExternalMarkdownSaveAsResult: Equatable, Sendable {
    let binding: CardFileBinding
    let markdown: String
    let copiedResourcePaths: [String]
    let unresolvedResourcePaths: [String]

    var fileURL: URL { binding.fileURL }
    var documentRootURL: URL {
        binding.fileURL.deletingLastPathComponent().standardizedFileURL
    }
}

enum ExternalMarkdownSaveResult: Equatable, Sendable {
    case unchanged(CardFileBinding)
    case saved(CardFileBinding)
    case conflict(ExternalMarkdownConflict)
}

enum ExternalMarkdownDocumentError: LocalizedError, Equatable, Sendable {
    case invalidLocation
    case unsupportedFileType
    case missingFile
    case notRegularFile
    case unreadableFile
    case invalidUTF8
    case documentTooLarge
    case invalidManagedAttachment(String)
    case missingManagedAttachment(String)
    case unsafeResourcePath(String)
    case missingResource(String)
    case unsupportedResource(String)
    case resourceTooLarge(String)
    case unableToCopyResource(String)
    case unableToWrite
    case coordinationFailed

    var errorDescription: String? {
        switch self {
        case .invalidLocation:
            "Choose a local Markdown file."
        case .unsupportedFileType:
            "Markdown Card can open and save .md or .markdown files."
        case .missingFile:
            "The linked Markdown file no longer exists."
        case .notRegularFile:
            "The selected location is not a regular file."
        case .unreadableFile:
            "Markdown Card could not read this file. Check its permissions and try again."
        case .invalidUTF8:
            "The Markdown file is not valid UTF-8 text."
        case .documentTooLarge:
            "The Markdown document is larger than the 4 MiB limit."
        case let .invalidManagedAttachment(identifier):
            "The managed attachment identifier \(identifier) is invalid."
        case let .missingManagedAttachment(identifier):
            "The managed attachment \(identifier).png is missing or invalid."
        case let .unsafeResourcePath(path):
            "The relative resource \(path) escapes the linked document folder."
        case let .missingResource(path):
            "The relative resource \(path) no longer exists."
        case let .unsupportedResource(path):
            "The relative resource \(path) is not a supported image."
        case let .resourceTooLarge(path):
            "The relative resource \(path) exceeds the image safety limit."
        case let .unableToCopyResource(path):
            "Markdown Card could not copy the relative resource \(path)."
        case .unableToWrite:
            "Markdown Card could not write this Markdown file."
        case .coordinationFailed:
            "Markdown Card could not coordinate access to this file."
        }
    }
}

final class ExternalMarkdownDocumentService: @unchecked Sendable {
    static let supportedFilenameExtensions: Set<String> = ["md", "markdown"]

    private let fileManager: FileManager
    private let maximumDocumentSize: Int
    private let attachmentStore: LocalAttachmentStore
    private let documentImageResolver: DocumentImageResolver

    init(
        fileManager: FileManager = .default,
        maximumDocumentSize: Int = IPCFrameCodec.maximumPayloadSize,
        attachmentStore: LocalAttachmentStore = LocalAttachmentStore(),
        documentImageResolver: DocumentImageResolver? = nil
    ) {
        self.fileManager = fileManager
        self.maximumDocumentSize = maximumDocumentSize
        self.attachmentStore = attachmentStore
        self.documentImageResolver = documentImageResolver
            ?? DocumentImageResolver(fileManager: fileManager)
    }

    func open(_ sourceURL: URL) throws -> ExternalMarkdownDocument {
        let url = try validatedFileURL(sourceURL)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ExternalMarkdownDocumentError.missingFile
        }

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            throw ExternalMarkdownDocumentError.unreadableFile
        }
        guard values.isRegularFile == true else {
            throw ExternalMarkdownDocumentError.notRegularFile
        }
        if let fileSize = values.fileSize, fileSize > maximumDocumentSize {
            throw ExternalMarkdownDocumentError.documentTooLarge
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw ExternalMarkdownDocumentError.unreadableFile
        }
        guard data.count <= maximumDocumentSize else {
            throw ExternalMarkdownDocumentError.documentTooLarge
        }
        guard let markdown = String(data: data, encoding: .utf8) else {
            throw ExternalMarkdownDocumentError.invalidUTF8
        }
        return ExternalMarkdownDocument(
            fileURL: url,
            markdown: markdown,
            digest: Self.digest(data)
        )
    }

    func save(_ markdown: String, binding: CardFileBinding) throws -> ExternalMarkdownSaveResult {
        let localData = try encodedMarkdown(markdown)
        let localDigest = Self.digest(localData)
        let destination = try validatedFileURL(binding.fileURL)
        guard fileManager.fileExists(atPath: destination.path) else {
            throw ExternalMarkdownDocumentError.missingFile
        }

        var coordinatedResult: ExternalMarkdownSaveResult?
        var operationError: Error?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let disk = try open(coordinatedURL)
                guard disk.digest == binding.baseDigest else {
                    coordinatedResult = .conflict(ExternalMarkdownConflict(
                        binding: binding,
                        diskDigest: disk.digest,
                        localDigest: localDigest
                    ))
                    return
                }
                guard localDigest != binding.baseDigest else {
                    coordinatedResult = .unchanged(binding)
                    return
                }
                try writeAtomically(localData, to: coordinatedURL)
                coordinatedResult = .saved(CardFileBinding(
                    fileURL: coordinatedURL,
                    baseDigest: localDigest
                ))
            } catch {
                operationError = error
            }
        }

        if let operationError { throw operationError }
        if coordinationError != nil {
            throw ExternalMarkdownDocumentError.coordinationFailed
        }
        guard let coordinatedResult else {
            throw ExternalMarkdownDocumentError.coordinationFailed
        }
        return coordinatedResult
    }

    /// Writes the card version selected by a conflict dialog without overwriting a
    /// newer disk edit that happened while the dialog was visible.
    func keepLocalVersion(
        _ markdown: String,
        after conflict: ExternalMarkdownConflict
    ) throws -> ExternalMarkdownSaveResult {
        let localData = try encodedMarkdown(markdown)
        let localDigest = Self.digest(localData)
        let destination = try validatedFileURL(conflict.binding.fileURL)
        guard fileManager.fileExists(atPath: destination.path) else {
            throw ExternalMarkdownDocumentError.missingFile
        }

        var coordinatedResult: ExternalMarkdownSaveResult?
        var operationError: Error?
        var coordinationError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(
            writingItemAt: destination,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                let disk = try open(coordinatedURL)
                guard disk.digest == conflict.diskDigest else {
                    coordinatedResult = .conflict(ExternalMarkdownConflict(
                        binding: conflict.binding,
                        diskDigest: disk.digest,
                        localDigest: localDigest
                    ))
                    return
                }
                guard localDigest != disk.digest else {
                    coordinatedResult = .unchanged(CardFileBinding(
                        fileURL: coordinatedURL,
                        baseDigest: disk.digest
                    ))
                    return
                }
                try writeAtomically(localData, to: coordinatedURL)
                coordinatedResult = .saved(CardFileBinding(
                    fileURL: coordinatedURL,
                    baseDigest: localDigest
                ))
            } catch {
                operationError = error
            }
        }

        if let operationError { throw operationError }
        if coordinationError != nil {
            throw ExternalMarkdownDocumentError.coordinationFailed
        }
        guard let coordinatedResult else {
            throw ExternalMarkdownDocumentError.coordinationFailed
        }
        return coordinatedResult
    }

    func saveAs(_ markdown: String, to destinationURL: URL) throws -> CardFileBinding {
        let destination = try validatedFileURL(destinationURL)
        let data = try encodedMarkdown(markdown)
        try writeAtomically(data, to: destination)
        return CardFileBinding(fileURL: destination, baseDigest: Self.digest(data))
    }

    /// Saves a portable Markdown document, copying managed attachments and safe
    /// document-local image references beside the new file. Existing resources
    /// are never overwritten: equal bytes are reused, while collisions receive a
    /// deterministic numeric suffix and their Markdown references are rewritten.
    func saveAs(
        _ bundle: MarkdownExportBundle,
        sourceDocumentRoot: URL?,
        to destinationURL: URL
    ) throws -> ExternalMarkdownSaveAsResult {
        let destination = try validatedFileURL(destinationURL)
        let destinationRoot = destination.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        try validateDestinationRoot(destinationRoot)

        let references = MarkdownSaveAsResourceScanner.references(in: bundle.markdown)
        let prepared = try prepareSaveAsResources(
            bundle: bundle,
            references: references,
            sourceDocumentRoot: sourceDocumentRoot,
            destinationRoot: destinationRoot
        )
        let rewrittenMarkdown = rewriteMarkdown(
            bundle.markdown,
            references: references,
            destinationsByReference: prepared.destinationsByReference
        )
        let markdownData = try encodedMarkdown(rewrittenMarkdown)

        var createdFiles: [URL] = []
        var createdDirectories: [URL] = []
        do {
            for resource in prepared.resources {
                let outputURL = try safeDestinationURL(
                    relativePath: resource.destinationRelativePath,
                    root: destinationRoot
                )
                if try existingRegularFile(at: outputURL, equals: resource.data) {
                    continue
                }
                try createParentDirectories(
                    for: outputURL,
                    root: destinationRoot,
                    createdDirectories: &createdDirectories
                )
                if try writeNewResourceAtomically(
                    resource.data,
                    to: outputURL,
                    resourcePath: resource.destinationRelativePath
                ) {
                    createdFiles.append(outputURL)
                }
            }
            try writeAtomically(markdownData, to: destination)
        } catch {
            rollbackCreatedResources(
                files: createdFiles,
                directories: createdDirectories
            )
            throw error
        }

        return ExternalMarkdownSaveAsResult(
            binding: CardFileBinding(
                fileURL: destination,
                baseDigest: Self.digest(markdownData)
            ),
            markdown: rewrittenMarkdown,
            copiedResourcePaths: createdFiles.compactMap {
                relativePath(of: $0, under: destinationRoot)
            },
            unresolvedResourcePaths: prepared.unresolvedResourcePaths
        )
    }

    /// Re-bases local image sources after a portable Save As has staged one
    /// chapter's resources in a namespaced directory. Remote/data sources and
    /// unresolved local paths are deliberately left untouched.
    func markdownByPrefixingPortableImageReferences(
        _ markdown: String,
        relativeDirectory: String,
        excluding unresolvedPaths: Set<String> = []
    ) throws -> String {
        let components = relativeDirectory.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              !components.contains(""),
              !components.contains("."),
              !components.contains(".."),
              !components.contains(where: { $0.contains("\\") || $0.contains("\0") })
        else {
            throw ExternalMarkdownDocumentError.unsafeResourcePath(relativeDirectory)
        }

        let references = MarkdownSaveAsResourceScanner.references(in: markdown)
        var destinations: [Int: String] = [:]
        for (index, reference) in references.enumerated() {
            guard case let .relative(path, suffix) = relativeResourceSource(reference.rawSource),
                  !unresolvedPaths.contains(path),
                  !unresolvedPaths.contains(reference.rawSource)
            else { continue }
            destinations[index] = encodedMarkdownResourcePath(
                components.joined(separator: "/") + "/" + path
            ) + suffix
        }
        return rewriteMarkdown(
            markdown,
            references: references,
            destinationsByReference: destinations
        )
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct SaveAsResourcePayload {
        let key: String
        let data: Data
        let preferredRelativePath: String
    }

    private struct PreparedSaveAsResource {
        let data: Data
        let destinationRelativePath: String
    }

    private struct PreparedSaveAsResources {
        let resources: [PreparedSaveAsResource]
        let destinationsByReference: [Int: String]
        let unresolvedResourcePaths: [String]
    }

    private enum RelativeResourceSource {
        case ignore
        case unsafe(String)
        case relative(path: String, suffix: String)
    }

    private enum DestinationAvailability {
        case available
        case reusable
        case occupied
    }

    private func prepareSaveAsResources(
        bundle: MarkdownExportBundle,
        references: [MarkdownSaveAsResourceReference],
        sourceDocumentRoot: URL?,
        destinationRoot: URL
    ) throws -> PreparedSaveAsResources {
        var managedIdentifiers = Set<String>()
        for rawIdentifier in bundle.attachmentIDs {
            let identifier = rawIdentifier.lowercased()
            guard LocalAttachmentStore.isValidAttachmentID(identifier) else {
                throw ExternalMarkdownDocumentError.invalidManagedAttachment(rawIdentifier)
            }
            managedIdentifiers.insert(identifier)
        }

        var payloads: [SaveAsResourcePayload] = []
        var payloadIndexByKey: [String: Int] = [:]
        var payloadKeyByReference: [Int: String] = [:]
        var parsedSourceByReference: [Int: (path: String, suffix: String)] = [:]
        var unresolvedResourcePaths = Set<String>()

        func appendPayload(
            key: String,
            data: Data,
            preferredRelativePath: String
        ) {
            guard payloadIndexByKey[key] == nil else { return }
            payloadIndexByKey[key] = payloads.count
            payloads.append(SaveAsResourcePayload(
                key: key,
                data: data,
                preferredRelativePath: preferredRelativePath
            ))
        }

        for (index, reference) in references.enumerated() {
            switch relativeResourceSource(reference.rawSource) {
            case .ignore:
                continue
            case let .unsafe(path):
                if sourceDocumentRoot != nil {
                    throw ExternalMarkdownDocumentError.unsafeResourcePath(path)
                }
                unresolvedResourcePaths.insert(path)
            case let .relative(path, suffix):
                parsedSourceByReference[index] = (path, suffix)
                if let identifier = managedAttachmentID(fromRelativePath: path) {
                    managedIdentifiers.insert(identifier)
                    let data = try managedAttachmentData(identifier)
                    let key = "managed:\(identifier)"
                    appendPayload(
                        key: key,
                        data: data,
                        preferredRelativePath: "\(LocalAttachmentStore.markdownDirectory)/\(identifier).png"
                    )
                    payloadKeyByReference[index] = key
                    continue
                }
                guard let sourceDocumentRoot else {
                    if (try? documentImageResolver.load(
                        relativePath: path,
                        documentRoot: destinationRoot
                    )) == nil {
                        unresolvedResourcePaths.insert(path)
                    }
                    continue
                }
                let resolvedURL: URL
                let asset: DocumentImageAsset
                do {
                    resolvedURL = try documentImageResolver.resolvedFileURL(
                        relativePath: path,
                        documentRoot: sourceDocumentRoot
                    )
                    asset = try documentImageResolver.load(
                        relativePath: path,
                        documentRoot: sourceDocumentRoot
                    )
                } catch let error as DocumentImageResolverError {
                    throw externalDocumentError(for: error, path: path)
                } catch {
                    throw ExternalMarkdownDocumentError.unableToCopyResource(path)
                }
                let key = "document:\(resolvedURL.path)"
                appendPayload(key: key, data: asset.data, preferredRelativePath: path)
                payloadKeyByReference[index] = key
            }
        }

        // Preserve the renderer's complete managed-attachment inventory even if
        // a future Markdown syntax is not recognized by the conservative scanner.
        for identifier in managedIdentifiers.sorted() {
            let key = "managed:\(identifier)"
            guard payloadIndexByKey[key] == nil else { continue }
            appendPayload(
                key: key,
                data: try managedAttachmentData(identifier),
                preferredRelativePath: "\(LocalAttachmentStore.markdownDirectory)/\(identifier).png"
            )
        }

        var reservedDestinations: [String: Data] = [:]
        var destinationByPayloadKey: [String: String] = [:]
        var preparedResources: [PreparedSaveAsResource] = []
        let referencedPayloadKeys = Set(payloadKeyByReference.values)
        for payload in payloads {
            let destinationPath = try uniqueDestinationRelativePath(
                preferred: payload.preferredRelativePath,
                data: payload.data,
                root: destinationRoot,
                reserved: &reservedDestinations
            )
            if destinationPath != payload.preferredRelativePath,
               !referencedPayloadKeys.contains(payload.key)
            {
                throw ExternalMarkdownDocumentError.unableToCopyResource(
                    payload.preferredRelativePath
                )
            }
            destinationByPayloadKey[payload.key] = destinationPath
            preparedResources.append(PreparedSaveAsResource(
                data: payload.data,
                destinationRelativePath: destinationPath
            ))
        }

        var destinationsByReference: [Int: String] = [:]
        for (referenceIndex, payloadKey) in payloadKeyByReference {
            guard let parsedSource = parsedSourceByReference[referenceIndex],
                  let destinationPath = destinationByPayloadKey[payloadKey],
                  destinationPath != parsedSource.path
            else { continue }
            destinationsByReference[referenceIndex] = encodedMarkdownResourcePath(
                destinationPath
            ) + parsedSource.suffix
        }
        return PreparedSaveAsResources(
            resources: preparedResources,
            destinationsByReference: destinationsByReference,
            unresolvedResourcePaths: unresolvedResourcePaths.sorted()
        )
    }

    private func managedAttachmentData(_ identifier: String) throws -> Data {
        guard LocalAttachmentStore.isValidAttachmentID(identifier) else {
            throw ExternalMarkdownDocumentError.invalidManagedAttachment(identifier)
        }
        guard let data = attachmentStore.data(forAttachmentID: identifier) else {
            throw ExternalMarkdownDocumentError.missingManagedAttachment(identifier)
        }
        return data
    }

    private func managedAttachmentID(fromRelativePath path: String) -> String? {
        let prefix = "\(LocalAttachmentStore.markdownDirectory)/"
        guard path.hasPrefix(prefix), path.hasSuffix(".png") else { return nil }
        let start = path.index(path.startIndex, offsetBy: prefix.count)
        let end = path.index(path.endIndex, offsetBy: -4)
        let identifier = String(path[start..<end]).lowercased()
        return LocalAttachmentStore.isValidAttachmentID(identifier) ? identifier : nil
    }

    private func externalDocumentError(
        for error: DocumentImageResolverError,
        path: String
    ) -> ExternalMarkdownDocumentError {
        switch error {
        case .invalidRequest, .pathEscapesDocumentRoot:
            .unsafeResourcePath(path)
        case .missingFile:
            .missingResource(path)
        case .unsupportedType, .invalidImage, .imageTooLarge:
            .unsupportedResource(path)
        case .fileTooLarge:
            .resourceTooLarge(path)
        }
    }

    private func relativeResourceSource(_ rawSource: String) -> RelativeResourceSource {
        let unescaped = markdownDestinationUnescaped(rawSource)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unescaped.isEmpty, !unescaped.hasPrefix("#") else { return .ignore }
        if unescaped.hasPrefix("//")
            || unescaped.range(
                of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#,
                options: .regularExpression
            ) != nil
        {
            return .ignore
        }

        let suffixIndex = unescaped.firstIndex { $0 == "?" || $0 == "#" }
        let rawPath = suffixIndex.map { String(unescaped[..<$0]) } ?? unescaped
        let suffix = suffixIndex.map { String(unescaped[$0...]) } ?? ""
        let decodedPath = rawPath.removingPercentEncoding ?? rawPath
        guard !decodedPath.hasPrefix("/"),
              !decodedPath.hasPrefix("~"),
              !decodedPath.hasPrefix("\\"),
              !decodedPath.contains("\0")
        else {
            return .unsafe(rawSource)
        }

        let components = decodedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              !components.contains(""),
              !components.contains(".."),
              !components.contains(where: { $0.contains("\\") })
        else {
            return .unsafe(rawSource)
        }
        let normalized = components.filter { $0 != "." }.joined(separator: "/")
        guard !normalized.isEmpty else { return .ignore }
        return .relative(path: normalized, suffix: suffix)
    }

    private func markdownDestinationUnescaped(_ source: String) -> String {
        var result = ""
        var iterator = source.makeIterator()
        while let character = iterator.next() {
            if character == "\\", let escaped = iterator.next() {
                result.append(escaped)
            } else {
                result.append(character)
            }
        }
        return result
    }

    private func encodedMarkdownResourcePath(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "/-._~")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    private func uniqueDestinationRelativePath(
        preferred: String,
        data: Data,
        root: URL,
        reserved: inout [String: Data]
    ) throws -> String {
        for sequence in 1 ... 10_000 {
            let candidate = sequence == 1
                ? preferred
                : suffixedRelativePath(preferred, sequence: sequence)
            let reservationKey = candidate.precomposedStringWithCanonicalMapping.lowercased()
            if let reservedData = reserved[reservationKey] {
                if reservedData == data { return candidate }
                continue
            }
            let availability = try destinationAvailability(
                relativePath: candidate,
                data: data,
                root: root
            )
            switch availability {
            case .available, .reusable:
                reserved[reservationKey] = data
                return candidate
            case .occupied:
                continue
            }
        }
        throw ExternalMarkdownDocumentError.unableToCopyResource(preferred)
    }

    private func suffixedRelativePath(_ path: String, sequence: Int) -> String {
        let nsPath = path as NSString
        let directory = nsPath.deletingLastPathComponent
        let filename = nsPath.lastPathComponent as NSString
        let pathExtension = filename.pathExtension
        let stem = filename.deletingPathExtension
        let suffixedFilename = pathExtension.isEmpty
            ? "\(stem)-\(sequence)"
            : "\(stem)-\(sequence).\(pathExtension)"
        return directory.isEmpty || directory == "."
            ? suffixedFilename
            : (directory as NSString).appendingPathComponent(suffixedFilename)
    }

    private func destinationAvailability(
        relativePath: String,
        data: Data,
        root: URL
    ) throws -> DestinationAvailability {
        let url = try safeDestinationURL(relativePath: relativePath, root: root)
        try validateDestinationAncestors(of: url, root: root, resourcePath: relativePath)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return .available
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            return .occupied
        }
        return (try? Data(contentsOf: url, options: [.mappedIfSafe])) == data
            ? .reusable
            : .occupied
    }

    private func safeDestinationURL(relativePath: String, root: URL) throws -> URL {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              !components.contains(""),
              !components.contains("."),
              !components.contains(".."),
              !components.contains(where: { $0.contains("\\") || $0.contains("\0") })
        else {
            throw ExternalMarkdownDocumentError.unsafeResourcePath(relativePath)
        }
        return components.reduce(root) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }.standardizedFileURL
    }

    private func validateDestinationRoot(_ root: URL) throws {
        guard root.isFileURL,
              let attributes = try? fileManager.attributesOfItem(atPath: root.path),
              attributes[.type] as? FileAttributeType == .typeDirectory
        else {
            throw ExternalMarkdownDocumentError.unableToWrite
        }
    }

    private func validateDestinationAncestors(
        of outputURL: URL,
        root: URL,
        resourcePath: String
    ) throws {
        let parent = outputURL.deletingLastPathComponent()
        guard let relativeParent = relativePath(of: parent, under: root) else {
            throw ExternalMarkdownDocumentError.unsafeResourcePath(resourcePath)
        }
        var cursor = root
        for component in relativeParent.split(separator: "/").map(String.init) {
            cursor.appendPathComponent(component, isDirectory: true)
            guard let attributes = try? fileManager.attributesOfItem(atPath: cursor.path) else {
                continue
            }
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw ExternalMarkdownDocumentError.unableToCopyResource(resourcePath)
            }
        }
        let resolvedParent = parent.resolvingSymlinksInPath()
        guard relativePath(of: resolvedParent, under: root) != nil else {
            throw ExternalMarkdownDocumentError.unsafeResourcePath(resourcePath)
        }
    }

    private func createParentDirectories(
        for outputURL: URL,
        root: URL,
        createdDirectories: inout [URL]
    ) throws {
        let resourcePath = relativePath(of: outputURL, under: root) ?? outputURL.lastPathComponent
        try validateDestinationAncestors(
            of: outputURL,
            root: root,
            resourcePath: resourcePath
        )
        guard let relativeParent = relativePath(
            of: outputURL.deletingLastPathComponent(),
            under: root
        ) else {
            throw ExternalMarkdownDocumentError.unsafeResourcePath(resourcePath)
        }
        var cursor = root
        for component in relativeParent.split(separator: "/").map(String.init) {
            cursor.appendPathComponent(component, isDirectory: true)
            if let attributes = try? fileManager.attributesOfItem(atPath: cursor.path) {
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw ExternalMarkdownDocumentError.unableToCopyResource(resourcePath)
                }
                continue
            }
            do {
                try fileManager.createDirectory(
                    at: cursor,
                    withIntermediateDirectories: false
                )
                createdDirectories.append(cursor)
            } catch {
                throw ExternalMarkdownDocumentError.unableToCopyResource(resourcePath)
            }
        }
    }

    private func existingRegularFile(at url: URL, equals data: Data) throws -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return false
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            return false
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe]) == data
    }

    /// Stages bytes beside the destination and creates the final directory entry
    /// with a hard link. `link(2)` fails rather than replacing a concurrent file,
    /// while removing the staging name leaves the successfully linked bytes intact.
    private func writeNewResourceAtomically(
        _ data: Data,
        to destination: URL,
        resourcePath: String
    ) throws -> Bool {
        let stagingURL = destination.deletingLastPathComponent().appendingPathComponent(
            ".markdown-card-save-as-\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: stagingURL) }
        do {
            try data.write(to: stagingURL, options: [.atomic])
            try fileManager.linkItem(at: stagingURL, to: destination)
            return true
        } catch {
            if (try? existingRegularFile(at: destination, equals: data)) == true {
                return false
            }
            throw ExternalMarkdownDocumentError.unableToCopyResource(resourcePath)
        }
    }

    private func rewriteMarkdown(
        _ markdown: String,
        references: [MarkdownSaveAsResourceReference],
        destinationsByReference: [Int: String]
    ) -> String {
        let rewritten = NSMutableString(string: markdown)
        for (index, destination) in destinationsByReference.sorted(
            by: { references[$0.key].sourceRange.location > references[$1.key].sourceRange.location }
        ) {
            rewritten.replaceCharacters(
                in: references[index].sourceRange,
                with: destination
            )
        }
        return rewritten as String
    }

    private func rollbackCreatedResources(files: [URL], directories: [URL]) {
        for file in files.reversed() {
            try? fileManager.removeItem(at: file)
        }
        for directory in directories.reversed() {
            guard (try? fileManager.contentsOfDirectory(atPath: directory.path).isEmpty) == true else {
                continue
            }
            try? fileManager.removeItem(at: directory)
        }
    }

    private func relativePath(of url: URL, under root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        if candidatePath == rootPath { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidatePath.hasPrefix(prefix) else { return nil }
        return String(candidatePath.dropFirst(prefix.count))
    }

    private func validatedFileURL(_ sourceURL: URL) throws -> URL {
        guard sourceURL.isFileURL else {
            throw ExternalMarkdownDocumentError.invalidLocation
        }
        let standardized = sourceURL.standardizedFileURL
        guard Self.supportedFilenameExtensions.contains(standardized.pathExtension.lowercased()) else {
            throw ExternalMarkdownDocumentError.unsupportedFileType
        }
        let resolved = standardized.resolvingSymlinksInPath()
        guard Self.supportedFilenameExtensions.contains(resolved.pathExtension.lowercased()) else {
            throw ExternalMarkdownDocumentError.unsupportedFileType
        }
        return resolved
    }

    private func encodedMarkdown(_ markdown: String) throws -> Data {
        let data = Data(markdown.utf8)
        guard data.count <= maximumDocumentSize else {
            throw ExternalMarkdownDocumentError.documentTooLarge
        }
        return data
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ExternalMarkdownDocumentError.unableToWrite
        }
        if fileManager.fileExists(atPath: destination.path),
           !fileManager.isWritableFile(atPath: destination.path) {
            throw ExternalMarkdownDocumentError.unableToWrite
        }
        let existingPermissions = (try? fileManager.attributesOfItem(atPath: destination.path))?[
            .posixPermissions
        ]
        do {
            try data.write(to: destination, options: [.atomic])
            if let existingPermissions {
                try? fileManager.setAttributes(
                    [.posixPermissions: existingPermissions],
                    ofItemAtPath: destination.path
                )
            }
        } catch {
            throw ExternalMarkdownDocumentError.unableToWrite
        }
    }
}

private struct MarkdownSaveAsResourceReference {
    let sourceRange: NSRange
    let rawSource: String
}

private enum MarkdownSaveAsResourceScanner {
    private struct Fence {
        let marker: Character
        let length: Int
    }

    private static let inlineImageExpression = try! NSRegularExpression(
        pattern: #"(?<!\\)!\[(?:\\.|[^\]\r\n])*\]\(\s*(?:<([^>\r\n]+)>|((?:\\.|[^\s)\r\n])+))"#
    )
    private static let HTMLImageExpression = try! NSRegularExpression(
        pattern: #"<img\b[^>]*?\bsrc\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#,
        options: [.caseInsensitive]
    )
    private static let fullReferenceImageExpression = try! NSRegularExpression(
        pattern: #"(?<!\\)!\[((?:\\.|[^\]\r\n])*)\][ \t]*\[((?:\\.|[^\]\r\n])*)\]"#
    )
    private static let shortcutReferenceImageExpression = try! NSRegularExpression(
        pattern: #"(?<!\\)!\[((?:\\.|[^\]\r\n])+)\](?![ \t]*(?:\(|\[))"#
    )
    private static let referenceDefinitionExpression = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]{0,3}\[((?:\\.|[^\]\r\n])+)\]:[ \t]*(?:<([^>\r\n]+)>|((?:\\.|[^\s\r\n])+))"#
    )

    static func references(in markdown: String) -> [MarkdownSaveAsResourceReference] {
        let source = markdown as NSString
        let wholeRange = NSRange(location: 0, length: source.length)
        let ignoredRanges = codeRanges(in: source)
        var referencesByRange: [String: MarkdownSaveAsResourceReference] = [:]

        func isIgnored(_ range: NSRange) -> Bool {
            ignoredRanges.contains { NSIntersectionRange($0, range).length > 0 }
        }

        func appendMatches(
            expression: NSRegularExpression,
            sourceCaptureGroups: [Int]
        ) {
            for match in expression.matches(in: markdown, range: wholeRange) {
                guard !isIgnored(match.range) else { continue }
                guard let sourceRange = sourceCaptureGroups
                    .map({ match.range(at: $0) })
                    .first(where: { $0.location != NSNotFound })
                else { continue }
                let key = "\(sourceRange.location):\(sourceRange.length)"
                referencesByRange[key] = MarkdownSaveAsResourceReference(
                    sourceRange: sourceRange,
                    rawSource: source.substring(with: sourceRange)
                )
            }
        }

        appendMatches(expression: inlineImageExpression, sourceCaptureGroups: [1, 2])
        appendMatches(expression: HTMLImageExpression, sourceCaptureGroups: [1, 2, 3])

        var imageReferenceLabels = Set<String>()
        for match in fullReferenceImageExpression.matches(in: markdown, range: wholeRange) {
            guard !isIgnored(match.range) else { continue }
            let alternativeRange = match.range(at: 1)
            let explicitLabelRange = match.range(at: 2)
            let rawLabel = explicitLabelRange.location != NSNotFound
                && explicitLabelRange.length > 0
                ? source.substring(with: explicitLabelRange)
                : source.substring(with: alternativeRange)
            imageReferenceLabels.insert(normalizedReferenceLabel(rawLabel))
        }
        for match in shortcutReferenceImageExpression.matches(in: markdown, range: wholeRange) {
            guard !isIgnored(match.range) else { continue }
            imageReferenceLabels.insert(
                normalizedReferenceLabel(source.substring(with: match.range(at: 1)))
            )
        }

        for match in referenceDefinitionExpression.matches(in: markdown, range: wholeRange) {
            guard !isIgnored(match.range),
                  imageReferenceLabels.contains(
                      normalizedReferenceLabel(source.substring(with: match.range(at: 1)))
                  )
            else { continue }
            guard let sourceRange = [match.range(at: 2), match.range(at: 3)]
                .first(where: { $0.location != NSNotFound })
            else { continue }
            let key = "\(sourceRange.location):\(sourceRange.length)"
            referencesByRange[key] = MarkdownSaveAsResourceReference(
                sourceRange: sourceRange,
                rawSource: source.substring(with: sourceRange)
            )
        }

        return referencesByRange.values.sorted {
            if $0.sourceRange.location == $1.sourceRange.location {
                return $0.sourceRange.length < $1.sourceRange.length
            }
            return $0.sourceRange.location < $1.sourceRange.location
        }
    }

    private static func normalizedReferenceLabel(_ rawLabel: String) -> String {
        let unescaped = rawLabel.replacingOccurrences(
            of: #"\\(.)"#,
            with: "$1",
            options: .regularExpression
        )
        return unescaped
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private static func codeRanges(in source: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var activeFence: Fence?
        var location = 0
        while location < source.length {
            let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
            let line = source.substring(with: lineRange)
                .trimmingCharacters(in: .newlines)
            if let fence = activeFence {
                ranges.append(lineRange)
                if isClosingFence(line, matching: fence) {
                    activeFence = nil
                }
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

    private static func openingFence(in line: String) -> Fence? {
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
        return Fence(marker: marker, length: end - index)
    }

    private static func isClosingFence(_ line: String, matching fence: Fence) -> Bool {
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
}

final class CardFileBindingStore: @unchecked Sendable {
    private static let keyPrefix = "MarkdownCardFileBinding."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func binding(for cardID: UUID) -> CardFileBinding? {
        guard let data = defaults.data(forKey: key(for: cardID)) else { return nil }
        return try? JSONDecoder().decode(CardFileBinding.self, from: data)
    }

    func fileURL(for cardID: UUID) -> URL? {
        binding(for: cardID)?.fileURL
    }

    func documentRootURL(for cardID: UUID) -> URL? {
        fileURL(for: cardID)?.deletingLastPathComponent().standardizedFileURL
    }

    func set(_ binding: CardFileBinding, for cardID: UUID) {
        guard let data = try? JSONEncoder().encode(binding) else { return }
        defaults.set(data, forKey: key(for: cardID))
    }

    func removeBinding(for cardID: UUID) {
        defaults.removeObject(forKey: key(for: cardID))
    }

    private func key(for cardID: UUID) -> String {
        Self.keyPrefix + cardID.uuidString.lowercased()
    }
}
