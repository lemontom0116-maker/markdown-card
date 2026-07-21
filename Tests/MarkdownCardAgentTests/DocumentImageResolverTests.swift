import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import MarkdownCardAgent

final class DocumentImageResolverTests: XCTestCase {
    func testDocumentImageRequestParsesOneEncodedRelativePath() throws {
        let cardID = UUID()
        var components = URLComponents()
        components.scheme = YouTubeThumbnailSchemeHandler.scheme
        components.host = YouTubeThumbnailSchemeHandler.documentHost
        components.path = "/\(cardID.uuidString)"
        components.queryItems = [URLQueryItem(name: "path", value: "images/注意力 flow.png")]

        let request = try XCTUnwrap(DocumentImageRequest.parse(components.url))
        XCTAssertEqual(request.cardID, cardID)
        XCTAssertEqual(request.relativePath, "images/注意力 flow.png")
    }

    func testLoadsValidatedRasterImageInsideDocumentRoot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let imageDirectory = fixture.root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(
            at: imageDirectory,
            withIntermediateDirectories: true
        )
        let imageURL = imageDirectory.appendingPathComponent("pixel.png")
        try fixture.png.write(to: imageURL, options: .atomic)

        let asset = try DocumentImageResolver().load(
            relativePath: "./images/pixel.png",
            documentRoot: fixture.root
        )
        XCTAssertEqual(asset.mimeType, "image/png")
        XCTAssertEqual(asset.data, fixture.png)
    }

    func testLoadsPercentEncodedFilenameAndStillRejectsEncodedTraversal() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let imageDirectory = fixture.root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(
            at: imageDirectory,
            withIntermediateDirectories: true
        )
        try fixture.png.write(
            to: imageDirectory.appendingPathComponent("attention flow.png"),
            options: .atomic
        )
        let resolver = DocumentImageResolver()

        let asset = try resolver.load(
            relativePath: "images/attention%20flow.png",
            documentRoot: fixture.root
        )
        XCTAssertEqual(asset.data, fixture.png)
        XCTAssertThrowsError(try resolver.resolvedFileURL(
            relativePath: "%2E%2E/outside.png",
            documentRoot: fixture.root
        )) { error in
            XCTAssertEqual(error as? DocumentImageResolverError, .pathEscapesDocumentRoot)
        }
        XCTAssertThrowsError(try resolver.resolvedFileURL(
            relativePath: "images%5Coutside.png",
            documentRoot: fixture.root
        )) { error in
            XCTAssertEqual(error as? DocumentImageResolverError, .invalidRequest)
        }
    }

    func testLoadsJPEGGIFAndWebPFixturesThroughImageIO() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let formats: [(UTType, String, String)] = [
            (.jpeg, "photo.jpg", "image/jpeg"),
            (.gif, "animation.gif", "image/gif"),
            (.webP, "diagram.webp", "image/webp"),
        ]
        for (type, filename, mimeType) in formats {
            let data = try encodedPixel(type: type)
            try data.write(to: fixture.root.appendingPathComponent(filename), options: .atomic)

            let asset = try DocumentImageResolver().load(
                relativePath: filename,
                documentRoot: fixture.root
            )

            XCTAssertEqual(asset.mimeType, mimeType)
            XCTAssertFalse(asset.data.isEmpty)
        }
    }

    func testRejectsRasterDimensionsThatExceedTotalPixelBudget() {
        XCTAssertNotNil(DocumentImageResolver.checkedPixelCount(width: 8_000, height: 5_000))
        XCTAssertNil(DocumentImageResolver.checkedPixelCount(width: 8_192, height: 8_192))
        XCTAssertNil(DocumentImageResolver.checkedPixelCount(width: 8_193, height: 1))
        XCTAssertNotNil(DocumentImageResolver.checkedAnimatedPixelBudget(
            current: 60_000_000,
            adding: 40_000_000,
            frameCount: 2
        ))
        XCTAssertNil(DocumentImageResolver.checkedAnimatedPixelBudget(
            current: 60_000_001,
            adding: 40_000_000,
            frameCount: 2
        ))
    }

    func testRejectsAnimatedImagePastFrameBudget() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let animation = try encodedAnimation(
            frameCount: DocumentImageResolver.maximumAnimatedFrameCount + 1
        )
        try animation.write(
            to: fixture.root.appendingPathComponent("too-many-frames.gif"),
            options: .atomic
        )

        XCTAssertThrowsError(try DocumentImageResolver().load(
            relativePath: "too-many-frames.gif",
            documentRoot: fixture.root
        )) { error in
            XCTAssertEqual(error as? DocumentImageResolverError, .imageTooLarge)
        }
    }

    func testRejectsParentTraversalAndAbsolutePaths() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resolver = DocumentImageResolver()

        XCTAssertThrowsError(
            try resolver.resolvedFileURL(
                relativePath: "../outside.png",
                documentRoot: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? DocumentImageResolverError, .pathEscapesDocumentRoot)
        }
        XCTAssertThrowsError(
            try resolver.resolvedFileURL(
                relativePath: "/tmp/outside.png",
                documentRoot: fixture.root
            )
        ) { error in
            XCTAssertEqual(error as? DocumentImageResolverError, .invalidRequest)
        }
    }

    func testRejectsSymlinkThatEscapesDocumentRoot() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let outside = fixture.root
            .deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outside) }
        try fixture.png.write(to: outside, options: .atomic)
        let link = fixture.root.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(
            try DocumentImageResolver().load(
                relativePath: "linked.png",
                documentRoot: fixture.root
            )
        ) { error in
            XCTAssertEqual(
                error as? DocumentImageResolverError,
                .pathEscapesDocumentRoot
            )
        }
    }

    func testAcceptsConservativeOfflineSVG() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let svg = fixture.root.appendingPathComponent("diagram.svg")
        let data = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 640 320\"><rect width=\"10\" height=\"10\"/></svg>".utf8)
        try data
            .write(to: svg, options: .atomic)

        let asset = try DocumentImageResolver().load(
            relativePath: "diagram.svg",
            documentRoot: fixture.root
        )

        XCTAssertEqual(asset.mimeType, "image/svg+xml")
        XCTAssertEqual(asset.data, data)
    }

    func testRejectsScriptedOrExternallyLinkedSVG() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for (name, source) in [
            ("script.svg", "<svg viewBox=\"0 0 10 10\"><script>alert(1)</script></svg>"),
            ("remote.svg", "<svg viewBox=\"0 0 10 10\"><image href=\"https://example.com/x.png\"/></svg>"),
        ] {
            try Data(source.utf8).write(
                to: fixture.root.appendingPathComponent(name),
                options: .atomic
            )
            XCTAssertThrowsError(
                try DocumentImageResolver().load(relativePath: name, documentRoot: fixture.root)
            ) { error in
                XCTAssertEqual(error as? DocumentImageResolverError, .invalidImage)
            }
        }
    }

    func testRejectsSVGStyleCSSObfuscationAndEntityDeclarations() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cases = [
            ("style-element.svg", "<svg viewBox=\"0 0 10 10\"><style>rect { fill: red }</style><rect/></svg>"),
            ("style-attribute.svg", "<svg viewBox=\"0 0 10 10\"><rect style=\"fill:red\"/></svg>"),
            ("escaped-url.svg", "<svg viewBox=\"0 0 10 10\"><rect fill=\"u\\\\72l(https://example.com/x)\"/></svg>"),
            ("entity.svg", "<!DOCTYPE svg [<!ENTITY xxe SYSTEM \"file:///etc/passwd\">]><svg viewBox=\"0 0 10 10\"><text>&xxe;</text></svg>"),
        ]
        for (name, source) in cases {
            try Data(source.utf8).write(
                to: fixture.root.appendingPathComponent(name),
                options: .atomic
            )
            XCTAssertThrowsError(
                try DocumentImageResolver().load(relativePath: name, documentRoot: fixture.root),
                "Expected \(name) to be rejected"
            ) { error in
                XCTAssertEqual(error as? DocumentImageResolverError, .invalidImage)
            }
        }
    }

    func testAllowsOnlyLocalSVGPaintReferencesAndEnforcesPixelArea() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let local = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 640 320\"><defs><linearGradient id=\"fade\"><stop offset=\"0\" stop-color=\"#fff\"/></linearGradient></defs><rect width=\"10\" height=\"10\" fill=\"url(#fade)\"/></svg>"
        try Data(local.utf8).write(
            to: fixture.root.appendingPathComponent("local-gradient.svg"),
            options: .atomic
        )
        XCTAssertNoThrow(try DocumentImageResolver().load(
            relativePath: "local-gradient.svg",
            documentRoot: fixture.root
        ))

        let excessive = "<svg viewBox=\"0 0 8192 8192\"><rect width=\"1\" height=\"1\"/></svg>"
        try Data(excessive.utf8).write(
            to: fixture.root.appendingPathComponent("too-many-pixels.svg"),
            options: .atomic
        )
        XCTAssertThrowsError(try DocumentImageResolver().load(
            relativePath: "too-many-pixels.svg",
            documentRoot: fixture.root
        )) { error in
            XCTAssertEqual(error as? DocumentImageResolverError, .imageTooLarge)
        }
    }

    private func makeFixture() throws -> (root: URL, png: Data) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentImageResolverTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z0b8AAAAASUVORK5CYII="
        return (root, try XCTUnwrap(Data(base64Encoded: encoded)))
    }

    private func encodedPixel(type: UTType) throws -> Data {
        if type == .webP {
            return try XCTUnwrap(Data(base64Encoded:
                "UklGRhIAAABXRUJQVlA4TAYAAAAvAAAAAAfQ//73v/+BiOh/AAA="
            ))
        }
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func encodedAnimation(frameCount: Int) throws -> Data {
        let frameData = try encodedPixel(type: .gif)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(frameData as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output,
            UTType.gif.identifier as CFString,
            frameCount,
            nil
        ))
        for _ in 0..<frameCount {
            CGImageDestinationAddImage(destination, image, nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
