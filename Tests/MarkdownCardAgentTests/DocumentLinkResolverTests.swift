import Foundation
import XCTest
@testable import MarkdownCardAgent

final class DocumentLinkResolverTests: XCTestCase {
    func testResolvesRootConfinedFileAndPreservesLineFragment() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentLinkResolverTests-\(UUID().uuidString)")
        let source = root.appendingPathComponent("src/model.py")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("one\ntwo\n".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        let link = try DocumentLinkResolver().resolve("./src/model.py#L2", documentRoot: root)

        XCTAssertEqual(link.fileURL, source.standardizedFileURL)
        XCTAssertEqual(link.fragment, "L2")
    }

    func testRejectsTraversalSymlinkEscapeAndExternalURLs() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentLinkEscapeTests-\(UUID().uuidString)")
        let root = parent.appendingPathComponent("docs")
        let secret = parent.appendingPathComponent("secret.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.txt"),
            withDestinationURL: secret
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let resolver = DocumentLinkResolver()

        XCTAssertThrowsError(try resolver.resolve("../secret.txt", documentRoot: root))
        XCTAssertThrowsError(try resolver.resolve("./escape.txt", documentRoot: root))
        XCTAssertThrowsError(try resolver.resolve("https://example.com", documentRoot: root))
    }

    func testOnlyFragmentLinksRequestSourcePreview() {
        let file = URL(fileURLWithPath: "/tmp/guide.md")

        XCTAssertFalse(DocumentLinkCoordinator.requiresSourcePreview(for: .init(
            fileURL: file,
            fragment: nil
        )))
        XCTAssertTrue(DocumentLinkCoordinator.requiresSourcePreview(for: .init(
            fileURL: file,
            fragment: "L12"
        )))
    }

    func testSourcePreviewReadsThroughSizeCheckedConfinedDescriptor() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentLinkReadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("guide.md")
        try Data("# Guide\nbody\n".utf8).write(to: source)

        XCTAssertEqual(
            DocumentLinkCoordinator.readSourceText(fileURL: source, documentRoot: root),
            "# Guide\nbody\n"
        )

        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("secret".utf8).write(to: outside)
        XCTAssertNil(DocumentLinkCoordinator.readSourceText(
            fileURL: outside,
            documentRoot: root
        ))
    }

    func testSourcePreviewRejectsFileLargerThanPreviewBudgetBeforeReading() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentLinkLargeReadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large.md")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(
            atOffset: UInt64(DocumentLinkCoordinator.maximumSourcePreviewSize + 1)
        )
        try handle.close()

        XCTAssertNil(DocumentLinkCoordinator.readSourceText(
            fileURL: source,
            documentRoot: root
        ))
    }
}
