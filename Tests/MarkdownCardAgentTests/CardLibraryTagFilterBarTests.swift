import AppKit
import MarkdownCardCore
import XCTest
@testable import MarkdownCardAgent

@MainActor
final class CardLibraryTagFilterBarTests: XCTestCase {
    func testResponsiveLayoutScalesAtBothSidebarWidthsWithLongUnicodeTags() throws {
        for count in [0, 1, 10, 100] {
            let tags = try (0 ..< count).map {
                try CardTag("学习资料与研究方向 \(String(format: "%03d", $0))")
            }
            let entries = tags.enumerated().map {
                CardLibraryTagEntry(tag: $0.element, cardCount: $0.offset + 1)
            }
            for width in [CGFloat(248), CGFloat(328)] {
                let activeID = tags.last?.id
                let layout = CardLibraryTagFilterBar.layout(
                    entries: entries,
                    activeTagID: activeID,
                    candidateOrder: tags.map(\.id),
                    availableWidth: width
                )

                XCTAssertEqual(
                    Set(layout.quickTagIDs + layout.hiddenTagIDs),
                    Set(tags.map(\.id)),
                    "count=\(count), width=\(width)"
                )
                XCTAssertEqual(Set(layout.quickTagIDs).count, layout.quickTagIDs.count)
                if let activeID {
                    XCTAssertTrue(
                        layout.quickTagIDs.contains(activeID),
                        "count=\(count), width=\(width)"
                    )
                }
            }
        }
    }

    func testResponsiveBarKeepsAllMoreAndActiveVisibleWithoutScrolling() throws {
        let tags = try [
            "Architecture",
            "Research",
            "Reading",
            "Ideas",
            "Swift",
            "Active Tag",
        ].map { try CardTag($0) }
        let entries = tags.enumerated().map {
            CardLibraryTagEntry(tag: $0.element, cardCount: $0.offset + 1)
        }
        let active = tags.last!
        let bar = CardLibraryTagFilterBar(
            frame: NSRect(x: 0, y: 0, width: 250, height: CardLibraryTagFilterMetrics.height)
        )
        var selections: [CardTag?] = []
        bar.onSelectionChange = { selections.append($0) }

        bar.update(
            entries: entries,
            activeTagID: active.id,
            candidateOrder: tags.dropLast().map(\.id),
            animated: false
        )
        bar.layoutSubtreeIfNeeded()

        XCTAssertFalse(bar.allButton.isHidden)
        XCTAssertFalse(bar.moreButton.isHidden)
        XCTAssertEqual(bar.allButton.frame.minX, 0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(bar.moreButton.frame.maxX, bar.bounds.maxX + 0.001)
        XCTAssertTrue(bar.currentLayout.quickTagIDs.contains(active.id))
        XCTAssertTrue(bar.quickTagButtons.contains { $0.cardTag.id == active.id })
        XCTAssertTrue(bar.quickTagButtons.allSatisfy { $0.frame.maxX <= bar.moreButton.frame.minX })
        XCTAssertEqual(bar.moreButton.title, "+\(bar.currentLayout.hiddenTagIDs.count)")
        XCTAssertTrue(descendants(of: NSScrollView.self, in: bar).isEmpty)

        bar.setFrameSize(NSSize(width: 132, height: CardLibraryTagFilterMetrics.height))
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        XCTAssertTrue(bar.currentLayout.quickTagIDs.contains(active.id))
        XCTAssertGreaterThan(
            try XCTUnwrap(bar.quickTagButtons.first { $0.cardTag.id == active.id }).frame.width,
            0
        )
        XCTAssertFalse(bar.allButton.isHidden)
        XCTAssertFalse(bar.moreButton.isHidden)

        bar.allButton.performClick(nil)
        XCTAssertNil(selections.last!)
        try XCTUnwrap(bar.quickTagButtons.first { $0.cardTag.id == active.id })
            .performClick(nil)
        XCTAssertEqual(selections.last!, active)
        XCTAssertEqual(bar.accessibilityLabel(), "Tag filters")
        XCTAssertTrue(bar.moreButton.accessibilityLabel()?.contains("More tags") == true)
    }

    func testLayoutPriorityIsActiveThenPinnedCandidateOrder() throws {
        let active = try CardTag("Active")
        let alpha = try CardTag("Alpha")
        let pinned = try CardTag("Pinned")
        let recent = try CardTag("Recent")
        let entries = [
            CardLibraryTagEntry(tag: alpha, cardCount: 1),
            CardLibraryTagEntry(tag: pinned, cardCount: 2, isPinned: true),
            CardLibraryTagEntry(tag: recent, cardCount: 3),
            CardLibraryTagEntry(tag: active, cardCount: 4),
        ]

        let layout = CardLibraryTagFilterBar.layout(
            entries: entries,
            activeTagID: active.id,
            candidateOrder: [recent.id, pinned.id, alpha.id, active.id],
            availableWidth: 230
        )

        XCTAssertEqual(layout.quickTagIDs.first, active.id)
        if layout.quickTagIDs.count > 1 {
            XCTAssertEqual(layout.quickTagIDs[1], pinned.id)
        }
        XCTAssertEqual(Set(layout.quickTagIDs + layout.hiddenTagIDs), Set(entries.map(\.tag.id)))
        XCTAssertEqual(Set(layout.quickTagIDs).count, layout.quickTagIDs.count)
    }

    func testShortRecentDoesNotJumpAheadOfPinnedTagThatCannotFit() throws {
        let pinned = try CardTag("A pinned tag whose complete label cannot fit")
        let recent = try CardTag("R")
        let entries = [
            CardLibraryTagEntry(tag: pinned, cardCount: 2, isPinned: true),
            CardLibraryTagEntry(tag: recent, cardCount: 1),
        ]

        let layout = CardLibraryTagFilterBar.layout(
            entries: entries,
            activeTagID: nil,
            candidateOrder: [pinned.id, recent.id],
            availableWidth: 142
        )

        XCTAssertTrue(layout.quickTagIDs.isEmpty)
        XCTAssertEqual(layout.hiddenTagIDs, [pinned.id, recent.id])
    }

    func testMorePopoverSearchesFullCatalogAndRoutesSelectPinAndManage() throws {
        let alpha = try CardTag("Alpha")
        let beta = try CardTag("Beta")
        let gamma = try CardTag("Gamma")
        let entries = [
            CardLibraryTagEntry(tag: alpha, cardCount: 12),
            CardLibraryTagEntry(tag: beta, cardCount: 2, isPinned: true),
            CardLibraryTagEntry(tag: gamma, cardCount: 1),
        ]
        let bar = CardLibraryTagFilterBar(frame: NSRect(x: 0, y: 0, width: 180, height: 28))
        var selected: CardTag?
        var pinChange: (CardTag, Bool)?
        var manageCount = 0
        bar.onSelectionChange = { selected = $0 }
        bar.onPinChange = { pinChange = ($0, $1) }
        bar.onManageTags = { manageCount += 1 }
        bar.update(
            entries: entries,
            activeTagID: beta.id,
            candidateOrder: [beta.id, alpha.id, gamma.id],
            animated: false
        )

        let controller = bar.makeMoreViewController()
        controller.loadView()
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.visibleEntries.map(\.tag.id), entries.map(\.tag.id))
        XCTAssertEqual(controller.rowViews.count, 3)
        XCTAssertEqual(controller.rowViews[0].countLabel.stringValue, "12")
        XCTAssertEqual(controller.rowViews[1].selectButton.accessibilityValue() as? String, "Selected")

        controller.searchField.stringValue = "gam"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.searchField)
        )
        XCTAssertEqual(controller.visibleEntries.map(\.tag.id), [gamma.id])
        controller.rowViews[0].selectButton.performClick(nil)
        XCTAssertEqual(selected, gamma)

        controller.searchField.stringValue = "Alpha"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.searchField)
        )
        controller.rowViews[0].pinButton.performClick(nil)
        XCTAssertEqual(pinChange?.0, alpha)
        XCTAssertEqual(pinChange?.1, true)
        XCTAssertEqual(controller.rowViews[0].pinButton.accessibilityValue() as? String, "Pinned")

        controller.manageButton.performClick(nil)
        XCTAssertEqual(manageCount, 1)
        XCTAssertEqual(controller.searchField.accessibilityLabel(), "Search tags")
        XCTAssertEqual(controller.manageButton.accessibilityLabel(), "Manage tags")

        controller.setManagementActionsEnabled(false)
        XCTAssertFalse(controller.manageButton.isEnabled)
        XCTAssertTrue(controller.rowViews.allSatisfy { !$0.pinButton.isEnabled })
    }

    func testMoreRowsHitTestVisibleLabelsAsOneSelectionTarget() throws {
        let entry = CardLibraryTagEntry(tag: try CardTag("Clickable"), cardCount: 42)
        let row = CardLibraryTagPopoverRowView(entry: entry, selected: false)
        row.frame = NSRect(x: 0, y: 0, width: 310, height: 38)
        row.layoutSubtreeIfNeeded()

        for view in [row.swatch, row.nameLabel, row.countLabel] {
            let point = row.convert(
                NSPoint(x: view.bounds.midX, y: view.bounds.midY),
                from: view
            )
            XCTAssertTrue(row.hitTest(point) === row.selectButton)
        }
    }

    func testMoreControllerRendersHundredRowsSearchesWidthInsensitivelyAndUsesKeyboard() throws {
        let entries = try (0 ..< 100).map { index in
            let prefix = index == 99 ? "ＡＩ" : "Tag"
            return CardLibraryTagEntry(
                tag: try CardTag("\(prefix) \(String(format: "%03d", index))"),
                cardCount: index + 1
            )
        }
        let controller = CardLibraryTagMoreViewController(
            entries: entries,
            activeTagID: nil,
            resolvedAppearance: .dark
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 326, height: 396),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        controller.loadView()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(controller.rowViews.count, 100)
        XCTAssertEqual(controller.scrollView.documentView?.frame.height, 3_800)
        XCTAssertTrue(controller.control(
            controller.searchField,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.moveDown(_:))
        ))
        XCTAssertTrue(window.firstResponder === controller.rowViews[0].selectButton)

        controller.searchField.stringValue = "AI 099"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.searchField)
        )
        XCTAssertEqual(controller.visibleEntries.map(\.tag.name), ["ＡＩ 099"])
        var selected: CardTag?
        controller.onSelectTag = { selected = $0 }
        XCTAssertTrue(controller.control(
            controller.searchField,
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        ))
        XCTAssertEqual(selected?.id, entries[99].tag.id)

        controller.update(entries: Array(entries.prefix(2)), activeTagID: entries[1].tag.id)
        XCTAssertEqual(controller.visibleEntries.count, 0)
        controller.searchField.stringValue = ""
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.searchField)
        )
        XCTAssertEqual(controller.visibleEntries.map(\.tag.id), entries.prefix(2).map(\.tag.id))
    }

    func testMorePopoverAndManagementDismissRestoreFocusToMoreButton() throws {
        let tag = try CardTag("Focus")
        let bar = CardLibraryTagFilterBar(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        let otherField = NSTextField(string: "Other")
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        content.addSubview(bar)
        content.addSubview(otherField)
        let window = NSWindow(
            contentRect: content.bounds,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = content
        bar.update(
            entries: [CardLibraryTagEntry(tag: tag, cardCount: 1)],
            activeTagID: nil,
            candidateOrder: [tag.id],
            animated: false
        )

        XCTAssertTrue(window.makeFirstResponder(otherField))
        bar.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertTrue(window.firstResponder === bar.moreButton)

        XCTAssertTrue(window.makeFirstResponder(otherField))
        bar.restoreMoreButtonFocus()
        XCTAssertTrue(window.firstResponder === bar.moreButton)
    }

    private func descendants<View: NSView>(of type: View.Type, in root: NSView) -> [View] {
        root.subviews.flatMap { subview -> [View] in
            let current = (subview as? View).map { [$0] } ?? []
            return current + descendants(of: type, in: subview)
        }
    }
}

@MainActor
final class TagManagementWindowControllerTests: XCTestCase {
    func testManagementSearchPinAndConfirmedMutationsUseClosures() throws {
        let alpha = try CardTag("Alpha")
        let beta = try CardTag("Beta")
        let entries = [
            CardLibraryTagEntry(tag: alpha, cardCount: 7),
            CardLibraryTagEntry(tag: beta, cardCount: 3, isPinned: true),
        ]
        let presenter = ImmediateTagManagementConfirmationPresenter()
        presenter.renameResponse = "Renamed Alpha"
        presenter.mergeResponse = beta
        presenter.deleteResponse = true
        let controller = TagManagementWindowController(confirmationPresenter: presenter)
        var pins: [(CardTag, Bool)] = []
        var renames: [(CardTag, String)] = []
        var merges: [(CardTag, CardTag)] = []
        var deletes: [CardTag] = []
        controller.onPinChange = { pins.append(($0, $1)) }
        controller.onRenameTag = { renames.append(($0, $1)) }
        controller.onMergeTag = { merges.append(($0, $1)) }
        controller.onDeleteTag = { deletes.append($0) }
        controller.update(entries: entries, selectedTagID: alpha.id)

        XCTAssertEqual(controller.visibleEntries.map(\.tag.id), [alpha.id, beta.id])
        XCTAssertEqual(controller.tableView.numberOfRows, 2)
        XCTAssertTrue(controller.renameButton.isEnabled)
        XCTAssertTrue(controller.mergeButton.isEnabled)
        XCTAssertTrue(controller.deleteButton.isEnabled)

        let pinColumn = try XCTUnwrap(controller.tableView.tableColumns.first)
        let pinButton = try XCTUnwrap(
            controller.tableView(
                controller.tableView,
                viewFor: pinColumn,
                row: 0
            ) as? TagManagementPinButton
        )
        pinButton.performClick(nil)
        XCTAssertEqual(pins.count, 1)
        XCTAssertEqual(pins[0].0, alpha)
        XCTAssertEqual(pins[0].1, true)

        controller.renameButton.performClick(nil)
        controller.mergeButton.performClick(nil)
        controller.deleteButton.performClick(nil)
        XCTAssertEqual(renames.first?.0, alpha)
        XCTAssertEqual(renames.first?.1, "Renamed Alpha")
        XCTAssertEqual(merges.first?.0, alpha)
        XCTAssertEqual(merges.first?.1, beta)
        XCTAssertEqual(deletes, [alpha])
        XCTAssertEqual(presenter.renameRequests, [alpha])
        XCTAssertEqual(presenter.mergeRequests, [alpha])
        XCTAssertEqual(presenter.deleteRequests, [alpha])
        XCTAssertEqual(presenter.lastDeleteCardCount, 7)

        controller.searchField.stringValue = "beta"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: controller.searchField)
        )
        XCTAssertEqual(controller.visibleEntries.map(\.tag.id), [beta.id])
        XCTAssertEqual(controller.tableView.numberOfRows, 1)
        XCTAssertEqual(controller.searchField.accessibilityLabel(), "Search tags")
        XCTAssertEqual(controller.doneButton.keyEquivalent, "\u{1b}")

        controller.setMutationActionsEnabled(false)
        XCTAssertFalse(controller.renameButton.isEnabled)
        XCTAssertFalse(controller.mergeButton.isEnabled)
        XCTAssertFalse(controller.deleteButton.isEnabled)
        let renameRequestCount = presenter.renameRequests.count
        let doubleAction = try XCTUnwrap(controller.tableView.doubleAction)
        _ = NSApp.sendAction(
            doubleAction,
            to: controller.tableView.target,
            from: controller.tableView
        )
        XCTAssertEqual(presenter.renameRequests.count, renameRequestCount)
        let disabledPin = try XCTUnwrap(
            controller.tableView(
                controller.tableView,
                viewFor: pinColumn,
                row: 0
            ) as? TagManagementPinButton
        )
        XCTAssertFalse(disabledPin.isEnabled)
    }

    func testManagementSheetDismissesAndReportsOnce() throws {
        let controller = TagManagementWindowController(
            confirmationPresenter: ImmediateTagManagementConfirmationPresenter()
        )
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        var dismissCount = 0
        controller.onDismiss = { dismissCount += 1 }

        controller.beginSheet(for: parent)
        XCTAssertTrue(controller.window?.sheetParent === parent)
        controller.doneButton.performClick(nil)
        XCTAssertNil(controller.window?.sheetParent)
        XCTAssertEqual(dismissCount, 1)
        controller.windowWillClose(
            Notification(name: NSWindow.willCloseNotification, object: controller.window)
        )
        XCTAssertEqual(dismissCount, 1)
    }

    func testRenameToExistingIdentityRequiresMergeConfirmationAndRoutesAsMerge() throws {
        let source = try CardTag("Source")
        let target = try CardTag("Target")
        let presenter = ImmediateTagManagementConfirmationPresenter()
        presenter.renameResponse = "TARGET"
        presenter.mergeResponse = target
        let controller = TagManagementWindowController(confirmationPresenter: presenter)
        var renames: [(CardTag, String)] = []
        var merges: [(CardTag, CardTag)] = []
        controller.onRenameTag = { renames.append(($0, $1)) }
        controller.onMergeTag = { merges.append(($0, $1)) }
        controller.update(
            entries: [
                CardLibraryTagEntry(tag: source, cardCount: 2),
                CardLibraryTagEntry(tag: target, cardCount: 3),
            ],
            selectedTagID: source.id
        )

        controller.renameButton.performClick(nil)

        XCTAssertTrue(renames.isEmpty)
        XCTAssertEqual(merges.count, 1)
        XCTAssertEqual(merges[0].0, source)
        XCTAssertEqual(merges[0].1, target)
        XCTAssertEqual(presenter.renameRequests, [source])
        XCTAssertEqual(presenter.mergeRequests, [source])
    }

    func testCancelledManagementConfirmationsDoNotPublishMutations() throws {
        let alpha = try CardTag("Alpha")
        let beta = try CardTag("Beta")
        let presenter = ImmediateTagManagementConfirmationPresenter()
        let controller = TagManagementWindowController(confirmationPresenter: presenter)
        var renames: [(CardTag, String)] = []
        var merges: [(CardTag, CardTag)] = []
        var deletes: [CardTag] = []
        controller.onRenameTag = { renames.append(($0, $1)) }
        controller.onMergeTag = { merges.append(($0, $1)) }
        controller.onDeleteTag = { deletes.append($0) }
        controller.update(
            entries: [
                CardLibraryTagEntry(tag: alpha, cardCount: 2),
                CardLibraryTagEntry(tag: beta, cardCount: 1),
            ],
            selectedTagID: alpha.id
        )

        controller.renameButton.performClick(nil)
        controller.mergeButton.performClick(nil)
        controller.deleteButton.performClick(nil)

        XCTAssertTrue(renames.isEmpty)
        XCTAssertTrue(merges.isEmpty)
        XCTAssertTrue(deletes.isEmpty)
        XCTAssertEqual(presenter.renameRequests, [alpha])
        XCTAssertEqual(presenter.mergeRequests, [alpha])
        XCTAssertEqual(presenter.deleteRequests, [alpha])
    }

    func testDisablingActionsWhileConfirmationIsOpenDropsItsCompletion() throws {
        let alpha = try CardTag("Alpha")
        let beta = try CardTag("Beta")
        let presenter = DeferredTagManagementConfirmationPresenter()
        let controller = TagManagementWindowController(confirmationPresenter: presenter)
        var renameCount = 0
        var mergeCount = 0
        var deleteCount = 0
        controller.onRenameTag = { _, _ in renameCount += 1 }
        controller.onMergeTag = { _, _ in mergeCount += 1 }
        controller.onDeleteTag = { _ in deleteCount += 1 }
        controller.update(
            entries: [
                CardLibraryTagEntry(tag: alpha, cardCount: 2),
                CardLibraryTagEntry(tag: beta, cardCount: 1),
            ],
            selectedTagID: alpha.id
        )

        controller.renameButton.performClick(nil)
        controller.setMutationActionsEnabled(false)
        presenter.renameCompletion?("Renamed")
        XCTAssertEqual(renameCount, 0)

        controller.setMutationActionsEnabled(true)
        controller.mergeButton.performClick(nil)
        controller.setMutationActionsEnabled(false)
        presenter.mergeCompletion?(beta)
        XCTAssertEqual(mergeCount, 0)

        controller.setMutationActionsEnabled(true)
        controller.deleteButton.performClick(nil)
        controller.setMutationActionsEnabled(false)
        presenter.deleteCompletion?(true)
        XCTAssertEqual(deleteCount, 0)
    }

    func testCatalogRefreshPreservesManagementSelectionWhenNoOverrideIsRequested() throws {
        let alpha = try CardTag("Alpha")
        let beta = try CardTag("Beta")
        let controller = TagManagementWindowController(
            confirmationPresenter: ImmediateTagManagementConfirmationPresenter()
        )
        let entries = [
            CardLibraryTagEntry(tag: alpha, cardCount: 1),
            CardLibraryTagEntry(tag: beta, cardCount: 2),
        ]
        controller.update(entries: entries, selectedTagID: alpha.id)
        controller.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        controller.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: controller.tableView)
        )

        controller.update(
            entries: [
                entries[0],
                CardLibraryTagEntry(tag: beta, cardCount: 2, isPinned: true),
            ],
            selectedTagID: nil
        )

        XCTAssertEqual(controller.tableView.selectedRow, 1)
        XCTAssertTrue(controller.renameButton.isEnabled)
    }
}

@MainActor
private final class ImmediateTagManagementConfirmationPresenter:
    TagManagementConfirmationPresenting
{
    var renameResponse: String?
    var mergeResponse: CardTag?
    var deleteResponse = false
    var renameRequests: [CardTag] = []
    var mergeRequests: [CardTag] = []
    var deleteRequests: [CardTag] = []
    var lastDeleteCardCount: Int?

    func requestRename(
        tag: CardTag,
        in window: NSWindow,
        completion: @escaping (String?) -> Void
    ) {
        renameRequests.append(tag)
        completion(renameResponse)
    }

    func requestMerge(
        source: CardTag,
        candidates: [CardTag],
        in window: NSWindow,
        completion: @escaping (CardTag?) -> Void
    ) {
        mergeRequests.append(source)
        completion(mergeResponse)
    }

    func requestDelete(
        tag: CardTag,
        cardCount: Int,
        in window: NSWindow,
        completion: @escaping (Bool) -> Void
    ) {
        deleteRequests.append(tag)
        lastDeleteCardCount = cardCount
        completion(deleteResponse)
    }
}

@MainActor
private final class DeferredTagManagementConfirmationPresenter:
    TagManagementConfirmationPresenting
{
    var renameCompletion: ((String?) -> Void)?
    var mergeCompletion: ((CardTag?) -> Void)?
    var deleteCompletion: ((Bool) -> Void)?

    func requestRename(
        tag: CardTag,
        in window: NSWindow,
        completion: @escaping (String?) -> Void
    ) {
        renameCompletion = completion
    }

    func requestMerge(
        source: CardTag,
        candidates: [CardTag],
        in window: NSWindow,
        completion: @escaping (CardTag?) -> Void
    ) {
        mergeCompletion = completion
    }

    func requestDelete(
        tag: CardTag,
        cardCount: Int,
        in window: NSWindow,
        completion: @escaping (Bool) -> Void
    ) {
        deleteCompletion = completion
    }
}
