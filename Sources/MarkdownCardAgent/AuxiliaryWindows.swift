import AppKit
import KeyboardShortcuts
import MarkdownCardCore

extension KeyboardShortcuts.Name {
    static let commandCenter = Self(
        "commandCenter",
        initial: .init(.space, modifiers: [.option])
    )
    static let newCard = Self(
        "newCard",
        initial: .init(.n, modifiers: [.command, .option])
    )
    // These names use KeyboardShortcuts only as a recorder and persistence
    // store. They are intentionally not registered as global handlers.
    static let toggleFoldedCards = Self("toggleFoldedCards")
    static let moveActiveCard = Self(
        "moveActiveCard",
        initial: .init(.j, modifiers: [.command])
    )
    static let cardLibrary = Self(
        "cardLibrary",
        initial: .init(.l, modifiers: [.command, .shift])
    )
    static let settings = Self(
        "settings",
        initial: .init(.comma, modifiers: [.command])
    )
}

struct ShortcutBindingDefinition {
    let name: KeyboardShortcuts.Name
    let title: String
    let replacementCandidates: [KeyboardShortcuts.Shortcut]
}

struct ShortcutMigrationChange: Equatable {
    let name: KeyboardShortcuts.Name
    let title: String
    let previousShortcut: KeyboardShortcuts.Shortcut
    let replacementShortcut: KeyboardShortcuts.Shortcut?
    let message: String
}

@MainActor
enum ShortcutDefaultsMigration {
    static let cardLibraryCommandShiftLMarkerKey =
        "MarkdownCard.shortcutMigration.cardLibraryCommandShiftL.v1"
    static let reservedBindingsMarkerKey =
        "MarkdownCard.shortcutMigration.reservedBindings.v2"
    static let reservedBindingsNoticeKey =
        "MarkdownCard.shortcutMigration.reservedBindingsNotice.v1"

    typealias ShortcutProvider = @MainActor (
        KeyboardShortcuts.Name
    ) -> KeyboardShortcuts.Shortcut?
    typealias ShortcutSetter = @MainActor (
        KeyboardShortcuts.Shortcut?,
        KeyboardShortcuts.Name
    ) -> Void

    private static let oldCardLibraryDefault = KeyboardShortcuts.Shortcut(
        .l,
        modifiers: [.command]
    )
    private static let newCardLibraryDefault = KeyboardShortcuts.Shortcut(
        .l,
        modifiers: [.command, .shift]
    )

    static func migrateCardLibraryDefaultIfNeeded(
        defaults: UserDefaults = .standard,
        shortcutName: KeyboardShortcuts.Name = .cardLibrary
    ) {
        if defaults.object(forKey: cardLibraryCommandShiftLMarkerKey) == nil {
            // KeyboardShortcuts persists an initial shortcut and a user-assigned shortcut in the
            // same form, so an exact stored ⌘L has no provenance. The product migration policy
            // treats that one exact value as the old default; the marker prevents reclassifying a
            // later user assignment on subsequent launches.
            if KeyboardShortcuts.getShortcut(for: shortcutName) == oldCardLibraryDefault {
                KeyboardShortcuts.setShortcut(newCardLibraryDefault, for: shortcutName)
            }
            defaults.set(true, forKey: cardLibraryCommandShiftLMarkerKey)
        }

        // AppDelegate already calls this entry point at startup. Only the real Card Library
        // migration should fan out to the app-wide audit; isolated/custom-name callers keep the
        // original single-binding behavior used by tests and migration tools.
        if shortcutName == .cardLibrary {
            migrateReservedBindingsIfNeeded(defaults: defaults)
        }
    }

    @discardableResult
    static func migrateReservedBindingsIfNeeded(
        defaults: UserDefaults = .standard,
        markerKey: String = reservedBindingsMarkerKey,
        noticeKey: String = reservedBindingsNoticeKey,
        bindings: [ShortcutBindingDefinition] = ShortcutConflictDetector.managedBindings,
        shortcutProvider: @escaping ShortcutProvider = {
            KeyboardShortcuts.getShortcut(for: $0)
        },
        shortcutSetter: @escaping ShortcutSetter = { shortcut, name in
            KeyboardShortcuts.setShortcut(shortcut, for: name)
        }
    ) -> [ShortcutMigrationChange] {
        guard defaults.object(forKey: markerKey) == nil else { return [] }
        defer { defaults.set(true, forKey: markerKey) }

        let names = bindings.map(\.name)
        var changes: [ShortcutMigrationChange] = []
        for binding in bindings {
            guard let current = shortcutProvider(binding.name),
                  let reservation = ShortcutConflictDetector.reservationDescription(for: current)
            else { continue }

            let replacement = binding.replacementCandidates.first { candidate in
                !ShortcutConflictDetector.isReservedEditorShortcut(candidate)
                    && !candidate.isTakenBySystem
                    && !ShortcutConflictDetector.conflicts(
                        candidate,
                        excluding: binding.name,
                        among: names,
                        shortcutProvider: shortcutProvider
                    )
            }
            shortcutSetter(replacement, binding.name)

            let oldText = ShortcutDisplayFormatter.string(for: current)
            let resolution: String
            if let replacement {
                resolution = "changed to \(ShortcutDisplayFormatter.string(for: replacement))"
            } else {
                resolution = "disabled; choose a replacement in Settings"
            }
            let message = "\(binding.title) used \(oldText), which is reserved for "
                + "\(reservation); it was \(resolution)."
            changes.append(ShortcutMigrationChange(
                name: binding.name,
                title: binding.title,
                previousShortcut: current,
                replacementShortcut: replacement,
                message: message
            ))
        }

        if changes.isEmpty {
            defaults.removeObject(forKey: noticeKey)
        } else {
            defaults.set(changes.map(\.message).joined(separator: " "), forKey: noticeKey)
        }
        return changes
    }
}

@MainActor
enum MarkdownShortcutContract {
    private static let relevantModifiers: NSEvent.ModifierFlags = [
        .command,
        .option,
        .control,
        .shift,
    ]

    static func matches(_ event: NSEvent) -> Bool {
        guard let shortcut = KeyboardShortcuts.Shortcut(event: event) else { return false }
        return contains(shortcut)
    }

    static func contains(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        let modifiers = shortcut.modifiers.intersection(relevantModifiers)
        if modifiers == [.command], shortcut.key == .return { return true }
        if modifiers == [.shift], shortcut.key == .return { return true }
        guard let key = shortcut.nsMenuItemKeyEquivalent?.lowercased() else { return false }

        switch modifiers {
        case [.command]:
            return [
                "a", "b", "c", "e", "f", "i", "k", "u", "v", "x", "y", "z",
                "0", "1", "2", "3", "4", "5", "6",
            ].contains(key)
        case [.command, .shift]:
            return [
                "b", "i", "m", "o", "s", "u", "z", "7", "8", "9",
            ].contains(key)
        case [.command, .option]:
            return ["c", "f", "0", "1", "2", "3", "4", "5", "6"].contains(key)
        default:
            return false
        }
    }

    static func takesPriority(
        over shortcut: KeyboardShortcuts.Shortcut?,
        editorFocused: Bool
    ) -> Bool {
        guard editorFocused, let shortcut else { return false }
        return contains(shortcut)
    }
}

extension Notification.Name {
    static let markdownCardEditorFocusMayHaveChanged = Self(
        "MarkdownCard.editorFocusMayHaveChanged"
    )
}

/// Temporarily unregisters configurable global shortcuts that overlap the
/// Markdown editing contract while a renderer WebView owns keyboard focus.
///
/// The stored shortcut is never changed. Only names that this guard actually
/// suspended are re-enabled, so a shortcut that was already disabled remains
/// disabled.
@MainActor
final class MarkdownFocusedGlobalShortcutGuard {
    typealias ShortcutProvider = @MainActor (KeyboardShortcuts.Name) -> KeyboardShortcuts.Shortcut?
    typealias ShortcutStateProvider = @MainActor (KeyboardShortcuts.Name) -> Bool
    typealias ShortcutStateMutation = @MainActor (KeyboardShortcuts.Name) -> Void
    typealias EditorFocusProvider = @MainActor () -> Bool
    typealias EditorFocusObserver = @MainActor (Bool) -> Void

    private let managedNames: [KeyboardShortcuts.Name]
    private let shortcutProvider: ShortcutProvider
    private let shortcutIsEnabled: ShortcutStateProvider
    private let disableShortcut: ShortcutStateMutation
    private let enableShortcut: ShortcutStateMutation
    private let editorIsFocused: EditorFocusProvider
    private let onEditorFocusChange: EditorFocusObserver
    private var suspendedNames = Set<KeyboardShortcuts.Name>()
    private var notificationObservers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var isStarted = false
    private var reportedEditorFocus: Bool?

    init(
        managedNames: [KeyboardShortcuts.Name] = [.commandCenter, .newCard],
        shortcutProvider: @escaping ShortcutProvider = KeyboardShortcuts.getShortcut(for:),
        shortcutIsEnabled: @escaping ShortcutStateProvider = KeyboardShortcuts.isEnabled(for:),
        disableShortcut: @escaping ShortcutStateMutation = { KeyboardShortcuts.disable($0) },
        enableShortcut: @escaping ShortcutStateMutation = { KeyboardShortcuts.enable($0) },
        editorIsFocused: @escaping EditorFocusProvider = MarkdownFocusedGlobalShortcutGuard
            .currentKeyWindowHasFocusedMarkdownEditor,
        onEditorFocusChange: @escaping EditorFocusObserver = { _ in }
    ) {
        self.managedNames = managedNames
        self.shortcutProvider = shortcutProvider
        self.shortcutIsEnabled = shortcutIsEnabled
        self.disableShortcut = disableShortcut
        self.enableShortcut = enableShortcut
        self.editorIsFocused = editorIsFocused
        self.onEditorFocusChange = onEditorFocusChange
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
            .markdownCardEditorFocusMayHaveChanged,
        ]
        notificationObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if Self.targetsMarkdownEditor(event) {
                // A click is delivered before AppKit changes first responder.
                // Suspend now so the very next Markdown key cannot be captured
                // by Carbon's global hot-key registration.
                refresh(editorFocused: true)
            }
            DispatchQueue.main.async { self.refresh() }
            return event
        }

        refresh()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        notificationObservers.forEach(NotificationCenter.default.removeObserver(_:))
        notificationObservers.removeAll(keepingCapacity: false)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        restoreSuspendedShortcuts()
        reportEditorFocus(false)
    }

    func refresh(editorFocused: Bool? = nil) {
        let hasFocusedEditor = editorFocused ?? editorIsFocused()
        for name in managedNames {
            let overlapsMarkdown = shortcutProvider(name).map(MarkdownShortcutContract.contains)
                ?? false
            if hasFocusedEditor && overlapsMarkdown {
                guard !suspendedNames.contains(name), shortcutIsEnabled(name) else { continue }
                disableShortcut(name)
                suspendedNames.insert(name)
            } else if suspendedNames.remove(name) != nil {
                enableShortcut(name)
            }
        }
        reportEditorFocus(hasFocusedEditor)
    }

    private func restoreSuspendedShortcuts() {
        let names = suspendedNames
        suspendedNames.removeAll(keepingCapacity: false)
        names.forEach(enableShortcut)
    }

    private func reportEditorFocus(_ isFocused: Bool) {
        guard reportedEditorFocus != isFocused else { return }
        reportedEditorFocus = isFocused
        onEditorFocusChange(isFocused)
    }

    private static func currentKeyWindowHasFocusedMarkdownEditor() -> Bool {
        guard NSApp.isActive,
              let responderView = NSApp.keyWindow?.firstResponder as? NSView
        else { return false }
        return belongsToMarkdownEditor(responderView)
    }

    private static func targetsMarkdownEditor(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown
                || event.type == .rightMouseDown
                || event.type == .otherMouseDown,
              let contentView = event.window?.contentView
        else { return false }
        let point = contentView.convert(event.locationInWindow, from: nil)
        guard let hitView = contentView.hitTest(point) else { return false }
        return belongsToMarkdownEditor(hitView)
    }

    private static func belongsToMarkdownEditor(_ view: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if current is MarkdownPreviewView { return true }
            candidate = current.superview
        }
        return false
    }
}

@MainActor
enum CardWindowFixedShortcut: Equatable {
    case newCard
    case openMarkdown
    case quit
    case save
    case closeCard
    case saveAs
    case layout(Int)
    case customLayout

    var title: String {
        switch self {
        case .newCard: "New Card"
        case .openMarkdown: "Open Markdown"
        case .quit: "Quit"
        case .save: "Save"
        case .closeCard: "Close Card"
        case .saveAs: "Save As"
        case let .layout(index): "Card Layout \(index + 1)"
        case .customLayout: "Custom Card Layout"
        }
    }

    static func command(for event: NSEvent) -> Self? {
        guard let shortcut = KeyboardShortcuts.Shortcut(event: event) else { return nil }
        return command(for: shortcut)
    }

    static func command(for shortcut: KeyboardShortcuts.Shortcut) -> Self? {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let modifiers = shortcut.modifiers.intersection(relevant)
        guard let key = shortcut.key else { return nil }
        return switch (modifiers, key) {
        case ([.command], .n): .newCard
        case ([.command], .o): .openMarkdown
        case ([.command], .q): .quit
        case ([.command], .s): .save
        case ([.command], .w): .closeCard
        case ([.command, .option], .s): .saveAs
        case ([.control], .one): .layout(0)
        case ([.control], .two): .layout(1)
        case ([.control], .three): .layout(2)
        case ([.control], .five): .customLayout
        default: nil
        }
    }
}

struct ShortcutConflictIssue: Equatable {
    let reason: String
    let recommendedShortcut: KeyboardShortcuts.Shortcut?

    @MainActor
    var message: String {
        guard let recommendedShortcut else {
            return reason + " Choose another shortcut."
        }
        return reason + " Recommended: "
            + ShortcutDisplayFormatter.string(for: recommendedShortcut) + "."
    }
}

@MainActor
enum ShortcutConflictDetector {
    typealias ShortcutProvider = @MainActor (
        KeyboardShortcuts.Name
    ) -> KeyboardShortcuts.Shortcut?

    static let managedBindings: [ShortcutBindingDefinition] = [
        .init(
            name: .commandCenter,
            title: "Open Command Center",
            replacementCandidates: [
                .init(.space, modifiers: [.option]),
                .init(.space, modifiers: [.control, .option]),
            ]
        ),
        .init(
            name: .newCard,
            title: "New Card",
            replacementCandidates: [
                .init(.n, modifiers: [.command, .option]),
                .init(.n, modifiers: [.control, .option]),
            ]
        ),
        .init(
            name: .toggleFoldedCards,
            title: "Fold All Cards",
            replacementCandidates: [
                .init(.k, modifiers: [.control, .option]),
                .init(.f, modifiers: [.control, .option]),
            ]
        ),
        .init(
            name: .moveActiveCard,
            title: "Move Active Card to Preset",
            replacementCandidates: [
                .init(.j, modifiers: [.command]),
                .init(.j, modifiers: [.command, .option]),
                .init(.j, modifiers: [.control, .option]),
            ]
        ),
        .init(
            name: .cardLibrary,
            title: "Card Library",
            replacementCandidates: [
                .init(.l, modifiers: [.command, .shift]),
                .init(.l, modifiers: [.control, .option]),
            ]
        ),
        .init(
            name: .settings,
            title: "Settings",
            replacementCandidates: [
                .init(.comma, modifiers: [.command]),
                .init(.comma, modifiers: [.control, .option]),
            ]
        ),
    ]

    static var managedNames: [KeyboardShortcuts.Name] { managedBindings.map(\.name) }

    static func title(for name: KeyboardShortcuts.Name) -> String {
        managedBindings.first { $0.name == name }?.title ?? name.rawValue
    }

    static func conflicts(
        _ shortcut: KeyboardShortcuts.Shortcut,
        excluding shortcutName: KeyboardShortcuts.Name,
        among names: [KeyboardShortcuts.Name]? = nil,
        shortcutProvider: ShortcutProvider = { KeyboardShortcuts.getShortcut(for: $0) }
    ) -> Bool {
        conflictingName(
            for: shortcut,
            excluding: shortcutName,
            among: names,
            shortcutProvider: shortcutProvider
        ) != nil
    }

    static func conflictingName(
        for shortcut: KeyboardShortcuts.Shortcut,
        excluding shortcutName: KeyboardShortcuts.Name,
        among names: [KeyboardShortcuts.Name]? = nil,
        shortcutProvider: ShortcutProvider = { KeyboardShortcuts.getShortcut(for: $0) }
    ) -> KeyboardShortcuts.Name? {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let modifiers = shortcut.modifiers.intersection(relevant)
        return (names ?? managedNames).first { name in
            guard name != shortcutName,
                  let existing = shortcutProvider(name)
            else { return false }
            return existing.key == shortcut.key
                && existing.modifiers.intersection(relevant) == modifiers
        }
    }

    static func reservationDescription(
        for shortcut: KeyboardShortcuts.Shortcut
    ) -> String? {
        if MarkdownShortcutContract.contains(shortcut) {
            return "Markdown editing while a card editor is focused"
        }
        return CardWindowFixedShortcut.command(for: shortcut)?.title
    }

    static func isReservedEditorShortcut(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        reservationDescription(for: shortcut) != nil
    }

    static func issue(
        for shortcut: KeyboardShortcuts.Shortcut,
        excluding shortcutName: KeyboardShortcuts.Name
    ) -> ShortcutConflictIssue? {
        let text = ShortcutDisplayFormatter.string(for: shortcut)
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let modifiers = shortcut.modifiers.intersection(relevant)
        let recommendation = recommendedShortcut(for: shortcutName)

        if modifiers.isDisjoint(with: [.command, .option, .control]) {
            return .init(
                reason: "\(text) needs Command, Option, or Control to be recordable.",
                recommendedShortcut: recommendation
            )
        }
        if shortcut.isTakenBySystem {
            return .init(
                reason: "\(text) is already used by macOS.",
                recommendedShortcut: recommendation
            )
        }
        if MarkdownShortcutContract.contains(shortcut) {
            return .init(
                reason: "\(text) belongs to Markdown editing while a card editor is focused.",
                recommendedShortcut: recommendation
            )
        }
        if let fixed = CardWindowFixedShortcut.command(for: shortcut) {
            return .init(
                reason: "\(text) is fixed to \(fixed.title) while a card is active.",
                recommendedShortcut: recommendation
            )
        }
        if let conflict = conflictingName(for: shortcut, excluding: shortcutName) {
            return .init(
                reason: "\(text) is already assigned to \(title(for: conflict)).",
                recommendedShortcut: recommendation
            )
        }
        return nil
    }

    static func issue(
        reason: String,
        for shortcutName: KeyboardShortcuts.Name
    ) -> ShortcutConflictIssue {
        .init(
            reason: reason,
            recommendedShortcut: recommendedShortcut(for: shortcutName)
        )
    }

    static func recommendedShortcut(
        for shortcutName: KeyboardShortcuts.Name
    ) -> KeyboardShortcuts.Shortcut? {
        let preferred = managedBindings.first { $0.name == shortcutName }?
            .replacementCandidates ?? []
        let fallbacks: [KeyboardShortcuts.Shortcut] = [
            .init(.k, modifiers: [.control, .option]),
            .init(.j, modifiers: [.control, .option]),
            .init(.l, modifiers: [.control, .option]),
            .init(.m, modifiers: [.control, .option]),
            .init(.n, modifiers: [.control, .option]),
            .init(.p, modifiers: [.control, .option]),
        ]
        return (preferred + fallbacks).first { candidate in
            !isReservedEditorShortcut(candidate)
                && !candidate.isTakenBySystem
                && !conflicts(candidate, excluding: shortcutName)
        }
    }
}

@MainActor
final class ShortcutRecorderButton: NSButton {
    var onChange: (() -> Void)?
    var onValidationMessage: ((String?) -> Void)?

    private let shortcutName: KeyboardShortcuts.Name
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var isRecording = false
    private var shortcutBeforeRecording: KeyboardShortcuts.Shortcut?
    private var resolvedAppearance: ResolvedAppearance = .dark

    init(name: KeyboardShortcuts.Name) {
        shortcutName = name
        super.init(frame: .zero)
        isBordered = false
        focusRingType = .none
        alignment = .right
        font = .monospacedSystemFont(ofSize: 17, weight: .medium)
        target = self
        action = #selector(toggleRecording(_:))
        setAccessibilityLabel(
            "Record \(ShortcutConflictDetector.title(for: shortcutName)) shortcut"
        )
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { finishRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        self.resolvedAppearance = resolvedAppearance
        updateTitle()
    }

    @objc private func toggleRecording(_ sender: Any?) {
        if isRecording {
            cancelRecording()
            return
        }

        clearConflictFeedback()
        shortcutBeforeRecording = KeyboardShortcuts.getShortcut(for: shortcutName)
        KeyboardShortcuts.disable(shortcutName)
        isRecording = true
        state = .on
        window?.makeFirstResponder(self)
        updateTitle()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, isRecording else { return event }
            consume(event)
            return nil
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, isRecording else { return event }
            guard event.window === window else {
                cancelRecording()
                return event
            }
            let point = convert(event.locationInWindow, from: nil)
            if !bounds.contains(point) { cancelRecording() }
            return event
        }
    }

    private func consume(_ event: NSEvent) {
        if event.keyCode == 53 {
            finishRecording()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            KeyboardShortcuts.setShortcut(nil, for: shortcutName)
            finishRecording()
            clearConflictFeedback()
            onChange?()
            return
        }

        guard let shortcut = KeyboardShortcuts.Shortcut(event: event), shortcut.key != nil else {
            presentConflict(ShortcutConflictDetector.issue(
                reason: "Press a keyboard key together with Command, Option, or Control.",
                for: shortcutName
            ))
            NSSound.beep()
            return
        }
        if let issue = ShortcutConflictDetector.issue(
            for: shortcut,
            excluding: shortcutName
        ) {
            presentConflict(issue)
            NSSound.beep()
            return
        }

        let previousShortcut = shortcutBeforeRecording
        KeyboardShortcuts.setShortcut(shortcut, for: shortcutName)
        finishRecording()
        if !KeyboardShortcuts.isEnabled(for: shortcutName) {
            KeyboardShortcuts.setShortcut(previousShortcut, for: shortcutName)
            KeyboardShortcuts.enable(shortcutName)
            updateTitle()
            presentConflict(ShortcutConflictDetector.issue(
                reason: "\(ShortcutDisplayFormatter.string(for: shortcut)) could not be "
                    + "registered by macOS.",
                for: shortcutName
            ))
            NSSound.beep()
        } else {
            clearConflictFeedback()
            onChange?()
        }
    }

    func cancelRecording() {
        guard isRecording else { return }
        finishRecording()
        clearConflictFeedback()
    }

    func presentConflict(_ issue: ShortcutConflictIssue) {
        let message = issue.message
        toolTip = message
        setAccessibilityHelp(message)
        onValidationMessage?(message)
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    func clearConflictFeedback() {
        toolTip = nil
        setAccessibilityHelp(nil)
        onValidationMessage?(nil)
    }

    private func finishRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        KeyboardShortcuts.enable(shortcutName)
        isRecording = false
        shortcutBeforeRecording = nil
        state = .off
        updateTitle()
    }

    private func updateTitle() {
        let text: String
        if isRecording {
            text = "Type shortcut…"
        } else {
            text = KeyboardShortcuts.getShortcut(for: shortcutName)
                .map(ShortcutDisplayFormatter.string(for:))
                ?? "Not Set"
        }
        let color = isRecording
            ? NSColor.controlAccentColor
            : MonochromePalette.primaryText(for: resolvedAppearance)
        attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 17, weight: .medium),
                .foregroundColor: color,
            ]
        )
        setAccessibilityValue(text)
    }

}

@MainActor
enum ShortcutDisplayFormatter {
    static func string(for shortcut: KeyboardShortcuts.Shortcut) -> String {
        var result = ""
        let modifiers = shortcut.modifiers
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }

        let specialKeys: [KeyboardShortcuts.Key: String] = [
            .space: " Space", .return: "↩", .tab: "⇥", .escape: "Esc",
            .delete: "⌫", .deleteForward: "⌦", .leftArrow: "←",
            .rightArrow: "→", .upArrow: "↑", .downArrow: "↓",
            .pageUp: "⇞", .pageDown: "⇟", .home: "↖", .end: "↘",
            .f1: "F1", .f2: "F2", .f3: "F3", .f4: "F4", .f5: "F5",
            .f6: "F6", .f7: "F7", .f8: "F8", .f9: "F9", .f10: "F10",
            .f11: "F11", .f12: "F12", .f13: "F13", .f14: "F14",
            .f15: "F15", .f16: "F16", .f17: "F17", .f18: "F18",
            .f19: "F19", .f20: "F20",
        ]
        if let key = shortcut.key, let special = specialKeys[key] {
            return result + special
        }
        return result + (shortcut.nsMenuItemKeyEquivalent?.uppercased() ?? "Key")
    }
}

@MainActor
enum ShortcutMatcher {
    static func matches(_ event: NSEvent, name: KeyboardShortcuts.Name) -> Bool {
        guard let configured = KeyboardShortcuts.getShortcut(for: name),
              let incoming = KeyboardShortcuts.Shortcut(event: event)
        else { return false }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        return configured.key == incoming.key
            && configured.modifiers.intersection(relevant)
                == incoming.modifiers.intersection(relevant)
    }
}
