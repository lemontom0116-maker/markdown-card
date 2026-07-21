import AppKit
import XCTest
@testable import MarkdownCardAgent
import MarkdownCardCore

final class CardLibraryTagTests: XCTestCase {
    @MainActor
    func testFileOperationSelectionGuardRejectsASelectionChangedDuringAwait() throws {
        let expected = UUID()
        XCTAssertNoThrow(try CardLibraryWindowController.validateFileOperationSelection(
            expected: expected,
            current: expected
        ))
        XCTAssertThrowsError(try CardLibraryWindowController.validateFileOperationSelection(
            expected: expected,
            current: UUID()
        )) { error in
            XCTAssertEqual(error as? CardLibraryFileOperationError, .selectionChanged)
        }
        XCTAssertThrowsError(try CardLibraryWindowController.validateFileOperationSelection(
            expected: expected,
            current: nil
        ))
    }

    @MainActor
    func testLibraryTagCatalogUsesFirstCardCreationAppearanceAndDeduplicates() throws {
        let first = try CardTag("research")
        let second = try CardTag("reading")
        let laterSpelling = try CardTag("RESEARCH")
        let base = Date(timeIntervalSince1970: 1_000)
        let oldest = CardRecord(
            markdown: "oldest",
            createdAt: base,
            tags: [first, second]
        )
        let newest = CardRecord(
            markdown: "newest",
            createdAt: base.addingTimeInterval(60),
            tags: [laterSpelling]
        )

        let ordered = CardLibraryWindowController.orderedTags(in: [newest, oldest])
        XCTAssertEqual(ordered.map(\.id), [first.id, second.id])
        XCTAssertEqual(ordered.map(\.name), ["research", "reading"])
    }

    @MainActor
    func testLibraryDefersPreferenceCleanupUntilGlobalMutationUnfreezes() throws {
        let alpha = try CardTag("Alpha")
        let beta = try CardTag("Beta")
        let valid = Set([alpha.id, beta.id])
        let suite = "CardLibraryTagPreferenceFreezeTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TagCatalogPreferencesStore(defaults: defaults)
        _ = try store.setPinned(true, tagID: alpha.id, validTagIDs: valid)
        _ = try store.setPinned(true, tagID: beta.id, validTagIDs: valid)
        let controller = CardLibraryWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults,
            tagPreferencesStore: store
        )
        let card = CardRecord(markdown: "Alpha", tags: [alpha])

        controller.setGlobalTagMutationInFlight(true)
        controller.applySnapshot([card], revisions: [card.id: 0])

        XCTAssertEqual(
            store.load(validTagIDs: valid, persistCleanup: false).pinnedTagIDs,
            valid
        )

        controller.setGlobalTagMutationInFlight(false)

        XCTAssertEqual(
            store.load(validTagIDs: valid, persistCleanup: false).pinnedTagIDs,
            [alpha.id]
        )
    }

    @MainActor
    func testLibrarySingleTagStartsInAllStateWithoutFilteringOrNotification() throws {
        let research = try CardTag("research")
        let base = Date(timeIntervalSince1970: 1_500)
        let untagged = CardRecord(markdown: "untagged", createdAt: base)
        let tagged = CardRecord(
            markdown: "tagged and selected",
            createdAt: base.addingTimeInterval(10),
            tags: [research]
        )
        let defaults = UserDefaults(suiteName: "CardLibraryTagTests.\(UUID())")!
        let controller = CardLibraryWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )
        var selectionEvents: [(UUID, String?)] = []
        controller.onTagSelectionChange = { selectionEvents.append(($0, $1)) }
        let cards = [tagged, untagged]

        controller.applySnapshot(
            cards,
            revisions: Dictionary(uniqueKeysWithValues: cards.map { ($0.id, 0) })
        )

        let root = try XCTUnwrap(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let sidebar = try XCTUnwrap(
            descendants(of: CardLibraryTagFilterBar.self, in: root).first
        )
        let table = try XCTUnwrap(descendants(of: NSTableView.self, in: root).first)
        XCTAssertNil(sidebar.activeTagID)
        XCTAssertTrue(sidebar.quickTagButtons.allSatisfy { !$0.isTagSelected })
        XCTAssertEqual(table.numberOfRows, 2)
        XCTAssertTrue(selectionEvents.isEmpty)
    }

    @MainActor
    func testLibraryEmptyStateDistinguishesNoCardsFromNoFilterMatches() {
        XCTAssertEqual(
            CardLibraryWindowController.emptyState(totalCardCount: 0, filteredCardCount: 0),
            .noCards
        )
        XCTAssertEqual(
            CardLibraryWindowController.emptyState(totalCardCount: 3, filteredCardCount: 0),
            .noMatches
        )
        XCTAssertEqual(
            CardLibraryWindowController.emptyState(totalCardCount: 3, filteredCardCount: 2),
            .noSelection
        )
        XCTAssertEqual(CardLibraryEmptyState.noMatches.title, "No matching cards")
        XCTAssertTrue(CardLibraryEmptyState.noMatches.note.contains("clear"))
    }

    @MainActor
    func testLibraryDocumentHeaderUsesSharedResponsiveTagLayout() throws {
        let tag = try CardTag("sample")
        let taggedCard = CardRecord(markdown: "# Tagged", tags: [tag])
        let defaults = UserDefaults(suiteName: "CardLibraryTagTests.\(UUID())")!
        let controller = CardLibraryWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults
        )

        controller.applySnapshot([taggedCard], revisions: [taggedCard.id: 0])

        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)
        root.layoutSubtreeIfNeeded()
        let splitView = try XCTUnwrap(root as? NSSplitView)
        let documentTagStrip = try XCTUnwrap(
            descendants(of: CurtainTagStripView.self, in: root).first {
                !$0.tagButtons.isEmpty && $0.tagButtons.allSatisfy { $0.menu != nil }
            }
        )
        let documentHeader = try XCTUnwrap(documentTagStrip.superview)

        XCTAssertEqual(documentHeader.frame.height, CardHeaderView.expandedHeight, accuracy: 0.001)
        XCTAssertGreaterThan(documentHeader.frame.width, CardContentLayoutMetrics.compactBreakpoint)
        XCTAssertEqual(documentTagStrip.frame.minX, 40, accuracy: 0.001)
        XCTAssertEqual(documentTagStrip.frame.height, CardHeaderView.tagRailHeight, accuracy: 0.001)

        for titleRowView in documentHeader.subviews where titleRowView !== documentTagStrip {
            let centerConstraint = try XCTUnwrap(
                documentHeader.constraints.first {
                    ($0.firstItem as? NSView) === titleRowView
                        && $0.firstAttribute == .centerY
                        && ($0.secondItem as? NSView) === documentHeader
                        && $0.secondAttribute == .top
                }
            )
            XCTAssertEqual(
                centerConstraint.constant,
                CardHeaderView.titleRowHeight / 2,
                accuracy: 0.001
            )
            let distanceFromTop = documentHeader.isFlipped
                ? titleRowView.frame.midY
                : documentHeader.bounds.maxY - titleRowView.frame.midY
            XCTAssertEqual(
                distanceFromTop,
                CardHeaderView.titleRowHeight / 2,
                accuracy: 1,
                "\(type(of: titleRowView)) is not centered in the shared 48-point title row"
            )
        }

        window.setContentSize(NSSize(width: 820, height: 760))
        root.layoutSubtreeIfNeeded()
        controller.splitViewDidResizeSubviews(
            Notification(name: NSSplitView.didResizeSubviewsNotification, object: splitView)
        )
        root.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(
            documentHeader.frame.width,
            CardContentLayoutMetrics.compactBreakpoint
        )
        XCTAssertEqual(documentTagStrip.frame.minX, 28, accuracy: 0.001)

        window.setContentSize(NSSize(width: 1180, height: 760))
        root.layoutSubtreeIfNeeded()
        controller.splitViewDidResizeSubviews(
            Notification(name: NSSplitView.didResizeSubviewsNotification, object: splitView)
        )
        root.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(documentHeader.frame.width, CardContentLayoutMetrics.compactBreakpoint)
        XCTAssertEqual(documentTagStrip.frame.minX, 40, accuracy: 0.001)

        let untaggedCard = CardRecord(markdown: "# Untagged")
        controller.applySnapshot([untaggedCard], revisions: [untaggedCard.id: 1])
        root.layoutSubtreeIfNeeded()

        XCTAssertEqual(documentHeader.frame.height, CardHeaderView.titleRowHeight, accuracy: 0.001)
        XCTAssertTrue(documentTagStrip.isHidden)
    }

    @MainActor
    func testLibrarySeriesNavigationNeverLeavesFilteredCards() throws {
        let tag = try CardTag("research")
        let base = Date(timeIntervalSince1970: 2_000)
        let oldest = CardRecord(
            markdown: "oldest visible match",
            createdAt: base,
            tags: [tag]
        )
        let excludedMiddle = CardRecord(
            markdown: "excluded by search",
            createdAt: base.addingTimeInterval(10),
            tags: [tag]
        )
        let newest = CardRecord(
            markdown: "newest visible match",
            createdAt: base.addingTimeInterval(20),
            tags: [tag]
        )
        let filtered = [newest, oldest]

        let newestNeighbors = CardLibraryWindowController.seriesNeighbors(
            of: newest.id,
            tagID: tag.id,
            within: filtered
        )
        XCTAssertNil(newestNeighbors?.newerCardID)
        XCTAssertEqual(newestNeighbors?.olderCardID, oldest.id)
        XCTAssertNotEqual(newestNeighbors?.olderCardID, excludedMiddle.id)

        let oldestNeighbors = CardLibraryWindowController.seriesNeighbors(
            of: oldest.id,
            tagID: tag.id,
            within: filtered
        )
        XCTAssertEqual(oldestNeighbors?.newerCardID, newest.id)
        XCTAssertNil(oldestNeighbors?.olderCardID)
    }

    @MainActor
    func testLibraryTagSelectionUsesFilteredCardAndEveryClearPathDeactivatesIt() throws {
        let research = try CardTag("research")
        let reading = try CardTag("reading")
        let ideas = try CardTag("ideas")
        let base = Date(timeIntervalSince1970: 3_000)
        let untagged = CardRecord(markdown: "untagged", createdAt: base)
        let researchOnly = CardRecord(
            markdown: "research only",
            createdAt: base.addingTimeInterval(10),
            tags: [research]
        )
        var selected = CardRecord(
            markdown: "selected",
            createdAt: base.addingTimeInterval(20),
            tags: [reading, ideas]
        )
        let defaults = UserDefaults(suiteName: "CardLibraryTagTests.\(UUID())")!
        let tagPreferencesStore = TagCatalogPreferencesStore(defaults: defaults)
        _ = try tagPreferencesStore.setPinned(
            true,
            tagID: research.id,
            validTagIDs: [research.id, reading.id, ideas.id]
        )
        let controller = CardLibraryWindowController(
            appearanceController: AppearanceController(defaults: defaults),
            defaults: defaults,
            tagPreferencesStore: tagPreferencesStore
        )
        var selectionEvents: [(UUID, String?)] = []
        controller.onTagSelectionChange = { selectionEvents.append(($0, $1)) }
        let cards = [selected, researchOnly, untagged]
        controller.applySnapshot(
            cards,
            revisions: Dictionary(uniqueKeysWithValues: cards.map { ($0.id, 0) })
        )
        controller.showLibrary()
        defer { controller.window?.orderOut(nil) }

        let root = try XCTUnwrap(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let sidebar = try XCTUnwrap(
            descendants(of: CardLibraryTagFilterBar.self, in: root).first
        )
        let table = try XCTUnwrap(descendants(of: NSTableView.self, in: root).first)
        let researchButton = try XCTUnwrap(
            sidebar.quickTagButtons.first(where: { $0.cardTag.id == research.id })
        )

        XCTAssertEqual(table.numberOfRows, 3)
        researchButton.performClick(nil)
        XCTAssertTrue(researchButton.isTagSelected)
        XCTAssertEqual(sidebar.activeTagID, research.id)
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(selectionEvents.count, 1)
        XCTAssertEqual(selectionEvents[0].0, researchOnly.id)
        XCTAssertEqual(selectionEvents[0].1, research.id)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))

        researchButton.performClick(nil)
        XCTAssertFalse(researchButton.isTagSelected)
        XCTAssertNil(sidebar.activeTagID)
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertEqual(selectionEvents.count, 2)
        XCTAssertEqual(selectionEvents[1].0, researchOnly.id)
        XCTAssertNil(selectionEvents[1].1)

        researchButton.performClick(nil)
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(selectionEvents.count, 3)
        XCTAssertEqual(selectionEvents[2].0, researchOnly.id)
        XCTAssertEqual(selectionEvents[2].1, research.id)

        let searchField = try XCTUnwrap(descendants(of: NSSearchField.self, in: root).first)
        searchField.stringValue = "no matching research card"
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: searchField)
        )
        XCTAssertEqual(table.numberOfRows, 0)
        let clearButton = try XCTUnwrap(
            descendants(of: NSButton.self, in: root).first { $0.title == "Clear Filters" }
        )
        clearButton.performClick(nil)
        XCTAssertEqual(searchField.stringValue, "")
        XCTAssertNil(sidebar.activeTagID)
        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertEqual(selectionEvents.count, 4)
        XCTAssertEqual(selectionEvents[3].0, researchOnly.id)
        XCTAssertNil(selectionEvents[3].1)

        selected.tags = [reading]
        let refreshedCards = [selected, researchOnly, untagged]
        controller.applySnapshot(
            refreshedCards,
            revisions: Dictionary(uniqueKeysWithValues: refreshedCards.map { ($0.id, 1) })
        )
        XCTAssertFalse(researchButton.isTagSelected)
        XCTAssertEqual(table.numberOfRows, 3)
    }

    @MainActor
    private func descendants<View: NSView>(
        of type: View.Type,
        in root: NSView
    ) -> [View] {
        var matches = root.subviews.compactMap { $0 as? View }
        for subview in root.subviews {
            matches.append(contentsOf: descendants(of: type, in: subview))
        }
        return matches
    }
}
