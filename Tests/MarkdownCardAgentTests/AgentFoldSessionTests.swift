import AppKit
import KeyboardShortcuts
import MarkdownCardCore
import XCTest
@testable import MarkdownCardAgent

private actor FoldSessionCardRepository: CardRepository {
    private var cardsByID: [UUID: CardRecord] = [:]

    func allCards() async throws -> [CardRecord] {
        Array(cardsByID.values)
    }

    func card(id: UUID) async throws -> CardRecord? {
        cardsByID[id]
    }

    func upsert(_ card: CardRecord) async throws -> CardRecord {
        cardsByID[card.id] = card
        return card
    }

    func delete(id: UUID) async throws -> Bool {
        cardsByID.removeValue(forKey: id) != nil
    }

    func deleteLegacyQuickCards() async throws -> Int {
        let ids = cardsByID.values.filter(\.isQuick).map(\.id)
        ids.forEach { cardsByID[$0] = nil }
        return ids.count
    }

    func replaceAll(with cards: [CardRecord]) async throws {
        let replacement = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        guard replacement.count == cards.count else {
            let duplicate = cards.first { card in
                cards.filter { $0.id == card.id }.count > 1
            }!
            throw CardRepositoryError.duplicateCardID(duplicate.id)
        }
        cardsByID = replacement
    }

}

@MainActor
final class AgentFoldSessionTests: XCTestCase {
    func testFocusedCardShortcutFoldsThroughAgentWiring() async throws {
        let savedShortcut = KeyboardShortcuts.getShortcut(for: .toggleFoldedCards)
        defer { KeyboardShortcuts.setShortcut(savedShortcut, for: .toggleFoldedCards) }
        KeyboardShortcuts.setShortcut(
            KeyboardShortcuts.Shortcut(.k, modifiers: [.control, .option]),
            for: .toggleFoldedCards
        )

        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let card = try await fixture.controller.createIndependentCard(
            markdown: "# Card-focused Fold"
        )
        let window = try XCTUnwrap(fixture.controller.cardWindowForTesting(card.id))
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.control, .option],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "k",
            charactersIgnoringModifiers: "k",
            isARepeat: false,
            keyCode: 40
        ))

        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertTrue(fixture.controller.isFolded)
        let storedCard = try await fixture.repository.card(id: card.id)
        XCTAssertTrue(storedCard?.isVisible == true)

        fixture.controller.restoreFoldedCards(animated: false)
        await hideAllCards(in: fixture.controller)
    }

    func testRestoreReconstructsWindowFramesZOrderAndKeyCard() async throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("A window-server display is required for z-order restoration testing")
        }
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let backCard = try await fixture.controller.createIndependentCard(markdown: "# Back")
        let keyCard = try await fixture.controller.createIndependentCard(markdown: "# Key")
        let backWindow = try XCTUnwrap(fixture.controller.cardWindowForTesting(backCard.id))
        let keyWindow = try XCTUnwrap(fixture.controller.cardWindowForTesting(keyCard.id))
        let visibleFrame = screen.visibleFrame
        let backFrame = NSRect(
            x: visibleFrame.minX + 40,
            y: visibleFrame.minY + 40,
            width: min(360, visibleFrame.width - 80),
            height: min(300, visibleFrame.height - 80)
        )
        let keyFrame = NSRect(
            x: visibleFrame.minX + 90,
            y: visibleFrame.minY + 90,
            width: min(360, visibleFrame.width - 180),
            height: min(300, visibleFrame.height - 180)
        )
        backWindow.setFrame(backFrame, display: false)
        keyWindow.setFrame(keyFrame, display: false)
        backWindow.orderFront(nil)
        keyWindow.makeKeyAndOrderFront(nil)
        let beforeOrder = cardWindowOrder([backWindow, keyWindow])
        let establishedKeyWindow = keyWindow.isKeyWindow

        fixture.controller.foldAllCards(animated: false)
        XCTAssertFalse(backWindow.isVisible)
        XCTAssertFalse(keyWindow.isVisible)

        fixture.controller.restoreFoldedCards(animated: false)
        XCTAssertTrue(backWindow.isVisible)
        XCTAssertTrue(keyWindow.isVisible)
        XCTAssertEqual(backWindow.frame, backFrame)
        XCTAssertEqual(keyWindow.frame, keyFrame)
        if !beforeOrder.isEmpty {
            XCTAssertEqual(cardWindowOrder([backWindow, keyWindow]), beforeOrder)
            if establishedKeyWindow {
                XCTAssertTrue(keyWindow.isKeyWindow)
            }
        }

        await hideAllCards(in: fixture.controller)
    }

    func testFoldAndRestoreAreIdempotentAndDoNotMutateCardRecords() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let stableTag = try CardTag("Stable")
        let first = try await fixture.controller.createIndependentCard(
            markdown: "# First",
            tags: [stableTag]
        )
        let second = try await fixture.controller.createIndependentCard(
            markdown: "# Second",
            tags: [stableTag]
        )

        // The first panel flush commits the initial AppKit-assigned frame and
        // screen. Establish that presentation baseline before measuring Fold.
        fixture.controller.foldAllCards(animated: false)
        fixture.controller.restoreFoldedCards(animated: false)

        // A duplicate Tag is a mutation-free way to drain the presentation
        // persistence generated while the two windows were first shown.
        _ = try await fixture.controller.addTag(id: first.id, name: stableTag.name)
        _ = try await fixture.controller.addTag(id: second.id, name: stableTag.name)
        let before = try await records([first.id, second.id], in: fixture.repository)

        fixture.controller.foldAllCards(animated: false)
        fixture.controller.foldAllCards(animated: false)

        XCTAssertTrue(fixture.controller.isFolded)
        XCTAssertEqual(fixture.controller.foldedCardCount, 2)
        let foldedList = try await listPayload(from: fixture.controller)
        XCTAssertTrue(foldedList.isFolded)
        XCTAssertTrue(foldedList.cards.allSatisfy(\.isVisible))
        try await assertRecordsUnchanged(
            before,
            ids: [first.id, second.id],
            repository: fixture.repository
        )

        fixture.controller.restoreFoldedCards(animated: false)
        fixture.controller.restoreFoldedCards(animated: false)

        XCTAssertFalse(fixture.controller.isFolded)
        XCTAssertEqual(fixture.controller.foldedCardCount, 0)
        let restoredList = try await listPayload(from: fixture.controller)
        XCTAssertFalse(restoredList.isFolded)
        try await assertRecordsUnchanged(
            before,
            ids: [first.id, second.id],
            repository: fixture.repository
        )
        await hideAllCards(in: fixture.controller)
    }

    func testCreateShowHideDeleteAndTransientCardsQueueWhileFolded() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let anchor = try await fixture.controller.createIndependentCard(markdown: "# Anchor")
        let initiallyHidden = try await fixture.controller.createIndependentCard(
            markdown: "# Initially hidden"
        )
        let initialHideResponse = await send(
            .hide(HideOptions(selector: .card(initiallyHidden.id))),
            to: fixture.controller
        )
        XCTAssertTrue(initialHideResponse.ok)

        fixture.controller.foldAllCards(animated: false)
        XCTAssertEqual(fixture.controller.foldedCardCount, 1)

        let queuedCreate = try await fixture.controller.createIndependentCard(
            markdown: "# Created while folded"
        )
        let showResponse = await send(
            .show(ShowOptions(cardID: initiallyHidden.id)),
            to: fixture.controller
        )
        XCTAssertTrue(showResponse.ok)

        let removedByHide = try await fixture.controller.createIndependentCard(
            markdown: "# Hide while folded"
        )
        let hideResponse = await send(
            .hide(HideOptions(selector: .card(removedByHide.id))),
            to: fixture.controller
        )
        XCTAssertTrue(hideResponse.ok)

        let removedByDelete = try await fixture.controller.createIndependentCard(
            markdown: "# Delete while folded"
        )
        let deleteResponse = await send(
            .delete(DeleteOptions(cardID: removedByDelete.id, force: true)),
            to: fixture.controller
        )
        XCTAssertTrue(deleteResponse.ok)

        let transient = try await fixture.controller.createIndependentCard(
            show: true,
            persistEmpty: false
        )
        let transientHideResponse = await send(
            .hide(HideOptions(selector: .card(transient.id))),
            to: fixture.controller
        )
        XCTAssertTrue(transientHideResponse.ok)

        XCTAssertTrue(fixture.controller.isFolded)
        XCTAssertEqual(fixture.controller.foldedCardCount, 3)
        let storedAnchor = try await fixture.repository.card(id: anchor.id)
        let storedQueuedCreate = try await fixture.repository.card(id: queuedCreate.id)
        let storedInitiallyHidden = try await fixture.repository.card(id: initiallyHidden.id)
        let storedRemovedByHide = try await fixture.repository.card(id: removedByHide.id)
        let storedRemovedByDelete = try await fixture.repository.card(id: removedByDelete.id)
        let storedTransient = try await fixture.repository.card(id: transient.id)
        XCTAssertTrue(storedAnchor?.isVisible == true)
        XCTAssertTrue(storedQueuedCreate?.isVisible == true)
        XCTAssertTrue(storedInitiallyHidden?.isVisible == true)
        XCTAssertFalse(storedRemovedByHide?.isVisible == true)
        XCTAssertNil(storedRemovedByDelete)
        XCTAssertNil(storedTransient)

        fixture.controller.restoreFoldedCards(animated: false)
        XCTAssertFalse(fixture.controller.isFolded)
        let visibleIDs = Set(
            try await listPayload(from: fixture.controller).cards
                .filter(\.isVisible)
                .map(\.id)
        )
        XCTAssertEqual(visibleIDs, Set([anchor.id, queuedCreate.id, initiallyHidden.id]))

        await hideAllCards(in: fixture.controller)
    }

    func testUnavailableSessionRejectsUnfoldAndWakeDoesNotRestoreAutomatically() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.controller.createIndependentCard(markdown: "# Lock test")
        fixture.controller.foldAllCards(animated: false)

        fixture.controller.handleSystemSleepEvent(.screenLocked)
        fixture.controller.handleSystemSleepEvent(.screensDidSleep)

        let lockedResponse = await send(.unfold, to: fixture.controller)
        XCTAssertFalse(lockedResponse.ok)
        XCTAssertEqual(lockedResponse.error?.code, "screen_locked")
        XCTAssertTrue(fixture.controller.isFolded)

        fixture.controller.handleSystemSleepEvent(.screenUnlocked)
        let displayStillAsleepResponse = await send(.unfold, to: fixture.controller)
        XCTAssertFalse(displayStillAsleepResponse.ok)
        XCTAssertEqual(displayStillAsleepResponse.error?.code, "screen_locked")
        XCTAssertTrue(fixture.controller.isFolded)

        fixture.controller.handleSystemSleepEvent(.screensDidWake)
        XCTAssertTrue(fixture.controller.isFolded, "Wake only reveals the stack affordance")
        let awakeList = try await listPayload(from: fixture.controller)
        XCTAssertTrue(awakeList.isFolded)

        let restoredResponse = await send(.unfold, to: fixture.controller)
        XCTAssertTrue(restoredResponse.ok)
        XCTAssertFalse(fixture.controller.isFolded)

        await hideAllCards(in: fixture.controller)
    }

    func testCreateAfterLockWithNoExistingVisibleCardsQueuesWithoutFlashing() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        fixture.controller.handleSystemSleepEvent(.screenLocked)

        let queued = try await fixture.controller.createIndependentCard(markdown: "# Locked create")
        let window = try XCTUnwrap(fixture.controller.cardWindowForTesting(queued.id))
        XCTAssertTrue(fixture.controller.isFolded)
        XCTAssertFalse(window.isVisible)

        fixture.controller.handleSystemSleepEvent(.screenUnlocked)
        XCTAssertTrue(fixture.controller.isFolded)
        XCTAssertFalse(window.isVisible, "Unlock only reveals the stack affordance")
        fixture.controller.restoreFoldedCards(animated: false)
        XCTAssertTrue(window.isVisible)

        await hideAllCards(in: fixture.controller)
    }

    func testHidingLastVisibleCardEndsFoldSessionAndEmptyFoldIsNoOp() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        let card = try await fixture.controller.createIndependentCard(markdown: "# Only card")
        fixture.controller.foldAllCards(animated: false)
        XCTAssertTrue(fixture.controller.isFolded)

        let hideResponse = await send(
            .hide(HideOptions(selector: .card(card.id))),
            to: fixture.controller
        )
        XCTAssertTrue(hideResponse.ok)
        XCTAssertFalse(fixture.controller.isFolded)
        XCTAssertEqual(fixture.controller.foldedCardCount, 0)

        fixture.controller.foldAllCards(animated: false)
        XCTAssertFalse(fixture.controller.isFolded)
    }

    func testFoldStateIsProcessLocalToControllerInstance() async throws {
        let fixture = makeFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.controller.createIndependentCard(markdown: "# Session one")
        fixture.controller.foldAllCards(animated: false)
        XCTAssertTrue(fixture.controller.isFolded)

        let replacement = AgentApplicationController(
            repository: fixture.repository,
            appearanceController: AppearanceController(defaults: fixture.defaults),
            defaults: fixture.defaults
        )
        XCTAssertFalse(replacement.isFolded)
        XCTAssertEqual(replacement.foldedCardCount, 0)
        replacement.foldAllCards(animated: false)
        XCTAssertFalse(replacement.isFolded, "Fold sessions are not loaded from defaults or storage")

        fixture.controller.restoreFoldedCards(animated: false)
        await hideAllCards(in: fixture.controller)
    }

    private struct Fixture {
        let controller: AgentApplicationController
        let repository: FoldSessionCardRepository
        let defaults: UserDefaults
        let suiteName: String

        @MainActor
        func cleanUp() {
            controller.stop()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeFixture() -> Fixture {
        let suiteName = "AgentFoldSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let repository = FoldSessionCardRepository()
        return Fixture(
            controller: AgentApplicationController(
                repository: repository,
                appearanceController: AppearanceController(defaults: defaults),
                defaults: defaults
            ),
            repository: repository,
            defaults: defaults,
            suiteName: suiteName
        )
    }

    private func records(
        _ ids: [UUID],
        in repository: FoldSessionCardRepository
    ) async throws -> [UUID: CardRecord] {
        var result: [UUID: CardRecord] = [:]
        for id in ids {
            let stored = try await repository.card(id: id)
            result[id] = try XCTUnwrap(stored)
        }
        return result
    }

    private func cardWindowOrder(_ windows: [NSWindow]) -> [ObjectIdentifier] {
        let identifiers = Set(windows.map(ObjectIdentifier.init))
        return NSApp.orderedWindows
            .map(ObjectIdentifier.init)
            .filter { identifiers.contains($0) }
    }

    private func assertRecordsUnchanged(
        _ before: [UUID: CardRecord],
        ids: [UUID],
        repository: FoldSessionCardRepository,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for id in ids {
            let original = try XCTUnwrap(before[id], file: file, line: line)
            let stored = try await repository.card(id: id)
            let current = try XCTUnwrap(
                stored,
                file: file,
                line: line
            )
            XCTAssertEqual(current.isVisible, original.isVisible, file: file, line: line)
            XCTAssertEqual(current.windowFrame, original.windowFrame, file: file, line: line)
            XCTAssertEqual(current.screenID, original.screenID, file: file, line: line)
            XCTAssertEqual(current.layoutMode, original.layoutMode, file: file, line: line)
            XCTAssertEqual(current.customLayout, original.customLayout, file: file, line: line)
            XCTAssertEqual(current.updatedAt, original.updatedAt, file: file, line: line)
            XCTAssertEqual(current, original, file: file, line: line)
        }
    }

    private func listPayload(
        from controller: AgentApplicationController
    ) async throws -> CardListPayload {
        let response = await send(.list(ListOptions(includeHidden: true)), to: controller)
        XCTAssertTrue(response.ok)
        return try response.decodedPayload(CardListPayload.self)
    }

    private func send(
        _ command: AgentCommand,
        to controller: AgentApplicationController
    ) async -> AgentResponse {
        await controller.handle(AgentRequest(command: command))
    }

    private func hideAllCards(in controller: AgentApplicationController) async {
        _ = await send(.hide(HideOptions(selector: .all)), to: controller)
    }
}
