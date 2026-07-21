import AppKit
import MarkdownCardCore
import XCTest
@testable import MarkdownCardAgent

final class ExternalMarkdownDocumentServiceTests: XCTestCase {
    func testOpenAcceptsUTF8MarkdownExtensionsAndComputesDigest() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ExternalMarkdownDocumentService()

        for filename in ["lesson.md", "lesson.markdown"] {
            let url = root.appendingPathComponent(filename)
            let markdown = "# 并发教程\n\n`async let`"
            try Data(markdown.utf8).write(to: url)

            let document = try service.open(url)

            XCTAssertEqual(document.fileURL, url.standardizedFileURL.resolvingSymlinksInPath())
            XCTAssertEqual(document.markdown, markdown)
            XCTAssertEqual(document.digest, ExternalMarkdownDocumentService.digest(Data(markdown.utf8)))
        }
    }

    func testOpenRejectsUnsupportedTypeInvalidUTF8AndOversizedDocument() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ExternalMarkdownDocumentService(maximumDocumentSize: 8)
        let textURL = root.appendingPathComponent("notes.txt")
        try Data("text".utf8).write(to: textURL)
        XCTAssertThrowsError(try service.open(textURL)) {
            XCTAssertEqual($0 as? ExternalMarkdownDocumentError, .unsupportedFileType)
        }

        let invalidURL = root.appendingPathComponent("invalid.md")
        try Data([0xC3, 0x28]).write(to: invalidURL)
        XCTAssertThrowsError(try service.open(invalidURL)) {
            XCTAssertEqual($0 as? ExternalMarkdownDocumentError, .invalidUTF8)
        }

        let largeURL = root.appendingPathComponent("large.markdown")
        try Data(repeating: 0x61, count: 9).write(to: largeURL)
        XCTAssertThrowsError(try service.open(largeURL)) {
            XCTAssertEqual($0 as? ExternalMarkdownDocumentError, .documentTooLarge)
        }
    }

    func testOpenRejectsMarkdownSymlinkWhoseResolvedTargetIsNotMarkdown() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.txt")
        try Data("# Looks like Markdown".utf8).write(to: target)
        let alias = root.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        XCTAssertThrowsError(try ExternalMarkdownDocumentService().open(alias)) {
            XCTAssertEqual($0 as? ExternalMarkdownDocumentError, .unsupportedFileType)
        }
    }

    func testSaveWritesLocalChangeAndRefreshesBaseDigest() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("lesson.md")
        try Data("# Base".utf8).write(to: url)
        let service = ExternalMarkdownDocumentService()
        let opened = try service.open(url)
        let binding = CardFileBinding(fileURL: opened.fileURL, baseDigest: opened.digest)

        let result = try service.save("# Local\n\nUpdated", binding: binding)

        guard case let .saved(updatedBinding) = result else {
            return XCTFail("Expected a saved result")
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Local\n\nUpdated")
        XCTAssertNotEqual(updatedBinding.baseDigest, binding.baseDigest)
        XCTAssertEqual(updatedBinding.baseDigest, try service.open(url).digest)
    }

    func testSaveReturnsUnchangedWhenNeitherSideChanged() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("lesson.md")
        try Data("# Base".utf8).write(to: url)
        let service = ExternalMarkdownDocumentService()
        let opened = try service.open(url)
        let binding = CardFileBinding(fileURL: opened.fileURL, baseDigest: opened.digest)

        XCTAssertEqual(try service.save(opened.markdown, binding: binding), .unchanged(binding))
    }

    func testSaveConflictsOnTwoSidedChangeAndNeverOverwritesDisk() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("lesson.md")
        try Data("# Base".utf8).write(to: url)
        let service = ExternalMarkdownDocumentService()
        let opened = try service.open(url)
        let binding = CardFileBinding(fileURL: opened.fileURL, baseDigest: opened.digest)
        try Data("# External".utf8).write(to: url, options: .atomic)

        let result = try service.save("# Local", binding: binding)

        guard case let .conflict(conflict) = result else {
            return XCTFail("Expected a conflict")
        }
        XCTAssertTrue(conflict.diskChanged)
        XCTAssertTrue(conflict.localChanged)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# External")
    }

    func testSaveConflictsOnDiskOnlyChangeInsteadOfSilentlyAdoptingIt() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("lesson.md")
        try Data("# Base".utf8).write(to: url)
        let service = ExternalMarkdownDocumentService()
        let opened = try service.open(url)
        let binding = CardFileBinding(fileURL: opened.fileURL, baseDigest: opened.digest)
        try Data("# External".utf8).write(to: url, options: .atomic)

        let result = try service.save(opened.markdown, binding: binding)

        guard case let .conflict(conflict) = result else {
            return XCTFail("Expected a conflict")
        }
        XCTAssertTrue(conflict.diskChanged)
        XCTAssertFalse(conflict.localChanged)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# External")
    }

    func testKeepLocalVersionOverwritesOnlyTheConflictSnapshot() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("lesson.md")
        try Data("# Base".utf8).write(to: url)
        let service = ExternalMarkdownDocumentService()
        let opened = try service.open(url)
        let binding = CardFileBinding(fileURL: opened.fileURL, baseDigest: opened.digest)
        try Data("# External".utf8).write(to: url, options: .atomic)

        guard case let .conflict(conflict) = try service.save("# Mine", binding: binding) else {
            return XCTFail("Expected the initial conflict")
        }
        guard case let .saved(updatedBinding) = try service.keepLocalVersion(
            "# Mine",
            after: conflict
        ) else {
            return XCTFail("Expected Keep Mine to save")
        }

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Mine")
        XCTAssertEqual(updatedBinding.baseDigest, try service.open(url).digest)
    }

    func testKeepLocalVersionReturnsFreshConflictWhenDiskChangesAgain() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("lesson.md")
        try Data("# Base".utf8).write(to: url)
        let service = ExternalMarkdownDocumentService()
        let opened = try service.open(url)
        let binding = CardFileBinding(fileURL: opened.fileURL, baseDigest: opened.digest)
        try Data("# External".utf8).write(to: url, options: .atomic)
        guard case let .conflict(conflict) = try service.save("# Mine", binding: binding) else {
            return XCTFail("Expected the initial conflict")
        }
        try Data("# External Again".utf8).write(to: url, options: .atomic)

        guard case let .conflict(freshConflict) = try service.keepLocalVersion(
            "# Mine",
            after: conflict
        ) else {
            return XCTFail("Expected a fresh conflict")
        }

        XCTAssertNotEqual(freshConflict.diskDigest, conflict.diskDigest)
        XCTAssertEqual(
            freshConflict.diskDigest,
            ExternalMarkdownDocumentService.digest(Data("# External Again".utf8))
        )
        XCTAssertEqual(
            freshConflict.localDigest,
            ExternalMarkdownDocumentService.digest(Data("# Mine".utf8))
        )
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# External Again")
    }

    func testMissingLinkedFileFailsAndSaveAsCreatesReopenableDocument() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ExternalMarkdownDocumentService()
        let missingURL = root.appendingPathComponent("missing.md")
        let missingBinding = CardFileBinding(fileURL: missingURL, baseDigest: "gone")
        XCTAssertThrowsError(try service.save("# Local", binding: missingBinding)) {
            XCTAssertEqual($0 as? ExternalMarkdownDocumentError, .missingFile)
        }

        let destination = root.appendingPathComponent("saved.markdown")
        let binding = try service.saveAs("# Saved", to: destination)
        let reopened = try service.open(destination)
        XCTAssertEqual(reopened.markdown, "# Saved")
        XCTAssertEqual(binding.fileURL, reopened.fileURL)
        XCTAssertEqual(binding.baseDigest, reopened.digest)
    }

    func testPortableSaveAsCopiesRelativeImagesAndManagedAttachmentsWithCollisionRewrite() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let sourceAssets = sourceRoot.appendingPathComponent("assets", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("Destination", isDirectory: true)
        let destinationAssets = destinationRoot.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceAssets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationAssets, withIntermediateDirectories: true)

        let relativePNG = try makePNG()
        try relativePNG.write(to: sourceAssets.appendingPathComponent("diagram.png"))
        let occupiedResource = Data("existing-user-file".utf8)
        try occupiedResource.write(to: destinationAssets.appendingPathComponent("diagram.png"))

        let attachmentStore = LocalAttachmentStore(
            directory: root.appendingPathComponent("Managed", isDirectory: true)
        )
        let attachmentSource = try attachmentStore.saveClipboardImage(
            data: try makePNG(),
            mimeType: "image/png"
        )
        let attachmentID = try XCTUnwrap(
            LocalAttachmentStore.attachmentID(fromMarkdownSource: attachmentSource)
        )
        let managedPNG = try XCTUnwrap(attachmentStore.data(forAttachmentID: attachmentID))
        let markdown = """
        # Portable

        ![Inline](./assets/diagram.png "Flow")
        ![Managed](attachments/\(attachmentID).png)
        ![Reference][diagram]
        <img alt="HTML" src="assets/diagram.png">

        `![Inline example](assets/not-a-real-image.png)`

        ```markdown
        ![Fenced example](assets/not-a-real-image.png)
        ```

        [diagram]: assets/diagram.png "Reference title"
        """
        let service = ExternalMarkdownDocumentService(
            attachmentStore: attachmentStore
        )
        let destination = destinationRoot.appendingPathComponent("Tutorial.md")

        let result = try service.saveAs(
            MarkdownExportBundle(
                markdown: markdown,
                attachmentIDs: [attachmentID, attachmentID.uppercased()]
            ),
            sourceDocumentRoot: sourceRoot,
            to: destination
        )

        XCTAssertEqual(
            try Data(contentsOf: destinationAssets.appendingPathComponent("diagram.png")),
            occupiedResource,
            "Save As must not overwrite a colliding user resource."
        )
        XCTAssertEqual(
            try Data(contentsOf: destinationAssets.appendingPathComponent("diagram-2.png")),
            relativePNG
        )
        XCTAssertEqual(
            try Data(contentsOf: destinationRoot
                .appendingPathComponent("attachments", isDirectory: true)
                .appendingPathComponent("\(attachmentID).png")),
            managedPNG
        )
        XCTAssertTrue(result.markdown.contains("![Inline](assets/diagram-2.png \"Flow\")"))
        XCTAssertTrue(result.markdown.contains("<img alt=\"HTML\" src=\"assets/diagram-2.png\">"))
        XCTAssertTrue(result.markdown.contains("[diagram]: assets/diagram-2.png \"Reference title\""))
        XCTAssertTrue(result.markdown.contains("`![Inline example](assets/not-a-real-image.png)`"))
        XCTAssertTrue(result.markdown.contains("![Fenced example](assets/not-a-real-image.png)"))
        XCTAssertEqual(
            Set(result.copiedResourcePaths),
            Set(["assets/diagram-2.png", "attachments/\(attachmentID).png"])
        )
        XCTAssertTrue(result.unresolvedResourcePaths.isEmpty)
        let reopened = try service.open(destination)
        XCTAssertEqual(reopened.markdown, result.markdown)
        XCTAssertEqual(reopened.digest, result.binding.baseDigest)
        XCTAssertEqual(result.documentRootURL, destinationRoot.standardizedFileURL)
    }

    func testPortableSaveAsRejectsTraversalWithoutReadingOutsideDocumentRoot() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try makePNG().write(to: root.appendingPathComponent("outside.png"))
        let destination = destinationRoot.appendingPathComponent("Traversal.md")
        let service = ExternalMarkdownDocumentService()

        XCTAssertThrowsError(
            try service.saveAs(
                MarkdownExportBundle(
                    markdown: "![Escape](../outside.png)",
                    attachmentIDs: []
                ),
                sourceDocumentRoot: sourceRoot,
                to: destination
            )
        ) { error in
            XCTAssertEqual(
                error as? ExternalMarkdownDocumentError,
                .unsafeResourcePath("../outside.png")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationRoot.appendingPathComponent("outside.png").path
            )
        )
    }

    func testFirstSaveAsReportsUnresolvedRelativeImagesWithoutBreakingPlainSave() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Draft.md")
        let markdown = "# Draft\n\n![Add later](assets/future.png)"

        let result = try ExternalMarkdownDocumentService().saveAs(
            MarkdownExportBundle(markdown: markdown, attachmentIDs: []),
            sourceDocumentRoot: nil,
            to: destination
        )

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), markdown)
        XCTAssertEqual(result.markdown, markdown)
        XCTAssertTrue(result.copiedResourcePaths.isEmpty)
        XCTAssertEqual(result.unresolvedResourcePaths, ["assets/future.png"])
    }

    func testPortableSaveAsMissingManagedAttachmentPreservesExistingMarkdown() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Existing.md")
        try Data("original".utf8).write(to: destination)
        let missingID = "34d1880c-35d5-4c7e-9620-40c3140b003c"
        let service = ExternalMarkdownDocumentService(
            attachmentStore: LocalAttachmentStore(
                directory: root.appendingPathComponent("Missing Managed", isDirectory: true)
            )
        )

        XCTAssertThrowsError(
            try service.saveAs(
                MarkdownExportBundle(
                    markdown: "![Missing](attachments/\(missingID).png)",
                    attachmentIDs: [missingID]
                ),
                sourceDocumentRoot: nil,
                to: destination
            )
        ) { error in
            XCTAssertEqual(
                error as? ExternalMarkdownDocumentError,
                .missingManagedAttachment(missingID)
            )
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(LocalAttachmentStore.markdownDirectory).path
            )
        )
    }

    func testPortableSaveAsRollsBackNewResourcesWhenMarkdownCannotBeWritten() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let sourceAssets = sourceRoot.appendingPathComponent("assets", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceAssets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try makePNG().write(
            to: sourceAssets.appendingPathComponent("rollback.png")
        )
        let destination = destinationRoot.appendingPathComponent("Existing.md")
        try Data("original".utf8).write(to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444],
            ofItemAtPath: destination.path
        )
        let service = ExternalMarkdownDocumentService()

        XCTAssertThrowsError(
            try service.saveAs(
                MarkdownExportBundle(
                    markdown: "![Rollback](assets/rollback.png)",
                    attachmentIDs: []
                ),
                sourceDocumentRoot: sourceRoot,
                to: destination
            )
        ) { error in
            XCTAssertEqual(error as? ExternalMarkdownDocumentError, .unableToWrite)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "original")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationRoot.appendingPathComponent("assets").path
            ),
            "A failed Save As must remove resource files and directories it created."
        )
    }

    func testSaveRefusesReadOnlyLinkedFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("readonly.md")
        try Data("# Base".utf8).write(to: url)
        let service = ExternalMarkdownDocumentService()
        let opened = try service.open(url)
        let binding = CardFileBinding(fileURL: opened.fileURL, baseDigest: opened.digest)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)

        XCTAssertThrowsError(try service.save("# Local", binding: binding)) {
            XCTAssertEqual($0 as? ExternalMarkdownDocumentError, .unableToWrite)
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Base")
    }

    func testBindingStorePersistsCanonicalFileAndDocumentRootThenRemovesIt() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "CardFileBindingStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cardID = UUID()
        let fileURL = root.appendingPathComponent("lesson.md")
        let binding = CardFileBinding(fileURL: fileURL, baseDigest: "abc123")

        CardFileBindingStore(defaults: defaults).set(binding, for: cardID)
        let reopenedStore = CardFileBindingStore(defaults: defaults)

        XCTAssertEqual(reopenedStore.binding(for: cardID), binding)
        XCTAssertEqual(reopenedStore.fileURL(for: cardID), binding.fileURL)
        XCTAssertEqual(
            reopenedStore.documentRootURL(for: cardID),
            binding.fileURL.deletingLastPathComponent().standardizedFileURL
        )
        reopenedStore.removeBinding(for: cardID)
        XCTAssertNil(CardFileBindingStore(defaults: defaults).binding(for: cardID))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalMarkdownDocumentServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makePNG() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 16,
            bitsPerPixel: 32
        ))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for offset in stride(from: 0, to: 64, by: 4) {
            pixels[offset] = 35
            pixels[offset + 1] = 110
            pixels[offset + 2] = 220
            pixels[offset + 3] = 255
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}

@MainActor
final class MarkdownFileMenuTests: XCTestCase {
    func testFileMenuExposesExpectedCommandsShortcutsAndValidation() async throws {
        let fixture = try makeControllerFixture()
        defer { fixture.cleanUp() }
        let menu = fixture.controller.makeFileMenu()

        XCTAssertEqual(
            menu.items.map(\.title),
            ["New Card", "Open Markdown…", "", "Save", "Save As…", "", "Version History…"]
        )
        XCTAssertEqual(try item(named: "Open Markdown…", in: menu).keyEquivalent, "o")
        XCTAssertEqual(try item(named: "Save", in: menu).keyEquivalent, "s")
        let saveAs = try item(named: "Save As…", in: menu)
        XCTAssertEqual(saveAs.keyEquivalent, "s")
        XCTAssertEqual(saveAs.keyEquivalentModifierMask, [.command, .option])
        XCTAssertEqual(
            try item(named: "Open Markdown…", in: menu).action.map(NSStringFromSelector),
            "openMarkdownFromMenu:"
        )
        XCTAssertEqual(try item(named: "Save", in: menu).action.map(NSStringFromSelector), "saveMarkdownFromMenu:")
        XCTAssertEqual(saveAs.action.map(NSStringFromSelector), "saveMarkdownAsFromMenu:")
        XCTAssertFalse(fixture.controller.validateMenuItem(try item(named: "Save", in: menu)))
        XCTAssertFalse(fixture.controller.validateMenuItem(saveAs))

        let card = try await fixture.controller.createIndependentCard(
            markdown: "# Menu State"
        )
        let activeState = fixture.controller.fileMenuState(forActiveCardID: card.id)
        XCTAssertEqual(activeState.activeCardID, card.id)
        XCTAssertTrue(activeState.canSave)
        XCTAssertTrue(activeState.canSaveAs)
        fixture.controller.cardWindowForTesting(card.id)?.orderOut(nil)
        XCTAssertNil(
            fixture.controller.currentFileMenuState().activeCardID,
            "A recent card must not become the implicit Save target when no CardPanel is key."
        )
        _ = await fixture.controller.handle(AgentRequest(
            command: .delete(DeleteOptions(cardID: card.id, force: true))
        ))
    }

    func testFileMenuStateReflectsBindingAndDeleteCleansItUp() async throws {
        let fixture = try makeControllerFixture()
        defer { fixture.cleanUp() }
        let card = try await fixture.controller.createIndependentCard(
            markdown: "# Bound"
        )
        let fileURL = fixture.root.appendingPathComponent("bound.md")
        let binding = CardFileBinding(fileURL: fileURL, baseDigest: "base")
        fixture.bindingStore.set(binding, for: card.id)

        let state = fixture.controller.fileMenuState(forActiveCardID: card.id)
        XCTAssertEqual(state.activeCardID, card.id)
        XCTAssertEqual(state.binding, binding)
        XCTAssertTrue(state.isFileBound)

        let response = await fixture.controller.handle(AgentRequest(
            command: .delete(DeleteOptions(cardID: card.id, force: true))
        ))
        XCTAssertTrue(response.ok)
        XCTAssertNil(fixture.bindingStore.binding(for: card.id))
        XCTAssertNil(fixture.controller.fileMenuState(forActiveCardID: card.id).activeCardID)
    }

    private func item(named title: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.title == title })
    }

    private func makeControllerFixture() throws -> ControllerFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownFileMenuTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "MarkdownFileMenuTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let repository = JSONCardRepository(fileURL: root.appendingPathComponent("cards.json"))
        let bindingStore = CardFileBindingStore(defaults: defaults)
        let controller = AgentApplicationController(
            repository: repository,
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults,
            fileBindingStore: bindingStore
        )
        return ControllerFixture(
            controller: controller,
            bindingStore: bindingStore,
            defaults: defaults,
            defaultsSuiteName: suiteName,
            root: root
        )
    }
}

@MainActor
final class RendererMarkdownSnapshotTests: XCTestCase {
    func testValidationDistinguishesCurrentMarkdownFromBridgeFailureAndOversize() {
        XCTAssertEqual(
            MarkdownPreviewView.validatedMarkdownSnapshot(value: "# Live", error: nil),
            .markdown("# Live")
        )
        XCTAssertEqual(
            MarkdownPreviewView.validatedMarkdownSnapshot(
                value: String(repeating: "x", count: IPCFrameCodec.maximumPayloadSize + 1),
                error: nil
            ),
            .failure(.documentTooLarge)
        )
        XCTAssertEqual(
            MarkdownPreviewView.validatedMarkdownSnapshot(
                value: nil,
                error: NSError(domain: "Renderer", code: 1)
            ),
            .failure(.unavailable)
        )
    }

    func testReloadGuardRejectsContentEditedAfterConflictSnapshot() {
        let snapshot = "# Local at conflict"
        let digest = ExternalMarkdownDocumentService.digest(Data(snapshot.utf8))

        XCTAssertTrue(AgentApplicationController.localMarkdownMatchesReloadSnapshot(
            snapshot,
            expectedDigest: digest
        ))
        XCTAssertFalse(AgentApplicationController.localMarkdownMatchesReloadSnapshot(
            "# Newer edit while reloading",
            expectedDigest: digest
        ))
    }

    func testPortableSaveAsResultOnlyAppliesToUnchangedEditorRevisionAndBinding() {
        let originalURL = URL(fileURLWithPath: "/tmp/original.md")
        let original = CardFileBinding(fileURL: originalURL, baseDigest: "base")
        XCTAssertTrue(AgentApplicationController.canApplyPortableSaveAsResult(
            currentMarkdown: "# Exported",
            exportedMarkdown: "# Exported",
            currentRevision: 7,
            exportedRevision: 7,
            currentBinding: original,
            originalBinding: original
        ))
        XCTAssertFalse(AgentApplicationController.canApplyPortableSaveAsResult(
            currentMarkdown: "# Newer edit",
            exportedMarkdown: "# Exported",
            currentRevision: 8,
            exportedRevision: 7,
            currentBinding: original,
            originalBinding: original
        ))
        XCTAssertFalse(AgentApplicationController.canApplyPortableSaveAsResult(
            currentMarkdown: "# Exported",
            exportedMarkdown: "# Exported",
            currentRevision: 7,
            exportedRevision: 7,
            currentBinding: CardFileBinding(
                fileURL: URL(fileURLWithPath: "/tmp/other.md"),
                baseDigest: "other"
            ),
            originalBinding: original
        ))
    }
}

@MainActor
final class LinkedMarkdownHeaderTests: XCTestCase {
    func testLinkedFilenameShowsCleanEditedAndMiniStates() throws {
        let header = CardHeaderView(frame: NSRect(x: 0, y: 0, width: 720, height: 48))
        let fileURL = URL(fileURLWithPath: "/tmp/tutorial.md")

        header.updateLinkedFile(fileURL, isDirty: false)
        let status = try XCTUnwrap(header.subviews.compactMap { $0 as? NSTextField }.first {
            $0.accessibilityLabel() == "Linked Markdown file"
        })
        XCTAssertFalse(status.isHidden)
        XCTAssertEqual(status.stringValue, "tutorial.md")
        XCTAssertEqual(status.accessibilityHelp(), "tutorial.md, saved to the linked file")

        header.updateLinkedFile(fileURL, isDirty: true)
        XCTAssertEqual(status.stringValue, "tutorial.md · Edited")
        XCTAssertEqual(
            status.accessibilityHelp(),
            "tutorial.md, edited and not saved to the linked file"
        )

        header.setMiniMode(true)
        XCTAssertTrue(status.isHidden)
        header.setMiniMode(false)
        XCTAssertFalse(status.isHidden)

        header.updateLinkedFile(nil, isDirty: false)
        XCTAssertTrue(status.isHidden)
    }
}

@MainActor
private struct ControllerFixture {
    let controller: AgentApplicationController
    let bindingStore: CardFileBindingStore
    let defaults: UserDefaults
    let defaultsSuiteName: String
    let root: URL

    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
