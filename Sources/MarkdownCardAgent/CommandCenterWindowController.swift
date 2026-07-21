import AppKit
import KeyboardShortcuts
import MarkdownCardCore

enum CommandID: String, CaseIterable, Codable, Hashable {
    case newCard
    case cardLibrary
    case toggleFoldedCards
    case settings
    case quit
}

enum CommandCenterRoute: Equatable {
    case home
    case library
    case settings(SettingsSection?)

    var isWorkspace: Bool {
        switch self {
        case .home: false
        case .library, .settings: true
        }
    }
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

struct CommandCenterMaterialConfiguration: Equatable {
    enum Backdrop: Equatable {
        case nativeGlass
        case visualEffect
    }

    let backdrop: Backdrop
    let surfaceAlpha: CGFloat
    let borderWidth: CGFloat
    let borderAlpha: CGFloat
    let selectionAlpha: CGFloat

    static func resolve(
        appearance: ResolvedAppearance,
        nativeGlassAvailable: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Self {
        let backdrop: Backdrop = nativeGlassAvailable ? .nativeGlass : .visualEffect
        let surfaceAlpha: CGFloat
        if reduceTransparency {
            surfaceAlpha = 1
        } else if nativeGlassAvailable {
            surfaceAlpha = 0
        } else {
            surfaceAlpha = appearance == .dark ? 0.22 : 0.16
        }

        return Self(
            backdrop: backdrop,
            surfaceAlpha: surfaceAlpha,
            borderWidth: increaseContrast ? 1.5 : (nativeGlassAvailable ? 0 : 1),
            borderAlpha: increaseContrast ? 1 : (nativeGlassAvailable ? 0 : 0.55),
            selectionAlpha: increaseContrast ? 0.50 : 0.32
        )
    }
}

struct CommandCenterMotionConfiguration: Equatable {
    let openingDuration: TimeInterval
    let closingDuration: TimeInterval
    let usesScale: Bool

    static func resolve(reduceMotion: Bool) -> Self {
        reduceMotion
            ? Self(openingDuration: 0.07, closingDuration: 0.05, usesScale: false)
            : Self(openingDuration: 0.14, closingDuration: 0.09, usesScale: true)
    }
}

struct CommandCenterAccessibilityPreferences: Equatable {
    let reduceTransparency: Bool
    let increaseContrast: Bool
    let reduceMotion: Bool

    static var current: Self {
        Self(
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }
}

struct CommandCenterRouteTransitionState: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var isApplyingFrame = false

    mutating func begin(applyingFrame: Bool) -> UInt64 {
        generation &+= 1
        isApplyingFrame = applyingFrame
        return generation
    }

    @discardableResult
    mutating func complete(generation: UInt64) -> Bool {
        guard self.generation == generation else { return false }
        isApplyingFrame = false
        return true
    }

    mutating func invalidate() {
        generation &+= 1
        isApplyingFrame = false
    }
}

struct CommandCenterChromeState: Equatable {
    let isBackVisible: Bool
    let isMagnifierVisible: Bool
    let isPrimaryVisible: Bool
    let isPrimaryEnabled: Bool
    let primaryTitle: String
    let primaryUsesFooterTrailing: Bool
    let isActionsVisible: Bool
    let usesVerticallyCenteredSearchCell: Bool
    let isSearchEditable: Bool
    let isSearchSelectable: Bool
}

@MainActor
final class CommandCenterWindowController: NSWindowController, NSTableViewDataSource,
    NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate, AppearanceConsumer
{
    var onOpenCard: ((UUID) -> Void)?
    var onExecuteCommand: ((CommandID) -> Void)?
    var onRouteChange: ((CommandCenterRoute, CommandCenterRoute) -> Void)?

    private enum Constants {
        static let recentLimit = 3
        static let storedRecentLimit = 12
        static let recentDefaultsKey = "commandCenterRecentItems.v1"
        static let workspaceFrameDefaultsKey = "commandCenterWorkspaceFrame.v1"
        static let legacyLibraryFrameDefaultsKey = "cardLibraryWindowFrame"
        static let homeSize = NSSize(width: 720, height: 360)
        static let workspaceSize = NSSize(width: 1180, height: 760)
        static let workspaceMinimumSize = NSSize(width: 980, height: 620)
        static let visibleMargin: CGFloat = 24
        static let topBarHeight: CGFloat = 72
        static let footerHeight: CGFloat = 52
    }

    private let appearanceController: AppearanceController
    private let defaults: UserDefaults
    private let accessibilityPreferencesProvider: () -> CommandCenterAccessibilityPreferences
    private let searchField = CommandCenterSearchField()
    private let searchIcon = NSImageView()
    private let backButton = NSButton()
    private let contentHost = NSView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let footerView = NSView()
    private let footerIcon = NSImageView()
    private let footerTitle = NSTextField(labelWithString: "Command Center")
    private let primaryButton = NSButton(title: "Open", target: nil, action: nil)
    private let actionsButton = NSButton(title: "Actions  ⌘K", target: nil, action: nil)
    private let topDivider = NSBox()
    private let footerDivider = NSBox()
    private let materialView = CommandCenterMaterialHostView()
    private let surfaceView = NSView()
    private var cards: [CardRecord] = []
    private var items: [CommandCenterItem] = []
    private var recentReferences: [CommandCenterRecentReference] = []
    private var appearance: ResolvedAppearance = .dark
    private var isClosing = false
    private var isFolded = false
    private var selectionAlpha: CGFloat = 0.32
    private var selectedItemIndex: Int?
    private var appliedMaterialConfiguration: CommandCenterMaterialConfiguration?
    private var libraryController: CardLibraryWindowController?
    private var settingsController: SettingsCenterWindowController?
    private var homeQuery = ""
    private var libraryQuery = ""
    private var settingsQuery = ""
    private var backButtonWidthConstraint: NSLayoutConstraint?
    private var searchIconWidthConstraint: NSLayoutConstraint?
    private var homeSearchFieldLeadingConstraint: NSLayoutConstraint?
    private var workspaceSearchFieldLeadingConstraint: NSLayoutConstraint?
    private var primaryBeforeActionsTrailingConstraint: NSLayoutConstraint?
    private var primaryFooterTrailingConstraint: NSLayoutConstraint?
    private var routeTransitionState = CommandCenterRouteTransitionState()
    private(set) var activeRoute: CommandCenterRoute = .home

    var commands: [CommandDefinition] {
        [
            .init(
                id: .newCard,
                title: "New Card",
                keywords: ["create", "note", "new"],
                symbol: "plus.circle"
            ),
            .init(
                id: .cardLibrary,
                title: "Card Library",
                keywords: ["library", "cards", "browse"],
                symbol: "rectangle.split.2x1"
            ),
            .init(
                id: .toggleFoldedCards,
                title: isFolded ? "Restore All Cards" : "Fold All Cards",
                keywords: ["fold", "unfold", "sleep", "wake", "restore"],
                symbol: "rectangle.stack.fill"
            ),
            .init(
                id: .settings,
                title: "Settings",
                keywords: ["preferences", "appearance", "shortcuts", "cli"],
                symbol: "gearshape"
            ),
            .init(
                id: .quit,
                title: "Quit Markdown Card",
                keywords: ["quit", "exit"],
                symbol: "power"
            ),
        ]
    }

    init(
        appearanceController: AppearanceController,
        defaults: UserDefaults = .standard,
        accessibilityPreferencesProvider: @escaping () -> CommandCenterAccessibilityPreferences = {
            .current
        }
    ) {
        self.appearanceController = appearanceController
        self.defaults = defaults
        self.accessibilityPreferencesProvider = accessibilityPreferencesProvider
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsDidChange(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NSObject.cancelPreviousPerformRequests(withTarget: self)
    }

    func configureWorkspace(
        library: CardLibraryWindowController,
        settings: SettingsCenterWindowController
    ) {
        libraryController = library
        settingsController = settings

        let libraryView = library.prepareForEmbedding { [weak self] in self?.window }
        let settingsView = settings.prepareForEmbedding { [weak self] in self?.window }
        [libraryView, settingsView].forEach { view in
            view.translatesAutoresizingMaskIntoConstraints = false
            contentHost.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                view.topAnchor.constraint(equalTo: contentHost.topAnchor),
                view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            ])
            view.isHidden = true
        }
        library.onExternalSearchQueryChange = { [weak self] query in
            guard let self else { return }
            libraryQuery = query
            if activeRoute == .library {
                searchField.stringValue = query
                window?.makeFirstResponder(searchField)
            }
        }
        library.onRequestBack = { [weak self] in
            self?.goBack()
        }
        updateRoutePresentation(focusSearch: false)
    }

    var isShowingLibrary: Bool { activeRoute == .library && window?.isVisible == true }

    func activeLibraryCardSelection() -> UUID? {
        guard activeRoute == .library else { return nil }
        return libraryController?.activeCardSelection()
    }

    func activeLibrarySeriesSelection() -> (cardID: UUID, tagID: String)? {
        guard activeRoute == .library else { return nil }
        return libraryController?.activeSeriesSelection()
    }

    func flushLibraryEdits() {
        libraryController?.flushLatestMarkdown()
    }

    func flushLibraryEditsForTermination() async {
        await libraryController?.flushLatestMarkdownForTermination()
    }

    func latestLibraryMarkdownForFileOperation(cardID: UUID) async throws -> String {
        guard activeRoute == .library, let libraryController else {
            throw CardLibraryFileOperationError.selectionChanged
        }
        return try await libraryController.latestMarkdownForFileOperation(cardID: cardID)
    }

    func latestLibraryExportBundleForFileOperation(
        cardID: UUID
    ) async throws -> MarkdownExportBundle {
        guard activeRoute == .library, let libraryController else {
            throw CardLibraryFileOperationError.selectionChanged
        }
        return try await libraryController.latestMarkdownExportBundleForFileOperation(cardID: cardID)
    }

    func applySnapshot(_ cards: [CardRecord]) {
        self.cards = cards
        recentReferences = recentReferences.filter { reference in
            if case let .card(id) = reference { return cards.contains { $0.id == id } }
            return true
        }
        persistRecentReferences()
        rebuildItems(resetSelection: false)
    }

    func setFoldedState(_ isFolded: Bool) {
        guard self.isFolded != isFolded else { return }
        self.isFolded = isFolded
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

    var snapshotContentViewForTesting: NSView { surfaceView }

    func materialConfigurationForTesting() -> CommandCenterMaterialConfiguration? {
        appliedMaterialConfiguration
    }

    func isClosingForTesting() -> Bool { isClosing }

    func materialOpacityForTesting() -> Float {
        materialView.layer?.presentation()?.opacity ?? materialView.layer?.opacity ?? 1
    }

    func recordRecentForTesting(_ reference: CommandCenterRecentReference) {
        recordRecent(reference)
        rebuildItems(resetSelection: false)
    }

    func targetFrameForTesting(
        route: CommandCenterRoute,
        visibleFrame: NSRect
    ) -> NSRect {
        targetFrame(
            for: route,
            visibleFrame: visibleFrame,
            centeredOn: NSPoint(x: visibleFrame.midX, y: visibleFrame.midY)
        )
    }

    func chromeStateForTesting() -> CommandCenterChromeState {
        CommandCenterChromeState(
            isBackVisible: !backButton.isHidden,
            isMagnifierVisible: !searchIcon.isHidden && searchIconWidthConstraint?.constant != 0,
            isPrimaryVisible: !primaryButton.isHidden,
            isPrimaryEnabled: primaryButton.isEnabled,
            primaryTitle: primaryButton.title,
            primaryUsesFooterTrailing: primaryFooterTrailingConstraint?.isActive == true,
            isActionsVisible: !actionsButton.isHidden,
            usesVerticallyCenteredSearchCell: searchField.cell is CommandCenterSearchFieldCell,
            isSearchEditable: searchField.isEditable,
            isSearchSelectable: searchField.isSelectable
        )
    }

    func setSearchQueryForTesting(_ query: String) {
        searchField.stringValue = query
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
    }

    func performPrimaryActionForTesting() {
        performPrimaryAction()
    }

    func toggle(cards: [CardRecord], on screen: NSScreen?) {
        if window?.isVisible == true, !isClosing {
            close(animated: true)
        } else {
            show(route: .home, cards: cards, on: screen)
        }
    }

    func show(cards: [CardRecord], on screen: NSScreen?) {
        show(route: .home, cards: cards, on: screen)
    }

    func show(
        route: CommandCenterRoute,
        cards: [CardRecord],
        on screen: NSScreen?
    ) {
        guard let panel = window else { return }
        let wasVisible = panel.isVisible
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(finishAnimatedClose),
            object: nil
        )
        isClosing = false
        self.cards = cards
        guard setRoute(route, animated: wasVisible, focusSearch: false) else { return }
        if route == .home { homeQuery = "" }
        searchField.stringValue = query(for: route)
        if route == .home {
            rebuildItems(resetSelection: true)
        }
        appearanceController.applyMode(to: panel)
        if wasVisible {
            panel.alphaValue = 1
            materialView.setScaleImmediately(1)
            materialView.animateOpacity(
                to: 1,
                duration: CommandCenterMotionConfiguration.resolve(
                    reduceMotion: accessibilityPreferencesProvider().reduceMotion
                ).openingDuration,
                timing: .easeOut
            )
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(searchField)
            if route == .home { selectFirstResult() }
            return
        }
        let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        configurePanelBehavior(for: route, visibleFrame: visibleFrame)
        panel.setFrame(
            targetFrame(
                for: route,
                visibleFrame: visibleFrame,
                centeredOn: NSPoint(x: visibleFrame.midX, y: visibleFrame.midY)
            ),
            display: false
        )
        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 1
        if !wasVisible { materialView.setOpacityImmediately(0) }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        if route == .home { selectFirstResult() }

        let motion = CommandCenterMotionConfiguration.resolve(
            reduceMotion: accessibilityPreferencesProvider().reduceMotion
        )
        if motion.usesScale {
            if !wasVisible {
                materialView.setScaleImmediately(0.985)
            }
            materialView.animateScale(to: 1, duration: motion.openingDuration, timing: .easeOut)
        } else {
            materialView.setScaleImmediately(1)
        }
        materialView.animateOpacity(
            to: 1,
            duration: motion.openingDuration,
            timing: .easeOut
        )
    }

    func navigate(to route: CommandCenterRoute) {
        _ = setRoute(route, animated: window?.isVisible == true, focusSearch: true)
    }

    func goBack() {
        guard activeRoute != .home else {
            close(animated: true)
            return
        }
        guard window?.attachedSheet == nil else { return }
        navigate(to: .home)
    }

    private func setRoute(
        _ route: CommandCenterRoute,
        animated: Bool,
        focusSearch: Bool
    ) -> Bool {
        let previous = activeRoute
        if previous == route {
            configurePanelBehavior(for: route)
            if case let .settings(section) = route {
                settingsController?.activate(section: section)
            }
            updateRoutePresentation(focusSearch: focusSearch)
            return true
        }
        if window?.attachedSheet != nil { return false }

        saveQuery(searchField.stringValue, for: previous)
        switch previous {
        case .library:
            libraryController?.routeDidDeactivate()
        case .settings:
            settingsController?.routeDidDeactivate()
        case .home:
            break
        }

        activeRoute = route
        let reduceMotion = accessibilityPreferencesProvider().reduceMotion
        let transitionGeneration = routeTransitionState.begin(
            applyingFrame: animated && window != nil && !reduceMotion
        )
        searchField.stringValue = query(for: route)
        configurePanelBehavior(for: route)
        updateRoutePresentation(focusSearch: focusSearch)
        onRouteChange?(previous, route)

        guard animated, let panel = window else { return true }
        let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        configurePanelBehavior(for: route, visibleFrame: visibleFrame)
        let target = targetFrame(
            for: route,
            visibleFrame: visibleFrame,
            centeredOn: NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        )
        let applyFrame = {
            panel.animator().setFrame(target, display: true)
            self.contentHost.animator().alphaValue = 1
        }
        guard !reduceMotion else {
            panel.setFrame(target, display: true)
            contentHost.alphaValue = 1
            if routeTransitionState.complete(generation: transitionGeneration) {
                saveWorkspaceFrameIfNeeded()
            }
            return true
        }
        contentHost.alphaValue = 0.82
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            applyFrame()
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      routeTransitionState.complete(generation: transitionGeneration)
                else { return }
                saveWorkspaceFrameIfNeeded()
            }
        }
        return true
    }

    private func updateRoutePresentation(focusSearch: Bool) {
        scrollView.isHidden = activeRoute != .home
        libraryController?.rootViewForEmbedding.isHidden = activeRoute != .library
        let settingsIsVisible: Bool
        if case .settings = activeRoute {
            settingsIsVisible = true
        } else {
            settingsIsVisible = false
        }
        settingsController?.rootViewForEmbedding.isHidden = !settingsIsVisible

        let isHome = activeRoute == .home
        backButton.isHidden = isHome
        backButtonWidthConstraint?.constant = isHome ? 0 : 36
        searchIcon.isHidden = !isHome
        searchIconWidthConstraint?.constant = isHome ? 18 : 0
        homeSearchFieldLeadingConstraint?.isActive = isHome
        workspaceSearchFieldLeadingConstraint?.isActive = !isHome

        switch activeRoute {
        case .home:
            searchField.placeholderString = "Search cards and commands…"
            searchField.setAccessibilityLabel("Search cards and commands")
            footerTitle.stringValue = "Command Center"
            footerIcon.image = NSImage(systemSymbolName: "command", accessibilityDescription: nil)
            showStandardPrimaryButton(title: "Open  ↩")
            actionsButton.isHidden = false
            setPrimaryButtonUsesFooterTrailing(false)
            rebuildItems(resetSelection: false)
        case .library:
            searchField.placeholderString = "Search cards…"
            searchField.setAccessibilityLabel("Search cards")
            footerTitle.stringValue = "Card Library"
            footerIcon.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
            showStandardPrimaryButton(title: "Open Card  ↩")
            actionsButton.isHidden = true
            setPrimaryButtonUsesFooterTrailing(true)
            libraryController?.setExternalSearchQuery(searchField.stringValue)
            libraryController?.activate()
        case let .settings(section):
            searchField.placeholderString = "Search settings…"
            searchField.setAccessibilityLabel("Search settings")
            footerTitle.stringValue = "Settings"
            footerIcon.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
            actionsButton.isHidden = true
            setPrimaryButtonUsesFooterTrailing(true)
            updateSettingsPrimaryButton()
            settingsController?.activate(section: section)
            settingsController?.setExternalSearchQuery(searchField.stringValue)
        }

        if focusSearch {
            window?.makeFirstResponder(searchField)
        }
    }

    private func showStandardPrimaryButton(title: String) {
        primaryButton.title = title
        primaryButton.isHidden = false
        primaryButton.isEnabled = true
    }

    private func updateSettingsPrimaryButton() {
        let hasQuery = !searchField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        primaryButton.title = "Open Setting  ↩"
        primaryButton.isHidden = !hasQuery
        primaryButton.isEnabled = hasQuery
    }

    private func setPrimaryButtonUsesFooterTrailing(_ usesFooterTrailing: Bool) {
        primaryBeforeActionsTrailingConstraint?.isActive = !usesFooterTrailing
        primaryFooterTrailingConstraint?.isActive = usesFooterTrailing
    }

    private func configurePanelBehavior(
        for route: CommandCenterRoute,
        visibleFrame explicitVisibleFrame: NSRect? = nil
    ) {
        guard let panel = window else { return }
        let visibleFrame = explicitVisibleFrame
            ?? panel.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(origin: .zero, size: Constants.workspaceSize)
        let constrainedMinimum = routeMinimumSize(for: route, visibleFrame: visibleFrame)
        if route.isWorkspace {
            panel.styleMask.insert(.resizable)
            panel.minSize = constrainedMinimum
            panel.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            // AppKit automatically restores a window whose
            // `hidesOnDeactivate` flag is set when this accessory app becomes
            // active again. Clicking a floating card would therefore revive a
            // previously hidden Library or Settings workspace. Deep routes are
            // hidden explicitly from `hideForApplicationDeactivation()` so
            // their state survives without making them follow card focus.
            panel.hidesOnDeactivate = false
        } else {
            panel.styleMask.remove(.resizable)
            panel.minSize = constrainedMinimum
            panel.maxSize = constrainedMinimum
            panel.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
        }
    }

    func routeMinimumSize(
        for route: CommandCenterRoute,
        visibleFrame: NSRect
    ) -> NSSize {
        let available = NSSize(
            width: max(1, visibleFrame.width - Constants.visibleMargin * 2),
            height: max(1, visibleFrame.height - Constants.visibleMargin * 2)
        )
        let preferred = route.isWorkspace ? Constants.workspaceMinimumSize : Constants.homeSize
        return NSSize(
            width: min(preferred.width, available.width),
            height: min(preferred.height, available.height)
        )
    }

    private func query(for route: CommandCenterRoute) -> String {
        switch route {
        case .home: homeQuery
        case .library: libraryQuery
        case .settings: settingsQuery
        }
    }

    private func saveQuery(_ query: String, for route: CommandCenterRoute) {
        switch route {
        case .home: homeQuery = query
        case .library: libraryQuery = query
        case .settings: settingsQuery = query
        }
    }

    func close(animated: Bool) {
        guard let panel = window, panel.isVisible, !isClosing else { return }
        guard panel.attachedSheet == nil else { return }
        routeTransitionState.invalidate()
        if activeRoute.isWorkspace {
            let previous = activeRoute
            saveQuery(searchField.stringValue, for: previous)
            switch previous {
            case .library:
                libraryController?.routeDidDeactivate()
            case .settings:
                settingsController?.routeDidDeactivate()
            case .home:
                break
            }
            activeRoute = .home
            onRouteChange?(previous, .home)
        }
        isClosing = true
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(finishAnimatedClose),
            object: nil
        )
        guard animated else { finishAnimatedClose(); return }
        let motion = CommandCenterMotionConfiguration.resolve(
            reduceMotion: accessibilityPreferencesProvider().reduceMotion
        )
        if motion.usesScale {
            materialView.animateScale(to: 0.985, duration: motion.closingDuration, timing: .easeIn)
        } else {
            materialView.setScaleImmediately(1)
        }
        materialView.animateOpacity(
            to: 0,
            duration: motion.closingDuration,
            timing: .easeIn
        )
        perform(#selector(finishAnimatedClose), with: nil, afterDelay: motion.closingDuration)
    }

    func hideForApplicationDeactivation() {
        guard activeRoute.isWorkspace,
              let panel = window,
              panel.isVisible,
              panel.attachedSheet == nil
        else { return }

        routeTransitionState.invalidate()
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(finishAnimatedClose),
            object: nil
        )
        isClosing = false
        saveQuery(searchField.stringValue, for: activeRoute)
        switch activeRoute {
        case .library:
            libraryController?.routeDidDeactivate()
        case .settings:
            settingsController?.routeDidDeactivate()
        case .home:
            return
        }
        panel.orderOut(nil)
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        appearance = resolvedAppearance
        guard let window else { return }
        appearanceController.applyMode(to: window)
        let accessibilityPreferences = accessibilityPreferencesProvider()
        let reduceTransparency = accessibilityPreferences.reduceTransparency
        let materialConfiguration = CommandCenterMaterialConfiguration.resolve(
            appearance: appearance,
            nativeGlassAvailable: materialView.usesNativeGlass,
            reduceTransparency: reduceTransparency,
            increaseContrast: accessibilityPreferences.increaseContrast
        )
        appliedMaterialConfiguration = materialConfiguration
        selectionAlpha = materialConfiguration.selectionAlpha
        materialView.apply(
            configuration: materialConfiguration,
            appearance: appearance,
            contentView: surfaceView,
            reduceTransparency: reduceTransparency
        )
        searchField.textColor = MonochromePalette.primaryText(for: appearance)
        searchIcon.contentTintColor = MonochromePalette.secondaryText(for: appearance)
        backButton.contentTintColor = MonochromePalette.primaryText(for: appearance)
        footerIcon.contentTintColor = MonochromePalette.secondaryText(for: appearance)
        footerTitle.textColor = MonochromePalette.primaryText(for: appearance)
        primaryButton.contentTintColor = MonochromePalette.primaryText(for: appearance)
        actionsButton.contentTintColor = MonochromePalette.secondaryText(for: appearance)
        footerView.layer?.backgroundColor = MonochromePalette.windowBackground(for: appearance)
            .withAlphaComponent(accessibilityPreferences.reduceTransparency ? 1 : 0.18).cgColor
        tableView.backgroundColor = .clear
        tableView.reloadData()
        updateRoutePresentation(focusSearch: false)
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
                selected: row == selectedItemIndex,
                selectionAlpha: selectionAlpha
            )
        case let .command(command):
            return CommandCenterResultCell(
                title: command.title,
                symbol: command.symbol,
                appearance: appearance,
                selected: row == selectedItemIndex,
                selectionAlpha: selectionAlpha
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
        saveQuery(searchField.stringValue, for: activeRoute)
        switch activeRoute {
        case .home:
            rebuildItems(resetSelection: true)
        case .library:
            libraryController?.setExternalSearchQuery(searchField.stringValue)
        case .settings:
            settingsController?.setExternalSearchQuery(searchField.stringValue)
            updateSettingsPrimaryButton()
        }
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)):
            if activeRoute == .home { moveSelection(by: -1) }
            else if activeRoute == .library { libraryController?.moveListSelection(by: -1) }
            return true
        case #selector(NSResponder.moveDown(_:)):
            if activeRoute == .home { moveSelection(by: 1) }
            else if activeRoute == .library { libraryController?.moveListSelection(by: 1) }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            performPrimaryAction(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            handleCancel(); return true
        default:
            return false
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard activeRoute == .home else {
            if NSApp.isActive == false {
                switch activeRoute {
                case .library:
                    libraryController?.cancelTransientUI()
                case .settings:
                    settingsController?.cancelTransientUI()
                case .home:
                    break
                }
            }
            return
        }
        guard window?.attachedSheet == nil else { return }
        close(animated: true)
    }

    func windowDidResize(_ notification: Notification) {
        saveWorkspaceFrameIfNeeded()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let panel = window, let visibleFrame = panel.screen?.visibleFrame else { return }
        configurePanelBehavior(for: activeRoute, visibleFrame: visibleFrame)
        let safeFrame = visibleFrame.insetBy(
            dx: min(Constants.visibleMargin, visibleFrame.width / 4),
            dy: min(Constants.visibleMargin, visibleFrame.height / 4)
        )
        let constrained = Self.constrained(panel.frame, to: safeFrame)
        if constrained != panel.frame {
            panel.setFrame(constrained, display: true)
        }
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
        panel.setAccessibilityLabel("Markdown Card Command Center")
        panel.onMoveSelection = { [weak self] delta in self?.moveSelectionForActiveRoute(by: delta) }
        panel.onConfirm = { [weak self] in self?.performPrimaryAction() }
        panel.onCancel = { [weak self] in self?.handleCancel() }
        panel.onCloseRequest = { [weak self] in self?.close(animated: true) }
        panel.onActions = { [weak self] in self?.showActions() ?? false }
        panel.onLocalShortcut = { [weak self] event in
            guard let self else { return false }
            if ShortcutMatcher.matches(event, name: .cardLibrary) {
                recordRecent(.command(.cardLibrary))
                navigate(to: .library)
                return true
            }
            if ShortcutMatcher.matches(event, name: .settings) {
                recordRecent(.command(.settings))
                navigate(to: .settings(nil))
                return true
            }
            return false
        }
        panel.shouldDeferKeyEquivalentToFirstResponder = { [weak self] event in
            guard let self,
                  activeRoute == .library,
                  libraryController?.editorOwnsFirstResponder(in: window) == true
            else { return false }
            return MarkdownShortcutContract.matches(event)
        }

        materialView.install(contentView: surfaceView)
        surfaceView.wantsLayer = true
        surfaceView.layer?.cornerRadius = 16
        surfaceView.layer?.cornerCurve = .continuous
        surfaceView.layer?.masksToBounds = true

        searchField.cell = CommandCenterSearchFieldCell(textCell: "")
        // Replacing NSTextField's default cell resets both flags to false.
        // Restore them explicitly so the vertically centered field remains a
        // real editable search control instead of an accessibility-only label.
        searchField.isEditable = true
        searchField.isSelectable = true
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 20, weight: .regular)
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search cards and commands")
        searchField.onMoveSelection = { [weak self] delta in self?.moveSelectionForActiveRoute(by: delta) }
        searchField.onConfirm = { [weak self] in self?.performPrimaryAction() }
        searchField.onCancel = { [weak self] in self?.handleCancel() }

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

        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.isBordered = false
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back")
        backButton.imagePosition = .imageOnly
        backButton.target = self
        backButton.action = #selector(backPressed(_:))
        backButton.toolTip = "Back (Esc)"
        backButton.setAccessibilityLabel("Back")

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentHost.wantsLayer = true

        topDivider.translatesAutoresizingMaskIntoConstraints = false
        topDivider.boxType = .separator
        footerDivider.translatesAutoresizingMaskIntoConstraints = false
        footerDivider.boxType = .separator

        footerView.translatesAutoresizingMaskIntoConstraints = false
        footerView.wantsLayer = true
        footerIcon.translatesAutoresizingMaskIntoConstraints = false
        footerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        footerTitle.translatesAutoresizingMaskIntoConstraints = false
        footerTitle.font = .systemFont(ofSize: 13.5, weight: .medium)
        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.isBordered = false
        primaryButton.font = .systemFont(ofSize: 13.5, weight: .semibold)
        primaryButton.alignment = .right
        primaryButton.target = self
        primaryButton.action = #selector(primaryPressed(_:))
        actionsButton.translatesAutoresizingMaskIntoConstraints = false
        actionsButton.isBordered = false
        actionsButton.font = .systemFont(ofSize: 13.5, weight: .medium)
        actionsButton.target = self
        actionsButton.action = #selector(actionsPressed(_:))
        footerView.addSubview(footerIcon)
        footerView.addSubview(footerTitle)
        footerView.addSubview(primaryButton)
        footerView.addSubview(actionsButton)

        surfaceView.addSubview(backButton)
        surfaceView.addSubview(searchIcon)
        surfaceView.addSubview(searchField)
        surfaceView.addSubview(topDivider)
        surfaceView.addSubview(contentHost)
        surfaceView.addSubview(footerDivider)
        surfaceView.addSubview(footerView)
        contentHost.addSubview(scrollView)
        panel.contentView = materialView
        let backWidth = backButton.widthAnchor.constraint(equalToConstant: 0)
        let searchIconWidth = searchIcon.widthAnchor.constraint(equalToConstant: 18)
        let homeSearchFieldLeading = searchField.leadingAnchor.constraint(
            equalTo: searchIcon.trailingAnchor,
            constant: 14
        )
        let workspaceSearchFieldLeading = searchField.leadingAnchor.constraint(
            equalTo: backButton.trailingAnchor,
            constant: 14
        )
        let primaryBeforeActionsTrailing = primaryButton.trailingAnchor.constraint(
            equalTo: actionsButton.leadingAnchor,
            constant: -18
        )
        let primaryFooterTrailing = primaryButton.trailingAnchor.constraint(
            equalTo: footerView.trailingAnchor,
            constant: -20
        )
        backButtonWidthConstraint = backWidth
        searchIconWidthConstraint = searchIconWidth
        homeSearchFieldLeadingConstraint = homeSearchFieldLeading
        workspaceSearchFieldLeadingConstraint = workspaceSearchFieldLeading
        primaryBeforeActionsTrailingConstraint = primaryBeforeActionsTrailing
        primaryFooterTrailingConstraint = primaryFooterTrailing
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor, constant: 18),
            backButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            backWidth,
            backButton.heightAnchor.constraint(equalToConstant: 36),
            searchIcon.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 8),
            searchIcon.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            searchIconWidth,
            searchIcon.heightAnchor.constraint(equalToConstant: 18),
            homeSearchFieldLeading,
            searchField.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor, constant: -26),
            searchField.centerYAnchor.constraint(
                equalTo: surfaceView.topAnchor,
                constant: Constants.topBarHeight / 2
            ),
            searchField.heightAnchor.constraint(equalToConstant: 38),
            topDivider.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor),
            topDivider.topAnchor.constraint(equalTo: surfaceView.topAnchor, constant: Constants.topBarHeight),
            contentHost.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            contentHost.bottomAnchor.constraint(equalTo: footerDivider.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: 18),
            scrollView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -18),
            scrollView.topAnchor.constraint(equalTo: contentHost.topAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor, constant: -8),
            footerDivider.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: footerView.topAnchor),
            footerView.leadingAnchor.constraint(equalTo: surfaceView.leadingAnchor),
            footerView.trailingAnchor.constraint(equalTo: surfaceView.trailingAnchor),
            footerView.bottomAnchor.constraint(equalTo: surfaceView.bottomAnchor),
            footerView.heightAnchor.constraint(equalToConstant: Constants.footerHeight),
            footerIcon.leadingAnchor.constraint(equalTo: footerView.leadingAnchor, constant: 20),
            footerIcon.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
            footerIcon.widthAnchor.constraint(equalToConstant: 18),
            footerIcon.heightAnchor.constraint(equalToConstant: 18),
            footerTitle.leadingAnchor.constraint(equalTo: footerIcon.trailingAnchor, constant: 10),
            footerTitle.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
            primaryBeforeActionsTrailing,
            primaryButton.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
            actionsButton.trailingAnchor.constraint(equalTo: footerView.trailingAnchor, constant: -20),
            actionsButton.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
        ])
        configurePanelBehavior(for: .home)
        updateRoutePresentation(focusSearch: false)
        apply(resolvedAppearance: appearanceController.resolvedAppearance)
    }

    private func rebuildItems(resetSelection: Bool) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var next: [CommandCenterItem] = []
        if query.isEmpty {
            let recent = recentItems()
            if !recent.isEmpty {
                next.append(.section("Recent"))
                next.append(contentsOf: recent)
            }
            let recentCardIDs = Set(recent.compactMap { item -> UUID? in
                guard case let .card(card) = item else { return nil }
                return card.id
            })
            let orderedCards = CommandCenterSearch.cards(matching: "", in: cards)
                .filter { !recentCardIDs.contains($0.id) }
            if !orderedCards.isEmpty {
                next.append(.section("Cards"))
                next.append(contentsOf: orderedCards.prefix(3).map(CommandCenterItem.card))
            }
            let recentCommandIDs = Set(recent.compactMap { item -> CommandID? in
                guard case let .command(command) = item else { return nil }
                return command.id
            })
            let remainingCommands = commands.filter { !recentCommandIDs.contains($0.id) }
            if !remainingCommands.isEmpty {
                next.append(.section("Commands"))
                next.append(contentsOf: remainingCommands.map(CommandCenterItem.command))
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

    private func moveSelectionForActiveRoute(by delta: Int) {
        switch activeRoute {
        case .home:
            moveSelection(by: delta)
        case .library:
            libraryController?.moveListSelection(by: delta)
        case .settings:
            break
        }
    }

    private func performPrimaryAction() {
        switch activeRoute {
        case .home:
            executeSelection()
        case .library:
            libraryController?.performPrimaryAction()
        case .settings:
            guard !searchField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            else { return }
            settingsController?.focusSearchResult(for: searchField.stringValue)
        }
    }

    @discardableResult
    private func showActions() -> Bool {
        guard activeRoute == .home else { return false }
        executeSelection()
        return true
    }

    private func handleCancel() {
        if window?.attachedSheet != nil { return }
        switch activeRoute {
        case .home:
            close(animated: true)
        case .library, .settings:
            goBack()
        }
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
        switch command {
        case .cardLibrary:
            navigate(to: .library)
        case .settings:
            navigate(to: .settings(nil))
        case .newCard, .toggleFoldedCards, .quit:
            close(animated: false)
            onExecuteCommand?(command)
        }
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

    @objc private func backPressed(_ sender: Any?) { goBack() }

    @objc private func primaryPressed(_ sender: Any?) { performPrimaryAction() }

    @objc private func actionsPressed(_ sender: Any?) { _ = showActions() }

    @objc private func finishAnimatedClose() {
        guard isClosing else { return }
        window?.orderOut(nil)
        window?.alphaValue = 1
        materialView.setScaleImmediately(1)
        materialView.setOpacityImmediately(1)
        isClosing = false
    }

    @objc private func accessibilityDisplayOptionsDidChange(_ notification: Notification) {
        apply(resolvedAppearance: appearanceController.resolvedAppearance)
    }

    private func targetFrame(
        for route: CommandCenterRoute,
        visibleFrame: NSRect,
        centeredOn center: NSPoint
    ) -> NSRect {
        let availableSize = NSSize(
            width: max(1, visibleFrame.width - Constants.visibleMargin * 2),
            height: max(1, visibleFrame.height - Constants.visibleMargin * 2)
        )
        let preferredSize: NSSize
        if route.isWorkspace {
            let stored = defaults.string(forKey: Constants.workspaceFrameDefaultsKey)
                ?? defaults.string(forKey: Constants.legacyLibraryFrameDefaultsKey)
            let restored = stored.map(NSRectFromString)
            let candidate = restored?.size ?? Constants.workspaceSize
            preferredSize = NSSize(
                width: min(max(candidate.width, Constants.workspaceMinimumSize.width), availableSize.width),
                height: min(max(candidate.height, Constants.workspaceMinimumSize.height), availableSize.height)
            )
        } else {
            preferredSize = NSSize(
                width: min(Constants.homeSize.width, availableSize.width),
                height: min(Constants.homeSize.height, availableSize.height)
            )
        }
        let frame = NSRect(
            x: center.x - preferredSize.width / 2,
            y: center.y - preferredSize.height / 2,
            width: preferredSize.width,
            height: preferredSize.height
        )
        return Self.constrained(frame, to: visibleFrame.insetBy(
            dx: min(Constants.visibleMargin, visibleFrame.width / 4),
            dy: min(Constants.visibleMargin, visibleFrame.height / 4)
        ))
    }

    private func saveWorkspaceFrameIfNeeded() {
        guard activeRoute.isWorkspace,
              !routeTransitionState.isApplyingFrame,
              let frame = window?.frame
        else { return }
        defaults.set(NSStringFromRect(frame), forKey: Constants.workspaceFrameDefaultsKey)
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
private final class CommandCenterMaterialHostView: NSView {
    let usesNativeGlass: Bool

    private let backdropView: NSView

    override init(frame frameRect: NSRect) {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView()
            glassView.style = .regular
            glassView.cornerRadius = 16
            glassView.tintColor = nil
            backdropView = glassView
            usesNativeGlass = true
        } else {
            let effectView = NSVisualEffectView()
            effectView.material = .hudWindow
            effectView.blendingMode = .behindWindow
            effectView.state = .active
            backdropView = effectView
            usesNativeGlass = false
        }
        #else
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        backdropView = effectView
        usesNativeGlass = false
        #endif

        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        backdropView.translatesAutoresizingMaskIntoConstraints = false
        backdropView.wantsLayer = true
        backdropView.layer?.cornerRadius = 16
        backdropView.layer?.cornerCurve = .continuous
        backdropView.layer?.masksToBounds = true
        addSubview(backdropView)
        NSLayoutConstraint.activate([
            backdropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func install(contentView: NSView) {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glassView = backdropView as? NSGlassEffectView {
            contentView.translatesAutoresizingMaskIntoConstraints = true
            contentView.frame = glassView.bounds
            contentView.autoresizingMask = [.width, .height]
            glassView.contentView = contentView
            return
        }
        #endif
        contentView.translatesAutoresizingMaskIntoConstraints = false
        backdropView.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: backdropView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: backdropView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: backdropView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: backdropView.bottomAnchor),
        ])
    }

    func apply(
        configuration: CommandCenterMaterialConfiguration,
        appearance: ResolvedAppearance,
        contentView: NSView,
        reduceTransparency: Bool
    ) {
        if let effectView = backdropView as? NSVisualEffectView {
            effectView.state = reduceTransparency ? .inactive : .active
            effectView.layer?.backgroundColor = NSColor.clear.cgColor
        }
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glassView = backdropView as? NSGlassEffectView {
            glassView.style = .regular
            glassView.cornerRadius = 16
            glassView.tintColor = nil
        }
        #endif

        contentView.layer?.backgroundColor = MonochromePalette.windowBackground(for: appearance)
            .withAlphaComponent(configuration.surfaceAlpha).cgColor
        layer?.borderWidth = configuration.borderWidth
        layer?.borderColor = MonochromePalette.border(for: appearance)
            .withAlphaComponent(configuration.borderAlpha).cgColor
    }

    func setScaleImmediately(_ scale: CGFloat) {
        guard let layer else { return }
        layer.removeAnimation(forKey: "commandCenterScale")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
    }

    func setOpacityImmediately(_ opacity: Float) {
        guard let layer else { return }
        layer.removeAnimation(forKey: "commandCenterOpacity")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        CATransaction.commit()
    }

    func animateOpacity(
        to opacity: Float,
        duration: TimeInterval,
        timing: CAMediaTimingFunctionName
    ) {
        guard let layer else { return }
        let currentOpacity = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "commandCenterOpacity")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = opacity
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = currentOpacity
        animation.toValue = opacity
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        layer.add(animation, forKey: "commandCenterOpacity")
    }

    func animateScale(
        to scale: CGFloat,
        duration: TimeInterval,
        timing: CAMediaTimingFunctionName
    ) {
        guard let layer else { return }
        let currentTransform = layer.presentation()?.transform ?? layer.transform
        let targetTransform = CATransform3DMakeScale(scale, scale, 1)
        layer.removeAnimation(forKey: "commandCenterScale")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = targetTransform
        CATransaction.commit()

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: currentTransform)
        animation.toValue = NSValue(caTransform3D: targetTransform)
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        layer.add(animation, forKey: "commandCenterScale")
    }
}

@MainActor
private final class CommandCenterPanel: NSPanel {
    var onMoveSelection: ((Int) -> Void)?
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCloseRequest: (() -> Void)?
    var onActions: (() -> Bool)?
    var onLocalShortcut: ((NSEvent) -> Bool)?
    var shouldDeferKeyEquivalentToFirstResponder: ((NSEvent) -> Bool)?

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
        if shouldDeferKeyEquivalentToFirstResponder?(event) == true {
            return super.performKeyEquivalent(with: event)
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == [.command], event.charactersIgnoringModifiers?.lowercased() == "w" {
            onCloseRequest?()
            return true
        }
        if modifiers == [.command],
           event.charactersIgnoringModifiers?.lowercased() == "k",
           onActions?() == true {
            return true
        }
        if onLocalShortcut?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class CommandCenterSearchFieldCell: NSTextFieldCell {
    private func verticallyCenteredFrame(for bounds: NSRect) -> NSRect {
        var frame = super.drawingRect(forBounds: bounds)
        let textHeight = ceil((font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize))
            .boundingRectForFont.height)
        guard textHeight < frame.height else { return frame }
        frame.origin.y += floor((frame.height - textHeight) / 2)
        frame.size.height = textHeight
        return frame
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        verticallyCenteredFrame(for: rect)
    }

    override func edit(
        withFrame aRect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: verticallyCenteredFrame(for: aRect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame aRect: NSRect,
        in controlView: NSView,
        editor textObj: NSText,
        delegate: Any?,
        start selStart: Int,
        length selLength: Int
    ) {
        super.select(
            withFrame: verticallyCenteredFrame(for: aRect),
            in: controlView,
            editor: textObj,
            delegate: delegate,
            start: selStart,
            length: selLength
        )
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
    init(
        title: String,
        symbol: String,
        appearance: ResolvedAppearance,
        selected: Bool,
        selectionAlpha: CGFloat
    ) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = selected
            ? MonochromePalette.selection(for: appearance).withAlphaComponent(selectionAlpha).cgColor
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
