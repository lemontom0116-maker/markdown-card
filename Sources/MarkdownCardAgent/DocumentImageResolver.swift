import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct DocumentImageAsset: Equatable, Sendable {
    let data: Data
    let mimeType: String
}

enum DocumentImageResolverError: Error, Equatable {
    case invalidRequest
    case pathEscapesDocumentRoot
    case missingFile
    case unsupportedType
    case fileTooLarge
    case invalidImage
    case imageTooLarge
}

struct DocumentImageRequest: Equatable, Sendable {
    let cardID: UUID
    let relativePath: String

    static func parse(_ url: URL?) -> Self? {
        guard let url,
              url.scheme?.lowercased() == YouTubeThumbnailSchemeHandler.scheme,
              url.host?.lowercased() == YouTubeThumbnailSchemeHandler.documentHost,
              let cardID = UUID(
                  uuidString: url.path.trimmingCharacters(
                      in: CharacterSet(charactersIn: "/")
                  )
              ),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        let paths = components.queryItems?.filter { $0.name == "path" } ?? []
        guard paths.count == 1,
              let relativePath = paths[0].value,
              !relativePath.isEmpty,
              relativePath.utf8.count <= 4_096
        else { return nil }
        return Self(cardID: cardID, relativePath: relativePath)
    }
}

final class DocumentImageResolver: @unchecked Sendable {
    static let maximumInputSize = 16 * 1_024 * 1_024
    static let maximumPixelDimension = 8_192
    static let maximumTotalPixels: Int64 = 40_000_000
    static let maximumAnimatedFrameCount = 120
    static let maximumAnimatedPixelBudget: Int64 = 100_000_000
    static let allowedMIMETypes: Set<String> = [
        "image/png",
        "image/jpeg",
        "image/gif",
        "image/webp",
        "image/svg+xml",
    ]

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func load(relativePath: String, documentRoot: URL) throws -> DocumentImageAsset {
        let fileURL = try resolvedFileURL(
            relativePath: relativePath,
            documentRoot: documentRoot
        )
        let data = try secureRead(fileURL: fileURL, documentRoot: documentRoot)
        guard data.count <= Self.maximumInputSize,
              !data.isEmpty
        else {
            throw DocumentImageResolverError.invalidImage
        }
        if fileURL.pathExtension.lowercased() == "svg" {
            return try validatedSVG(data)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let typeIdentifier = CGImageSourceGetType(source),
              let mimeType = Self.mimeType(for: typeIdentifier as String),
              Self.allowedMIMETypes.contains(mimeType)
        else {
            throw DocumentImageResolverError.invalidImage
        }
        try Self.validateRasterBudget(source)
        return DocumentImageAsset(data: data, mimeType: mimeType)
    }

    private func secureRead(fileURL: URL, documentRoot: URL) throws -> Data {
        let root = documentRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
        else { throw DocumentImageResolverError.pathEscapesDocumentRoot }

        var descriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw DocumentImageResolverError.missingFile }

        let relativeComponents = candidateComponents.dropFirst(rootComponents.count)
        for (index, component) in relativeComponents.enumerated() {
            let isFinal = index == relativeComponents.count - 1
            let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (isFinal ? 0 : O_DIRECTORY)
            let next = component.withCString { pointer in
                Darwin.openat(descriptor, pointer, flags)
            }
            Darwin.close(descriptor)
            guard next >= 0 else { throw DocumentImageResolverError.missingFile }
            descriptor = next
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0
        else { throw DocumentImageResolverError.missingFile }
        guard status.st_size <= off_t(Self.maximumInputSize) else {
            throw DocumentImageResolverError.fileTooLarge
        }

        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        do {
            while data.count <= Self.maximumInputSize {
                let remaining = Self.maximumInputSize + 1 - data.count
                guard remaining > 0,
                      let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                      !chunk.isEmpty
                else { break }
                data.append(chunk)
            }
        } catch {
            throw DocumentImageResolverError.missingFile
        }
        guard data.count <= Self.maximumInputSize else {
            throw DocumentImageResolverError.fileTooLarge
        }
        return data
    }

    private static func validateRasterBudget(_ source: CGImageSource) throws {
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { throw DocumentImageResolverError.invalidImage }
        guard frameCount <= maximumAnimatedFrameCount else {
            throw DocumentImageResolverError.imageTooLarge
        }

        var animatedPixelBudget: Int64 = 0
        for index in 0..<frameCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                    as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.intValue > 0,
                  height.intValue > 0
            else { throw DocumentImageResolverError.invalidImage }

            guard let pixels = checkedPixelCount(width: width.intValue, height: height.intValue)
            else { throw DocumentImageResolverError.imageTooLarge }
            guard let nextBudget = checkedAnimatedPixelBudget(
                current: animatedPixelBudget,
                adding: pixels,
                frameCount: frameCount
            ) else { throw DocumentImageResolverError.imageTooLarge }
            animatedPixelBudget = nextBudget
        }
    }

    static func checkedPixelCount(width: Int, height: Int) -> Int64? {
        guard width > 0, height > 0,
              width <= maximumPixelDimension,
              height <= maximumPixelDimension
        else { return nil }
        let (pixels, overflow) = Int64(width).multipliedReportingOverflow(by: Int64(height))
        guard !overflow, pixels <= maximumTotalPixels else { return nil }
        return pixels
    }

    static func checkedAnimatedPixelBudget(
        current: Int64,
        adding pixels: Int64,
        frameCount: Int
    ) -> Int64? {
        guard current >= 0, pixels >= 0 else { return nil }
        let (nextBudget, overflow) = current.addingReportingOverflow(pixels)
        guard !overflow,
              frameCount == 1 || nextBudget <= maximumAnimatedPixelBudget
        else { return nil }
        return nextBudget
    }

    private static func mimeType(for typeIdentifier: String) -> String? {
        guard let type = UTType(typeIdentifier) else { return nil }
        if type.conforms(to: .png) { return "image/png" }
        if type.conforms(to: .jpeg) { return "image/jpeg" }
        if type.conforms(to: .gif) { return "image/gif" }
        if type.conforms(to: .webP) { return "image/webp" }
        return type.preferredMIMEType?.lowercased()
    }

    private func validatedSVG(_ data: Data) throws -> DocumentImageAsset {
        guard let source = String(data: data, encoding: .utf8),
              let metrics = SafeSVGValidator.validate(data: data, source: source)
        else {
            throw DocumentImageResolverError.invalidImage
        }
        let resolvedWidth = metrics.width ?? metrics.viewBox?.width
        let resolvedHeight = metrics.height ?? metrics.viewBox?.height
        guard let resolvedWidth, let resolvedHeight,
              resolvedWidth.isFinite, resolvedHeight.isFinite,
              resolvedWidth > 0, resolvedHeight > 0,
              resolvedWidth.rounded(.up) <= Double(Int.max),
              resolvedHeight.rounded(.up) <= Double(Int.max)
        else {
            throw DocumentImageResolverError.invalidImage
        }
        guard Self.checkedPixelCount(
            width: Int(resolvedWidth.rounded(.up)),
            height: Int(resolvedHeight.rounded(.up))
        ) != nil
        else {
            throw DocumentImageResolverError.imageTooLarge
        }
        return DocumentImageAsset(data: data, mimeType: "image/svg+xml")
    }

    func resolvedFileURL(relativePath: String, documentRoot: URL) throws -> URL {
        let decodedRelativePath = relativePath.removingPercentEncoding ?? relativePath
        guard documentRoot.isFileURL,
              !decodedRelativePath.isEmpty,
              !decodedRelativePath.hasPrefix("/"),
              !decodedRelativePath.hasPrefix("~"),
              !decodedRelativePath.contains("\\"),
              !decodedRelativePath.contains("\0")
        else {
            throw DocumentImageResolverError.invalidRequest
        }

        let pathComponents = NSString(string: decodedRelativePath).pathComponents.filter { $0 != "." }
        guard !pathComponents.isEmpty,
              pathComponents.allSatisfy({ component in
                  component != ".." && component != "/"
              })
        else {
            throw DocumentImageResolverError.pathEscapesDocumentRoot
        }

        let root = documentRoot
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let candidate = pathComponents.reduce(root) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw DocumentImageResolverError.pathEscapesDocumentRoot
        }
        return candidate
    }
}

private struct SVGDocumentMetrics {
    let width: Double?
    let height: Double?
    let viewBox: (width: Double, height: Double)?
}

/// Parses a deliberately small, passive SVG profile. An allowlist keeps active
/// content and resource-loading elements out; CSS blocks and inline styles are
/// not accepted at all, so escaped `url()` or `@import` spellings never reach a
/// CSS parser.
private final class SafeSVGValidator: NSObject, XMLParserDelegate {
    private static let svgNamespace = "http://www.w3.org/2000/svg"
    private static let maximumElementCount = 50_000

    private static let allowedElements: Set<String> = [
        "circle", "clippath", "defs", "desc", "ellipse", "g", "line",
        "lineargradient", "marker", "mask", "path", "pattern", "polygon",
        "polyline", "radialgradient", "rect", "stop", "svg", "symbol",
        "text", "title", "tspan", "use",
    ]
    private static let allowedAttributes: Set<String> = [
        "aria-label", "aria-labelledby", "class", "clip-path", "clip-rule",
        "cx", "cy", "d", "dominant-baseline", "dx", "dy", "fill",
        "fill-opacity", "fill-rule", "focusable", "font-family", "font-size",
        "font-style", "font-weight", "gradienttransform", "gradientunits",
        "height", "href", "id", "marker-end", "marker-mid", "marker-start",
        "markerheight", "markerunits", "markerwidth", "mask", "offset",
        "opacity", "orient", "patterncontentunits", "patterntransform",
        "patternunits", "points", "preserveaspectratio", "refx", "refy",
        "role", "r", "rx", "ry", "space", "spreadmethod", "stop-color",
        "stop-opacity", "stroke", "stroke-dasharray", "stroke-dashoffset",
        "stroke-linecap", "stroke-linejoin", "stroke-opacity", "stroke-width",
        "text-anchor", "transform", "version", "viewbox", "width", "x",
        "x1", "x2", "y", "y1", "y2",
    ]
    private static let strictLocalReferenceAttributes: Set<String> = [
        "clip-path", "marker-end", "marker-mid", "marker-start", "mask",
    ]

    private var valid = true
    private var depth = 0
    private var sawRoot = false
    private var elementCount = 0
    private var width: Double?
    private var height: Double?
    private var viewBox: (width: Double, height: Double)?

    static func validate(data: Data, source: String) -> SVGDocumentMetrics? {
        // XMLParser has no portable "did see a doctype" callback. This token is
        // fixed by the XML grammar (entities cannot hide it), while the parser
        // delegate below independently rejects every entity declaration.
        guard source.range(of: "<!doctype", options: .caseInsensitive) == nil else {
            return nil
        }
        let validator = SafeSVGValidator()
        let parser = XMLParser(data: data)
        parser.delegate = validator
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), validator.valid, validator.sawRoot, validator.depth == 0 else {
            return nil
        }
        return SVGDocumentMetrics(
            width: validator.width,
            height: validator.height,
            viewBox: validator.viewBox
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        guard valid else { return }
        elementCount += 1
        guard elementCount <= Self.maximumElementCount else {
            valid = false
            return
        }

        let name = elementName.lowercased()
        if depth == 0 {
            guard !sawRoot,
                  name == "svg",
                  namespaceURI == nil || namespaceURI?.isEmpty == true
                    || namespaceURI == Self.svgNamespace
            else {
                valid = false
                return
            }
            sawRoot = true
        } else if !Self.allowedElements.contains(name) || name == "svg" {
            valid = false
            return
        }

        for (rawName, value) in attributeDict {
            let attribute = Self.localName(rawName)
            if rawName.lowercased().hasPrefix("xmlns") {
                continue
            }
            guard Self.allowedAttributes.contains(attribute),
                  Self.isSafeAttribute(name: attribute, value: value)
            else {
                valid = false
                return
            }
        }

        if depth == 0 {
            width = attributeDict.firstValue(named: "width").flatMap(Self.svgNumber)
            height = attributeDict.firstValue(named: "height").flatMap(Self.svgNumber)
            viewBox = attributeDict.firstValue(named: "viewBox").flatMap(Self.svgViewBox)
        }
        depth += 1
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard valid, depth > 0 else { return }
        depth -= 1
    }

    func parser(
        _ parser: XMLParser,
        foundProcessingInstructionWithTarget target: String,
        data: String?
    ) {
        valid = false
    }

    func parser(
        _ parser: XMLParser,
        foundInternalEntityDeclarationWithName name: String,
        value: String?
    ) {
        valid = false
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        valid = false
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        valid = false
        return nil
    }

    private static func localName(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }

    private static func isSafeAttribute(name: String, value: String) -> Bool {
        guard !value.contains("\\"),
              value.unicodeScalars.allSatisfy({ scalar in
                  scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D
                    || scalar.value >= 0x20
              })
        else { return false }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "href" {
            return isLocalFragment(trimmed)
        }
        if strictLocalReferenceAttributes.contains(name) {
            return trimmed.caseInsensitiveCompare("none") == .orderedSame
                || isLocalURLFunction(trimmed)
        }
        if name == "fill" || name == "stroke" {
            return isSafePaint(trimmed)
        }
        // No other accepted attribute is interpreted as CSS or a resource URL.
        return trimmed.range(of: "url(", options: .caseInsensitive) == nil
            && trimmed.range(of: "@import", options: .caseInsensitive) == nil
    }

    private static func isSafePaint(_ value: String) -> Bool {
        if isLocalURLFunction(value) { return true }
        if value.range(of: "url", options: .caseInsensitive) != nil
            || value.contains("/") || value.contains("(") && !isNumericColorFunction(value)
        {
            return false
        }
        return value.range(
            of: #"^(?:none|currentColor|transparent|#[0-9A-Fa-f]{3,8}|[A-Za-z]+)$"#,
            options: .regularExpression
        ) != nil || isNumericColorFunction(value)
    }

    private static func isNumericColorFunction(_ value: String) -> Bool {
        value.range(
            of: #"^(?:rgb|rgba|hsl|hsla)\([+\-0-9.,% ]+\)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isLocalURLFunction(_ value: String) -> Bool {
        value.range(
            of: #"^url\(\s*#[A-Za-z_][A-Za-z0-9_.:-]*\s*\)$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isLocalFragment(_ value: String) -> Bool {
        value.range(
            of: #"^#[A-Za-z_][A-Za-z0-9_.:-]*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func svgNumber(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(
            of: #"^[0-9]+(?:\.[0-9]+)?(?:px)?$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else { return nil }
        let number = trimmed.lowercased().hasSuffix("px")
            ? String(trimmed.dropLast(2))
            : trimmed
        return Double(number)
    }

    private static func svgViewBox(_ value: String) -> (width: Double, height: Double)? {
        let values = value.split { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "," }
        guard values.count == 4,
              let width = Double(values[2]),
              let height = Double(values[3]),
              width.isFinite, height.isFinite,
              width > 0, height > 0
        else { return nil }
        return (width, height)
    }
}

private extension Dictionary where Key == String, Value == String {
    func firstValue(named wanted: String) -> String? {
        first { key, _ in
            (key.split(separator: ":").last.map(String.init) ?? key)
                .caseInsensitiveCompare(wanted) == .orderedSame
        }?.value
    }
}
