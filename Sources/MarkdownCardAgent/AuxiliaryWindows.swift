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
    static let cardLibrary = Self(
        "cardLibrary",
        initial: .init(.l, modifiers: [.command])
    )
    static let settings = Self(
        "settings",
        initial: .init(.comma, modifiers: [.command])
    )
}

@MainActor
final class ShortcutRecorderButton: NSButton {
    var onChange: (() -> Void)?

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
        setAccessibilityLabel("Record shortcut")
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
            finishRecording()
            return
        }

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
            onChange?()
            return
        }

        guard let shortcut = KeyboardShortcuts.Shortcut(event: event), shortcut.key != nil else {
            NSSound.beep()
            return
        }
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let modifiers = shortcut.modifiers.intersection(relevant)
        guard !modifiers.isDisjoint(with: [.command, .option, .control]),
              !shortcut.isTakenBySystem,
              !isReservedEditorShortcut(shortcut),
              !conflictsWithAnotherShortcut(shortcut)
        else {
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
            NSSound.beep()
        } else {
            onChange?()
        }
    }

    func cancelRecording() {
        guard isRecording else { return }
        finishRecording()
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

    private func isReservedEditorShortcut(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard shortcut.modifiers.intersection(relevant) == [.command],
              let key = shortcut.nsMenuItemKeyEquivalent?.lowercased()
        else { return false }
        return ["e", "w"].contains(key)
    }

    private func conflictsWithAnotherShortcut(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        let names: [KeyboardShortcuts.Name] = [
            .commandCenter,
            .newCard,
            .cardLibrary,
            .settings,
        ]
        let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let modifiers = shortcut.modifiers.intersection(relevant)
        return names.contains { name in
            guard name != shortcutName,
                  let existing = KeyboardShortcuts.getShortcut(for: name)
            else { return false }
            return existing.key == shortcut.key
                && existing.modifiers.intersection(relevant) == modifiers
        }
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
