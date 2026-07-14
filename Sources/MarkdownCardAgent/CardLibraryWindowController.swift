import AppKit
import MarkdownCardCore
import QuartzCore

@MainActor
final class CardLibraryWindowController: NSWindowController, NSTableViewDataSource,
    NSTableViewDelegate, NSSearchFieldDelegate, NSSplitViewDelegate, NSWindowDelegate,
    AppearanceConsumer
{
    var onOpenCard: ((UUID) -> Void)?
    var onDeleteCard: ((UUID) -> Void)?
    var onCreateCard: (() -> Void)?
    var onMarkdownChange: ((UUID, String, UInt64, EditorSourceID) -> Void)?
    var onClose: (() -> Void)?

    let editorSourceID = EditorSourceID()

    private enum DefaultsKey {
        static let frame = "cardLibraryWindowFrame"
        static let divider = "cardLibraryDividerPosition"
        static let selection = "cardLibrarySelectedCardID"
    }

    private let appearanceController: AppearanceController
    private let defaults: UserDefaults
    private let splitView = NSSplitView()
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let titleLabel = NSTextField(labelWithString: "Card Library")
    private let documentTitleLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let copyButton = NSButton()
    private let exportButton = NSButton()
    private let deleteButton = NSButton()
    private let previewView: MarkdownPreviewView
    private let exportService = MarkdownExportService()
    private let emptyView = NSView()
    private var cards: [CardRecord] = []
    private var filteredCards: [CardRecord] = []
    private var revisions: [UUID: UInt64] = [:]
    private var selectedCardID: UUID?
    private var selectedRendererRevision: UInt64 = 0
    private var appearance: ResolvedAppearance
    private var hasRestoredFrame = false
    private var managedAttachmentCardID: UUID?
    private var hasManagedAttachments = false
    private var exportWidthConstraint: NSLayoutConstraint?
    private var copyFeedbackTask: Task<Void, Never>?
    private var exportFeedbackTask: Task<Void, Never>?

    init(appearanceController: AppearanceController, defaults: UserDefaults = .standard) {
        self.appearanceController = appearanceController
        self.defaults = defaults
        appearance = appearanceController.resolvedAppearance
        previewView = MarkdownPreviewView(initialAppearance: appearanceController.resolvedAppearance)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configureWindow(window)
        appearanceController.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showLibrary() {
        guard let window else { return }
        restoreFrameIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        let divider = defaults.object(forKey: DefaultsKey.divider) as? CGFloat ?? 312
        splitView.setPosition(min(max(divider, 280), 360), ofDividerAt: 0)
        appearanceController.applyMode(to: window)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        if cards.isEmpty {
            window.makeFirstResponder(searchField)
        } else {
            previewView.focusEditor()
        }
    }

    func applySnapshot(
        _ cards: [CardRecord],
        revisions: [UUID: UInt64],
        excluding source: EditorSourceID? = nil
    ) {
        let oldCards = self.cards
        let oldVisibleIDs = filteredCards.map(\.id)
        self.cards = Self.orderedByCreation(cards)
        self.revisions = revisions
        filterCards(preserving: selectedCardID)

        if oldVisibleIDs == filteredCards.map(\.id) {
            let oldByID = Dictionary(uniqueKeysWithValues: oldCards.map { ($0.id, $0) })
            let rows = IndexSet(filteredCards.indices.filter { index in
                let card = filteredCards[index]
                return oldByID[card.id] != card
            })
            if !rows.isEmpty {
                tableView.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
            }
        } else {
            tableView.reloadData()
        }

        if selectedCardID == nil || !self.cards.contains(where: { $0.id == selectedCardID }) {
            selectedCardID = restoredSelection() ?? filteredCards.first?.id
            selectCurrentCardInTable()
        }
        updateDocumentPresentation(renderEditor: source != editorSourceID)
    }

    func flushLatestMarkdown() {
        flushEditor(for: selectedCardID)
    }

    func flushLatestMarkdownForTermination() async {
        guard let selectedCardID,
              let markdown = await previewView.currentMarkdown()
        else { return }
        onMarkdownChange?(
            selectedCardID,
            markdown,
            selectedRendererRevision &+ 1,
            editorSourceID
        )
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        appearance = resolvedAppearance
        guard let window else { return }
        appearanceController.applyMode(to: window)
        window.backgroundColor = MonochromePalette.windowBackground(for: appearance)
        splitView.layer?.backgroundColor = MonochromePalette.windowBackground(for: appearance).cgColor
        tableView.backgroundColor = .clear
        scrollView.backgroundColor = .clear
        titleLabel.textColor = MonochromePalette.primaryText(for: appearance)
        documentTitleLabel.textColor = MonochromePalette.primaryText(for: appearance)
        let actionTint = MonochromePalette.secondaryText(for: appearance)
        [copyButton, exportButton, deleteButton].forEach { $0.contentTintColor = actionTint }
        previewView.apply(resolvedAppearance: appearance)
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filteredCards.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 60 }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard filteredCards.indices.contains(row) else { return nil }
        return LibraryCardCell(card: filteredCards[row], appearance: appearance)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let previousID = selectedCardID
        if filteredCards.indices.contains(tableView.selectedRow) {
            selectedCardID = filteredCards[tableView.selectedRow].id
        } else {
            selectedCardID = nil
        }
        if previousID != selectedCardID {
            flushEditor(for: previousID)
            if let selectedCardID {
                defaults.set(selectedCardID.uuidString, forKey: DefaultsKey.selection)
            }
            updateDocumentPresentation(renderEditor: true)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        filterCards(preserving: selectedCardID)
        tableView.reloadData()
        selectCurrentCardInTable()
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard splitView.subviews.count >= 2 else { return }
        defaults.set(splitView.subviews[0].frame.width, forKey: DefaultsKey.divider)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat { 280 }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat { 360 }

    func windowWillClose(_ notification: Notification) {
        flushLatestMarkdown()
        if let frame = window?.frame {
            defaults.set(NSStringFromRect(frame), forKey: DefaultsKey.frame)
        }
        onClose?()
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

    private func configureWindow(_ window: NSWindow) {
        window.delegate = self
        window.title = "Card Library"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 540)

        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.wantsLayer = true

        let sidebar = makeSidebar()
        let document = makeDocumentView()
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(document)
        window.contentView = splitView

        let divider = defaults.object(forKey: DefaultsKey.divider) as? CGFloat ?? 312
        splitView.setPosition(min(max(divider, 280), 360), ofDividerAt: 0)
        apply(resolvedAppearance: appearance)
    }

    private func makeSidebar() -> NSView {
        let root = NSVisualEffectView()
        root.material = .sidebar
        root.blendingMode = .behindWindow
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        root.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search cards"
        searchField.delegate = self

        let column = NSTableColumn(identifier: .init("LibraryCards"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 60
        tableView.intercellSpacing = NSSize(width: 0, height: 3)
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .clear
        tableView.target = self
        tableView.doubleAction = #selector(openSelected(_:))

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        root.addSubview(titleLabel)
        root.addSubview(searchField)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 70),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            searchField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        return root
    }

    private func makeDocumentView() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        documentTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        documentTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        documentTitleLabel.lineBreakMode = .byTruncatingTail

        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.isBordered = false
        openButton.target = self
        openButton.action = #selector(openSelected(_:))
        openButton.font = .systemFont(ofSize: 13, weight: .medium)

        configureIconButton(
            copyButton,
            symbol: "doc.on.doc",
            label: "Copy Markdown",
            action: #selector(copySelected(_:))
        )
        configureIconButton(
            exportButton,
            symbol: "square.and.arrow.down",
            label: "Export Markdown",
            action: #selector(exportSelected(_:)),
            fixedWidth: false
        )
        configureIconButton(
            deleteButton,
            symbol: "trash",
            label: "Delete Card",
            action: #selector(deleteSelected(_:))
        )
        exportButton.alphaValue = 0
        exportButton.isHidden = true
        exportWidthConstraint = exportButton.widthAnchor.constraint(equalToConstant: 0)
        exportWidthConstraint?.isActive = true
        header.addSubview(documentTitleLabel)
        header.addSubview(openButton)
        header.addSubview(copyButton)
        header.addSubview(exportButton)
        header.addSubview(deleteButton)

        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.onMarkdownChange = { [weak self] cardID, markdown, incomingRevision in
            guard let self, selectedCardID == cardID else { return }
            selectedRendererRevision = max(selectedRendererRevision, incomingRevision)
            if let index = cards.firstIndex(where: { $0.id == cardID }) {
                cards[index].updateMarkdown(markdown)
            }
            onMarkdownChange?(cardID, markdown, incomingRevision, editorSourceID)
        }
        previewView.onManagedAttachmentsChange = { [weak self] cardID, identifiers in
            guard let self, selectedCardID == cardID else { return }
            managedAttachmentCardID = cardID
            setManagedAttachmentsPresent(!identifiers.isEmpty, animated: true)
        }

        configureEmptyView()
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(previewView)
        root.addSubview(emptyView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 56),
            documentTitleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            documentTitleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            documentTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -20),
            deleteButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            deleteButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            exportButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -4),
            exportButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: exportButton.leadingAnchor, constant: -4),
            copyButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            openButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -12),
            openButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            previewView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: header.bottomAnchor),
            previewView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: header.bottomAnchor),
            emptyView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    private func configureEmptyView() {
        let title = NSTextField(labelWithString: "No cards yet")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let note = NSTextField(labelWithString: "Create a card to start writing.")
        note.translatesAutoresizingMaskIntoConstraints = false
        note.font = .systemFont(ofSize: 13)
        let button = NSButton(title: "New Card", target: self, action: #selector(createCard(_:)))
        button.translatesAutoresizingMaskIntoConstraints = false
        emptyView.addSubview(title)
        emptyView.addSubview(note)
        emptyView.addSubview(button)
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: emptyView.centerYAnchor, constant: -30),
            note.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
            note.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            button.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
            button.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 20),
        ])
    }

    private func configureIconButton(
        _ button: NSButton,
        symbol: String,
        label: String,
        action: Selector,
        fixedWidth: Bool = true
    ) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
        button.toolTip = label
        if fixedWidth {
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        }
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
    }

    private func filterCards(preserving selection: UUID?) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        filteredCards = Self.orderedByCreation(cards.filter { card in
            query.isEmpty
                || card.title.localizedCaseInsensitiveContains(query)
                || card.markdown.localizedCaseInsensitiveContains(query)
        })
        if let selection, filteredCards.contains(where: { $0.id == selection }) {
            selectedCardID = selection
        } else if !query.isEmpty {
            selectedCardID = filteredCards.first?.id
        }
    }

    static func orderedByCreation(_ cards: [CardRecord]) -> [CardRecord] {
        cards.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func selectCurrentCardInTable() {
        guard let selectedCardID,
              let row = filteredCards.firstIndex(where: { $0.id == selectedCardID })
        else {
            tableView.deselectAll(nil)
            return
        }
        if tableView.selectedRow != row {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private func updateDocumentPresentation(renderEditor: Bool) {
        guard let card = cards.first(where: { $0.id == selectedCardID }) else {
            documentTitleLabel.stringValue = cards.isEmpty ? "Card Library" : "No Selection"
            openButton.isEnabled = false
            copyButton.isEnabled = false
            exportButton.isEnabled = false
            deleteButton.isEnabled = false
            managedAttachmentCardID = nil
            setManagedAttachmentsPresent(false, animated: false)
            previewView.isHidden = true
            emptyView.isHidden = !cards.isEmpty
            return
        }
        documentTitleLabel.stringValue = card.title
        openButton.isEnabled = true
        copyButton.isEnabled = true
        exportButton.isEnabled = true
        deleteButton.isEnabled = true
        if managedAttachmentCardID != card.id {
            setManagedAttachmentsPresent(false, animated: false)
        }
        previewView.isHidden = false
        emptyView.isHidden = true
        guard renderEditor else { return }
        let revision = revisions[card.id, default: 0]
        selectedRendererRevision = revision
        previewView.render(
            RenderPayload(
                cardID: card.id,
                markdown: card.markdown,
                title: card.title,
                resolvedAppearance: appearance,
                revision: revision
            )
        )
    }

    private func flushEditor(for cardID: UUID?) {
        guard let cardID else { return }
        let revision = selectedRendererRevision
        previewView.currentMarkdown { [weak self] markdown in
            guard let self, let markdown else { return }
            onMarkdownChange?(cardID, markdown, revision &+ 1, editorSourceID)
        }
    }

    private func restoredSelection() -> UUID? {
        defaults.string(forKey: DefaultsKey.selection).flatMap(UUID.init(uuidString:))
    }

    private func restoreFrameIfNeeded() {
        guard !hasRestoredFrame, let window else { return }
        hasRestoredFrame = true
        if let stored = defaults.string(forKey: DefaultsKey.frame) {
            window.setFrame(NSRectFromString(stored), display: false)
        } else {
            window.center()
        }
    }

    private func saveFrame() {
        guard hasRestoredFrame, let frame = window?.frame else { return }
        defaults.set(NSStringFromRect(frame), forKey: DefaultsKey.frame)
    }

    @objc private func openSelected(_ sender: Any?) {
        guard let selectedCardID else { return }
        flushLatestMarkdown()
        onOpenCard?(selectedCardID)
    }

    @objc private func copySelected(_ sender: Any?) {
        guard selectedCardID != nil else { return }
        previewView.currentMarkdownForCopy { [weak self] markdown in
            guard let self else { return }
            guard let markdown else {
                NSSound.beep()
                showCopyFeedback(success: false)
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(markdown, forType: .string) else {
                NSSound.beep()
                showCopyFeedback(success: false)
                return
            }
            showCopyFeedback(success: true)
        }
    }

    @objc private func exportSelected(_ sender: Any?) {
        guard let window,
              let card = cards.first(where: { $0.id == selectedCardID })
        else { return }
        previewView.currentMarkdownExportBundle { [weak self, weak window] bundle in
            guard let self, let window else { return }
            guard let bundle else {
                NSSound.beep()
                showExportFeedback(success: false)
                return
            }
            exportService.present(bundle: bundle, title: card.title, from: window) {
                [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .cancelled:
                    break
                case .success:
                    showExportFeedback(success: true)
                case .failure:
                    showExportFeedback(success: false)
                }
            }
        }
    }

    @objc private func deleteSelected(_ sender: Any?) {
        guard let selectedCardID,
              let card = cards.first(where: { $0.id == selectedCardID })
        else { return }
        let alert = NSAlert()
        alert.messageText = "Delete “\(card.title)” ?"
        alert.informativeText = "This removes the card from the local library. This action cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onDeleteCard?(selectedCardID)
    }

    @objc private func createCard(_ sender: Any?) { onCreateCard?() }

    private func setManagedAttachmentsPresent(_ present: Bool, animated: Bool) {
        guard hasManagedAttachments != present || exportButton.isHidden == present else { return }
        hasManagedAttachments = present
        if present { exportButton.isHidden = false }
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
        let changes = { [self] in
            exportWidthConstraint?.animator().constant = present ? 34 : 0
            exportButton.animator().alphaValue = present ? 1 : 0
            exportButton.superview?.layoutSubtreeIfNeeded()
        }
        guard animated, duration > 0, window?.isVisible == true else {
            exportWidthConstraint?.constant = present ? 34 : 0
            exportButton.alphaValue = present ? 1 : 0
            exportButton.isHidden = !present
            exportButton.superview?.layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            changes()
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.exportButton.isHidden = !present
            }
        }
    }

    private func showCopyFeedback(success: Bool) {
        copyFeedbackTask?.cancel()
        let symbol = success ? "checkmark" : "exclamationmark"
        let announcement = success ? "Markdown copied" : "Unable to copy Markdown"
        copyButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: announcement)
        NSAccessibility.post(
            element: copyButton,
            notification: .announcementRequested,
            userInfo: [.announcement: announcement]
        )
        copyFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.copyButton.image = NSImage(
                systemSymbolName: "doc.on.doc",
                accessibilityDescription: "Copy Markdown"
            )
        }
    }

    private func showExportFeedback(success: Bool) {
        exportFeedbackTask?.cancel()
        let symbol = success ? "checkmark" : "exclamationmark"
        let announcement = success ? "Markdown exported" : "Unable to export Markdown"
        exportButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: announcement)
        NSAccessibility.post(
            element: exportButton,
            notification: .announcementRequested,
            userInfo: [.announcement: announcement]
        )
        exportFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.exportButton.image = NSImage(
                systemSymbolName: "square.and.arrow.down",
                accessibilityDescription: "Export Markdown"
            )
        }
    }
}

@MainActor
private final class LibraryCardCell: NSTableCellView {
    init(card: CardRecord, appearance: ResolvedAppearance) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: card.title)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13.5, weight: .medium)
        title.textColor = MonochromePalette.primaryText(for: appearance)
        title.lineBreakMode = .byTruncatingTail
        let date = NSTextField(labelWithString: Self.relativeDate(card.updatedAt))
        date.translatesAutoresizingMaskIntoConstraints = false
        date.font = .systemFont(ofSize: 11, weight: .regular)
        date.textColor = MonochromePalette.secondaryText(for: appearance)
        addSubview(title)
        addSubview(date)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            date.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            date.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func relativeDate(_ date: Date) -> String {
        let interval = max(0, Date().timeIntervalSince(date))
        if interval < 60 { return "Now" }
        if interval < 3_600 { return "\(Int(interval / 60))m" }
        if interval < 86_400 { return "\(Int(interval / 3_600))h" }
        if interval < 172_800 { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
