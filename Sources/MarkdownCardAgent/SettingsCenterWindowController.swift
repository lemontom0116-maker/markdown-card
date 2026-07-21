import AppKit
import KeyboardShortcuts
import MarkdownCardCore
import ServiceManagement

enum FoldPreferences {
    static let defaultsKey = "foldCardsWhenMacLocks"

    static func foldCardsWhenMacLocks(in defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: defaultsKey) != nil else { return true }
        return defaults.bool(forKey: defaultsKey)
    }
}

enum SettingsSection: Int, CaseIterable, Equatable {
    case general
    case shortcuts
    case placement
    case cli

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .placement: "Card Placement"
        case .cli: "CLI"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "command"
        case .placement: "square.grid.3x3"
        case .cli: "apple.terminal"
        }
    }

    var searchKeywords: [String] {
        switch self {
        case .general:
            ["general", "appearance", "theme", "system", "light", "dark", "launch", "login", "fold", "lock", "sleep"]
        case .shortcuts:
            ["shortcuts", "keyboard", "keybinding", "hotkey", "command center", "new card", "library", "settings"]
        case .placement:
            ["card placement", "placement", "position", "layout", "mini", "sticky", "middle", "anchor", "defaults"]
        case .cli:
            ["cli", "terminal", "command line", "mdcard", "install", "replace"]
        }
    }
}

@MainActor
final class SettingsCenterWindowController: NSWindowController, NSTableViewDataSource,
    NSTableViewDelegate, NSWindowDelegate, AppearanceConsumer
{
    enum PresentationMode {
        case standalone
        case embedded
    }

    var onAppearanceChange: ((AppearanceMode) -> Void)?
    var onLaunchAtLoginChange: ((Bool) -> Void)?
    var onFoldCardsWhenMacLocksChange: ((Bool) -> Void)?
    var onInstallCLI: (() -> Void)?
    var onShortcutChange: (() -> Void)?
    var onClose: (() -> Void)?

    private let appearanceController: AppearanceController
    private let placementPreferences: CardPlacementPreferences
    private let defaults: UserDefaults
    private let presentationMode: PresentationMode
    private let rootView = NSView()
    private let sidebar = NSTableView()
    private let sidebarScroll = NSScrollView()
    private let contentHost = NSView()
    private let appearanceControl = NSSegmentedControl(
        labels: ["System", "Light", "Dark"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let loginSwitch = NSSwitch()
    private let foldOnLockSwitch = NSSwitch()
    private let foldOnLockExplanationLabel = NSTextField(
        wrappingLabelWithString: "Automatically folds cards when your Mac locks, the display sleeps, "
            + "or the system sleeps. Cards stay folded after wake until you restore them."
    )
    private let cliStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let agentNoteLabel = NSTextField(
        wrappingLabelWithString: "Markdown Card runs quietly in the background until you open it."
    )
    private let shortcutFeedbackLabel = NSTextField(wrappingLabelWithString: "")
    private let cliButton = NSButton(title: "Install", target: nil, action: nil)
    private let commandCenterRecorder = ShortcutRecorderButton(name: .commandCenter)
    private let newCardRecorder = ShortcutRecorderButton(name: .newCard)
    private let toggleFoldedCardsRecorder = ShortcutRecorderButton(name: .toggleFoldedCards)
    private let moveActiveCardRecorder = ShortcutRecorderButton(name: .moveActiveCard)
    private let libraryRecorder = ShortcutRecorderButton(name: .cardLibrary)
    private let settingsRecorder = ShortcutRecorderButton(name: .settings)
    private var shortcutRecorders: [ShortcutRecorderButton] {
        [
            commandCenterRecorder,
            newCardRecorder,
            toggleFoldedCardsRecorder,
            moveActiveCardRecorder,
            libraryRecorder,
            settingsRecorder,
        ]
    }
    private var placementButtons: [(
        mode: CardLayoutMode,
        anchor: CardPlacementAnchor,
        button: NSButton
    )] = []
    private var sectionViews: [SettingsSection: NSView] = [:]
    private var primaryLabels: [NSTextField] = []
    private var secondaryLabels: [NSTextField] = []
    private var appearance: ResolvedAppearance = .dark
    private var selectedSection: SettingsSection = .general
    private var hostingWindowProvider: (() -> NSWindow?)?

    private var contentTopInset: CGFloat {
        presentationMode == .embedded ? 34 : 72
    }

    static let foldCardsWhenMacLocksDefaultsKey = FoldPreferences.defaultsKey

    init(
        appearanceController: AppearanceController,
        placementPreferences: CardPlacementPreferences,
        defaults: UserDefaults = .standard,
        presentationMode: PresentationMode = .standalone
    ) {
        self.appearanceController = appearanceController
        self.placementPreferences = placementPreferences
        self.defaults = defaults
        self.presentationMode = presentationMode
        let window: NSWindow? = if presentationMode == .standalone {
            NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
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
        shortcutFeedbackLabel.font = .systemFont(ofSize: 12, weight: .regular)
        shortcutFeedbackLabel.maximumNumberOfLines = 3
        shortcutFeedbackLabel.identifier = .init("settings.shortcutFeedback")
        shortcutFeedbackLabel.setAccessibilityLabel("Shortcut status")
        secondaryLabels.append(shortcutFeedbackLabel)
        updateShortcutFeedback(nil)
        let changed: () -> Void = { [weak self] in
            self?.updateShortcutFeedback(nil)
            self?.onShortcutChange?()
        }
        shortcutRecorders.forEach { recorder in
            recorder.onChange = changed
            recorder.onValidationMessage = { [weak self] message in
                self?.updateShortcutFeedback(message)
            }
        }
        appearanceController.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showSettings() {
        if presentationMode == .embedded {
            activate(section: selectedSection)
            return
        }
        guard let window else { return }
        if sidebar.selectedRow < 0 {
            sidebar.selectRowIndexes(
                IndexSet(integer: SettingsSection.general.rawValue),
                byExtendingSelection: false
            )
        }
        syncControls()
        refreshCLIStatus()
        appearanceController.applyMode(to: window)
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func refreshCLIStatus() {
        let destination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/mdcard")
        let installed = FileManager.default.isExecutableFile(atPath: destination.path)
        cliStatusLabel.stringValue = installed
            ? "The command-line helper is installed and ready."
            : "Install the command-line helper for terminal workflows."
        cliButton.title = installed ? "Replace" : "Install"
    }

    func showShortcutsForTesting() {
        activate(section: .shortcuts)
    }

    func showPlacementForTesting() {
        activate(section: .placement)
    }

    var rootViewForEmbedding: NSView { rootView }

    var activeSection: SettingsSection { selectedSection }

    func prepareForEmbedding(hostingWindowProvider: @escaping () -> NSWindow?) -> NSView {
        self.hostingWindowProvider = hostingWindowProvider
        rootView.removeFromSuperview()
        return rootView
    }

    func activate(section: SettingsSection? = nil) {
        let target = section ?? selectedSection
        selectedSection = target
        sidebar.selectRowIndexes(
            IndexSet(integer: target.rawValue),
            byExtendingSelection: false
        )
        sidebar.reloadData()
        syncControls()
        refreshCLIStatus()
        show(target)
    }

    func setExternalSearchQuery(_ query: String) {
        guard let match = matchedSection(for: query) else { return }
        activate(section: match)
    }

    func focusSearchResult(for query: String) {
        guard let match = matchedSection(for: query) else { return }
        activate(section: match)
        guard let host = presentationWindow else { return }
        switch match {
        case .general:
            host.makeFirstResponder(appearanceControl)
        case .shortcuts:
            host.makeFirstResponder(commandCenterRecorder)
        case .placement:
            if let selected = placementButtons.first(where: { $0.button.state == .on })?.button
                ?? placementButtons.first?.button {
                host.makeFirstResponder(selected)
            }
        case .cli:
            host.makeFirstResponder(cliButton)
        }
    }

    private func matchedSection(for query: String) -> SettingsSection? {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !normalized.isEmpty else { return nil }
        return SettingsSection.allCases.first { section in
            ([section.title] + section.searchKeywords).contains { value in
                value.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ).contains(normalized)
            }
        }
    }

    func routeDidDeactivate() {
        cancelShortcutRecording()
    }

    func cancelTransientUI() {
        cancelShortcutRecording()
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        appearance = resolvedAppearance
        if let window = presentationWindow {
            appearanceController.applyMode(to: window)
        }
        let background = MonochromePalette.windowBackground(for: appearance)
        if presentationMode == .standalone {
            presentationWindow?.backgroundColor = background
        }
        rootView.layer?.backgroundColor = background.cgColor
        contentHost.layer?.backgroundColor = background.cgColor
        sidebar.backgroundColor = .clear
        sidebarScroll.backgroundColor = .clear
        primaryLabels.forEach { $0.textColor = MonochromePalette.primaryText(for: appearance) }
        secondaryLabels.forEach { $0.textColor = MonochromePalette.secondaryText(for: appearance) }
        shortcutRecorders.forEach {
            $0.apply(resolvedAppearance: appearance)
        }
        syncPlacementControls()
        sidebar.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { SettingsSection.allCases.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 44 }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let section = SettingsSection(rawValue: row) else { return nil }
        let cell = NSTableCellView()
        cell.wantsLayer = true
        cell.layer?.cornerRadius = 8
        cell.layer?.cornerCurve = .continuous
        cell.layer?.backgroundColor = section == selectedSection
            ? MonochromePalette.selection(for: appearance).withAlphaComponent(0.38).cgColor
            : NSColor.clear.cgColor

        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        image.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        image.contentTintColor = MonochromePalette.secondaryText(for: appearance)
        let label = NSTextField(labelWithString: section.title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = MonochromePalette.primaryText(for: appearance)
        cell.addSubview(image)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let section = SettingsSection(rawValue: sidebar.selectedRow) else { return }
        selectedSection = section
        sidebar.reloadData()
        show(section)
    }

    func windowWillClose(_ notification: Notification) {
        cancelShortcutRecording()
        onClose?()
    }

    func windowDidResignKey(_ notification: Notification) {
        cancelShortcutRecording()
    }

    private func cancelShortcutRecording() {
        shortcutRecorders.forEach {
            $0.cancelRecording()
        }
    }

    private func configureWindow(_ window: NSWindow) {
        window.delegate = self
        window.title = "Markdown Card Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Card windows intentionally live at the floating level. Keep operation
        // windows at the same level so a user-requested Settings window can be
        // ordered in front, but hide it when Markdown Card is not active so it
        // never floats above an unrelated app.
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.hidesOnDeactivate = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 520)

        window.contentView = rootView
    }

    private var presentationWindow: NSWindow? {
        hostingWindowProvider?() ?? window
    }

    private func configureContent() {
        rootView.wantsLayer = true

        let sidebarBackground = NSVisualEffectView()
        sidebarBackground.translatesAutoresizingMaskIntoConstraints = false
        sidebarBackground.material = .sidebar
        sidebarBackground.blendingMode = .behindWindow

        let column = NSTableColumn(identifier: .init("SettingsSidebar"))
        sidebar.addTableColumn(column)
        sidebar.headerView = nil
        sidebar.rowHeight = 44
        sidebar.intercellSpacing = NSSize(width: 0, height: 4)
        sidebar.selectionHighlightStyle = .none
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.backgroundColor = .clear

        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.documentView = sidebar
        sidebarScroll.drawsBackground = false
        sidebarScroll.borderType = .noBorder
        sidebarScroll.hasVerticalScroller = false
        sidebarBackground.addSubview(sidebarScroll)

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.wantsLayer = true
        rootView.addSubview(sidebarBackground)
        rootView.addSubview(contentHost)
        NSLayoutConstraint.activate([
            sidebarBackground.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            sidebarBackground.topAnchor.constraint(equalTo: rootView.topAnchor),
            sidebarBackground.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            sidebarBackground.widthAnchor.constraint(equalToConstant: 196),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarBackground.leadingAnchor, constant: 12),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor, constant: -12),
            sidebarScroll.topAnchor.constraint(
                equalTo: sidebarBackground.topAnchor,
                constant: presentationMode == .embedded ? 20 : 72
            ),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebarBackground.bottomAnchor, constant: -20),
            contentHost.leadingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: rootView.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])

        sectionViews[.general] = makeGeneralView()
        sectionViews[.shortcuts] = makeShortcutsView()
        sectionViews[.placement] = makePlacementView()
        sectionViews[.cli] = makeCLIView()
        for view in sectionViews.values {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentHost.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                view.topAnchor.constraint(equalTo: contentHost.topAnchor),
                view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            ])
        }
        sidebar.selectRowIndexes(IndexSet(integer: SettingsSection.general.rawValue), byExtendingSelection: false)
        show(.general)
        apply(resolvedAppearance: appearanceController.resolvedAppearance)
    }

    private func makeGeneralView() -> NSView {
        let view = NSView()
        let title = heading("General")
        let appearanceLabel = rowLabel("Appearance")
        let loginLabel = rowLabel("Open at Login")
        let foldOnLockLabel = rowLabel("Fold cards when Mac locks")
        agentNoteLabel.font = .systemFont(ofSize: 12.5)
        secondaryLabels.append(agentNoteLabel)
        foldOnLockExplanationLabel.font = .systemFont(ofSize: 12, weight: .regular)
        secondaryLabels.append(foldOnLockExplanationLabel)

        appearanceControl.target = self
        appearanceControl.action = #selector(appearanceChanged(_:))
        loginSwitch.target = self
        loginSwitch.action = #selector(loginChanged(_:))
        foldOnLockSwitch.target = self
        foldOnLockSwitch.action = #selector(foldOnLockChanged(_:))
        foldOnLockSwitch.identifier = .init("settings.foldCardsWhenMacLocks")
        foldOnLockSwitch.setAccessibilityLabel("Fold cards when Mac locks")
        [
            title,
            appearanceLabel,
            appearanceControl,
            loginLabel,
            loginSwitch,
            foldOnLockLabel,
            foldOnLockSwitch,
            foldOnLockExplanationLabel,
            agentNoteLabel,
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        let divider1 = divider(in: view)
        let divider2 = divider(in: view)
        let divider3 = divider(in: view)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 56),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: contentTopInset),
            appearanceLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            appearanceLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 52),
            appearanceControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -56),
            appearanceControl.centerYAnchor.constraint(equalTo: appearanceLabel.centerYAnchor),
            appearanceControl.widthAnchor.constraint(equalToConstant: 258),
            divider1.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            divider1.trailingAnchor.constraint(equalTo: appearanceControl.trailingAnchor),
            divider1.topAnchor.constraint(equalTo: appearanceLabel.bottomAnchor, constant: 24),
            loginLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            loginLabel.topAnchor.constraint(equalTo: divider1.bottomAnchor, constant: 24),
            loginSwitch.trailingAnchor.constraint(equalTo: appearanceControl.trailingAnchor),
            loginSwitch.centerYAnchor.constraint(equalTo: loginLabel.centerYAnchor),
            divider2.leadingAnchor.constraint(equalTo: divider1.leadingAnchor),
            divider2.trailingAnchor.constraint(equalTo: divider1.trailingAnchor),
            divider2.topAnchor.constraint(equalTo: loginLabel.bottomAnchor, constant: 24),
            foldOnLockLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            foldOnLockLabel.topAnchor.constraint(equalTo: divider2.bottomAnchor, constant: 24),
            foldOnLockSwitch.trailingAnchor.constraint(equalTo: appearanceControl.trailingAnchor),
            foldOnLockSwitch.centerYAnchor.constraint(equalTo: foldOnLockLabel.centerYAnchor),
            foldOnLockExplanationLabel.leadingAnchor.constraint(equalTo: foldOnLockLabel.leadingAnchor),
            foldOnLockExplanationLabel.trailingAnchor.constraint(equalTo: appearanceControl.trailingAnchor),
            foldOnLockExplanationLabel.topAnchor.constraint(
                equalTo: foldOnLockLabel.bottomAnchor,
                constant: 7
            ),
            divider3.leadingAnchor.constraint(equalTo: divider1.leadingAnchor),
            divider3.trailingAnchor.constraint(equalTo: divider1.trailingAnchor),
            divider3.topAnchor.constraint(
                equalTo: foldOnLockExplanationLabel.bottomAnchor,
                constant: 18
            ),
            agentNoteLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            agentNoteLabel.trailingAnchor.constraint(equalTo: appearanceControl.trailingAnchor),
            agentNoteLabel.topAnchor.constraint(equalTo: divider3.bottomAnchor, constant: 16),
        ])
        return view
    }

    private func makeShortcutsView() -> NSView {
        let view = NSView()
        let title = heading("Shortcuts")
        let note = secondaryLabel("Click a shortcut to record a replacement.")
        let rows: [(String, String, ShortcutRecorderButton)] = [
            ("Open Command Center", "Global", commandCenterRecorder),
            ("New Card", "Global", newCardRecorder),
            ("Fold All Cards", "While a card is active", toggleFoldedCardsRecorder),
            ("Move Active Card to Preset", "While a card is active", moveActiveCardRecorder),
            ("Card Library", "While Markdown Card is active", libraryRecorder),
            ("Settings", "While Markdown Card is active", settingsRecorder),
        ]
        [title, note, shortcutFeedbackLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 56),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: contentTopInset),
            note.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            note.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -56),
            note.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            shortcutFeedbackLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            shortcutFeedbackLabel.trailingAnchor.constraint(
                equalTo: view.trailingAnchor,
                constant: -56
            ),
            shortcutFeedbackLabel.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 8),
        ])

        var previous: NSView = shortcutFeedbackLabel
        for (index, row) in rows.enumerated() {
            let label = rowLabel(row.0)
            let scope = secondaryLabel(row.1)
            let recorder = row.2
            [label, scope, recorder].forEach {
                $0.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview($0)
            }
            let separator = divider(in: view)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                label.topAnchor.constraint(
                    equalTo: previous.bottomAnchor,
                    constant: index == 0 ? 18 : 10
                ),
                scope.leadingAnchor.constraint(equalTo: label.leadingAnchor),
                scope.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 3),
                recorder.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -56),
                recorder.centerYAnchor.constraint(equalTo: label.centerYAnchor, constant: 8),
                recorder.widthAnchor.constraint(equalToConstant: 150),
                recorder.heightAnchor.constraint(equalToConstant: 32),
                separator.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: recorder.trailingAnchor),
                separator.topAnchor.constraint(equalTo: scope.bottomAnchor, constant: 10),
            ])
            previous = separator
        }
        return view
    }

    private func updateShortcutFeedback(_ message: String?) {
        let guidance = "Markdown shortcuts win only while a card editor is focused. "
            + "Save, Save As, and card layouts keep their fixed shortcuts."
        let baseline = defaults.string(
            forKey: ShortcutDefaultsMigration.reservedBindingsNoticeKey
        ).map { $0 + " " + guidance } ?? guidance
        let resolvedMessage = message ?? baseline
        shortcutFeedbackLabel.stringValue = resolvedMessage
        shortcutFeedbackLabel.setAccessibilityValue(resolvedMessage)
    }

    private func makePlacementView() -> NSView {
        let view = NSView()
        let title = heading("Card Placement")
        let note = secondaryLabel(
            "Move the active card to its preset position on its current display."
        )
        let pickerStack = NSStackView()
        pickerStack.orientation = .horizontal
        pickerStack.alignment = .top
        pickerStack.distribution = .fillEqually
        pickerStack.spacing = 24

        let layouts: [(CardLayoutMode, String)] = [
            (.mini, "Mini"),
            (.sticky, "Sticky Note"),
            (.middle, "Middle Note"),
        ]
        for (mode, layoutName) in layouts {
            let layoutLabel = rowLabel(layoutName)
            layoutLabel.font = .systemFont(ofSize: 13, weight: .medium)
            layoutLabel.alignment = .center

            let anchors = CardPlacementAnchor.allCases
            let anchorRows = stride(from: 0, to: anchors.count, by: 3)
                .map { startIndex -> [NSView] in
                    Array(anchors[startIndex ..< min(startIndex + 3, anchors.count)])
                        .map { anchor in
                            let button = makePlacementButton(
                                mode: mode,
                                layoutName: layoutName,
                                anchor: anchor
                            )
                            placementButtons.append((mode, anchor, button))
                            return button
                        }
                }
            let grid = NSGridView(views: anchorRows)
            grid.rowSpacing = 6
            grid.columnSpacing = 6
            grid.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                grid.widthAnchor.constraint(equalToConstant: 108),
                grid.heightAnchor.constraint(equalToConstant: 108),
            ])

            let group = NSStackView(views: [layoutLabel, grid])
            group.orientation = .vertical
            group.alignment = .centerX
            group.spacing = 10
            pickerStack.addArrangedSubview(group)
        }

        let positionNote = secondaryLabel(
            "Custom Size follows the Middle Note preset."
        )
        let restoreButton = NSButton(
            title: "Restore Defaults",
            target: self,
            action: #selector(restorePlacementDefaults(_:))
        )
        restoreButton.bezelStyle = .rounded
        restoreButton.controlSize = .regular

        [title, note, pickerStack, positionNote, restoreButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 56),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: contentTopInset),
            note.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            note.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -56),
            note.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            pickerStack.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            pickerStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -56),
            pickerStack.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 32),
            positionNote.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            positionNote.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -56),
            positionNote.topAnchor.constraint(equalTo: pickerStack.bottomAnchor, constant: 34),
            restoreButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            restoreButton.topAnchor.constraint(equalTo: positionNote.bottomAnchor, constant: 16),
        ])
        return view
    }

    private func makePlacementButton(
        mode: CardLayoutMode,
        layoutName: String,
        anchor: CardPlacementAnchor
    ) -> NSButton {
        let button = NSButton(
            title: "",
            target: self,
            action: #selector(placementChanged(_:))
        )
        button.setButtonType(.toggle)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.focusRingType = .default
        button.imagePosition = .imageOnly
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.layer?.cornerCurve = .continuous
        button.layer?.borderWidth = 1
        button.toolTip = "\(layoutName) — \(anchor.displayName)"
        button.setAccessibilityLabel("\(layoutName) \(anchor.displayName)")
        button.setAccessibilityIdentifier(
            "card-placement.\(mode.rawValue).\(anchor.rawValue)"
        )
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 32),
        ])
        return button
    }

    private func makeCLIView() -> NSView {
        let view = NSView()
        let title = heading("CLI")
        let path = rowLabel("~/.local/bin/mdcard")
        secondaryLabels.append(cliStatusLabel)
        cliButton.target = self
        cliButton.action = #selector(installCLI(_:))
        [title, path, cliStatusLabel, cliButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 56),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: contentTopInset),
            path.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            path.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 52),
            cliStatusLabel.leadingAnchor.constraint(equalTo: path.leadingAnchor),
            cliStatusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -180),
            cliStatusLabel.topAnchor.constraint(equalTo: path.bottomAnchor, constant: 8),
            cliButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -56),
            cliButton.centerYAnchor.constraint(equalTo: path.centerYAnchor),
        ])
        return view
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 26, weight: .bold)
        primaryLabels.append(label)
        return label
    }

    private func rowLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15, weight: .regular)
        primaryLabels.append(label)
        return label
    }

    private func secondaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .regular)
        secondaryLabels.append(label)
        return label
    }

    private func divider(in view: NSView) -> NSBox {
        let divider = NSBox()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.boxType = .separator
        view.addSubview(divider)
        return divider
    }

    private func show(_ section: SettingsSection) {
        for (candidate, view) in sectionViews {
            view.isHidden = candidate != section
        }
    }

    private func syncControls() {
        switch appearanceController.mode {
        case .system: appearanceControl.selectedSegment = 0
        case .light: appearanceControl.selectedSegment = 1
        case .dark: appearanceControl.selectedSegment = 2
        }
        loginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        foldOnLockSwitch.state = FoldPreferences.foldCardsWhenMacLocks(in: defaults) ? .on : .off
        syncPlacementControls()
    }

    private func syncPlacementControls() {
        for entry in placementButtons {
            let selected = placementPreferences.anchor(for: entry.mode) == entry.anchor
            entry.button.state = selected ? .on : .off
            entry.button.layer?.backgroundColor = (selected
                ? MonochromePalette.selection(for: appearance)
                : MonochromePalette.controlFill(for: appearance)).cgColor
            entry.button.layer?.borderColor = (selected
                ? MonochromePalette.primaryText(for: appearance)
                : MonochromePalette.border(for: appearance)).cgColor
            entry.button.contentTintColor = selected
                ? MonochromePalette.primaryText(for: appearance)
                : MonochromePalette.tertiaryText(for: appearance)
            let image = NSImage(
                systemSymbolName: selected ? "circle.fill" : "circle",
                accessibilityDescription: nil
            )
            entry.button.image = image?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 7, weight: .medium)
            )
            entry.button.setAccessibilityValue(selected ? "Selected" : "Not selected")
        }
    }

    @objc private func appearanceChanged(_ sender: NSSegmentedControl) {
        let mode: AppearanceMode = switch sender.selectedSegment {
        case 1: .light
        case 2: .dark
        default: .system
        }
        onAppearanceChange?(mode)
    }

    @objc private func loginChanged(_ sender: NSSwitch) {
        onLaunchAtLoginChange?(sender.state == .on)
    }

    @objc private func foldOnLockChanged(_ sender: NSSwitch) {
        let enabled = sender.state == .on
        defaults.set(enabled, forKey: Self.foldCardsWhenMacLocksDefaultsKey)
        onFoldCardsWhenMacLocksChange?(enabled)
    }

    @objc private func installCLI(_ sender: Any?) {
        onInstallCLI?()
        refreshCLIStatus()
    }

    @objc private func placementChanged(_ sender: NSButton) {
        guard let entry = placementButtons.first(where: { $0.button === sender }) else { return }
        placementPreferences.set(entry.anchor, for: entry.mode)
        syncPlacementControls()
    }

    @objc private func restorePlacementDefaults(_ sender: Any?) {
        placementPreferences.restoreDefaults()
        syncPlacementControls()
    }
}
