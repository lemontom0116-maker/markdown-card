import AppKit
import KeyboardShortcuts
import XCTest
@testable import MarkdownCardAgent

@MainActor
final class ShortcutReservationTests: XCTestCase {
    func testCardLibraryDefaultsToCommandShiftL() throws {
        let savedShortcut = KeyboardShortcuts.getShortcut(for: .cardLibrary)
        defer { KeyboardShortcuts.setShortcut(savedShortcut, for: .cardLibrary) }

        KeyboardShortcuts.reset(.cardLibrary)
        let shortcut = try XCTUnwrap(KeyboardShortcuts.getShortcut(for: .cardLibrary))
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

        XCTAssertEqual(shortcut.key, .l)
        XCTAssertEqual(shortcut.modifiers.intersection(relevant), [.command, .shift])
        XCTAssertEqual(ShortcutDisplayFormatter.string(for: shortcut), "⇧⌘L")
    }

    func testLayoutShortcutsLeaveControlFourUnassignedAndKeepControlFiveForCustom() {
        XCTAssertEqual(
            CardWindowFixedShortcut.command(for: .init(.one, modifiers: [.control])),
            .layout(0)
        )
        XCTAssertEqual(
            CardWindowFixedShortcut.command(for: .init(.two, modifiers: [.control])),
            .layout(1)
        )
        XCTAssertEqual(
            CardWindowFixedShortcut.command(for: .init(.three, modifiers: [.control])),
            .layout(2)
        )
        XCTAssertNil(CardWindowFixedShortcut.command(
            for: .init(.four, modifiers: [.control])
        ))
        XCTAssertEqual(
            CardWindowFixedShortcut.command(for: .init(.five, modifiers: [.control])),
            .customLayout
        )
        XCTAssertNil(CardWindowFixedShortcut.command(
            for: .init(.one, modifiers: [.command, .control])
        ))
        XCTAssertNil(CardWindowFixedShortcut.command(
            for: .init(.one, modifiers: [.command])
        ))
    }

    func testLayoutMenuPresetsExposeOnlyMiniStickyAndMiddle() {
        XCTAssertEqual(CardLayoutPreset.allCases.map(\.title), [
            "Mini", "Sticky Note", "Middle Note",
        ])
        XCTAssertEqual(CardLayoutPreset.allCases.map(\.keyEquivalent), ["1", "2", "3"])
        XCTAssertEqual(CardLayoutPreset.allCases.map(\.mode), [.mini, .sticky, .middle])
    }

    func testEditorAndCardWindowShortcutsAreReserved() {
        let shortcuts: [KeyboardShortcuts.Shortcut] = [
            .init(.a, modifiers: [.command]),
            .init(.b, modifiers: [.command]),
            .init(.c, modifiers: [.command]),
            .init(.e, modifiers: [.command]),
            .init(.f, modifiers: [.command]),
            .init(.i, modifiers: [.command]),
            .init(.k, modifiers: [.command]),
            .init(.n, modifiers: [.command]),
            .init(.o, modifiers: [.command]),
            .init(.s, modifiers: [.command]),
            .init(.u, modifiers: [.command]),
            .init(.v, modifiers: [.command]),
            .init(.w, modifiers: [.command]),
            .init(.x, modifiers: [.command]),
            .init(.y, modifiers: [.command]),
            .init(.z, modifiers: [.command]),
            .init(.zero, modifiers: [.command]),
            .init(.one, modifiers: [.command]),
            .init(.five, modifiers: [.command]),
            .init(.six, modifiers: [.command]),
            .init(.b, modifiers: [.command, .shift]),
            .init(.i, modifiers: [.command, .shift]),
            .init(.m, modifiers: [.command, .shift]),
            .init(.o, modifiers: [.command, .shift]),
            .init(.s, modifiers: [.command, .shift]),
            .init(.u, modifiers: [.command, .shift]),
            .init(.z, modifiers: [.command, .shift]),
            .init(.seven, modifiers: [.command, .shift]),
            .init(.eight, modifiers: [.command, .shift]),
            .init(.nine, modifiers: [.command, .shift]),
            .init(.zero, modifiers: [.command, .option]),
            .init(.one, modifiers: [.command, .option]),
            .init(.three, modifiers: [.command, .option]),
            .init(.six, modifiers: [.command, .option]),
            .init(.c, modifiers: [.command, .option]),
            .init(.f, modifiers: [.command, .option]),
            .init(.s, modifiers: [.command, .option]),
            .init(.one, modifiers: [.control]),
            .init(.five, modifiers: [.control]),
            .init(.return, modifiers: [.command]),
        ]

        for shortcut in shortcuts {
            XCTAssertTrue(
                ShortcutConflictDetector.isReservedEditorShortcut(shortcut),
                "Expected reserved shortcut: \(ShortcutDisplayFormatter.string(for: shortcut))"
            )
        }
    }

    func testUnrelatedShortcutsRemainAvailableToRecord() {
        let shortcuts: [KeyboardShortcuts.Shortcut] = [
            .init(.l, modifiers: [.command]),
            .init(.l, modifiers: [.command, .shift]),
            .init(.k, modifiers: [.command, .shift]),
            .init(.k, modifiers: [.command, .option]),
            .init(.e, modifiers: [.command, .shift]),
            .init(.seven, modifiers: [.command, .option]),
            .init(.one, modifiers: [.command, .control]),
            .init(.six, modifiers: [.command, .control]),
            // Tiptap's internal macOS navigation/deletion keymap is not promoted to the
            // product-level editing shortcut contract.
            .init(.h, modifiers: [.control]),
            .init(.delete, modifiers: [.option]),
            .init(.f19, modifiers: [.command, .control, .option]),
        ]

        for shortcut in shortcuts {
            XCTAssertFalse(
                ShortcutConflictDetector.isReservedEditorShortcut(shortcut),
                "Expected recordable shortcut: \(ShortcutDisplayFormatter.string(for: shortcut))"
            )
        }
    }

    func testConflictFeedbackNamesReasonAndOffersUsableReplacement() throws {
        try preservingManagedShortcuts {
            configureDeterministicManagedShortcuts()

            let saveIssue = try XCTUnwrap(ShortcutConflictDetector.issue(
                for: .init(.s, modifiers: [.command]),
                excluding: .moveActiveCard
            ))
            XCTAssertTrue(saveIssue.reason.contains("fixed to Save"))
            XCTAssertEqual(
                saveIssue.recommendedShortcut,
                .init(.j, modifiers: [.command])
            )
            XCTAssertTrue(saveIssue.message.contains("Recommended: ⌘J"))

            let markdownIssue = try XCTUnwrap(ShortcutConflictDetector.issue(
                for: .init(.b, modifiers: [.command]),
                excluding: .toggleFoldedCards
            ))
            XCTAssertTrue(markdownIssue.reason.contains("Markdown editing"))
            XCTAssertEqual(
                markdownIssue.recommendedShortcut,
                .init(.k, modifiers: [.control, .option])
            )

            let duplicateIssue = try XCTUnwrap(ShortcutConflictDetector.issue(
                for: .init(.l, modifiers: [.command, .shift]),
                excluding: .moveActiveCard
            ))
            XCTAssertTrue(duplicateIssue.reason.contains("Card Library"))
        }
    }

    func testRecorderPresentsConflictVisiblyAndThroughAccessibilityHelp() throws {
        try preservingManagedShortcuts {
            configureDeterministicManagedShortcuts()
            let issue = try XCTUnwrap(ShortcutConflictDetector.issue(
                for: .init(.s, modifiers: [.command]),
                excluding: .moveActiveCard
            ))
            let recorder = ShortcutRecorderButton(name: .moveActiveCard)
            var feedback: String?
            recorder.onValidationMessage = { feedback = $0 }

            recorder.presentConflict(issue)

            XCTAssertEqual(feedback, issue.message)
            XCTAssertEqual(recorder.toolTip, issue.message)
            XCTAssertEqual(recorder.accessibilityHelp(), issue.message)

            recorder.clearConflictFeedback()
            XCTAssertNil(feedback)
            XCTAssertNil(recorder.toolTip)
            XCTAssertNil(recorder.accessibilityHelp())
        }
    }

    func testCardWindowUsesExactModifiersAndGivesFocusedMarkdownPriority() throws {
        let panel = CommandPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        var layouts: [Int] = []
        var customLayoutCount = 0
        var newCardCount = 0
        var hideCount = 0
        panel.onApplyLayout = { layouts.append($0) }
        panel.onShowCustomLayout = { customLayoutCount += 1 }
        panel.onCreateCard = { newCardCount += 1 }
        panel.onHide = { hideCount += 1 }
        panel.isMarkdownEditorFocused = { true }

        XCTAssertFalse(panel.performKeyEquivalent(with: try keyEvent(
            "1", keyCode: 18, modifiers: [.command, .option], window: panel
        )))
        XCTAssertFalse(panel.performKeyEquivalent(with: try keyEvent(
            "1", keyCode: 18, modifiers: [.command], window: panel
        )))
        XCTAssertFalse(panel.performKeyEquivalent(with: try keyEvent(
            "1", keyCode: 18, modifiers: [.command, .control], window: panel
        )))
        XCTAssertTrue(panel.performKeyEquivalent(with: try keyEvent(
            "1", keyCode: 18, modifiers: [.control], window: panel
        )))
        XCTAssertEqual(layouts, [0])
        XCTAssertFalse(panel.performKeyEquivalent(with: try keyEvent(
            "4", keyCode: 21, modifiers: [.control], window: panel
        )))
        XCTAssertEqual(layouts, [0])
        XCTAssertEqual(customLayoutCount, 0)
        XCTAssertTrue(panel.performKeyEquivalent(with: try keyEvent(
            "5", keyCode: 23, modifiers: [.control], window: panel
        )))
        XCTAssertEqual(customLayoutCount, 1)

        XCTAssertFalse(panel.performKeyEquivalent(with: try keyEvent(
            "n", keyCode: 45, modifiers: [.command, .option], window: panel
        )))
        XCTAssertEqual(newCardCount, 0)
        XCTAssertTrue(panel.performKeyEquivalent(with: try keyEvent(
            "n", keyCode: 45, modifiers: [.command], window: panel
        )))
        XCTAssertEqual(newCardCount, 1)

        XCTAssertFalse(panel.performKeyEquivalent(with: try keyEvent(
            "\u{1b}", keyCode: 53, modifiers: [], window: panel
        )))
        XCTAssertEqual(hideCount, 0)
        panel.isMarkdownEditorFocused = { false }
        XCTAssertTrue(panel.performKeyEquivalent(with: try keyEvent(
            "\u{1b}", keyCode: 53, modifiers: [], window: panel
        )))
        XCTAssertEqual(hideCount, 1)
    }

    func testFixedCardCommandsBeatLegacyFoldAndMoveBindings() throws {
        try preservingManagedShortcuts {
            configureDeterministicManagedShortcuts()
            let panel = CommandPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            var foldCount = 0
            var moveCount = 0
            var newCardCount = 0
            var layouts: [Int] = []
            var customLayoutCount = 0
            panel.onFoldAllCards = { foldCount += 1 }
            panel.onMoveActiveCard = { moveCount += 1 }
            panel.onCreateCard = { newCardCount += 1 }
            panel.onApplyLayout = { layouts.append($0) }
            panel.onShowCustomLayout = { customLayoutCount += 1 }
            panel.isMarkdownEditorFocused = { false }

            KeyboardShortcuts.setShortcut(
                .init(.s, modifiers: [.command]),
                for: .moveActiveCard
            )
            _ = panel.performKeyEquivalent(with: try keyEvent(
                "s", keyCode: 1, modifiers: [.command], window: panel
            ))
            XCTAssertEqual(moveCount, 0, "Legacy Move must not steal Save")

            KeyboardShortcuts.setShortcut(
                .init(.one, modifiers: [.control]),
                for: .toggleFoldedCards
            )
            XCTAssertTrue(panel.performKeyEquivalent(with: try keyEvent(
                "1", keyCode: 18, modifiers: [.control], window: panel
            )))
            XCTAssertEqual(layouts, [0])
            XCTAssertEqual(foldCount, 0, "Legacy Fold must not steal Card Layout 1")

            KeyboardShortcuts.setShortcut(
                .init(.n, modifiers: [.command]),
                for: .moveActiveCard
            )
            XCTAssertTrue(panel.performKeyEquivalent(with: try keyEvent(
                "n", keyCode: 45, modifiers: [.command], window: panel
            )))
            XCTAssertEqual(newCardCount, 1)
            XCTAssertEqual(moveCount, 0)

            KeyboardShortcuts.setShortcut(
                .init(.five, modifiers: [.control]),
                for: .toggleFoldedCards
            )
            XCTAssertTrue(panel.performKeyEquivalent(with: try keyEvent(
                "5", keyCode: 23, modifiers: [.control], window: panel
            )))
            XCTAssertEqual(customLayoutCount, 1)
            XCTAssertEqual(foldCount, 0)
        }
    }

    func testMarkdownShortcutWinsOnlyWhileCardEditorIsFocused() throws {
        try preservingManagedShortcuts {
            configureDeterministicManagedShortcuts()
            KeyboardShortcuts.setShortcut(
                .init(.b, modifiers: [.command]),
                for: .toggleFoldedCards
            )
            let panel = CommandPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            var foldCount = 0
            panel.onFoldAllCards = { foldCount += 1 }
            panel.isMarkdownEditorFocused = { true }

            _ = panel.performKeyEquivalent(with: try keyEvent(
                "b", keyCode: 11, modifiers: [.command], window: panel
            ))
            XCTAssertEqual(foldCount, 0)

            panel.isMarkdownEditorFocused = { false }
            XCTAssertTrue(panel.performKeyEquivalent(with: try keyEvent(
                "b", keyCode: 11, modifiers: [.command], window: panel
            )))
            XCTAssertEqual(foldCount, 1)
        }
    }

    func testFocusedIMECompositionBlocksLayoutFoldAndMoveUntilCompositionEnds() throws {
        try preservingManagedShortcuts {
            configureDeterministicManagedShortcuts()
            KeyboardShortcuts.setShortcut(
                .init(.k, modifiers: [.control, .option]),
                for: .toggleFoldedCards
            )
            KeyboardShortcuts.setShortcut(
                .init(.j, modifiers: [.command]),
                for: .moveActiveCard
            )
            let panel = CommandPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            var layouts: [Int] = []
            var foldCount = 0
            var moveCount = 0
            var composing = true
            panel.onApplyLayout = { layouts.append($0) }
            panel.onFoldAllCards = { foldCount += 1 }
            panel.onMoveActiveCard = { moveCount += 1 }
            panel.isMarkdownEditorFocused = { true }
            panel.isMarkdownEditorComposing = { composing }

            XCTAssertTrue(panel.performKeyEquivalent(with: try keyEvent(
                "1", keyCode: 18, modifiers: [.control], window: panel
            )))
            XCTAssertTrue(panel.performKeyEquivalent(with: try keyEvent(
                "k", keyCode: 40, modifiers: [.control, .option], window: panel
            )))
            XCTAssertTrue(panel.performKeyEquivalent(with: try keyEvent(
                "j", keyCode: 38, modifiers: [.command], window: panel
            )))
            XCTAssertTrue(layouts.isEmpty)
            XCTAssertEqual(foldCount, 0)
            XCTAssertEqual(moveCount, 0)

            composing = false
            XCTAssertTrue(panel.performKeyEquivalent(with: try keyEvent(
                "1", keyCode: 18, modifiers: [.control], window: panel
            )))
            XCTAssertTrue(panel.performKeyEquivalent(with: try keyEvent(
                "k", keyCode: 40, modifiers: [.control, .option], window: panel
            )))
            XCTAssertTrue(panel.performKeyEquivalent(with: try keyEvent(
                "j", keyCode: 38, modifiers: [.command], window: panel
            )))
            XCTAssertEqual(layouts, [0])
            XCTAssertEqual(foldCount, 1)
            XCTAssertEqual(moveCount, 1)
        }
    }

    func testSharedMarkdownPreviewCompositionStateClearsBeforeRendererReload() {
        let preview = MarkdownPreviewView(initialAppearance: .dark)
        XCTAssertFalse(preview.isEditorComposing)

        preview.updateEditorCompositionState(true)
        XCTAssertTrue(preview.isEditorComposing)

        preview.loadRenderer()
        XCTAssertFalse(preview.isEditorComposing)
    }

    func testFocusedEditorSuspendsOnlyConflictingGlobalRegistrationsWithoutChangingSettings() {
        let markdownName = KeyboardShortcuts.Name("focusedMarkdownGuard_markdown")
        let unrelatedName = KeyboardShortcuts.Name("focusedMarkdownGuard_unrelated")
        let alreadyDisabledName = KeyboardShortcuts.Name("focusedMarkdownGuard_disabled")
        let stored: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [
            markdownName: .init(.b, modifiers: [.command]),
            unrelatedName: .init(.j, modifiers: [.command, .option]),
            alreadyDisabledName: .init(.one, modifiers: [.command]),
        ]
        var enabled: Set<KeyboardShortcuts.Name> = [markdownName, unrelatedName]
        var disabledCalls: [KeyboardShortcuts.Name] = []
        var enabledCalls: [KeyboardShortcuts.Name] = []
        var focusChanges: [Bool] = []

        let guardController = MarkdownFocusedGlobalShortcutGuard(
            managedNames: [markdownName, unrelatedName, alreadyDisabledName],
            shortcutProvider: { stored[$0] },
            shortcutIsEnabled: { enabled.contains($0) },
            disableShortcut: {
                disabledCalls.append($0)
                enabled.remove($0)
            },
            enableShortcut: {
                enabledCalls.append($0)
                enabled.insert($0)
            },
            editorIsFocused: { false },
            onEditorFocusChange: { focusChanges.append($0) }
        )

        guardController.refresh(editorFocused: true)

        XCTAssertEqual(disabledCalls, [markdownName])
        XCTAssertFalse(enabled.contains(markdownName))
        XCTAssertTrue(enabled.contains(unrelatedName))
        XCTAssertFalse(enabled.contains(alreadyDisabledName))
        XCTAssertEqual(stored[markdownName], .init(.b, modifiers: [.command]))

        guardController.refresh(editorFocused: true)
        XCTAssertEqual(disabledCalls, [markdownName], "Repeated focus refreshes must be idempotent")

        guardController.refresh(editorFocused: false)

        XCTAssertEqual(enabledCalls, [markdownName])
        XCTAssertTrue(enabled.contains(markdownName))
        XCTAssertFalse(
            enabled.contains(alreadyDisabledName),
            "A shortcut disabled before the guard ran must remain disabled"
        )
        XCTAssertEqual(focusChanges, [true, false])
    }

    func testFocusedMarkdownPriorityAlsoRemovesConflictingLocalMenuEquivalent() {
        let markdownShortcut = KeyboardShortcuts.Shortcut(.s, modifiers: [.command, .shift])
        let unrelatedShortcut = KeyboardShortcuts.Shortcut(.l, modifiers: [.command, .shift])

        XCTAssertTrue(MarkdownShortcutContract.takesPriority(
            over: markdownShortcut,
            editorFocused: true
        ))
        XCTAssertFalse(MarkdownShortcutContract.takesPriority(
            over: markdownShortcut,
            editorFocused: false
        ))
        XCTAssertFalse(MarkdownShortcutContract.takesPriority(
            over: unrelatedShortcut,
            editorFocused: true
        ))
        XCTAssertFalse(MarkdownShortcutContract.takesPriority(
            over: nil,
            editorFocused: true
        ))
    }

    func testFocusedEditorStillAllowsNonConflictingGlobalShortcuts() {
        XCTAssertTrue(AgentApplicationController.shouldExecuteGlobalShortcut(
            .init(.space, modifiers: [.option]),
            editorFocused: true
        ))
        XCTAssertTrue(AgentApplicationController.shouldExecuteGlobalShortcut(
            .init(.n, modifiers: [.command, .option]),
            editorFocused: true
        ))
        XCTAssertFalse(AgentApplicationController.shouldExecuteGlobalShortcut(
            .init(.b, modifiers: [.command]),
            editorFocused: true
        ))
        XCTAssertTrue(AgentApplicationController.shouldExecuteGlobalShortcut(
            .init(.b, modifiers: [.command]),
            editorFocused: false
        ))
    }

    func testMigrationTreatsStoredCommandLAsOldDefaultBecauseStorageHasNoProvenance() {
        withMigrationFixture(initialShortcut: .init(.l, modifiers: [.command])) { name, defaults in
            ShortcutDefaultsMigration.migrateCardLibraryDefaultIfNeeded(
                defaults: defaults,
                shortcutName: name
            )

            XCTAssertEqual(
                KeyboardShortcuts.getShortcut(for: name),
                .init(.l, modifiers: [.command, .shift])
            )
            XCTAssertEqual(
                defaults.object(forKey: ShortcutDefaultsMigration.cardLibraryCommandShiftLMarkerKey)
                    as? Bool,
                true
            )
        }
    }

    func testMigrationLeavesCustomShortcutUnchanged() {
        let customShortcut = KeyboardShortcuts.Shortcut(.m, modifiers: [.command, .shift])
        withMigrationFixture(initialShortcut: customShortcut) { name, defaults in
            ShortcutDefaultsMigration.migrateCardLibraryDefaultIfNeeded(
                defaults: defaults,
                shortcutName: name
            )

            XCTAssertEqual(KeyboardShortcuts.getShortcut(for: name), customShortcut)
            XCTAssertEqual(
                defaults.object(forKey: ShortcutDefaultsMigration.cardLibraryCommandShiftLMarkerKey)
                    as? Bool,
                true
            )
        }
    }

    func testMigrationLeavesDisabledShortcutUnchanged() {
        withMigrationFixture(initialShortcut: nil) { name, defaults in
            ShortcutDefaultsMigration.migrateCardLibraryDefaultIfNeeded(
                defaults: defaults,
                shortcutName: name
            )

            XCTAssertNil(KeyboardShortcuts.getShortcut(for: name))
            XCTAssertEqual(
                defaults.object(forKey: ShortcutDefaultsMigration.cardLibraryCommandShiftLMarkerKey)
                    as? Bool,
                true
            )
        }
    }

    func testMigrationMarkerPreventsRepeatingAfterLaterCommandLAssignment() {
        withMigrationFixture(initialShortcut: .init(.l, modifiers: [.command])) { name, defaults in
            ShortcutDefaultsMigration.migrateCardLibraryDefaultIfNeeded(
                defaults: defaults,
                shortcutName: name
            )
            KeyboardShortcuts.setShortcut(.init(.l, modifiers: [.command]), for: name)

            ShortcutDefaultsMigration.migrateCardLibraryDefaultIfNeeded(
                defaults: defaults,
                shortcutName: name
            )

            XCTAssertEqual(
                KeyboardShortcuts.getShortcut(for: name),
                .init(.l, modifiers: [.command])
            )
        }
    }

    func testReservedMigrationReplacesSafeBindingAndDisablesBindingWithoutAlternative() throws {
        let identifier = UUID().uuidString
        let moveName = KeyboardShortcuts.Name("reservedMigrationMove_\(identifier)")
        let foldName = KeyboardShortcuts.Name("reservedMigrationFold_\(identifier)")
        let occupiedName = KeyboardShortcuts.Name("reservedMigrationOccupied_\(identifier)")
        let suiteName = "MarkdownCard.ReservedShortcutMigrationTests.\(identifier)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var stored: [KeyboardShortcuts.Name: KeyboardShortcuts.Shortcut] = [
            moveName: .init(.s, modifiers: [.command]),
            foldName: .init(.one, modifiers: [.control]),
            occupiedName: .init(.j, modifiers: [.command]),
        ]
        let marker = "reservedMigrationMarker_\(identifier)"
        let notice = "reservedMigrationNotice_\(identifier)"
        let changes = ShortcutDefaultsMigration.migrateReservedBindingsIfNeeded(
            defaults: defaults,
            markerKey: marker,
            noticeKey: notice,
            bindings: [
                .init(
                    name: moveName,
                    title: "Move Active Card",
                    replacementCandidates: [
                        .init(.j, modifiers: [.command]),
                        .init(.j, modifiers: [.command, .option]),
                    ]
                ),
                .init(
                    name: foldName,
                    title: "Fold All Cards",
                    replacementCandidates: []
                ),
                .init(
                    name: occupiedName,
                    title: "Existing Action",
                    replacementCandidates: []
                ),
            ],
            shortcutProvider: { stored[$0] },
            shortcutSetter: { shortcut, name in stored[name] = shortcut }
        )

        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(stored[moveName], .init(.j, modifiers: [.command, .option]))
        XCTAssertNil(stored[foldName])
        XCTAssertEqual(stored[occupiedName], .init(.j, modifiers: [.command]))
        XCTAssertEqual(defaults.object(forKey: marker) as? Bool, true)
        XCTAssertTrue(try XCTUnwrap(defaults.string(forKey: notice)).contains("reserved for Save"))
        XCTAssertTrue(try XCTUnwrap(defaults.string(forKey: notice)).contains("disabled"))

        let repeated = ShortcutDefaultsMigration.migrateReservedBindingsIfNeeded(
            defaults: defaults,
            markerKey: marker,
            noticeKey: notice,
            bindings: [],
            shortcutProvider: { stored[$0] },
            shortcutSetter: { shortcut, name in stored[name] = shortcut }
        )
        XCTAssertTrue(repeated.isEmpty)
    }

    func testStartupEntryPointRunsV2AuditEvenWhenV1MigrationAlreadyRan() throws {
        try preservingManagedShortcuts {
            configureDeterministicManagedShortcuts()
            KeyboardShortcuts.setShortcut(
                .init(.one, modifiers: [.control]),
                for: .moveActiveCard
            )
            let suiteName = "MarkdownCard.StartupShortcutMigrationTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defaults.removePersistentDomain(forName: suiteName)
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(
                true,
                forKey: ShortcutDefaultsMigration.cardLibraryCommandShiftLMarkerKey
            )
            defaults.set(
                true,
                forKey: "MarkdownCard.shortcutMigration.reservedBindings.v1"
            )

            ShortcutDefaultsMigration.migrateCardLibraryDefaultIfNeeded(defaults: defaults)

            XCTAssertEqual(
                KeyboardShortcuts.getShortcut(for: .moveActiveCard),
                .init(.j, modifiers: [.command])
            )
            XCTAssertEqual(
                defaults.object(forKey: ShortcutDefaultsMigration.reservedBindingsMarkerKey)
                    as? Bool,
                true
            )
            XCTAssertTrue(
                try XCTUnwrap(defaults.string(
                    forKey: ShortcutDefaultsMigration.reservedBindingsNoticeKey
                )).contains("Move Active Card to Preset")
            )
        }
    }

    private func preservingManagedShortcuts(_ body: () throws -> Void) rethrows {
        let saved = Dictionary(uniqueKeysWithValues: ShortcutConflictDetector.managedNames.map {
            ($0, KeyboardShortcuts.getShortcut(for: $0))
        })
        defer {
            for (name, shortcut) in saved {
                KeyboardShortcuts.setShortcut(shortcut, for: name)
            }
        }
        try body()
    }

    private func configureDeterministicManagedShortcuts() {
        KeyboardShortcuts.setShortcut(
            .init(.space, modifiers: [.option]),
            for: .commandCenter
        )
        KeyboardShortcuts.setShortcut(
            .init(.n, modifiers: [.command, .option]),
            for: .newCard
        )
        KeyboardShortcuts.setShortcut(nil, for: .toggleFoldedCards)
        KeyboardShortcuts.setShortcut(
            .init(.j, modifiers: [.command]),
            for: .moveActiveCard
        )
        KeyboardShortcuts.setShortcut(
            .init(.l, modifiers: [.command, .shift]),
            for: .cardLibrary
        )
        KeyboardShortcuts.setShortcut(
            .init(.comma, modifiers: [.command]),
            for: .settings
        )
    }

    private func withMigrationFixture(
        initialShortcut: KeyboardShortcuts.Shortcut?,
        body: (KeyboardShortcuts.Name, UserDefaults) -> Void
    ) {
        let identifier = UUID().uuidString
        let shortcutName = KeyboardShortcuts.Name("cardLibraryMigrationTest_\(identifier)")
        let suiteName = "MarkdownCard.ShortcutMigrationTests.\(identifier)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        KeyboardShortcuts.setShortcut(initialShortcut, for: shortcutName)
        defer {
            KeyboardShortcuts.setShortcut(nil, for: shortcutName)
            defaults.removePersistentDomain(forName: suiteName)
        }

        body(shortcutName, defaults)
    }

    private func keyEvent(
        _ characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
