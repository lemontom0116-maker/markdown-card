import AppKit
import MarkdownCardCore

struct CardLibraryTagEntry: Equatable, Sendable {
    let tag: CardTag
    let cardCount: Int
    var isPinned: Bool

    init(tag: CardTag, cardCount: Int, isPinned: Bool = false) {
        self.tag = tag
        self.cardCount = max(0, cardCount)
        self.isPinned = isPinned
    }

    init(catalogEntry: TagCatalogEntry, pinnedTagIDs: Set<String>) {
        self.init(
            tag: catalogEntry.tag,
            cardCount: catalogEntry.cardCount,
            isPinned: pinnedTagIDs.contains(catalogEntry.id)
        )
    }
}

struct CardLibraryTagFilterLayout: Equatable, Sendable {
    let quickTagIDs: [String]
    let hiddenTagIDs: [String]
}

@MainActor
enum CardLibraryTagFilterMetrics {
    static let height: CGFloat = 28
    static let spacing: CGFloat = 6
    static let allButtonWidth: CGFloat = 36
    static let minimumMoreButtonWidth: CGFloat = 38

    static func moreButtonWidth(maximumCount: Int) -> CGFloat {
        let title = "+\(max(0, maximumCount))" as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        return max(
            minimumMoreButtonWidth,
            ceil(title.size(withAttributes: [.font: font]).width) + 16
        )
    }
}

@MainActor
final class CardLibraryTagFilterBar: NSView, AppearanceConsumer, NSPopoverDelegate {
    var onSelectionChange: ((CardTag?) -> Void)?
    var onPinChange: ((CardTag, Bool) -> Void)?
    var onManageTags: (() -> Void)?

    let allButton = CardLibraryTagFilterUtilityButton(title: "All")
    let moreButton = CardLibraryTagFilterUtilityButton(title: "+0")

    private(set) var currentLayout = CardLibraryTagFilterLayout(
        quickTagIDs: [],
        hiddenTagIDs: []
    )
    private(set) var quickTagButtons: [CurtainTagButton] = []
    private(set) var activeTagID: String?
    private(set) var morePopover: NSPopover?

    private var entries: [CardLibraryTagEntry] = []
    private var candidateOrder: [String] = []
    private var buttonsByID: [String: CurtainTagButton] = [:]
    private var resolvedAppearance: ResolvedAppearance = .dark
    private var shouldAnimateSelection = false
    private var managementActionsEnabled = true

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CardLibraryTagFilterMetrics.height)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        entries: [CardLibraryTagEntry],
        activeTagID: String?,
        candidateOrder: [String],
        animated: Bool
    ) {
        let uniqueEntries = Self.uniqueEntries(entries)
        self.entries = uniqueEntries
        self.candidateOrder = candidateOrder
        self.activeTagID = activeTagID.flatMap { candidate in
            uniqueEntries.contains(where: { $0.tag.id == candidate }) ? candidate : nil
        }
        shouldAnimateSelection = animated

        (morePopover?.contentViewController as? CardLibraryTagMoreViewController)?.update(
            entries: uniqueEntries,
            activeTagID: self.activeTagID
        )

        let incomingIDs = Set(uniqueEntries.map(\.tag.id))
        for (id, button) in buttonsByID where !incomingIDs.contains(id) {
            button.removeFromSuperview()
            buttonsByID[id] = nil
        }

        for entry in uniqueEntries {
            if let existing = buttonsByID[entry.tag.id], existing.cardTag.name == entry.tag.name {
                continue
            }
            buttonsByID[entry.tag.id]?.removeFromSuperview()
            let button = CurtainTagButton(tag: entry.tag)
            button.menu = nil
            button.onActivate = { [weak self] tag in self?.onSelectionChange?(tag) }
            button.onRemove = nil
            button.apply(resolvedAppearance: resolvedAppearance)
            buttonsByID[entry.tag.id] = button
            addSubview(button)
        }

        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func update(
        catalogEntries: [TagCatalogEntry],
        activeTagID: String?,
        candidateOrder: [TagCatalogEntry],
        pinnedTagIDs: Set<String>,
        animated: Bool
    ) {
        update(
            entries: catalogEntries.map {
                CardLibraryTagEntry(catalogEntry: $0, pinnedTagIDs: pinnedTagIDs)
            },
            activeTagID: activeTagID,
            candidateOrder: candidateOrder.map(\.id),
            animated: animated
        )
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        self.resolvedAppearance = resolvedAppearance
        allButton.apply(resolvedAppearance: resolvedAppearance)
        moreButton.apply(resolvedAppearance: resolvedAppearance)
        buttonsByID.values.forEach { $0.apply(resolvedAppearance: resolvedAppearance) }
        (morePopover?.contentViewController as? CardLibraryTagMoreViewController)?
            .apply(resolvedAppearance: resolvedAppearance)
    }

    func setManagementActionsEnabled(_ enabled: Bool) {
        managementActionsEnabled = enabled
        (morePopover?.contentViewController as? CardLibraryTagMoreViewController)?
            .setManagementActionsEnabled(enabled)
    }

    override func layout() {
        super.layout()
        let layout = Self.layout(
            entries: entries,
            activeTagID: activeTagID,
            candidateOrder: candidateOrder,
            availableWidth: bounds.width
        )
        currentLayout = layout

        let spacing = CardLibraryTagFilterMetrics.spacing
        let allWidth = min(CardLibraryTagFilterMetrics.allButtonWidth, max(0, bounds.width))
        let moreWidth = min(
            CardLibraryTagFilterMetrics.moreButtonWidth(maximumCount: entries.count),
            max(0, bounds.width - allWidth - spacing)
        )
        let buttonHeight = min(CardLibraryTagFilterMetrics.height, bounds.height)
        let y = floor((bounds.height - buttonHeight) / 2)
        allButton.frame = NSRect(x: 0, y: y, width: allWidth, height: buttonHeight)
        moreButton.frame = NSRect(
            x: max(allButton.frame.maxX + spacing, bounds.width - moreWidth),
            y: y,
            width: moreWidth,
            height: buttonHeight
        )

        let quickIDs = Set(layout.quickTagIDs)
        var x = allButton.frame.maxX + spacing
        let quickMaxX = max(x, moreButton.frame.minX - spacing)
        quickTagButtons = []
        for id in layout.quickTagIDs {
            guard let button = buttonsByID[id] else { continue }
            let desiredWidth = button.intrinsicContentSize.width
            let width = min(desiredWidth, max(0, quickMaxX - x))
            button.isHidden = width <= 0
            button.frame = NSRect(x: x, y: y, width: width, height: buttonHeight)
            button.setSelected(id == activeTagID, animated: shouldAnimateSelection)
            if !button.isHidden {
                quickTagButtons.append(button)
                x += width + spacing
            }
        }
        for (id, button) in buttonsByID where !quickIDs.contains(id) {
            button.isHidden = true
            button.setSelected(id == activeTagID, animated: false)
        }
        shouldAnimateSelection = false

        allButton.setSelected(activeTagID == nil)
        let hiddenCount = layout.hiddenTagIDs.count
        moreButton.title = "+\(hiddenCount)"
        moreButton.setAccessibilityLabel(
            hiddenCount == 1 ? "More tags, 1 hidden" : "More tags, \(hiddenCount) hidden"
        )
        moreButton.setAccessibilityHelp("Shows every tag and tag pin controls")
    }

    func makeMoreViewController() -> CardLibraryTagMoreViewController {
        let controller = CardLibraryTagMoreViewController(
            entries: entries,
            activeTagID: activeTagID,
            resolvedAppearance: resolvedAppearance
        )
        controller.setManagementActionsEnabled(managementActionsEnabled)
        controller.onSelectTag = { [weak self, weak controller] tag in
            self?.onSelectionChange?(tag)
            controller?.view.window?.performClose(nil)
            self?.morePopover?.performClose(nil)
        }
        controller.onPinChange = { [weak self] tag, pinned in
            guard let self else { return }
            if let index = entries.firstIndex(where: { $0.tag.id == tag.id }) {
                entries[index].isPinned = pinned
                needsLayout = true
            }
            onPinChange?(tag, pinned)
        }
        controller.onManageTags = { [weak self] in
            self?.morePopover?.performClose(nil)
            self?.onManageTags?()
        }
        return controller
    }

    func restoreMoreButtonFocus() {
        window?.makeFirstResponder(moreButton)
    }

    func popoverDidClose(_ notification: Notification) {
        morePopover = nil
        restoreMoreButtonFocus()
    }

    static func layout(
        entries: [CardLibraryTagEntry],
        activeTagID: String?,
        candidateOrder: [String],
        availableWidth: CGFloat
    ) -> CardLibraryTagFilterLayout {
        let entries = uniqueEntries(entries)
        let entryByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.tag.id, $0) })
        let orderedIDs = orderedCandidateIDs(
            entries: entries,
            activeTagID: activeTagID,
            candidateOrder: candidateOrder
        )
        let fixedWidth = CardLibraryTagFilterMetrics.allButtonWidth
            + CardLibraryTagFilterMetrics.moreButtonWidth(maximumCount: entries.count)
            + CardLibraryTagFilterMetrics.spacing * 2
        var remainingWidth = max(0, availableWidth - fixedWidth)
        var quickIDs: [String] = []

        for id in orderedIDs {
            guard let entry = entryByID[id] else { continue }
            let width = CurtainTagMetrics.width(for: entry.tag.name)
            let spacing = quickIDs.isEmpty ? 0 : CardLibraryTagFilterMetrics.spacing
            if width + spacing <= remainingWidth {
                quickIDs.append(id)
                remainingWidth -= width + spacing
                continue
            }
            if id == activeTagID, quickIDs.isEmpty, remainingWidth > 0 {
                // Keeping the active filter visible is more useful than
                // preserving the chip's ideal width at an unusually narrow size.
                quickIDs.append(id)
                remainingWidth = 0
            }
            // Quick access is a strict priority prefix. Once a pinned or
            // recent candidate cannot fit, lower-priority items must not jump
            // ahead merely because their labels are shorter.
            break
        }

        let quickSet = Set(quickIDs)
        return CardLibraryTagFilterLayout(
            quickTagIDs: quickIDs,
            hiddenTagIDs: entries.map(\.tag.id).filter { !quickSet.contains($0) }
        )
    }

    private func setup() {
        setAccessibilityRole(.group)
        setAccessibilityLabel("Tag filters")

        allButton.target = self
        allButton.action = #selector(showAll(_:))
        allButton.toolTip = "Show all cards"
        allButton.setAccessibilityLabel("All cards")
        allButton.setAccessibilityHelp("Clears the active tag filter")

        moreButton.target = self
        moreButton.action = #selector(showMore(_:))
        moreButton.toolTip = "More tags"

        addSubview(allButton)
        addSubview(moreButton)
        apply(resolvedAppearance: resolvedAppearance)
    }

    @objc private func showAll(_ sender: Any?) {
        onSelectionChange?(nil)
    }

    @objc private func showMore(_ sender: Any?) {
        if morePopover?.isShown == true {
            morePopover?.performClose(sender)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentSize = NSSize(width: 326, height: 396)
        popover.contentViewController = makeMoreViewController()
        popover.delegate = self
        morePopover = popover
        popover.show(relativeTo: moreButton.bounds, of: moreButton, preferredEdge: .maxY)
    }

    private static func uniqueEntries(_ entries: [CardLibraryTagEntry]) -> [CardLibraryTagEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.tag.id).inserted }
    }

    private static func orderedCandidateIDs(
        entries: [CardLibraryTagEntry],
        activeTagID: String?,
        candidateOrder: [String]
    ) -> [String] {
        let validIDs = Set(entries.map(\.tag.id))
        let pinnedIDs = Set(entries.filter(\.isPinned).map(\.tag.id))
        var seen = Set<String>()
        var result: [String] = []
        func append(_ id: String?) {
            guard let id, validIDs.contains(id), seen.insert(id).inserted else { return }
            result.append(id)
        }

        append(activeTagID)
        candidateOrder.filter { pinnedIDs.contains($0) }.forEach { append($0) }
        entries.filter(\.isPinned).forEach { append($0.tag.id) }
        candidateOrder.forEach { append($0) }
        entries.forEach { append($0.tag.id) }
        return result
    }
}

@MainActor
final class CardLibraryTagFilterUtilityButton: NSButton, AppearanceConsumer {
    private var resolvedAppearance: ResolvedAppearance = .dark
    private(set) var isFilterSelected = false

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        focusRingType = .exterior
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelected(_ selected: Bool) {
        isFilterSelected = selected
        setAccessibilityValue(selected ? "Selected" : "Not selected")
        updateColors()
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        self.resolvedAppearance = resolvedAppearance
        updateColors()
    }

    private func updateColors() {
        contentTintColor = isFilterSelected
            ? MonochromePalette.primaryText(for: resolvedAppearance)
            : MonochromePalette.secondaryText(for: resolvedAppearance)
        layer?.backgroundColor = (isFilterSelected
            ? MonochromePalette.selection(for: resolvedAppearance).withAlphaComponent(0.32)
            : NSColor.clear).cgColor
    }
}

@MainActor
final class CardLibraryTagMoreViewController: NSViewController, NSSearchFieldDelegate,
    AppearanceConsumer
{
    var onSelectTag: ((CardTag) -> Void)?
    var onPinChange: ((CardTag, Bool) -> Void)?
    var onManageTags: (() -> Void)?

    let searchField = NSSearchField()
    let scrollView = NSScrollView()
    let manageButton = NSButton(title: "Manage Tags…", target: nil, action: nil)
    let emptyLabel = NSTextField(labelWithString: "No matching tags")
    private let documentView = CardLibraryTagRowsDocumentView()

    private(set) var entries: [CardLibraryTagEntry]
    private(set) var visibleEntries: [CardLibraryTagEntry] = []
    private(set) var rowViews: [CardLibraryTagPopoverRowView] = []
    private var activeTagID: String?
    private var resolvedAppearance: ResolvedAppearance
    private var managementActionsEnabled = true

    init(
        entries: [CardLibraryTagEntry],
        activeTagID: String?,
        resolvedAppearance: ResolvedAppearance
    ) {
        self.entries = entries
        self.activeTagID = activeTagID
        self.resolvedAppearance = resolvedAppearance
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 326, height: 396))
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("All tags")

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search tags"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Search tags")

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView

        manageButton.translatesAutoresizingMaskIntoConstraints = false
        manageButton.isBordered = false
        manageButton.font = .systemFont(ofSize: 12, weight: .medium)
        manageButton.target = self
        manageButton.action = #selector(manageTags(_:))
        manageButton.setAccessibilityLabel("Manage tags")
        manageButton.setAccessibilityHelp("Opens tag rename, merge, and delete controls")

        root.addSubview(searchField)
        root.addSubview(scrollView)
        root.addSubview(manageButton)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            manageButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            manageButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            manageButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            manageButton.heightAnchor.constraint(equalToConstant: 28),
            scrollView.bottomAnchor.constraint(equalTo: manageButton.topAnchor, constant: -6),
        ])
        view = root
        rebuildRows()
        apply(resolvedAppearance: resolvedAppearance)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(searchField)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        documentView.frame.size.width = scrollView.contentSize.width
        layoutRows()
    }

    func controlTextDidChange(_ obj: Notification) {
        rebuildRows()
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            return focusInitialRow()
        case #selector(NSResponder.insertNewline(_:)):
            guard let first = visibleEntries.first else { return false }
            onSelectTag?(first.tag)
            return true
        default:
            return false
        }
    }

    func update(entries: [CardLibraryTagEntry], activeTagID: String?) {
        self.entries = entries
        self.activeTagID = activeTagID.flatMap { candidate in
            entries.contains(where: { $0.tag.id == candidate }) ? candidate : nil
        }
        if isViewLoaded {
            rebuildRows()
        }
    }

    func setManagementActionsEnabled(_ enabled: Bool) {
        managementActionsEnabled = enabled
        if isViewLoaded {
            manageButton.isEnabled = enabled
            rowViews.forEach { $0.pinButton.isEnabled = enabled }
        }
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        self.resolvedAppearance = resolvedAppearance
        emptyLabel.textColor = MonochromePalette.tertiaryText(for: resolvedAppearance)
        manageButton.contentTintColor = MonochromePalette.secondaryText(for: resolvedAppearance)
        rowViews.forEach { $0.apply(resolvedAppearance: resolvedAppearance) }
    }

    private func rebuildRows() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        visibleEntries = entries.filter { entry in
            TagCatalogSearch.matches(tagName: entry.tag.name, query: query)
        }
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = visibleEntries.map { entry in
            let row = CardLibraryTagPopoverRowView(
                entry: entry,
                selected: entry.tag.id == activeTagID
            )
            row.onSelect = { [weak self] tag in self?.onSelectTag?(tag) }
            row.onMoveFocus = { [weak self, weak row] offset in
                guard let self, let row,
                      let index = rowViews.firstIndex(where: { $0 === row })
                else { return }
                moveFocus(from: index, offset: offset)
            }
            row.onPinChange = { [weak self] tag, pinned in
                guard let self else { return }
                if let index = entries.firstIndex(where: { $0.tag.id == tag.id }) {
                    entries[index].isPinned = pinned
                }
                onPinChange?(tag, pinned)
            }
            row.apply(resolvedAppearance: resolvedAppearance)
            row.pinButton.isEnabled = managementActionsEnabled
            documentView.addSubview(row)
            return row
        }

        emptyLabel.removeFromSuperview()
        if rowViews.isEmpty {
            emptyLabel.alignment = .center
            emptyLabel.setAccessibilityLabel("No matching tags")
            documentView.addSubview(emptyLabel)
        }
        manageButton.isEnabled = managementActionsEnabled
        wireKeyViewLoop()
        layoutRows()
    }

    private func focusInitialRow() -> Bool {
        guard !rowViews.isEmpty else { return false }
        let selectedIndex = visibleEntries.firstIndex { $0.tag.id == activeTagID } ?? 0
        return focusRow(at: selectedIndex)
    }

    private func moveFocus(from index: Int, offset: Int) {
        let target = index + offset
        if target < rowViews.startIndex {
            view.window?.makeFirstResponder(searchField)
        } else if rowViews.indices.contains(target) {
            _ = focusRow(at: target)
        } else {
            view.window?.makeFirstResponder(manageButton)
        }
    }

    @discardableResult
    private func focusRow(at index: Int) -> Bool {
        guard rowViews.indices.contains(index), let window = view.window else { return false }
        let row = rowViews[index]
        row.scrollToVisible(row.bounds)
        return window.makeFirstResponder(row.selectButton)
    }

    private func wireKeyViewLoop() {
        var previous: NSView = searchField
        for row in rowViews {
            previous.nextKeyView = row.selectButton
            row.selectButton.nextKeyView = row.pinButton
            previous = row.pinButton
        }
        previous.nextKeyView = manageButton
        manageButton.nextKeyView = searchField
    }

    private func layoutRows() {
        let width = max(0, scrollView.contentSize.width)
        let rowHeight: CGFloat = 38
        if rowViews.isEmpty {
            documentView.frame.size = NSSize(width: width, height: 72)
            emptyLabel.frame = NSRect(x: 8, y: 22, width: max(0, width - 16), height: 24)
            return
        }
        for (index, row) in rowViews.enumerated() {
            row.frame = NSRect(
                x: 0,
                y: CGFloat(index) * rowHeight,
                width: width,
                height: rowHeight
            )
        }
        documentView.frame.size = NSSize(
            width: width,
            height: CGFloat(rowViews.count) * rowHeight
        )
    }

    @objc private func manageTags(_ sender: Any?) {
        onManageTags?()
    }
}

@MainActor
final class CardLibraryTagPopoverRowView: NSView, AppearanceConsumer {
    let entry: CardLibraryTagEntry
    let selectButton = CardLibraryTagRowSelectButton(title: "", target: nil, action: nil)
    let countLabel = CardLibraryTagPassthroughLabel(labelWithString: "")
    let pinButton = NSButton()
    let swatch = CardLibraryTagPassthroughView()
    let nameLabel = CardLibraryTagPassthroughLabel(labelWithString: "")

    var onSelect: ((CardTag) -> Void)?
    var onPinChange: ((CardTag, Bool) -> Void)?
    var onMoveFocus: ((Int) -> Void)?
    private var isPinned: Bool
    private var selected: Bool
    private var resolvedAppearance: ResolvedAppearance = .dark

    init(entry: CardLibraryTagEntry, selected: Bool) {
        self.entry = entry
        isPinned = entry.isPinned
        self.selected = selected
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        self.resolvedAppearance = resolvedAppearance
        let accent = CurtainTagPalette.accent(
            for: entry.tag,
            selected: selected,
            appearance: resolvedAppearance
        )
        swatch.layer?.backgroundColor = accent.cgColor
        nameLabel.textColor = selected
            ? MonochromePalette.primaryText(for: resolvedAppearance)
            : MonochromePalette.secondaryText(for: resolvedAppearance)
        countLabel.textColor = MonochromePalette.tertiaryText(for: resolvedAppearance)
        pinButton.contentTintColor = isPinned
            ? accent
            : MonochromePalette.tertiaryText(for: resolvedAppearance)
    }

    private func setup() {
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(entry.tag.name), \(entry.cardCount) cards")

        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 4
        swatch.setAccessibilityElement(false)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.stringValue = entry.tag.name
        nameLabel.font = .systemFont(ofSize: 12, weight: selected ? .semibold : .regular)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setAccessibilityElement(false)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.stringValue = "\(entry.cardCount)"
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.alignment = .right
        countLabel.setAccessibilityLabel(
            entry.cardCount == 1 ? "1 card" : "\(entry.cardCount) cards"
        )

        selectButton.translatesAutoresizingMaskIntoConstraints = false
        selectButton.title = ""
        selectButton.isBordered = false
        selectButton.focusRingType = .exterior
        selectButton.target = self
        selectButton.action = #selector(selectTag(_:))
        selectButton.onMoveFocus = { [weak self] offset in
            self?.onMoveFocus?(offset)
        }
        selectButton.setAccessibilityLabel(
            "Filter by \(entry.tag.name), \(entry.cardCount) cards"
        )
        selectButton.setAccessibilityValue(selected ? "Selected" : "Not selected")

        pinButton.translatesAutoresizingMaskIntoConstraints = false
        pinButton.isBordered = false
        pinButton.imagePosition = .imageOnly
        pinButton.focusRingType = .exterior
        pinButton.target = self
        pinButton.action = #selector(togglePin(_:))
        pinButton.toolTip = isPinned ? "Unpin \(entry.tag.name)" : "Pin \(entry.tag.name)"
        updatePinPresentation()

        addSubview(selectButton)
        addSubview(swatch)
        addSubview(nameLabel)
        addSubview(countLabel)
        addSubview(pinButton)
        NSLayoutConstraint.activate([
            selectButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            selectButton.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -2),
            selectButton.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            selectButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            swatch.leadingAnchor.constraint(equalTo: selectButton.leadingAnchor, constant: 8),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 8),
            swatch.heightAnchor.constraint(equalToConstant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
            countLabel.trailingAnchor.constraint(equalTo: selectButton.trailingAnchor, constant: -8),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
            pinButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            pinButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 30),
            pinButton.heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    private func updatePinPresentation() {
        pinButton.image = NSImage(
            systemSymbolName: isPinned ? "pin.fill" : "pin",
            accessibilityDescription: nil
        )
        pinButton.setAccessibilityLabel(
            isPinned ? "Unpin \(entry.tag.name)" : "Pin \(entry.tag.name)"
        )
        pinButton.setAccessibilityValue(isPinned ? "Pinned" : "Not pinned")
    }

    @objc private func selectTag(_ sender: Any?) {
        onSelect?(entry.tag)
    }

    @objc private func togglePin(_ sender: Any?) {
        isPinned.toggle()
        updatePinPresentation()
        apply(resolvedAppearance: resolvedAppearance)
        onPinChange?(entry.tag, isPinned)
    }
}

@MainActor
final class CardLibraryTagRowSelectButton: NSButton {
    var onMoveFocus: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125:
            onMoveFocus?(1)
        case 126:
            onMoveFocus?(-1)
        default:
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class CardLibraryTagPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class CardLibraryTagPassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class CardLibraryTagRowsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
