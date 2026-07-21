import AppKit
import Foundation
import MarkdownCardCore
import XCTest
@testable import MarkdownCardAgent

final class MarkdownPreviewBridgeTests: XCTestCase {
    func testTagCommandSubmissionValidatesAndNormalizesRendererPayload() throws {
        let cardID = UUID()
        let submission = try XCTUnwrap(
            RendererTagCommandSubmission(
                payload: [
                    "cardID": cardID.uuidString,
                    "tagName": "  Cafe\u{301}   研究  ",
                    "markdown": "# Reading\n\nBody",
                    // WKScriptMessage transports JavaScript numbers as NSNumber doubles.
                    "revision": NSNumber(value: 12.0),
                ]
            )
        )

        XCTAssertEqual(submission.cardID, cardID)
        XCTAssertEqual(submission.tagName, "Café 研究")
        XCTAssertEqual(submission.markdown, "# Reading\n\nBody")
        XCTAssertEqual(submission.revision, 12)
    }

    func testTagCommandSubmissionRejectsInvalidIdentityNameMarkdownAndRevision() {
        let cardID = UUID()
        let valid: [String: Any] = [
            "cardID": cardID.uuidString,
            "tagName": "Research",
            "markdown": "Body",
            "revision": NSNumber(value: 2),
        ]

        XCTAssertNil(submission(valid, replacing: "cardID", with: "not-a-uuid"))
        XCTAssertNil(submission(valid, replacing: "tagName", with: "   "))
        XCTAssertNil(submission(valid, replacing: "tagName", with: "line\nbreak"))
        XCTAssertNil(submission(valid, replacing: "tagName", with: String(repeating: "x", count: 65)))
        XCTAssertNil(
            submission(
                valid,
                replacing: "markdown",
                with: String(repeating: "x", count: IPCFrameCodec.maximumPayloadSize + 1)
            )
        )
        XCTAssertNil(submission(valid, replacing: "revision", with: NSNumber(value: -1)))
        XCTAssertNil(submission(valid, replacing: "revision", with: NSNumber(value: 1.5)))
        XCTAssertNil(submission(valid, replacing: "revision", with: NSNumber(value: true)))
    }

    func testSlashCommandMenuStateStrictlyValidatesRendererPayload() throws {
        let visible: [String: Any] = [
            "visible": true,
            "selectedIndex": NSNumber(value: 1),
            "anchor": [
                "left": NSNumber(value: 28.0),
                "top": NSNumber(value: 710.0),
                "bottom": NSNumber(value: 728.0),
            ],
            "items": [
                ["id": "youtube", "title": "YouTube", "description": "Add a video cover"],
                ["id": "tag", "title": "Tag", "description": "Add to a card series"],
            ],
        ]
        let state = try XCTUnwrap(SlashCommandMenuState(payload: visible))
        XCTAssertTrue(state.visible)
        XCTAssertEqual(state.items.map(\.id), ["youtube", "tag"])
        XCTAssertEqual(state.selectedIndex, 1)
        XCTAssertEqual(state.anchorLeft, 28)
        XCTAssertEqual(state.anchorTop, 710)
        XCTAssertEqual(state.anchorBottom, 728)

        let hidden = try XCTUnwrap(
            SlashCommandMenuState(payload: ["visible": false])
        )
        XCTAssertFalse(hidden.visible)
        XCTAssertTrue(hidden.items.isEmpty)

        XCTAssertNil(slashState(visible, replacing: "selectedIndex", with: 2))
        XCTAssertNil(slashState(visible, replacing: "selectedIndex", with: true))
        XCTAssertNil(
            slashState(
                visible,
                replacing: "anchor",
                with: ["left": 0, "top": 10, "bottom": Double.nan]
            )
        )
        XCTAssertNil(
            slashState(
                visible,
                replacing: "items",
                with: Array(repeating: [
                    "id": "duplicate",
                    "title": "Duplicate",
                    "description": "Duplicate command",
                ], count: 17)
            )
        )
    }

    func testSlashCommandPanelLayoutEscapesCardButStaysOnScreenAndFlipsAtEdge() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1_440, height: 900)
        let parentCard = NSRect(x: 300, y: 300, width: 360, height: 420)
        let below = SlashCommandPanelLayout.frame(
            anchor: SlashCommandScreenAnchor(left: 328, top: 330, bottom: 310),
            panelSize: NSSize(width: 310, height: 102),
            visibleFrame: visibleFrame
        )
        XCTAssertLessThan(below.minY, parentCard.minY)
        XCTAssertGreaterThanOrEqual(below.minX, visibleFrame.minX + 8)
        XCTAssertLessThanOrEqual(below.maxX, visibleFrame.maxX - 8)

        let flipped = SlashCommandPanelLayout.frame(
            anchor: SlashCommandScreenAnchor(left: 20, top: 36, bottom: 18),
            panelSize: NSSize(width: 310, height: 102),
            visibleFrame: visibleFrame
        )
        XCTAssertGreaterThan(flipped.minY, 36)
        XCTAssertGreaterThanOrEqual(flipped.minX, visibleFrame.minX + 8)
    }

    func testRendererAttemptGateRejectsLateRenderCallbacksAndTimeouts() {
        var gate = RendererAttemptGate()
        let first = gate.begin()
        XCTAssertTrue(gate.accepts(first))

        let second = gate.begin()
        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second))

        gate.invalidate()
        XCTAssertFalse(gate.accepts(second))
    }

    @MainActor
    func testHiddenRecoveryOverlaysDoNotRaisePreviewFittingSize() {
        let preview = MarkdownPreviewView(initialAppearance: .dark)
        preview.frame = NSRect(x: 0, y: 0, width: 320, height: 192)
        preview.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(preview.fittingSize.width, CardLayoutGeometry.miniSize.width)
        XCTAssertLessThanOrEqual(preview.fittingSize.height, CardLayoutGeometry.headerHeight)
    }

    @MainActor
    func testRecoveryViewOffersRetrySourceAndCopyActions() throws {
        let recovery = MarkdownPreviewRecoveryView(resolvedAppearance: .dark)
        recovery.update(reason: .renderTimedOut, diagnostic: "Timed out after four seconds")
        var actions: [String] = []
        recovery.onRetry = { actions.append("retry") }
        recovery.onOpenSource = { actions.append("source") }
        recovery.onCopyMarkdown = { actions.append("copy") }

        let buttons = descendants(of: NSButton.self, in: recovery)
        try button("markdownPreview.recovery.retry", in: buttons).performClick(nil)
        try button("markdownPreview.recovery.source", in: buttons).performClick(nil)
        try button("markdownPreview.recovery.copy", in: buttons).performClick(nil)

        XCTAssertEqual(actions, ["retry", "source", "copy"])
        XCTAssertTrue(recovery.accessibilityLabel()?.contains("stopped responding") == true)
        XCTAssertEqual(
            try button("markdownPreview.recovery.source", in: buttons).accessibilityLabel(),
            "Open Source"
        )
    }

    @MainActor
    func testNativeSourceRecoveryContinuesEditingWithoutRenderer() {
        let source = MarkdownNativeSourceRecoveryView(resolvedAppearance: .light)
        source.setMarkdown("# Original\n")
        var changes: [String] = []
        source.onMarkdownChange = { changes.append($0) }

        source.textView.string = "# Continued\n\nSafe edit"
        source.textView.didChangeText()

        XCTAssertEqual(source.markdown, "# Continued\n\nSafe edit")
        XCTAssertEqual(changes, ["# Continued\n\nSafe edit"])
        XCTAssertEqual(source.textView.accessibilityLabel(), "Markdown source editor")
    }

    @MainActor
    func testDocumentLinkNoticeHasVisibleSaveAsGuidance() throws {
        let notice = MarkdownLinkNoticeView(resolvedAppearance: .dark)
        notice.show(
            message: "Relative links need a linked Markdown file. Choose Save As… to set its folder."
        )
        let stickyNoticeWidth: CGFloat = CardLayoutGeometry.stickyWidth - 24
        notice.frame = NSRect(
            x: 0,
            y: 0,
            width: stickyNoticeWidth,
            height: notice.preferredHeight(for: stickyNoticeWidth)
        )
        notice.layoutSubtreeIfNeeded()
        var didSaveAs = false
        var didDismiss = false
        notice.onSaveAs = { didSaveAs = true }
        notice.onDismiss = { didDismiss = true }
        let buttons = descendants(of: NSButton.self, in: notice)

        try button("markdownPreview.linkNotice.saveAs", in: buttons).performClick(nil)
        try button("markdownPreview.linkNotice.dismiss", in: buttons).performClick(nil)

        XCTAssertTrue(didSaveAs)
        XCTAssertTrue(didDismiss)
        XCTAssertTrue(notice.accessibilityLabel()?.contains("Save As") == true)
        for button in buttons {
            XCTAssertGreaterThanOrEqual(button.frame.minX, notice.bounds.minX)
            XCTAssertLessThanOrEqual(button.frame.maxX, notice.bounds.maxX)
            XCTAssertGreaterThanOrEqual(button.frame.minY, notice.bounds.minY)
            XCTAssertLessThanOrEqual(button.frame.maxY, notice.bounds.maxY)
        }
    }

    @MainActor
    func testSlashCommandPanelIsNonactivatingChildAndButtonsRemainClickable() throws {
        let parent = NSWindow(
            contentRect: NSRect(x: 300, y: 300, width: 360, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 240))
        let anchorView = NSView(frame: container.bounds)
        container.addSubview(anchorView)
        parent.contentView = container
        parent.orderFront(nil)
        defer { parent.orderOut(nil) }

        let controller = SlashCommandMenuController()
        var chosenID: String?
        controller.onChoose = { chosenID = $0 }
        controller.update(
            state: SlashCommandMenuState(
                visible: true,
                items: [SlashCommandMenuItem(
                    id: "tag",
                    title: "Tag",
                    description: "Add to a card series"
                )],
                selectedIndex: 0,
                anchorLeft: 28,
                anchorTop: 200,
                anchorBottom: 218
            ),
            relativeTo: anchorView
        )

        XCTAssertTrue(parent.childWindows?.contains(controller.panel) == true)
        XCTAssertTrue(controller.panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(controller.panel.canBecomeKey)
        XCTAssertFalse(controller.panel.canBecomeMain)
        XCTAssertTrue(controller.panel.isVisible)
        let button = try XCTUnwrap(
            descendants(of: NSButton.self, in: try XCTUnwrap(controller.panel.contentView)).first
        )
        button.performClick(nil)
        XCTAssertEqual(chosenID, "tag")

        let item = SlashCommandMenuItem(
            id: "tag",
            title: "Tag",
            description: "Add to a card series"
        )
        controller.update(
            state: SlashCommandMenuState(
                visible: true,
                items: [item],
                anchorTop: -40,
                anchorBottom: -20
            ),
            relativeTo: anchorView
        )
        XCTAssertFalse(controller.panel.isVisible)
        controller.update(
            state: SlashCommandMenuState(
                visible: true,
                items: [item],
                anchorTop: 260,
                anchorBottom: 280
            ),
            relativeTo: anchorView
        )
        XCTAssertFalse(controller.panel.isVisible)
        controller.update(
            state: SlashCommandMenuState(
                visible: true,
                items: [item],
                anchorLeft: 28,
                anchorTop: 200,
                anchorBottom: 218
            ),
            relativeTo: anchorView
        )
        XCTAssertTrue(controller.panel.isVisible)
        container.isHidden = true
        controller.updateLayout()
        XCTAssertFalse(controller.panel.isVisible)

        controller.detach()
        XCTAssertFalse(parent.childWindows?.contains(controller.panel) == true)
    }

    private func submission(
        _ payload: [String: Any],
        replacing key: String,
        with value: Any
    ) -> RendererTagCommandSubmission? {
        var payload = payload
        payload[key] = value
        return RendererTagCommandSubmission(payload: payload)
    }

    private func slashState(
        _ payload: [String: Any],
        replacing key: String,
        with value: Any
    ) -> SlashCommandMenuState? {
        var payload = payload
        payload[key] = value
        return SlashCommandMenuState(payload: payload)
    }

    @MainActor
    private func button(_ identifier: String, in buttons: [NSButton]) throws -> NSButton {
        try XCTUnwrap(buttons.first { $0.identifier?.rawValue == identifier })
    }

    @MainActor
    private func descendants<View: NSView>(of type: View.Type, in root: NSView) -> [View] {
        var matches = root.subviews.compactMap { $0 as? View }
        for subview in root.subviews {
            matches.append(contentsOf: descendants(of: type, in: subview))
        }
        return matches
    }
}
