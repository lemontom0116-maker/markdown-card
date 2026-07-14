import Foundation
import ImageIO
import UniformTypeIdentifiers

enum LocalAttachmentError: LocalizedError, Equatable {
    case unsupportedType
    case inputTooLarge
    case invalidImage
    case imageTooLarge
    case encodingFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedType:
            "Only PNG, JPEG, GIF, HEIC, TIFF, and WebP clipboard images are supported."
        case .inputTooLarge:
            "The clipboard image is larger than the 16 MiB attachment limit."
        case .invalidImage:
            "The clipboard does not contain a valid image."
        case .imageTooLarge:
            "The clipboard image dimensions exceed the 8192-pixel attachment limit."
        case .encodingFailed:
            "The clipboard image could not be converted to PNG."
        case .writeFailed:
            "The image attachment could not be saved."
        }
    }
}

final class LocalAttachmentStore: @unchecked Sendable {
    static let markdownDirectory = "attachments"
    static let maximumInputSize = 16 * 1_024 * 1_024
    static let maximumOutputSize = 24 * 1_024 * 1_024
    static let maximumPixelDimension = 8_192

    private static let supportedMIMETypes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/jpg",
        "image/gif",
        "image/heic",
        "image/heif",
        "image/tiff",
        "image/webp",
    ]

    private let fileManager: FileManager
    let directory: URL

    var standardizedDirectoryFileURL: URL {
        directory.standardizedFileURL
    }

    init(fileManager: FileManager = .default, directory: URL? = nil) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else if let configuredDirectory = ProcessInfo.processInfo.environment[
            "MARKDOWN_CARD_ATTACHMENTS_URL"
        ], !configuredDirectory.isEmpty {
            self.directory = URL(fileURLWithPath: configuredDirectory, isDirectory: true)
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.temporaryDirectory
            self.directory = applicationSupport
                .appendingPathComponent("Markdown Card", isDirectory: true)
                .appendingPathComponent(Self.markdownDirectory, isDirectory: true)
        }
    }

    func saveClipboardImage(data: Data, mimeType: String) throws -> String {
        let normalizedMIME = mimeType.lowercased()
        guard Self.supportedMIMETypes.contains(normalizedMIME) else {
            throw LocalAttachmentError.unsupportedType
        }
        guard data.count <= Self.maximumInputSize else {
            throw LocalAttachmentError.inputTooLarge
        }
        guard let png = Self.validatedPNG(from: data) else {
            throw LocalAttachmentError.invalidImage
        }
        guard png.count <= Self.maximumOutputSize else {
            throw LocalAttachmentError.encodingFailed
        }

        let filename = "\(UUID().uuidString.lowercased()).png"
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(
                to: directory.appendingPathComponent(filename, isDirectory: false),
                options: [.atomic]
            )
        } catch {
            throw LocalAttachmentError.writeFailed
        }
        return "\(Self.markdownDirectory)/\(filename)"
    }

    func data(forAttachmentID attachmentID: String) -> Data? {
        guard Self.isValidAttachmentID(attachmentID) else { return nil }
        let url = directory.appendingPathComponent("\(attachmentID).png", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              data.count <= Self.maximumOutputSize,
              Self.validatedPNG(from: data) != nil
        else { return nil }
        return data
    }

    static func attachmentID(fromMarkdownSource source: String) -> String? {
        let prefix = "\(markdownDirectory)/"
        guard source.hasPrefix(prefix), source.hasSuffix(".png") else { return nil }
        let start = source.index(source.startIndex, offsetBy: prefix.count)
        let end = source.index(source.endIndex, offsetBy: -4)
        let identifier = String(source[start..<end])
        return isValidAttachmentID(identifier) ? identifier : nil
    }

    static func isValidAttachmentID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
            && value.range(of: #"^[A-Fa-f0-9-]{36}$"#, options: .regularExpression) != nil
    }

    static func validatedPNG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.intValue > 0,
              height.intValue > 0,
              width.intValue <= maximumPixelDimension,
              height.intValue <= maximumPixelDimension,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
