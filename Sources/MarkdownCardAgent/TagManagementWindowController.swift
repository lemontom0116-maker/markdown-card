import AppKit
import MarkdownCardCore

@MainActor
protocol TagManagementConfirmationPresenting: AnyObject {
    func requestRename(
        tag: CardTag,
        in window: NSWindow,
        completion: @escaping (String?) -> Void
    )

    func requestMerge(
        source: CardTag,
        candidates: [CardTag],
        in window: NSWindow,
        completion: @escaping (CardTag?) -> Void
    )

    func requestDelete(
        tag: CardTag,
        cardCount: Int,
        in window: NSWindow,
        completion: @escaping (Bool) -> Void
    )
}

@MainActor
final class AppKitTagManagementConfirmationPresenter: TagManagementConfirmationPresenting {
    func requestRename(
        tag: CardTag,
        in window: NSWindow,
        completion: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Rename “\(tag.name)”"
        alert.informativeText = "Every card using this tag will be updated."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let nameField = NSTextField(string: tag.name)
        nameField.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        nameField.placeholderString = "Tag name"
        nameField.setAccessibilityLabel("New tag name")
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn,
                  let normalized = try? CardTag(nameField.stringValue)
            else {
                completion(nil)
                return
            }
            completion(normalized.name)
        }
    }

    func requestMerge(
        source: CardTag,
        candidates: [CardTag],
        in window: NSWindow,
        completion: @escaping (CardTag?) -> Void
    ) {
        guard !candidates.isEmpty else {
            completion(nil)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Merge “\(source.name)”"
        alert.informativeText = "Cards using this tag will move to the selected tag. This cannot be undone."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")

        let targetPicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        targetPicker.addItems(withTitles: candidates.map(\.name))
        targetPicker.setAccessibilityLabel("Merge destination tag")
        alert.accessoryView = targetPicker

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn,
                  candidates.indices.contains(targetPicker.indexOfSelectedItem)
            else {
                completion(nil)
                return
            }
            completion(candidates[targetPicker.indexOfSelectedItem])
        }
    }

    func requestDelete(
        tag: CardTag,
        cardCount: Int,
        in window: NSWindow,
        completion: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete “\(tag.name)” tag?"
        let cardDescription = cardCount == 1 ? "1 card" : "\(cardCount) cards"
        alert.informativeText = "This removes the tag from \(cardDescription). The cards themselves will not be deleted."
        alert.addButton(withTitle: "Delete Tag")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }
}

@MainActor
final class TagManagementWindowController: NSWindowController, NSSearchFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, AppearanceConsumer
{
    var onPinChange: ((CardTag, Bool) -> Void)?
    var onRenameTag: ((CardTag, String) -> Void)?
    var onMergeTag: ((CardTag, CardTag) -> Void)?
    var onDeleteTag: ((CardTag) -> Void)?
    var onDismiss: (() -> Void)?

    let searchField = NSSearchField()
    let tableView = NSTableView()
    let renameButton = NSButton(title: "Rename…", target: nil, action: nil)
    let mergeButton = NSButton(title: "Merge…", target: nil, action: nil)
    let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    let doneButton = NSButton(title: "Done", target: nil, action: nil)
    let emptyLabel = NSTextField(labelWithString: "No matching tags")

    private(set) var entries: [CardLibraryTagEntry] = []
    private(set) var visibleEntries: [CardLibraryTagEntry] = []

    private let confirmationPresenter: TagManagementConfirmationPresenting
    private let scrollView = NSScrollView()
    private let headingLabel = NSTextField(labelWithString: "Manage Tags")
    private var selectedTagID: String?
    private var resolvedAppearance: ResolvedAppearance = .dark
    private var didNotifyDismiss = false
    private var mutationActionsEnabled = true

    init(
        confirmationPresenter: TagManagementConfirmationPresenting =
            AppKitTagManagementConfirmationPresenter()
    ) {
        self.confirmationPresenter = confirmationPresenter
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configure(window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(entries: [CardLibraryTagEntry], selectedTagID: String? = nil) {
        var seen = Set<String>()
        self.entries = entries.filter { seen.insert($0.tag.id).inserted }
        let preferredSelection = selectedTagID ?? self.selectedTagID
        self.selectedTagID = preferredSelection.flatMap { candidate in
            self.entries.contains(where: { $0.tag.id == candidate }) ? candidate : nil
        }
        refreshFilter()
    }

    func update(
        catalogEntries: [TagCatalogEntry],
        pinnedTagIDs: Set<String>,
        selectedTagID: String? = nil
    ) {
        update(
            entries: catalogEntries.map {
                CardLibraryTagEntry(catalogEntry: $0, pinnedTagIDs: pinnedTagIDs)
            },
            selectedTagID: selectedTagID
        )
    }

    func beginSheet(for parentWindow: NSWindow) {
        guard let window else { return }
        didNotifyDismiss = false
        if window.sheetParent !== parentWindow {
            parentWindow.beginSheet(window)
        }
        window.makeFirstResponder(searchField)
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        self.resolvedAppearance = resolvedAppearance
        guard isWindowLoaded, let window else { return }
        window.backgroundColor = MonochromePalette.windowBackground(for: resolvedAppearance)
        headingLabel.textColor = MonochromePalette.primaryText(for: resolvedAppearance)
        emptyLabel.textColor = MonochromePalette.tertiaryText(for: resolvedAppearance)
        tableView.backgroundColor = .clear
        tableView.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) {
        refreshFilter()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleEntries.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard visibleEntries.indices.contains(row), let tableColumn else { return nil }
        let entry = visibleEntries[row]
        switch tableColumn.identifier.rawValue {
        case "Pin":
            let button = TagManagementPinButton(entry: entry)
            button.onPinChange = { [weak self] tag, pinned in
                self?.setPinned(tag: tag, pinned: pinned)
            }
            button.isEnabled = mutationActionsEnabled
            button.apply(resolvedAppearance: resolvedAppearance)
            return button
        case "Count":
            let label = NSTextField(labelWithString: "\(entry.cardCount)")
            label.alignment = .right
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.textColor = MonochromePalette.tertiaryText(for: resolvedAppearance)
            label.setAccessibilityLabel(
                entry.cardCount == 1 ? "1 card" : "\(entry.cardCount) cards"
            )
            return label
        default:
            let label = NSTextField(labelWithString: entry.tag.name)
            label.font = .systemFont(ofSize: 13, weight: .regular)
            label.lineBreakMode = .byTruncatingTail
            label.textColor = MonochromePalette.secondaryText(for: resolvedAppearance)
            label.setAccessibilityLabel(entry.tag.name)
            return label
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard visibleEntries.indices.contains(tableView.selectedRow) else {
            selectedTagID = nil
            updateActionState()
            return
        }
        selectedTagID = visibleEntries[tableView.selectedRow].tag.id
        updateActionState()
    }

    func windowWillClose(_ notification: Notification) {
        notifyDismissIfNeeded()
    }

    func setMutationActionsEnabled(_ enabled: Bool) {
        mutationActionsEnabled = enabled
        if isWindowLoaded {
            tableView.reloadData()
            updateActionState()
        }
    }

    private func configure(_ window: NSWindow) {
        window.title = "Manage Tags"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 380)
        window.delegate = self

        let root = NSVisualEffectView()
        root.material = .contentBackground
        root.blendingMode = .withinWindow
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        headingLabel.translatesAutoresizingMaskIntoConstraints = false
        headingLabel.font = .systemFont(ofSize: 20, weight: .semibold)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search tags"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search tags")

        let pinColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Pin"))
        pinColumn.title = "Pin"
        pinColumn.width = 44
        pinColumn.minWidth = 44
        pinColumn.maxWidth = 44
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Tag"))
        nameColumn.title = "Tag"
        nameColumn.minWidth = 220
        let countColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Count"))
        countColumn.title = "Cards"
        countColumn.width = 72
        countColumn.minWidth = 72
        countColumn.maxWidth = 72
        tableView.addTableColumn(pinColumn)
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(countColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 34
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(renameSelected(_:))
        tableView.setAccessibilityLabel("Tags")

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.setAccessibilityLabel("No matching tags")

        configureActionButton(renameButton, action: #selector(renameSelected(_:)))
        configureActionButton(mergeButton, action: #selector(mergeSelected(_:)))
        configureActionButton(deleteButton, action: #selector(deleteSelected(_:)))
        deleteButton.contentTintColor = .systemRed
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\u{1b}"
        doneButton.target = self
        doneButton.action = #selector(done(_:))
        doneButton.setAccessibilityLabel("Done managing tags")

        root.addSubview(headingLabel)
        root.addSubview(searchField)
        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        root.addSubview(renameButton)
        root.addSubview(mergeButton)
        root.addSubview(deleteButton)
        root.addSubview(doneButton)
        NSLayoutConstraint.activate([
            headingLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            headingLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            searchField.topAnchor.constraint(equalTo: headingLabel.bottomAnchor, constant: 14),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: renameButton.topAnchor, constant: -14),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            renameButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            renameButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            mergeButton.leadingAnchor.constraint(equalTo: renameButton.trailingAnchor, constant: 8),
            mergeButton.centerYAnchor.constraint(equalTo: renameButton.centerYAnchor),
            deleteButton.leadingAnchor.constraint(equalTo: mergeButton.trailingAnchor, constant: 8),
            deleteButton.centerYAnchor.constraint(equalTo: renameButton.centerYAnchor),
            doneButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            doneButton.centerYAnchor.constraint(equalTo: renameButton.centerYAnchor),
        ])
        apply(resolvedAppearance: resolvedAppearance)
        updateActionState()
    }

    private func configureActionButton(_ button: NSButton, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.setAccessibilityLabel(button.title.replacingOccurrences(of: "…", with: ""))
    }

    private func refreshFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleEntries = entries.filter { entry in
            TagCatalogSearch.matches(tagName: entry.tag.name, query: query)
        }
        tableView.reloadData()
        emptyLabel.isHidden = !visibleEntries.isEmpty

        if let selectedTagID,
           let row = visibleEntries.firstIndex(where: { $0.tag.id == selectedTagID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if let first = visibleEntries.first {
            selectedTagID = first.tag.id
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            selectedTagID = nil
            tableView.deselectAll(nil)
        }
        updateActionState()
    }

    private func selectedEntry() -> CardLibraryTagEntry? {
        guard let selectedTagID else { return nil }
        return entries.first(where: { $0.tag.id == selectedTagID })
    }

    private func setPinned(tag: CardTag, pinned: Bool) {
        guard mutationActionsEnabled else { return }
        guard let index = entries.firstIndex(where: { $0.tag.id == tag.id }) else { return }
        entries[index].isPinned = pinned
        if let visibleIndex = visibleEntries.firstIndex(where: { $0.tag.id == tag.id }) {
            visibleEntries[visibleIndex].isPinned = pinned
            tableView.reloadData(
                forRowIndexes: IndexSet(integer: visibleIndex),
                columnIndexes: IndexSet(integer: 0)
            )
        }
        onPinChange?(tag, pinned)
    }

    private func updateActionState() {
        let hasSelection = selectedEntry() != nil
        renameButton.isEnabled = mutationActionsEnabled && hasSelection
        mergeButton.isEnabled = mutationActionsEnabled && hasSelection && entries.count > 1
        deleteButton.isEnabled = mutationActionsEnabled && hasSelection
    }

    @objc private func renameSelected(_ sender: Any?) {
        guard mutationActionsEnabled,
              let entry = selectedEntry(),
              let window
        else { return }
        confirmationPresenter.requestRename(tag: entry.tag, in: window) { [weak self] name in
            guard let self, mutationActionsEnabled, let name else { return }
            if let replacement = try? CardTag(name),
               replacement.id != entry.tag.id,
               let existing = entries.first(where: { $0.tag.id == replacement.id }) {
                confirmationPresenter.requestMerge(
                    source: entry.tag,
                    candidates: [existing.tag],
                    in: window
                ) { [weak self] target in
                    guard let self, mutationActionsEnabled, let target else { return }
                    onMergeTag?(entry.tag, target)
                }
                return
            }
            onRenameTag?(entry.tag, name)
        }
    }

    @objc private func mergeSelected(_ sender: Any?) {
        guard mutationActionsEnabled,
              let entry = selectedEntry(),
              let window
        else { return }
        let candidates = entries.map(\.tag).filter { $0.id != entry.tag.id }
        confirmationPresenter.requestMerge(
            source: entry.tag,
            candidates: candidates,
            in: window
        ) { [weak self] target in
            guard let self, mutationActionsEnabled, let target else { return }
            onMergeTag?(entry.tag, target)
        }
    }

    @objc private func deleteSelected(_ sender: Any?) {
        guard mutationActionsEnabled,
              let entry = selectedEntry(),
              let window
        else { return }
        confirmationPresenter.requestDelete(
            tag: entry.tag,
            cardCount: entry.cardCount,
            in: window
        ) { [weak self] confirmed in
            guard let self, mutationActionsEnabled, confirmed else { return }
            onDeleteTag?(entry.tag)
        }
    }

    @objc private func done(_ sender: Any?) {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
            window.orderOut(nil)
        } else {
            close()
        }
        notifyDismissIfNeeded()
    }

    private func notifyDismissIfNeeded() {
        guard !didNotifyDismiss else { return }
        didNotifyDismiss = true
        onDismiss?()
    }
}

@MainActor
final class TagManagementPinButton: NSButton, AppearanceConsumer {
    let entry: CardLibraryTagEntry
    var onPinChange: ((CardTag, Bool) -> Void)?
    private var pinned: Bool
    private var resolvedAppearance: ResolvedAppearance = .dark

    init(entry: CardLibraryTagEntry) {
        self.entry = entry
        pinned = entry.isPinned
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        focusRingType = .exterior
        target = self
        action = #selector(togglePin(_:))
        updatePresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        self.resolvedAppearance = resolvedAppearance
        contentTintColor = pinned
            ? CurtainTagPalette.accent(
                for: entry.tag,
                selected: true,
                appearance: resolvedAppearance
            )
            : MonochromePalette.tertiaryText(for: resolvedAppearance)
    }

    private func updatePresentation() {
        image = NSImage(
            systemSymbolName: pinned ? "pin.fill" : "pin",
            accessibilityDescription: nil
        )
        toolTip = pinned ? "Unpin \(entry.tag.name)" : "Pin \(entry.tag.name)"
        setAccessibilityLabel(toolTip)
        setAccessibilityValue(pinned ? "Pinned" : "Not pinned")
        apply(resolvedAppearance: resolvedAppearance)
    }

    @objc private func togglePin(_ sender: Any?) {
        pinned.toggle()
        updatePresentation()
        onPinChange?(entry.tag, pinned)
    }
}
