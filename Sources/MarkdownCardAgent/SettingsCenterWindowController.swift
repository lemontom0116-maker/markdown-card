import AppKit
import KeyboardShortcuts
import MarkdownCardCore
import ServiceManagement

private enum SettingsSection: Int, CaseIterable {
    case general
    case shortcuts
    case cli

    var title: String {
        switch self {
        case .general: "General"
        case .shortcuts: "Shortcuts"
        case .cli: "CLI"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "command"
        case .cli: "apple.terminal"
        }
    }
}

@MainActor
final class SettingsCenterWindowController: NSWindowController, NSTableViewDataSource,
    NSTableViewDelegate, NSWindowDelegate, AppearanceConsumer
{
    var onAppearanceChange: ((AppearanceMode) -> Void)?
    var onLaunchAtLoginChange: ((Bool) -> Void)?
    var onInstallCLI: (() -> Void)?
    var onShortcutChange: (() -> Void)?
    var onClose: (() -> Void)?

    private let appearanceController: AppearanceController
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
    private let cliStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let agentNoteLabel = NSTextField(
        wrappingLabelWithString: "Markdown Card runs quietly in the background until you open it."
    )
    private let cliButton = NSButton(title: "Install", target: nil, action: nil)
    private let commandCenterRecorder = ShortcutRecorderButton(name: .commandCenter)
    private let newCardRecorder = ShortcutRecorderButton(name: .newCard)
    private let libraryRecorder = ShortcutRecorderButton(name: .cardLibrary)
    private let settingsRecorder = ShortcutRecorderButton(name: .settings)
    private var sectionViews: [SettingsSection: NSView] = [:]
    private var primaryLabels: [NSTextField] = []
    private var secondaryLabels: [NSTextField] = []
    private var appearance: ResolvedAppearance = .dark
    private var selectedSection: SettingsSection = .general

    init(appearanceController: AppearanceController) {
        self.appearanceController = appearanceController
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configureWindow(window)
        let changed: () -> Void = { [weak self] in
            self?.onShortcutChange?()
        }
        commandCenterRecorder.onChange = changed
        newCardRecorder.onChange = changed
        libraryRecorder.onChange = changed
        settingsRecorder.onChange = changed
        appearanceController.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showSettings() {
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
        sidebar.selectRowIndexes(
            IndexSet(integer: SettingsSection.shortcuts.rawValue),
            byExtendingSelection: false
        )
        selectedSection = .shortcuts
        sidebar.reloadData()
        show(.shortcuts)
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        appearance = resolvedAppearance
        guard let window else { return }
        appearanceController.applyMode(to: window)
        let background = MonochromePalette.windowBackground(for: appearance)
        window.backgroundColor = background
        contentHost.layer?.backgroundColor = background.cgColor
        sidebar.backgroundColor = .clear
        sidebarScroll.backgroundColor = .clear
        primaryLabels.forEach { $0.textColor = MonochromePalette.primaryText(for: appearance) }
        secondaryLabels.forEach { $0.textColor = MonochromePalette.secondaryText(for: appearance) }
        [commandCenterRecorder, newCardRecorder, libraryRecorder, settingsRecorder].forEach {
            $0.apply(resolvedAppearance: appearance)
        }
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
        [commandCenterRecorder, newCardRecorder, libraryRecorder, settingsRecorder].forEach {
            $0.cancelRecording()
        }
    }

    private func configureWindow(_ window: NSWindow) {
        window.delegate = self
        window.title = "Markdown Card Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 520)

        let root = NSView()
        root.wantsLayer = true
        window.contentView = root

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
        root.addSubview(sidebarBackground)
        root.addSubview(contentHost)
        NSLayoutConstraint.activate([
            sidebarBackground.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarBackground.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarBackground.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarBackground.widthAnchor.constraint(equalToConstant: 196),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarBackground.leadingAnchor, constant: 12),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor, constant: -12),
            sidebarScroll.topAnchor.constraint(equalTo: sidebarBackground.topAnchor, constant: 72),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebarBackground.bottomAnchor, constant: -20),
            contentHost.leadingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: root.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        sectionViews[.general] = makeGeneralView()
        sectionViews[.shortcuts] = makeShortcutsView()
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
        agentNoteLabel.font = .systemFont(ofSize: 12.5)
        secondaryLabels.append(agentNoteLabel)

        appearanceControl.target = self
        appearanceControl.action = #selector(appearanceChanged(_:))
        loginSwitch.target = self
        loginSwitch.action = #selector(loginChanged(_:))
        [title, appearanceLabel, appearanceControl, loginLabel, loginSwitch, agentNoteLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        let divider1 = divider(in: view)
        let divider2 = divider(in: view)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 56),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 72),
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
            agentNoteLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            agentNoteLabel.trailingAnchor.constraint(equalTo: appearanceControl.trailingAnchor),
            agentNoteLabel.topAnchor.constraint(equalTo: divider2.bottomAnchor, constant: 16),
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
            ("Card Library", "While Markdown Card is active", libraryRecorder),
            ("Settings", "While Markdown Card is active", settingsRecorder),
        ]
        [title, note].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 56),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 72),
            note.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            note.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
        ])

        var previous: NSView = note
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
                label.topAnchor.constraint(equalTo: previous.bottomAnchor, constant: index == 0 ? 30 : 16),
                scope.leadingAnchor.constraint(equalTo: label.leadingAnchor),
                scope.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 3),
                recorder.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -56),
                recorder.centerYAnchor.constraint(equalTo: label.centerYAnchor, constant: 8),
                recorder.widthAnchor.constraint(equalToConstant: 150),
                recorder.heightAnchor.constraint(equalToConstant: 32),
                separator.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                separator.trailingAnchor.constraint(equalTo: recorder.trailingAnchor),
                separator.topAnchor.constraint(equalTo: scope.bottomAnchor, constant: 14),
            ])
            previous = separator
        }
        return view
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
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 72),
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

    @objc private func installCLI(_ sender: Any?) {
        onInstallCLI?()
        refreshCLIStatus()
    }
}
