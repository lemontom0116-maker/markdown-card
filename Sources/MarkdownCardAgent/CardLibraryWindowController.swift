import AppKit
import MarkdownCardCore
import QuartzCore

enum CardLibraryEmptyState: Equatable {
    case noCards
    case noMatches
    case noSelection

    var title: String {
        switch self {
        case .noCards: "No cards yet"
        case .noMatches: "No matching cards"
        case .noSelection: "Select a card"
        }
    }

    var note: String {
        switch self {
        case .noCards: "Create a card to start writing."
        case .noMatches: "Try another search or clear the current filters."
        case .noSelection: "Choose a card from the library to start editing."
        }
    }
}

enum CardLibraryFileOperationError: LocalizedError, Equatable {
    case selectionChanged

    var errorDescription: String? {
        "The selected Library card changed before the file operation completed."
    }
}

private enum CardLibraryDateSection: String {
    case today = "Today"
    case yesterday = "Yesterday"
    case thisMonth = "This Month"
    case earlier = "Earlier"
}

private enum CardLibraryListRow: Equatable {
    case section(CardLibraryDateSection)
    case card(UUID)
}

@MainActor
final class CardLibraryWindowController: NSWindowController, NSTableViewDataSource,
    NSTableViewDelegate, NSSearchFieldDelegate, NSSplitViewDelegate, NSWindowDelegate,
    AppearanceConsumer
{
    enum PresentationMode {
        case standalone
        case embedded
    }

    var onOpenCard: ((UUID) -> Void)?
    var onDeleteCard: ((UUID) -> Void)?
    var onCreateCard: (() -> Void)?
    var onMarkdownChange: ((UUID, String, UInt64, EditorSourceID) -> Void)?
    var onTagCommandSubmitted: ((UUID, String, String, UInt64, EditorSourceID) -> Void)?
    var onTagSelectionChange: ((UUID, String?) -> Void)?
    var onRemoveTag: ((UUID, String) -> Void)?
    var onRenameTag: ((String, String) -> Void)?
    var onMergeTag: ((String, String) -> Void)?
    var onDeleteTag: ((String) -> Void)?
    var onTagPreferenceError: ((Error) -> Void)?
    var onRequestSaveAs: ((UUID) -> Void)?
    var onClose: (() -> Void)?
    var onExternalSearchQueryChange: ((String) -> Void)?
    var onRequestBack: (() -> Void)?
    var documentRootURLForCard: ((UUID) -> URL?)?
    var seriesOrderByTagID: (() -> [String: [UUID]])?

    let editorSourceID = EditorSourceID()

    private enum DefaultsKey {
        static let frame = "cardLibraryWindowFrame"
        static let divider = "cardLibraryDividerPosition"
        static let selection = "cardLibrarySelectedCardID"
    }

    private enum SidebarLayout {
        static let defaultWidth: CGFloat = 280
        static let minimumWidth: CGFloat = 280
        static let maximumWidth: CGFloat = 360
    }

    private let appearanceController: AppearanceController
    private let defaults: UserDefaults
    private let tagPreferencesStore: TagCatalogPreferencesStore
    private let presentationMode: PresentationMode
    private let splitView = NSSplitView()
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let titleLabel = NSTextField(labelWithString: "Card Library")
    private let sidebarTagFilterBar = CardLibraryTagFilterBar()
    private let documentTitleLabel = NSTextField(labelWithString: "")
    private let documentTagStrip = CurtainTagStripView()
    private let seriesNavigation = BareSeriesNavigationControl()
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let copyButton = NSButton()
    private let exportButton = NSButton()
    private let deleteButton = NSButton()
    private let previewView: MarkdownPreviewView
    private let exportService = MarkdownExportService()
    private let informationView = NSView()
    private let informationHeading = NSTextField(labelWithString: "Information")
    private let informationTitleValue = NSTextField(labelWithString: "—")
    private let informationCharactersValue = NSTextField(labelWithString: "0")
    private let informationWordsValue = NSTextField(labelWithString: "0")
    private let informationCreatedValue = NSTextField(labelWithString: "—")
    private let informationModifiedValue = NSTextField(labelWithString: "—")
    private let informationTagsValue = NSTextField(labelWithString: "—")
    private var informationKeyLabels: [NSTextField] = []
    private let emptyView = NSView()
    private let emptyTitleLabel = NSTextField(labelWithString: "")
    private let emptyNoteLabel = NSTextField(labelWithString: "")
    private let emptyActionButton = NSButton()
    private var cards: [CardRecord] = []
    private var filteredCards: [CardRecord] = []
    private var listRows: [CardLibraryListRow] = []
    private var tagCatalog = TagCatalogSnapshot(cards: [])
    private var tagPreferences = TagCatalogPreferences.empty
    private var revisions: [UUID: UInt64] = [:]
    private var selectedCardID: UUID?
    private var activeTagID: String?
    private var tagContextCardID: UUID?
    private var selectedRendererRevision: UInt64 = 0
    private var appearance: ResolvedAppearance
    private var hasRestoredFrame = false
    private var managedAttachmentCardID: UUID?
    private var hasManagedAttachments = false
    private var documentHeaderHeightConstraint: NSLayoutConstraint?
    private weak var documentHeaderView: NSView?
    private var documentTagLeadingConstraint: NSLayoutConstraint?
    private var exportWidthConstraint: NSLayoutConstraint?
    private var copyFeedbackTask: Task<Void, Never>?
    private var exportFeedbackTask: Task<Void, Never>?
    private var tagManagementWindowController: TagManagementWindowController?
    private var isGlobalTagMutationInFlight = false
    private var hasRestoredSidebarWidth = false
    private var isRestoringSidebarWidth = false
    private var hostingWindowProvider: (() -> NSWindow?)?

    init(
        appearanceController: AppearanceController,
        defaults: UserDefaults = .standard,
        tagPreferencesStore: TagCatalogPreferencesStore? = nil,
        presentationMode: PresentationMode = .standalone
    ) {
        self.appearanceController = appearanceController
        self.defaults = defaults
        self.presentationMode = presentationMode
        self.tagPreferencesStore = tagPreferencesStore
            ?? TagCatalogPreferencesStore(defaults: defaults)
        appearance = appearanceController.resolvedAppearance
        previewView = MarkdownPreviewView(initialAppearance: appearanceController.resolvedAppearance)
        let window: NSWindow? = if presentationMode == .standalone {
            NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
        } else {
            nil
        }
        super.init(window: window)
        configureContent()
        if let window {
            configureWindow(window)
        }
        appearanceController.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showLibrary() {
        if presentationMode == .embedded {
            activate()
            return
        }
        guard let window else { return }
        restoreFrameIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        restoreSidebarWidth()
        window.contentView?.layoutSubtreeIfNeeded()
        updateDocumentTagLeadingInset()
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
        let previousSelectedCardID = selectedCardID
        let previousSelectedCard = oldCards.first(where: { $0.id == previousSelectedCardID })
        let previousSelectedRevision = previousSelectedCardID.flatMap { self.revisions[$0] }
        let oldVisibleIDs = filteredCards.map(\.id)
        self.cards = Self.orderedByCreation(cards)
        self.revisions = revisions
        tagCatalog = TagCatalogSnapshot(cards: self.cards)
        tagPreferences = tagPreferencesStore.load(
            validTagIDs: tagCatalog.validTagIDs,
            persistCleanup: !isGlobalTagMutationInFlight
        )
        if let activeTagID, tagCatalog.entry(tagID: activeTagID) == nil {
            self.activeTagID = nil
            tagContextCardID = nil
        }
        refreshTagControls(animated: presentationWindow?.isVisible == true)
        filterCards(preserving: selectedCardID)

        if presentationMode == .embedded {
            tableView.reloadData()
        } else if oldVisibleIDs == filteredCards.map(\.id) {
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
            let restored = restoredSelection().flatMap { candidate in
                filteredCards.contains(where: { $0.id == candidate }) ? candidate : nil
            }
            selectedCardID = restored ?? filteredCards.first?.id
        }
        selectCurrentCardInTable()
        let currentSelectedCard = self.cards.first(where: { $0.id == selectedCardID })
        let currentSelectedRevision = selectedCardID.flatMap { revisions[$0] }
        let selectedDocumentChanged = previousSelectedCardID != selectedCardID
            || previousSelectedCard?.markdown != currentSelectedCard?.markdown
            || previousSelectedRevision != currentSelectedRevision
        updateDocumentPresentation(
            renderEditor: source != editorSourceID && selectedDocumentChanged
        )
    }

    func flushLatestMarkdown() {
        flushEditor(for: selectedCardID)
    }

    var rootViewForEmbedding: NSView { splitView }

    func listRowLabelsForTesting() -> [String] {
        listRows.compactMap { row in
            switch row {
            case let .section(section): "[\(section.rawValue)]"
            case let .card(cardID): cards.first(where: { $0.id == cardID })?.title
            }
        }
    }

    func informationValuesForTesting() -> [String: String] {
        [
            "Title": informationTitleValue.stringValue,
            "Characters": informationCharactersValue.stringValue,
            "Words": informationWordsValue.stringValue,
            "Created": informationCreatedValue.stringValue,
            "Modified": informationModifiedValue.stringValue,
            "Tags": informationTagsValue.stringValue,
        ]
    }

    func prepareForEmbedding(hostingWindowProvider: @escaping () -> NSWindow?) -> NSView {
        self.hostingWindowProvider = hostingWindowProvider
        splitView.removeFromSuperview()
        return splitView
    }

    func activate() {
        restoreSidebarWidth()
        rebuildListRows()
        tableView.reloadData()
        selectCurrentCardInTable()
        updateDocumentTagLeadingInset()
        apply(resolvedAppearance: appearance)
    }

    func routeDidDeactivate() {
        previewView.dismissTransientUI()
        flushLatestMarkdown()
    }

    func cancelTransientUI() {
        previewView.dismissTransientUI()
    }

    func setExternalSearchQuery(_ query: String) {
        guard searchField.stringValue != query else { return }
        let previousID = selectedCardID
        searchField.stringValue = query
        filterCards(preserving: selectedCardID)
        if previousID != selectedCardID {
            flushEditor(for: previousID)
        }
        tableView.reloadData()
        selectCurrentCardInTable()
        updateDocumentPresentation(renderEditor: previousID != selectedCardID)
    }

    func focusList() {
        presentationWindow?.makeFirstResponder(tableView)
    }

    func moveListSelection(by delta: Int) {
        guard !filteredCards.isEmpty else { return }
        let current = selectedCardID.flatMap { selected in
            filteredCards.firstIndex(where: { $0.id == selected })
        } ?? (delta > 0 ? -1 : filteredCards.count)
        let target = min(max(current + delta, 0), filteredCards.count - 1)
        guard target != current else { return }
        let targetID = filteredCards[target].id
        guard let row = listRows.firstIndex(where: { candidate in
            if case let .card(cardID) = candidate { return cardID == targetID }
            return false
        }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    func focusEditor() {
        previewView.focusEditor()
    }

    func editorOwnsFirstResponder(in window: NSWindow?) -> Bool {
        previewView.ownsFirstResponder(in: window)
    }

    func performPrimaryAction() {
        openSelected(nil)
    }

    func showActionsMenu(relativeTo view: NSView) {
        let menu = NSMenu(title: "Library Actions")
        let actions: [(String, Selector, String)] = [
            ("New Card", #selector(createCard(_:)), "plus"),
            ("Copy Markdown", #selector(copySelected(_:)), "doc.on.doc"),
            ("Export Markdown", #selector(exportSelected(_:)), "square.and.arrow.down"),
            ("Manage Tags…", #selector(manageTagsFromMenu(_:)), "tag"),
            ("Delete Card", #selector(deleteSelected(_:)), "trash"),
        ]
        for (title, action, symbol) in actions {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            if selectedCardID == nil,
               action != #selector(createCard(_:)),
               action != #selector(manageTagsFromMenu(_:)) {
                item.isEnabled = false
            }
            menu.addItem(item)
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: view.bounds.maxX, y: view.bounds.minY),
            in: view
        )
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

    func refreshDocumentRoot(for cardID: UUID) {
        guard selectedCardID == cardID else { return }
        updateDocumentPresentation(renderEditor: true)
    }

    func activeSeriesSelection() -> (cardID: UUID, tagID: String)? {
        guard let selectedCardID, let activeTagID else { return nil }
        return (selectedCardID, activeTagID)
    }

    /// Keeps the Library filter attached to a globally renamed or merged Tag.
    /// The following snapshot rebuilds the visible controls from committed
    /// card metadata; this method intentionally emits no selection callback.
    func migrateActiveTag(fromID sourceID: String, toID destinationID: String?) {
        guard activeTagID == sourceID else { return }
        activeTagID = destinationID
        if destinationID == nil { tagContextCardID = nil }
    }

    func setGlobalTagMutationInFlight(_ inFlight: Bool) {
        let wasInFlight = isGlobalTagMutationInFlight
        isGlobalTagMutationInFlight = inFlight
        sidebarTagFilterBar.setManagementActionsEnabled(!inFlight)
        tagManagementWindowController?.setMutationActionsEnabled(!inFlight)
        if wasInFlight, !inFlight {
            tagPreferences = tagPreferencesStore.load(
                validTagIDs: tagCatalog.validTagIDs,
                persistCleanup: true
            )
            refreshTagControls(animated: presentationWindow?.isVisible == true)
        }
    }

    /// Returns the document selected in the Library editor. File-menu actions
    /// use this only while the Library window is key, so Save never falls back
    /// to an unrelated recently active card.
    func activeCardSelection() -> UUID? { selectedCardID }

    /// Pulls the authoritative editor value before a native file operation.
    /// The Library keeps its own renderer, so looking only at CardPanel windows
    /// can otherwise save an older native snapshot.
    func latestMarkdownForFileOperation(cardID: UUID) async throws -> String {
        try Self.validateFileOperationSelection(expected: cardID, current: selectedCardID)
        let snapshot = await previewView.currentMarkdownSnapshot()
        try Self.validateFileOperationSelection(expected: cardID, current: selectedCardID)
        let markdown: String
        switch snapshot {
        case let .markdown(value):
            markdown = value
        case .notLoaded:
            guard let card = cards.first(where: { $0.id == cardID }) else {
                throw CardLibraryFileOperationError.selectionChanged
            }
            return card.markdown
        case let .failure(error):
            throw error
        }
        if let index = cards.firstIndex(where: { $0.id == cardID }),
           cards[index].markdown != markdown {
            selectedRendererRevision &+= 1
            cards[index].updateMarkdown(markdown)
            onMarkdownChange?(
                cardID,
                markdown,
                selectedRendererRevision,
                editorSourceID
            )
        }
        return markdown
    }

    func latestMarkdownExportBundleForFileOperation(
        cardID: UUID
    ) async throws -> MarkdownExportBundle {
        let firstSnapshot = try await latestMarkdownForFileOperation(cardID: cardID)
        let exportBundle = await previewView.currentMarkdownExportBundle()
        try Self.validateFileOperationSelection(expected: cardID, current: selectedCardID)
        guard let bundle = exportBundle else {
            throw RendererMarkdownSnapshotError.unavailable
        }
        if bundle.markdown != firstSnapshot,
           let index = cards.firstIndex(where: { $0.id == cardID }),
           cards[index].markdown != bundle.markdown {
            selectedRendererRevision &+= 1
            cards[index].updateMarkdown(bundle.markdown)
            onMarkdownChange?(
                cardID,
                bundle.markdown,
                selectedRendererRevision,
                editorSourceID
            )
        }
        return bundle
    }

    static func validateFileOperationSelection(expected: UUID, current: UUID?) throws {
        guard current == expected else {
            throw CardLibraryFileOperationError.selectionChanged
        }
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        appearance = resolvedAppearance
        if let window = presentationWindow {
            appearanceController.applyMode(to: window)
            if presentationMode == .standalone {
                window.backgroundColor = MonochromePalette.windowBackground(for: appearance)
            }
        }
        splitView.layer?.backgroundColor = MonochromePalette.windowBackground(for: appearance).cgColor
        tableView.backgroundColor = .clear
        scrollView.backgroundColor = .clear
        titleLabel.textColor = MonochromePalette.primaryText(for: appearance)
        documentTitleLabel.textColor = MonochromePalette.primaryText(for: appearance)
        emptyTitleLabel.textColor = MonochromePalette.primaryText(for: appearance)
        emptyNoteLabel.textColor = MonochromePalette.secondaryText(for: appearance)
        informationHeading.textColor = MonochromePalette.secondaryText(for: appearance)
        informationKeyLabels.forEach {
            $0.textColor = MonochromePalette.secondaryText(for: appearance)
        }
        [
            informationTitleValue,
            informationCharactersValue,
            informationWordsValue,
            informationCreatedValue,
            informationModifiedValue,
            informationTagsValue,
        ].forEach { $0.textColor = MonochromePalette.primaryText(for: appearance) }
        informationView.layer?.backgroundColor = MonochromePalette.windowBackground(for: appearance)
            .withAlphaComponent(0.34).cgColor
        let actionTint = MonochromePalette.secondaryText(for: appearance)
        [copyButton, exportButton, deleteButton].forEach { $0.contentTintColor = actionTint }
        sidebarTagFilterBar.apply(resolvedAppearance: appearance)
        tagManagementWindowController?.apply(resolvedAppearance: appearance)
        documentTagStrip.apply(resolvedAppearance: appearance)
        seriesNavigation.apply(resolvedAppearance: appearance)
        previewView.apply(resolvedAppearance: appearance)
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { listRows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard listRows.indices.contains(row) else { return 60 }
        if case .section = listRows[row] { return 34 }
        return 60
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard listRows.indices.contains(row) else { return false }
        if case .card = listRows[row] { return true }
        return false
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard listRows.indices.contains(row) else { return nil }
        switch listRows[row] {
        case let .section(section):
            return LibraryDateSectionCell(title: section.rawValue, appearance: appearance)
        case let .card(cardID):
            guard let card = filteredCards.first(where: { $0.id == cardID }) else { return nil }
            return LibraryCardCell(card: card, appearance: appearance)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let previousID = selectedCardID
        if listRows.indices.contains(tableView.selectedRow),
           case let .card(cardID) = listRows[tableView.selectedRow] {
            selectedCardID = cardID
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
        let previousID = selectedCardID
        filterCards(preserving: selectedCardID)
        if previousID != selectedCardID {
            flushEditor(for: previousID)
        }
        tableView.reloadData()
        selectCurrentCardInTable()
        if previousID != selectedCardID {
            updateDocumentPresentation(renderEditor: true)
        }
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard splitView.subviews.count >= 2,
              hasRestoredSidebarWidth,
              !isRestoringSidebarWidth
        else { return }
        defaults.set(splitView.subviews[0].frame.width, forKey: DefaultsKey.divider)
        updateDocumentTagLeadingInset()
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat { SidebarLayout.minimumWidth }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat { SidebarLayout.maximumWidth }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view !== splitView.subviews.first
    }

    func windowWillClose(_ notification: Notification) {
        previewView.dismissTransientUI()
        flushLatestMarkdown()
        if let frame = window?.frame {
            defaults.set(NSStringFromRect(frame), forKey: DefaultsKey.frame)
        }
        onClose?()
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) {
        saveFrame()
        updateDocumentTagLeadingInset()
    }
    func windowDidResignKey(_ notification: Notification) {
        previewView.dismissTransientUI()
    }

    private func configureWindow(_ window: NSWindow) {
        window.delegate = self
        window.title = "Card Library"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Match the floating Card level while the app is active so Library is
        // never trapped behind the cards it manages. Moving to the active Space
        // also keeps a reopened Library attached to the user's current context.
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.hidesOnDeactivate = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 540)

        window.contentView = splitView
        window.contentView?.layoutSubtreeIfNeeded()
        restoreSidebarWidth()
        window.contentView?.layoutSubtreeIfNeeded()
        updateDocumentTagLeadingInset()
        apply(resolvedAppearance: appearance)
    }

    private var presentationWindow: NSWindow? {
        hostingWindowProvider?() ?? window
    }

    private func configureContent() {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.wantsLayer = true

        let sidebar = makeSidebar()
        let document = makeDocumentView()
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(document)

    }

    private func makeSidebar() -> NSView {
        let root = NSVisualEffectView()
        root.material = .sidebar
        root.blendingMode = .behindWindow
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(
            greaterThanOrEqualToConstant: SidebarLayout.minimumWidth
        ).isActive = true
        root.widthAnchor.constraint(
            lessThanOrEqualToConstant: SidebarLayout.maximumWidth
        ).isActive = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search cards"
        searchField.delegate = self

        sidebarTagFilterBar.translatesAutoresizingMaskIntoConstraints = false
        sidebarTagFilterBar.onSelectionChange = { [weak self] tag in
            guard let self else { return }
            let nextTagID = activeTagID == tag?.id ? nil : tag?.id
            setActiveTag(nextTagID)
        }
        sidebarTagFilterBar.onPinChange = { [weak self] tag, pinned in
            self?.setTagPinned(pinned, tagID: tag.id)
        }
        sidebarTagFilterBar.onManageTags = { [weak self] in
            self?.showTagManagement()
        }

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

        if presentationMode == .standalone {
            root.addSubview(titleLabel)
            root.addSubview(searchField)
        }
        root.addSubview(sidebarTagFilterBar)
        root.addSubview(scrollView)
        var constraints = [
            sidebarTagFilterBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            sidebarTagFilterBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            sidebarTagFilterBar.heightAnchor.constraint(
                equalToConstant: CardLibraryTagFilterMetrics.height
            ),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: sidebarTagFilterBar.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ]
        if presentationMode == .standalone {
            constraints.append(contentsOf: [
                titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
                titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 70),
                searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
                searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
                searchField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),
                sidebarTagFilterBar.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            ])
        } else {
            constraints.append(
                sidebarTagFilterBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12)
            )
        }
        NSLayoutConstraint.activate(constraints)
        return root
    }

    private func makeDocumentView() -> NSView {
        let root = NSView()
        root.wantsLayer = true
        let header = NSView()
        documentHeaderView = header
        header.translatesAutoresizingMaskIntoConstraints = false
        documentTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        documentTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        documentTitleLabel.lineBreakMode = .byTruncatingTail

        documentTagStrip.translatesAutoresizingMaskIntoConstraints = false
        documentTagStrip.isHidden = true
        documentTagStrip.onSelectionChange = { [weak self] tag in
            guard let self else { return }
            setActiveTag(tag?.id)
        }
        documentTagStrip.onRemoveTag = { [weak self] tag in
            guard let self, let selectedCardID else { return }
            onRemoveTag?(selectedCardID, tag.id)
        }

        seriesNavigation.translatesAutoresizingMaskIntoConstraints = false
        seriesNavigation.isHidden = true
        seriesNavigation.onNavigate = { [weak self] direction in
            self?.navigateSeries(direction)
        }

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
        header.addSubview(documentTagStrip)
        header.addSubview(seriesNavigation)
        header.addSubview(openButton)
        header.addSubview(copyButton)
        header.addSubview(exportButton)
        header.addSubview(deleteButton)

        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.onRequestHide = { [weak self] in
            self?.onRequestBack?()
        }
        previewView.onMarkdownChange = { [weak self] cardID, markdown, incomingRevision in
            guard let self, selectedCardID == cardID else { return }
            selectedRendererRevision = max(selectedRendererRevision, incomingRevision)
            if let index = cards.firstIndex(where: { $0.id == cardID }) {
                cards[index].updateMarkdown(markdown)
                documentTitleLabel.stringValue = cards[index].title
                updateInformation(for: cards[index])
            }
            onMarkdownChange?(cardID, markdown, incomingRevision, editorSourceID)
        }
        previewView.onTagCommandSubmitted = {
            [weak self] cardID, tagName, markdown, incomingRevision in
            guard let self, selectedCardID == cardID else { return }
            selectedRendererRevision = max(selectedRendererRevision, incomingRevision)
            onTagCommandSubmitted?(
                cardID,
                tagName,
                markdown,
                incomingRevision,
                editorSourceID
            )
        }
        previewView.onManagedAttachmentsChange = { [weak self] cardID, identifiers in
            guard let self, selectedCardID == cardID else { return }
            managedAttachmentCardID = cardID
            setManagedAttachmentsPresent(!identifiers.isEmpty, animated: true)
        }
        previewView.onRequestSaveAs = { [weak self] in
            guard let self, let selectedCardID else { return }
            onRequestSaveAs?(selectedCardID)
        }

        configureEmptyView()
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(previewView)
        if presentationMode == .embedded {
            configureInformationView()
            root.addSubview(informationView)
        }
        root.addSubview(emptyView)
        documentHeaderHeightConstraint = header.heightAnchor.constraint(
            equalToConstant: CardHeaderView.titleRowHeight
        )
        documentHeaderHeightConstraint?.isActive = true
        let tagLeading = documentTagStrip.leadingAnchor.constraint(
            equalTo: header.leadingAnchor,
            constant: CardContentLayoutMetrics.leadingInset(for: header.bounds.width)
        )
        documentTagLeadingConstraint = tagLeading
        var constraints = [
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            documentTitleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            documentTitleLabel.centerYAnchor.constraint(
                equalTo: header.topAnchor,
                constant: CardHeaderView.titleRowHeight / 2
            ),
            documentTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: seriesNavigation.leadingAnchor, constant: -12),
            tagLeading,
            documentTagStrip.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            documentTagStrip.topAnchor.constraint(
                equalTo: header.topAnchor,
                constant: CardHeaderView.tagRailTop
            ),
            documentTagStrip.heightAnchor.constraint(
                equalToConstant: CardHeaderView.tagRailHeight
            ),
            deleteButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            deleteButton.centerYAnchor.constraint(
                equalTo: header.topAnchor,
                constant: CardHeaderView.titleRowHeight / 2
            ),
            exportButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -4),
            exportButton.centerYAnchor.constraint(
                equalTo: header.topAnchor,
                constant: CardHeaderView.titleRowHeight / 2
            ),
            copyButton.trailingAnchor.constraint(equalTo: exportButton.leadingAnchor, constant: -4),
            copyButton.centerYAnchor.constraint(
                equalTo: header.topAnchor,
                constant: CardHeaderView.titleRowHeight / 2
            ),
            openButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -12),
            openButton.centerYAnchor.constraint(
                equalTo: header.topAnchor,
                constant: CardHeaderView.titleRowHeight / 2
            ),
            seriesNavigation.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -8),
            seriesNavigation.centerYAnchor.constraint(
                equalTo: header.topAnchor,
                constant: CardHeaderView.titleRowHeight / 2
            ),
            seriesNavigation.widthAnchor.constraint(equalToConstant: seriesNavigation.intrinsicContentSize.width),
            seriesNavigation.heightAnchor.constraint(equalToConstant: seriesNavigation.intrinsicContentSize.height),
            previewView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: header.bottomAnchor),
            emptyView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: header.bottomAnchor),
            emptyView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ]
        if presentationMode == .embedded {
            constraints.append(contentsOf: [
                previewView.bottomAnchor.constraint(equalTo: informationView.topAnchor),
                informationView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                informationView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                informationView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                informationView.heightAnchor.constraint(equalToConstant: 170),
            ])
        } else {
            constraints.append(previewView.bottomAnchor.constraint(equalTo: root.bottomAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        return root
    }

    private func configureInformationView() {
        informationView.translatesAutoresizingMaskIntoConstraints = false
        informationView.wantsLayer = true
        informationHeading.translatesAutoresizingMaskIntoConstraints = false
        informationHeading.font = .systemFont(ofSize: 12.5, weight: .semibold)
        informationHeading.setAccessibilityRole(.staticText)

        let values = [
            informationTitleValue,
            informationCharactersValue,
            informationWordsValue,
            informationCreatedValue,
            informationModifiedValue,
            informationTagsValue,
        ]
        values.forEach {
            $0.font = .systemFont(ofSize: 12.5, weight: .regular)
            $0.alignment = .right
            $0.lineBreakMode = .byTruncatingMiddle
        }
        informationTagsValue.maximumNumberOfLines = 1

        let names = ["Title", "Characters", "Words", "Created", "Modified", "Tags"]
        informationKeyLabels = names.map { name in
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 12.5, weight: .medium)
            return label
        }
        let grid = NSGridView(views: zip(informationKeyLabels, values).map { [$0.0, $0.1] })
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 5
        grid.columnSpacing = 28
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing

        let divider = NSBox()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .separator
        informationView.addSubview(divider)
        informationView.addSubview(informationHeading)
        informationView.addSubview(grid)
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: informationView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: informationView.trailingAnchor),
            divider.topAnchor.constraint(equalTo: informationView.topAnchor),
            informationHeading.leadingAnchor.constraint(equalTo: informationView.leadingAnchor, constant: 28),
            informationHeading.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),
            grid.leadingAnchor.constraint(equalTo: informationHeading.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: informationView.trailingAnchor, constant: -28),
            grid.topAnchor.constraint(equalTo: informationHeading.bottomAnchor, constant: 9),
        ])
        informationView.isHidden = true
    }

    private func updateInformation(for card: CardRecord?) {
        guard presentationMode == .embedded, let card else {
            informationView.isHidden = true
            return
        }
        informationView.isHidden = false
        informationTitleValue.stringValue = card.title
        informationCharactersValue.stringValue = String(card.markdown.count)
        informationWordsValue.stringValue = String(
            card.markdown.split(whereSeparator: { $0.isWhitespace }).count
        )
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        informationCreatedValue.stringValue = formatter.string(from: card.createdAt)
        informationModifiedValue.stringValue = formatter.string(from: card.updatedAt)
        informationTagsValue.stringValue = card.tags.isEmpty
            ? "—"
            : card.tags.map(\.name).joined(separator: ", ")
        informationView.setAccessibilityLabel("Card information")
        informationView.setAccessibilityValue(
            "\(card.title), \(informationCharactersValue.stringValue) characters, "
                + "\(informationWordsValue.stringValue) words"
        )
    }

    private func updateDocumentTagLeadingInset() {
        guard let documentHeaderView else { return }
        let inset = CardContentLayoutMetrics.leadingInset(for: documentHeaderView.bounds.width)
        guard documentTagLeadingConstraint?.constant != inset else { return }
        documentTagLeadingConstraint?.constant = inset
    }

    private func configureEmptyView() {
        emptyTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyTitleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        emptyNoteLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyNoteLabel.font = .systemFont(ofSize: 13)
        emptyActionButton.translatesAutoresizingMaskIntoConstraints = false
        emptyActionButton.target = self
        emptyView.addSubview(emptyTitleLabel)
        emptyView.addSubview(emptyNoteLabel)
        emptyView.addSubview(emptyActionButton)
        NSLayoutConstraint.activate([
            emptyTitleLabel.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
            emptyTitleLabel.centerYAnchor.constraint(
                equalTo: emptyView.centerYAnchor,
                constant: -30
            ),
            emptyNoteLabel.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
            emptyNoteLabel.topAnchor.constraint(
                equalTo: emptyTitleLabel.bottomAnchor,
                constant: 8
            ),
            emptyActionButton.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
            emptyActionButton.topAnchor.constraint(
                equalTo: emptyNoteLabel.bottomAnchor,
                constant: 20
            ),
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
        let matchingCards = cards.filter { card in
            let matchesTag = activeTagID.map { tagID in
                card.tags.contains(where: { $0.id == tagID })
            } ?? true
            let matchesSearch = query.isEmpty
                || card.title.localizedCaseInsensitiveContains(query)
                || card.markdown.localizedCaseInsensitiveContains(query)
            return matchesTag && matchesSearch
        }
        if let activeTagID {
            filteredCards = CardSeriesIndex(
                cards: matchingCards,
                preferredOrderByTagID: seriesOrderByTagID?() ?? [:]
            ).series(tagID: activeTagID)
        } else {
            filteredCards = Self.orderedByCreation(matchingCards)
        }
        if let selection, filteredCards.contains(where: { $0.id == selection }) {
            selectedCardID = selection
        } else if !query.isEmpty || activeTagID != nil {
            selectedCardID = filteredCards.first?.id
        }
        rebuildListRows()
    }

    private func rebuildListRows(now: Date = Date(), calendar: Calendar = .current) {
        guard presentationMode == .embedded else {
            listRows = filteredCards.map { .card($0.id) }
            return
        }
        var rows: [CardLibraryListRow] = []
        var previousSection: CardLibraryDateSection?
        for card in filteredCards {
            let section: CardLibraryDateSection
            if calendar.isDate(card.createdAt, inSameDayAs: now) {
                section = .today
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                      calendar.isDate(card.createdAt, inSameDayAs: yesterday) {
                section = .yesterday
            } else if calendar.component(.year, from: card.createdAt) == calendar.component(.year, from: now),
                      calendar.component(.month, from: card.createdAt) == calendar.component(.month, from: now) {
                section = .thisMonth
            } else {
                section = .earlier
            }
            if section != previousSection {
                rows.append(.section(section))
                previousSection = section
            }
            rows.append(.card(card.id))
        }
        listRows = rows
    }

    static func orderedByCreation(_ cards: [CardRecord]) -> [CardRecord] {
        cards.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Tags do not carry an independent timestamp. Their stable library order
    /// is therefore the first appearance in card creation order, preserving
    /// the per-card tag order for tags introduced on the same card.
    static func orderedTags(in cards: [CardRecord]) -> [CardTag] {
        var seen = Set<String>()
        var result: [CardTag] = []
        let oldestFirst = cards.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        for card in oldestFirst {
            for tag in card.tags where seen.insert(tag.id).inserted {
                result.append(tag)
            }
        }
        return result
    }

    private func selectCurrentCardInTable() {
        guard let selectedCardID,
              let row = listRows.firstIndex(where: { row in
                  if case let .card(cardID) = row { return cardID == selectedCardID }
                  return false
              })
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
            previewView.dismissTransientUI()
            let emptyState = Self.emptyState(
                totalCardCount: cards.count,
                filteredCardCount: filteredCards.count
            )
            documentTitleLabel.stringValue = emptyState == .noMatches
                ? "No Results"
                : "Card Library"
            openButton.isEnabled = false
            copyButton.isEnabled = false
            exportButton.isEnabled = false
            deleteButton.isEnabled = false
            managedAttachmentCardID = nil
            setManagedAttachmentsPresent(false, animated: false)
            documentTagStrip.update(tags: [], activeTagID: nil, animated: false)
            documentTagStrip.isHidden = true
            documentHeaderHeightConstraint?.constant = CardHeaderView.titleRowHeight
            seriesNavigation.isHidden = true
            previewView.isHidden = true
            updateInformation(for: nil)
            configureEmptyPresentation(emptyState)
            emptyView.isHidden = false
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
        updateInformation(for: card)
        updateDocumentTagsAndNavigation(
            for: card,
            animated: presentationWindow?.isVisible == true
        )
        guard renderEditor else { return }
        let revision = revisions[card.id, default: 0]
        selectedRendererRevision = revision
        let documentRootURL = documentRootURLForCard?(card.id)
        previewView.setDocumentRoot(documentRootURL, for: card.id)
        previewView.render(
            RenderPayload(
                cardID: card.id,
                markdown: card.markdown,
                title: card.title,
                resolvedAppearance: appearance,
                revision: revision,
                documentImagesAvailable: documentRootURL != nil
            )
        )
    }

    static func emptyState(
        totalCardCount: Int,
        filteredCardCount: Int
    ) -> CardLibraryEmptyState {
        if totalCardCount == 0 { return .noCards }
        if filteredCardCount == 0 { return .noMatches }
        return .noSelection
    }

    private func configureEmptyPresentation(_ state: CardLibraryEmptyState) {
        emptyTitleLabel.stringValue = state.title
        emptyNoteLabel.stringValue = state.note
        switch state {
        case .noCards:
            emptyActionButton.title = "New Card"
            emptyActionButton.action = #selector(createCard(_:))
            emptyActionButton.isHidden = false
        case .noMatches:
            emptyActionButton.title = "Clear Filters"
            emptyActionButton.action = #selector(clearFilters(_:))
            emptyActionButton.isHidden = false
        case .noSelection:
            emptyActionButton.action = nil
            emptyActionButton.isHidden = true
        }
    }

    private func updateDocumentTagsAndNavigation(for card: CardRecord, animated: Bool) {
        let activeForCard = activeTagID.flatMap { activeID in
            card.tags.contains(where: { $0.id == activeID }) ? activeID : nil
        }
        documentTagStrip.update(
            tags: card.tags,
            activeTagID: activeForCard,
            animated: animated
        )
        let hasTags = !card.tags.isEmpty
        documentTagStrip.isHidden = !hasTags
        documentHeaderHeightConstraint?.constant = hasTags
            ? CardHeaderView.expandedHeight
            : CardHeaderView.titleRowHeight

        guard let activeForCard,
              let neighbors = Self.seriesNeighbors(
                of: card.id,
                tagID: activeForCard,
                within: filteredCards,
                preferredOrderByTagID: seriesOrderByTagID?() ?? [:]
              )
        else {
            seriesNavigation.isHidden = true
            return
        }
        seriesNavigation.update(
            canNavigateNewer: neighbors.newerCardID != nil,
            canNavigateOlder: neighbors.olderCardID != nil
        )
        seriesNavigation.isHidden = false
    }

    private func setActiveTag(_ tagID: String?) {
        let tagID = tagID.flatMap { candidate in
            tagCatalog.entry(tagID: candidate) == nil ? nil : candidate
        }
        let isSameTag = activeTagID == tagID
        guard !isSameTag else {
            refreshTagControls(animated: false)
            return
        }
        let previousID = selectedCardID
        activeTagID = tagID
        if let tagID, !isGlobalTagMutationInFlight {
            do {
                tagPreferences = try tagPreferencesStore.recordRecent(
                    tagID: tagID,
                    validTagIDs: tagCatalog.validTagIDs
                )
            } catch {
                onTagPreferenceError?(error)
            }
        }
        refreshTagControls(animated: presentationWindow?.isVisible == true)
        filterCards(preserving: previousID)
        if previousID != selectedCardID {
            flushEditor(for: previousID)
        }
        tableView.reloadData()
        selectCurrentCardInTable()
        updateDocumentPresentation(renderEditor: previousID != selectedCardID)
        let notificationCardID = tagID == nil
            ? (tagContextCardID ?? selectedCardID)
            : selectedCardID
        if let notificationCardID {
            notifyTagSelectionChange(cardID: notificationCardID, tagID: tagID)
        }
    }

    private func notifyTagSelectionChange(cardID: UUID, tagID: String?) {
        tagContextCardID = tagID == nil ? nil : cardID
        onTagSelectionChange?(cardID, tagID)
    }

    private func refreshTagControls(animated: Bool) {
        let candidates = tagCatalog.orderedCandidates(
            activeTagID: activeTagID,
            preferences: tagPreferences
        )
        sidebarTagFilterBar.update(
            catalogEntries: tagCatalog.entries,
            activeTagID: activeTagID,
            candidateOrder: candidates,
            pinnedTagIDs: tagPreferences.pinnedTagIDs,
            animated: animated
        )
        tagManagementWindowController?.update(
            catalogEntries: tagCatalog.entries,
            pinnedTagIDs: tagPreferences.pinnedTagIDs,
            selectedTagID: nil
        )
    }

    private func setTagPinned(_ pinned: Bool, tagID: String) {
        guard !isGlobalTagMutationInFlight else {
            refreshTagControls(animated: false)
            return
        }
        do {
            tagPreferences = try tagPreferencesStore.setPinned(
                pinned,
                tagID: tagID,
                validTagIDs: tagCatalog.validTagIDs
            )
            refreshTagControls(animated: true)
        } catch {
            // Popover pin buttons update optimistically. Rebuilding from the
            // last durable preferences immediately restores the old state.
            refreshTagControls(animated: false)
            onTagPreferenceError?(error)
        }
    }

    private func showTagManagement() {
        guard let window = presentationWindow else { return }
        let controller = tagManagementWindowController ?? makeTagManagementController()
        tagManagementWindowController = controller
        controller.update(
            catalogEntries: tagCatalog.entries,
            pinnedTagIDs: tagPreferences.pinnedTagIDs,
            selectedTagID: activeTagID
        )
        controller.apply(resolvedAppearance: appearance)
        controller.beginSheet(for: window)
    }

    private func makeTagManagementController() -> TagManagementWindowController {
        let controller = TagManagementWindowController()
        controller.onPinChange = { [weak self] tag, pinned in
            self?.setTagPinned(pinned, tagID: tag.id)
        }
        controller.onRenameTag = { [weak self] tag, name in
            self?.onRenameTag?(tag.id, name)
        }
        controller.onMergeTag = { [weak self] source, target in
            self?.onMergeTag?(source.id, target.id)
        }
        controller.onDeleteTag = { [weak self] tag in
            self?.onDeleteTag?(tag.id)
        }
        controller.onDismiss = { [weak self, weak controller] in
            guard let self, tagManagementWindowController === controller else { return }
            tagManagementWindowController = nil
            DispatchQueue.main.async { [weak self] in
                self?.sidebarTagFilterBar.restoreMoreButtonFocus()
            }
        }
        return controller
    }

    private func navigateSeries(_ direction: SeriesNavigationDirection) {
        guard let selectedCardID, let activeTagID,
              let neighbors = Self.seriesNeighbors(
                of: selectedCardID,
                tagID: activeTagID,
                within: filteredCards,
                preferredOrderByTagID: seriesOrderByTagID?() ?? [:]
              )
        else { return }
        let targetID = direction == .newer
            ? neighbors.newerCardID
            : neighbors.olderCardID
        guard let targetID else { return }

        let sourceID = selectedCardID
        let sourceRevision = selectedRendererRevision
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let markdown = await previewView.currentMarkdown(),
               self.selectedCardID == sourceID {
                onMarkdownChange?(
                    sourceID,
                    markdown,
                    sourceRevision &+ 1,
                    editorSourceID
                )
            }
            guard self.activeTagID == activeTagID,
                  cards.contains(where: { $0.id == targetID })
            else { return }
            self.selectedCardID = targetID
            defaults.set(targetID.uuidString, forKey: DefaultsKey.selection)
            selectCurrentCardInTable()
            updateDocumentPresentation(renderEditor: true)
            notifyTagSelectionChange(cardID: targetID, tagID: activeTagID)
        }
    }

    static func seriesNeighbors(
        of cardID: UUID,
        tagID: String,
        within filteredCards: [CardRecord],
        preferredOrderByTagID: [String: [UUID]] = [:]
    ) -> CardSeriesNeighbors? {
        CardSeriesIndex(
            cards: filteredCards,
            preferredOrderByTagID: preferredOrderByTagID
        ).neighbors(of: cardID, tagID: tagID)
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

    private func restoreSidebarWidth() {
        let storedWidth = defaults.object(forKey: DefaultsKey.divider).map { _ in
            CGFloat(defaults.double(forKey: DefaultsKey.divider))
        }
        let targetWidth = storedWidth.flatMap { width in
            guard (SidebarLayout.minimumWidth ... SidebarLayout.maximumWidth).contains(width) else {
                return nil
            }
            return width
        } ?? SidebarLayout.defaultWidth
        isRestoringSidebarWidth = true
        splitView.superview?.layoutSubtreeIfNeeded()
        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(targetWidth, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()
        isRestoringSidebarWidth = false
        hasRestoredSidebarWidth = true
        defaults.set(targetWidth, forKey: DefaultsKey.divider)
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
        guard let window = presentationWindow,
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
        if presentationMode == .embedded, let window = presentationWindow {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.onDeleteCard?(selectedCardID)
            }
            return
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onDeleteCard?(selectedCardID)
    }

    @objc private func createCard(_ sender: Any?) { onCreateCard?() }

    @objc private func manageTagsFromMenu(_ sender: Any?) {
        showTagManagement()
    }

    @objc private func clearFilters(_ sender: Any?) {
        let previousID = selectedCardID
        let tagWasActive = activeTagID != nil
        let deactivationCardID = tagContextCardID ?? previousID
        searchField.stringValue = ""
        onExternalSearchQueryChange?("")
        activeTagID = nil
        refreshTagControls(animated: presentationWindow?.isVisible == true)
        filterCards(preserving: previousID)
        if selectedCardID == nil
            || !filteredCards.contains(where: { $0.id == selectedCardID }) {
            selectedCardID = filteredCards.first?.id
        }
        tableView.reloadData()
        selectCurrentCardInTable()
        updateDocumentPresentation(renderEditor: previousID != selectedCardID)
        if tagWasActive, let deactivationCardID {
            notifyTagSelectionChange(cardID: deactivationCardID, tagID: nil)
        }
        if presentationMode == .standalone {
            searchField.window?.makeFirstResponder(searchField)
        }
    }

    private func setManagedAttachmentsPresent(_ present: Bool, animated: Bool) {
        let shouldShow = exportButton.isEnabled
        let targetWidth: CGFloat = shouldShow ? 34 : 0
        let targetAlpha: CGFloat = shouldShow ? 1 : 0
        let presentationChanged = exportButton.isHidden == shouldShow
            || exportWidthConstraint?.constant != targetWidth
            || exportButton.alphaValue != targetAlpha
        let attachmentStateChanged = hasManagedAttachments != present
        hasManagedAttachments = present
        exportButton.toolTip = present
            ? "Export Markdown with Attachments"
            : "Export Markdown"
        guard attachmentStateChanged || presentationChanged else { return }
        if shouldShow { exportButton.isHidden = false }
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
        let changes = { [self] in
            exportWidthConstraint?.animator().constant = targetWidth
            exportButton.animator().alphaValue = targetAlpha
            exportButton.superview?.layoutSubtreeIfNeeded()
        }
        guard animated, duration > 0, presentationWindow?.isVisible == true else {
            exportWidthConstraint?.constant = targetWidth
            exportButton.alphaValue = targetAlpha
            exportButton.isHidden = !shouldShow
            exportButton.superview?.layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            changes()
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.exportButton.isHidden = !shouldShow
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
private final class LibraryDateSectionCell: NSTableCellView {
    init(title: String, appearance: ResolvedAppearance) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.textColor = MonochromePalette.secondaryText(for: appearance)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),
        ])
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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
