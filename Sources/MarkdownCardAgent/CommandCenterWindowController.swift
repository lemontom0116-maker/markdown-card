import AppKit
import KeyboardShortcuts
import MarkdownCardCore

enum CommandID: String, CaseIterable, Codable, Hashable {
    case newCard
    case cardLibrary
    case settings
    case quit
}

struct CommandDefinition: Hashable {
    let id: CommandID
    let title: String
    let keywords: [String]
    let symbol: String
}

enum CommandCenterRecentReference: Codable, Equatable, Hashable {
    case card(UUID)
    case command(CommandID)

    private enum CodingKeys: String, CodingKey { case type, id }
    private enum Kind: String, Codable { case card, command }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .card: self = .card(try container.decode(UUID.self, forKey: .id))
        case .command: self = .command(try container.decode(CommandID.self, forKey: .id))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .card(id):
            try container.encode(Kind.card, forKey: .type)
            try container.encode(id, forKey: .id)
        case let .command(id):
            try container.encode(Kind.command, forKey: .type)
            try container.encode(id, forKey: .id)
        }
    }
}

enum CommandCenterItem: Hashable {
    case section(String)
    case card(CardRecord)
    case command(CommandDefinition)

    var isSelectable: Bool {
        switch self {
        case .card, .command: true
        case .section: false
        }
    }
}

enum CommandCenterSearch {
    static func cards(matching query: String, in cards: [CardRecord]) -> [CardRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return cards.sorted { $0.updatedAt > $1.updatedAt } }
        let needle = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return cards.compactMap { card -> (CardRecord, Int)? in
            let title = card.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let body = card.markdown.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let rank: Int
            if title == needle { rank = 0 }
            else if title.hasPrefix(needle) { rank = 1 }
            else if title.contains(needle) { rank = 2 }
            else if body.contains(needle) { rank = 3 }
            else { return nil }
            return (card, rank)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.updatedAt > $1.0.updatedAt
        }.map(\.0)
    }

    static func commands(
        matching query: String,
        in commands: [CommandDefinition]
    ) -> [CommandDefinition] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return commands }
        return commands.filter { command in
            ([command.title] + command.keywords).contains {
                $0.lowercased().contains(needle)
            }
        }
    }
}

@MainActor
final class CommandCenterWindowController: NSWindowController, NSTableViewDataSource,
    NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate, AppearanceConsumer
{
    var onOpenCard: ((UUID) -> Void)?
    var onExecuteCommand: ((CommandID) -> Void)?

    private enum Constants {
        static let recentLimit = 3
        static let storedRecentLimit = 12
        static let recentDefaultsKey = "commandCenterRecentItems.v1"
    }

    private let appearanceController: AppearanceController
    private let defaults: UserDefaults
    private let searchField = CommandCenterSearchField()
    private let searchIcon = NSImageView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let materialView = NSVisualEffectView()
    private let surfaceView = NSView()
    private var cards: [CardRecord] = []
    private var items: [CommandCenterItem] = []
    private var recentReferences: [CommandCenterRecentReference] = []
    private var appearance: ResolvedAppearance = .dark
    private var isClosing = false
    private var selectedItemIndex: Int?

    let commands: [CommandDefinition] = [
        .init(id: .newCard, title: "New Card", keywords: ["create", "note", "new"], symbol: "plus.circle"),
        .init(id: .cardLibrary, title: "Card Library", keywords: ["library", "cards", "browse"], symbol: "rectangle.split.2x1"),
        .init(id: .settings, title: "Settings", keywords: ["preferences", "appearance", "shortcuts", "cli"], symbol: "gearshape"),
        .init(id: .quit, title: "Quit Easy Card", keywords: ["quit", "exit"], symbol: "power"),
    ]

    init(appearanceController: AppearanceController, defaults: UserDefaults = .standard) {
        self.appearanceController = appearanceController
        self.defaults = defaults
        let panel = CommandCenterPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 360),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        recentReferences = loadRecentReferences()
        configureWindow(panel)
        appearanceController.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applySnapshot(_ cards: [CardRecord]) {
        self.cards = cards
        recentReferences = recentReferences.filter { reference in
            if case let .card(id) = reference { return cards.contains { $0.id == id } }
            return true
        }
        persistRecentReferences()
        rebuildItems(resetSelection: false)
    }

    func recentItemTitlesForTesting() -> [String] {
        recentItems().compactMap { item in
            switch item {
            case let .card(card): card.title
            case let .command(command): command.title
            case .section: nil
            }
        }
    }

    func itemLabelsForTesting() -> [String] {
        items.map { item in
            switch item {
            case let .section(title): "[\(title)]"
            case let .card(card): card.title
            case let .command(command): command.title
            }
        }
    }

    func isResultScrollingEnabledForTesting() -> Bool {
        scrollView.hasVerticalScroller && scrollView.documentView === tableView
    }

    func recordRecentForTesting(_ reference: CommandCenterRecentReference) {
        recordRecent(reference)
        rebuildItems(resetSelection: false)
    }

    func toggle(cards: [CardRecord], on screen: NSScreen?) {
        if window?.isVisible == true {
            close(animated: true)
        } else {
            show(cards: cards, on: screen)
        }
    }

    func show(cards: [CardRecord], on screen: NSScreen?) {
        guard let panel = window else { return }
        self.cards = cards
        searchField.stringValue = ""
        rebuildItems(resetSelection: true)
        appearanceController.applyMode(to: panel)
        let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        var frame = panel.frame
        frame.origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2
        )
        panel.setFrame(Self.constrained(frame, to: visibleFrame), display: false)
        isClosing = false
        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        selectFirstResult()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.07
                panel.animator().alphaValue = 1
            }
        } else {
            let finalFrame = panel.frame
            var startFrame = finalFrame
            startFrame.origin.y -= 7
            panel.setFrame(startFrame, display: false)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.13
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(finalFrame, display: true)
            }
        }
    }

    func close(animated: Bool) {
        guard let panel = window, panel.isVisible, !isClosing else { return }
        isClosing = true
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(finishAnimatedClose),
            object: nil
        )
        guard animated else { finishAnimatedClose(); return }
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.05 : 0.09
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }
        perform(#selector(finishAnimatedClose), with: nil, afterDelay: duration)
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        appearance = resolvedAppearance
        guard let window else { return }
        appearanceController.applyMode(to: window)
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        materialView.state = reduceTransparency ? .inactive : .active
        materialView.layer?.backgroundColor = NSColor.clear.cgColor
        surfaceView.layer?.backgroundColor = MonochromePalette.windowBackground(for: appearance)
            .withAlphaComponent(reduceTransparency ? 1 : 0.80).cgColor
        materialView.layer?.borderColor = MonochromePalette.border(for: appearance)
            .withAlphaComponent(0.72).cgColor
        searchField.textColor = MonochromePalette.primaryText(for: appearance)
        searchField.placeholderString = "Search cards and commands…"
        searchIcon.contentTintColor = MonochromePalette.secondaryText(for: appearance)
        tableView.backgroundColor = .clear
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard items.indices.contains(row) else { return 44 }
        if case .section = items[row] { return 28 }
        return 44
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        items.indices.contains(row) && items[row].isSelectable
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = CommandCenterRowView()
        view.appearanceMode = appearance
        return view
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        switch items[row] {
        case let .section(title):
            return CommandCenterSectionCell(title: title, appearance: appearance)
        case let .card(card):
            return CommandCenterResultCell(
                title: card.title,
                symbol: "doc.text",
                appearance: appearance,
                selected: row == selectedItemIndex
            )
        case let .command(command):
            return CommandCenterResultCell(
                title: command.title,
                symbol: command.symbol,
                appearance: appearance,
                selected: row == selectedItemIndex
            )
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if items.indices.contains(tableView.selectedRow), items[tableView.selectedRow].isSelectable {
            selectedItemIndex = tableView.selectedRow
        }
        tableView.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) {
        rebuildItems(resetSelection: true)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1); return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1); return true
        case #selector(NSResponder.insertNewline(_:)):
            executeSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            close(animated: true); return true
        default:
            return false
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close(animated: true)
    }

    private func configureWindow(_ panel: CommandCenterPanel) {
        panel.delegate = self
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.setAccessibilityLabel("Easy Card Command Center")
        panel.onMoveSelection = { [weak self] delta in self?.moveSelection(by: delta) }
        panel.onConfirm = { [weak self] in self?.executeSelection() }
        panel.onCancel = { [weak self] in self?.close(animated: true) }
        panel.onLocalShortcut = { [weak self] event in
            guard let self else { return false }
            if ShortcutMatcher.matches(event, name: .cardLibrary) {
                execute(command: .cardLibrary)
                return true
            }
            if ShortcutMatcher.matches(event, name: .settings) {
                execute(command: .settings)
                return true
            }
            return false
        }

        materialView.translatesAutoresizingMaskIntoConstraints = false
        materialView.material = .hudWindow
        materialView.blendingMode = .behindWindow
        materialView.wantsLayer = true
        materialView.layer?.cornerRadius = 16
        materialView.layer?.cornerCurve = .continuous
        materialView.layer?.masksToBounds = true
        materialView.layer?.borderWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1.5 : 1

        surfaceView.translatesAutoresizingMaskIntoConstraints = false
        surfaceView.wantsLayer = true
        surfaceView.layer?.cornerRadius = 16
        surfaceView.layer?.cornerCurve = .continuous
        surfaceView.layer?.masksToBounds = true

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 20, weight: .regular)
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search cards and commands")
        searchField.onMoveSelection = { [weak self] delta in self?.moveSelection(by: delta) }
        searchField.onConfirm = { [weak self] in self?.executeSelection() }
        searchField.onCancel = { [weak self] in self?.close(animated: true) }

        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)

        let column = NSTableColumn(identifier: .init("CommandCenter"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(activateSelected(_:))

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        materialView.addSubview(surfaceView)
        surfaceView.addSubview(searchIcon)
        surfaceView.addSubview(searchField)
        surfaceView.addSubview(scrollView)
        panel.contentView = materialView
        NSLayoutConstraint.activate([
            surfaceView.leadingAnchor.constraint(equalTo: materialView.leadingAnchor),
            surfaceView.trailingAnchor.constraint(equalTo: materialView.trailingAnchor),
            surfaceView.topAnchor.constraint(equalTo: materialView.topAnchor),
            surfaceView.bottomAnchor.constraint(equalTo: materialView.bottomAnchor),
            searchIcon.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor, constant: 26),
            searchIcon.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 18),
            searchIcon.heightAnchor.constraint(equalToConstant: 18),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor, constant: -26),
            searchField.topAnchor.constraint(equalTo: surfaceView.topAnchor, constant: 22),
            searchField.heightAnchor.constraint(equalToConstant: 38),
            scrollView.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor, constant: 18),
            scrollView.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor, constant: -18),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            scrollView.bottomAnchor.constraint(equalTo: surfaceView.bottomAnchor, constant: -16),
        ])
        apply(resolvedAppearance: appearanceController.resolvedAppearance)
    }

    private func rebuildItems(resetSelection: Bool) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var next: [CommandCenterItem] = []
        if query.isEmpty {
            next.append(.section("Recent"))
            next.append(contentsOf: recentItems())
            let orderedCards = CommandCenterSearch.cards(matching: "", in: cards)
            if !orderedCards.isEmpty {
                next.append(.section("Cards"))
                next.append(contentsOf: orderedCards.prefix(3).map(CommandCenterItem.card))
            }
            if !commands.isEmpty {
                next.append(.section("Commands"))
                next.append(contentsOf: commands.map(CommandCenterItem.command))
            }
        } else {
            let matchingCards = CommandCenterSearch.cards(matching: query, in: cards)
            let matchingCommands = CommandCenterSearch.commands(matching: query, in: commands)
            if !matchingCards.isEmpty {
                next.append(.section("Cards"))
                next.append(contentsOf: matchingCards.map(CommandCenterItem.card))
            }
            if !matchingCommands.isEmpty {
                next.append(.section("Commands"))
                next.append(contentsOf: matchingCommands.map(CommandCenterItem.command))
            }
        }
        items = next
        tableView.reloadData()
        if resetSelection || !items.indices.contains(tableView.selectedRow) { selectFirstResult() }
    }

    private func recentItems() -> [CommandCenterItem] {
        let cardsByID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        let commandsByID = Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
        var result: [CommandCenterItem] = []
        var used = Set<CommandCenterRecentReference>()

        func append(_ reference: CommandCenterRecentReference) {
            guard result.count < Constants.recentLimit, used.insert(reference).inserted else { return }
            switch reference {
            case let .card(id):
                if let card = cardsByID[id] { result.append(.card(card)) }
            case let .command(id):
                if let command = commandsByID[id] { result.append(.command(command)) }
            }
        }

        recentReferences.forEach(append)
        cards.sorted { $0.updatedAt > $1.updatedAt }.forEach { append(.card($0.id)) }
        [CommandID.newCard, .cardLibrary, .settings].forEach { append(.command($0)) }
        return Array(result.prefix(Constants.recentLimit))
    }

    private func selectFirstResult() {
        guard let row = items.firstIndex(where: \.isSelectable) else {
            selectedItemIndex = nil
            tableView.deselectAll(nil)
            return
        }
        selectedItemIndex = row
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        var row = selectedItemIndex ?? -1
        if row < 0 { row = delta > 0 ? -1 : items.count }
        repeat { row += delta } while items.indices.contains(row) && !items[row].isSelectable
        guard items.indices.contains(row) else { return }
        selectedItemIndex = row
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func executeSelection() {
        guard let selectedItemIndex, items.indices.contains(selectedItemIndex) else { return }
        switch items[selectedItemIndex] {
        case let .card(card):
            recordRecent(.card(card.id))
            close(animated: false)
            onOpenCard?(card.id)
        case let .command(command):
            execute(command: command.id)
        case .section:
            break
        }
    }

    private func execute(command: CommandID) {
        recordRecent(.command(command))
        close(animated: false)
        onExecuteCommand?(command)
    }

    private func recordRecent(_ reference: CommandCenterRecentReference) {
        recentReferences.removeAll { $0 == reference }
        recentReferences.insert(reference, at: 0)
        recentReferences = Array(recentReferences.prefix(Constants.storedRecentLimit))
        persistRecentReferences()
    }

    private func loadRecentReferences() -> [CommandCenterRecentReference] {
        guard let data = defaults.data(forKey: Constants.recentDefaultsKey),
              let decoded = try? JSONDecoder().decode([CommandCenterRecentReference].self, from: data)
        else { return [] }
        return decoded
    }

    private func persistRecentReferences() {
        guard let data = try? JSONEncoder().encode(recentReferences) else { return }
        defaults.set(data, forKey: Constants.recentDefaultsKey)
    }

    @objc private func activateSelected(_ sender: Any?) { executeSelection() }

    @objc private func finishAnimatedClose() {
        window?.orderOut(nil)
        window?.alphaValue = 1
        isClosing = false
    }

    private static func constrained(_ frame: NSRect, to visibleFrame: NSRect) -> NSRect {
        var result = frame
        result.size.width = min(result.width, visibleFrame.width)
        result.size.height = min(result.height, visibleFrame.height)
        result.origin.x = min(max(result.minX, visibleFrame.minX), visibleFrame.maxX - result.width)
        result.origin.y = min(max(result.minY, visibleFrame.minY), visibleFrame.maxY - result.height)
        return result
    }
}

@MainActor
private final class CommandCenterPanel: NSPanel {
    var onMoveSelection: ((Int) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onLocalShortcut: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 125: onMoveSelection?(1)
        case 126: onMoveSelection?(-1)
        case 36, 76: onConfirm?()
        default: super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onLocalShortcut?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class CommandCenterSearchField: NSTextField {
    var onMoveSelection: ((Int) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 125: onMoveSelection?(1)
        case 126: onMoveSelection?(-1)
        case 36, 76: onConfirm?()
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
private final class CommandCenterRowView: NSTableRowView {
    var appearanceMode: ResolvedAppearance = .dark

    override func drawSelection(in dirtyRect: NSRect) {}
}

@MainActor
private final class CommandCenterResultCell: NSTableCellView {
    init(title: String, symbol: String, appearance: ResolvedAppearance, selected: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = selected
            ? MonochromePalette.selection(for: appearance).withAlphaComponent(0.32).cgColor
            : NSColor.clear.cgColor
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        icon.contentTintColor = MonochromePalette.secondaryText(for: appearance)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15.5, weight: .medium)
        titleLabel.textColor = MonochromePalette.primaryText(for: appearance)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class CommandCenterSectionCell: NSTableCellView {
    init(title: String, appearance: ResolvedAppearance) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title.uppercased())
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = MonochromePalette.secondaryText(for: appearance)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
