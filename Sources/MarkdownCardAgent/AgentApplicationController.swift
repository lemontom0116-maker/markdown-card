import AppKit
import KeyboardShortcuts
import MarkdownCardCore
import ServiceManagement

@MainActor
final class AgentApplicationController: NSObject, AppearanceConsumer {
    private let repository: any CardRepository
    private let appearanceController: AppearanceController
    private var commandServer: AgentCommandServer?
    private var commandCenterWindowController: CommandCenterWindowController?
    private var settingsWindowController: SettingsCenterWindowController?
    private var libraryWindowController: CardLibraryWindowController?
    private var cards: [UUID: CardRecord] = [:]
    private var panels: [UUID: CardPanelController] = [:]
    private var transientCardIDs: Set<UUID> = []
    private let defaults: UserDefaults
    private var persistenceTail: Task<Void, Never>?
    private var persistenceGeneration = 0
    private var pendingMarkdownPersistence: [UUID: Task<Void, Never>] = [:]
    private let persistenceErrorState = PersistenceErrorState()
    private let mutationGate = AgentMutationGate()
    private let documentCoordinator = CardDocumentCoordinator()
    private let interfacePresence = UserInterfacePresenceCoordinator()
    private var libraryMenuItem: NSMenuItem?
    private var settingsMenuItem: NSMenuItem?

    static let lastActiveCardDefaultsKey = "lastActiveCardID"

    init(
        repository: any CardRepository,
        appearanceController: AppearanceController = AppearanceController(),
        defaults: UserDefaults = .standard
    ) {
        self.repository = repository
        self.appearanceController = appearanceController
        self.defaults = defaults
        super.init()
        appearanceController.register(self)
    }

    func start() async throws {
        try await loadCards()
        configureMainMenu()
        configureShortcut()
        configureAuxiliaryWindows()

        let socketPath = ProcessInfo.processInfo.environment["MDCARD_SOCKET_PATH"]
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? IPCSocketPath.defaultPath
        let server = AgentCommandServer(
            server: UnixDomainSocketServer(path: socketPath)
        ) { [weak self] request in
            guard let self else {
                return .failure(requestID: request.requestID, code: "agent_stopped", message: "The agent is stopping.")
            }
            return await self.handle(request)
        }
        try server.start()
        commandServer = server

        for card in cards.values where card.isVisible {
            let panel = panelController(for: card)
            panel.show(activate: false)
        }
    }

    func stop() {
        commandServer?.stop()
        commandServer = nil
    }

    func prepareForTermination() async throws {
        await mutationGate.acquire()
        for panel in panels.values {
            await panel.flushLatestMarkdownForTermination()
        }
        await libraryWindowController?.flushLatestMarkdownForTermination()
        let finalPersistence = beginTerminationFlush()
        await finalPersistence?.value
        let persistenceError = await persistenceErrorState.current()
        await mutationGate.release()
        if let persistenceError {
            throw AgentUIError.persistenceFailed(persistenceError)
        }
    }

    private func beginTerminationFlush() -> Task<Void, Never>? {
        // Stop accepting mutations before taking the final persistence handle.
        // Keeping this step synchronous lets AppKit cancel its first terminate
        // request, unwind, and retry only after the asynchronous flush ends.
        stop()
        panels.values.forEach { $0.flushPendingChanges() }
        libraryWindowController?.flushLatestMarkdown()
        flushStagedMarkdownPersistence()
        return persistenceTail
    }

    func toggleCommandCenter() {
        commandCenterWindowController?.toggle(cards: persistentCardsSnapshot(), on: currentScreen())
    }

    func showCommandCenter() {
        commandCenterWindowController?.show(cards: persistentCardsSnapshot(), on: currentScreen())
    }

    func createNewCard() {
        Task { [weak self] in
            guard let self else { return }
            await withSerializedMutation {
                _ = try? await createIndependentCard(persistEmpty: false)
            }
        }
    }

    private func loadCards() async throws {
        _ = try await repository.deleteLegacyQuickCards()
        let stored = try await repository.allCards()
        cards = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        documentCoordinator.register(stored)

        if let storedID = defaults.string(forKey: Self.lastActiveCardDefaultsKey)
            .flatMap(UUID.init(uuidString:)), cards[storedID] == nil
        {
            defaults.removeObject(forKey: Self.lastActiveCardDefaultsKey)
        }
    }

    private func configureShortcut() {
        KeyboardShortcuts.onKeyDown(for: .commandCenter) { [weak self] in
            self?.toggleCommandCenter()
        }
        KeyboardShortcuts.onKeyDown(for: .newCard) { [weak self] in
            self?.createNewCard()
        }
    }

    private func configureAuxiliaryWindows() {
        let settings = SettingsCenterWindowController(appearanceController: appearanceController)
        settings.onAppearanceChange = { [weak self] mode in
            self?.setAppearance(mode)
        }
        settings.onLaunchAtLoginChange = { [weak self] enabled in
            self?.setLaunchAtLogin(enabled)
        }
        settings.onInstallCLI = { [weak self] in self?.installCLI(nil) }
        settings.onShortcutChange = { [weak self] in self?.applyLocalMenuShortcuts() }
        settings.onClose = { [weak self] in self?.interfacePresence.didClose(.settings) }
        settingsWindowController = settings

        let library = CardLibraryWindowController(
            appearanceController: appearanceController,
            defaults: defaults
        )
        library.onOpenCard = { [weak self] id in
            Task { [weak self] in
                guard let self else { return }
                _ = await withSerializedMutation { try? await showCard(id: id) }
            }
        }
        library.onDeleteCard = { [weak self] id in
            Task { [weak self] in
                guard let self else { return }
                await withSerializedMutation { try? await deleteCard(id: id, force: true) }
            }
        }
        library.onCreateCard = { [weak self] in self?.createNewCard() }
        library.onMarkdownChange = { [weak self] id, markdown, revision, source in
            self?.stageMarkdownUpdate(
                id: id,
                markdown: markdown,
                incomingRevision: revision,
                source: source
            )
        }
        library.onClose = { [weak self] in self?.interfacePresence.didClose(.cardLibrary) }
        libraryWindowController = library

        let commandCenter = CommandCenterWindowController(
            appearanceController: appearanceController,
            defaults: defaults
        )
        commandCenter.onOpenCard = { [weak self] id in
            Task { [weak self] in
                guard let self else { return }
                _ = await withSerializedMutation { try? await showCard(id: id) }
            }
        }
        commandCenter.onExecuteCommand = { [weak self] command in
            self?.executeCommandCenterCommand(command)
        }
        commandCenter.applySnapshot(persistentCardsSnapshot())
        commandCenterWindowController = commandCenter
        refreshAuxiliarySnapshots()
    }

    private func executeCommandCenterCommand(_ command: CommandID) {
        switch command {
        case .newCard:
            createNewCard()
        case .cardLibrary:
            showLibrary(nil)
        case .settings:
            showSettings(nil)
        case .quit:
            NSApp.terminate(nil)
        }
    }

    private func menuItem(
        _ title: String,
        action: Selector?,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func configureMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Markdown Card")
        appMenu.addItem(menuItem("Settings…", action: #selector(showSettings(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("Quit Markdown Card", action: #selector(quit(_:)), key: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(menuItem("New Card", action: #selector(createNewCardFromMenu(_:)), key: "n"))
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let closeWindow = NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        closeWindow.target = nil
        closeWindow.keyEquivalentModifierMask = [.command]
        windowMenu.addItem(closeWindow)
        windowMenu.addItem(.separator())
        let library = menuItem("Card Library", action: #selector(showLibrary(_:)))
        let settings = menuItem("Settings…", action: #selector(showSettings(_:)))
        libraryMenuItem = library
        settingsMenuItem = settings
        windowMenu.addItem(library)
        windowMenu.addItem(settings)
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        applyLocalMenuShortcuts()
    }

    private func panelController(for card: CardRecord) -> CardPanelController {
        if let existing = panels[card.id] {
            existing.update(card: card, revision: documentCoordinator.revision(for: card.id))
            return existing
        }
        let controller = CardPanelController(card: card, appearanceController: appearanceController)
        controller.onMarkdownChange = { [weak self] id, markdown, revision, source in
            self?.stageMarkdownUpdate(
                id: id,
                markdown: markdown,
                incomingRevision: revision,
                source: source
            )
        }
        controller.onRequestHide = { [weak self] id in
            Task { [weak self] in
                guard let self else { return }
                await withSerializedMutation { try? await hideCard(id: id) }
            }
        }
        controller.onCreateCard = { [weak self] in self?.createNewCard() }
        controller.onFrameChange = { [weak self] id, frame, screenID in
            self?.stageFrameUpdate(id: id, frame: frame, screenID: screenID)
        }
        controller.onLayoutChange = { [weak self] id, mode, custom in
            self?.stageLayoutUpdate(id: id, mode: mode, custom: custom)
        }
        controller.onBecameKey = { [weak self] id in self?.markCardActive(id) }
        restoreFrame(of: card, to: controller.window)
        controller.update(card: card, revision: documentCoordinator.revision(for: card.id))
        panels[card.id] = controller
        return controller
    }

    private func restoreFrame(of card: CardRecord, to window: NSWindow?) {
        guard let frame = card.windowFrame, frame.isValid, let window else { return }
        var rect = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        let screen = NSScreen.screens.first { $0.localizedName == card.screenID }
            ?? NSScreen.screens.first { $0.frame.intersects(rect) }
            ?? NSScreen.main
        if let screen {
            rect = window.constrainFrameRect(rect, to: screen)
        }
        window.setFrame(rect, display: false)
    }

    private func currentScreen() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    @discardableResult
    func createIndependentCard(
        markdown: String = "",
        title: String? = nil,
        show: Bool = true,
        persistEmpty: Bool = true
    ) async throws -> CardRecord {
        try await flushPendingPersistence()
        var card = CardRecord(
            title: title,
            markdown: markdown,
            isVisible: true,
            layoutMode: .sticky
        )
        card.isQuick = false
        cards[card.id] = card
        documentCoordinator.register([card])
        if persistEmpty || !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            card = try await repository.upsert(card)
            cards[card.id] = card
        } else {
            transientCardIDs.insert(card.id)
        }
        if show {
            panelController(for: card).show(on: currentScreen(), centerIfNeeded: true)
        }
        markCardActive(card.id)
        refreshAuxiliarySnapshots()
        return card
    }

    @discardableResult
    private func showCard(id: UUID) async throws -> CardRecord {
        try await flushPendingPersistence()
        guard var card = cards[id] else { throw AgentUIError.cardNotFound(id) }
        card.isVisible = true
        card.touch()
        cards[id] = card
        _ = try await repository.upsert(card)
        let panel = panelController(for: card)
        let shouldCenter = card.windowFrame == nil
        panel.show(
            on: Self.presentationScreen(
                for: card,
                currentScreen: currentScreen()
            ),
            centerIfNeeded: shouldCenter
        )
        markCardActive(id)
        refreshAuxiliarySnapshots()
        return card
    }

    static func presentationScreen(
        for card: CardRecord,
        currentScreen: NSScreen?
    ) -> NSScreen? {
        card.windowFrame == nil ? currentScreen : nil
    }

    private func hideCard(id: UUID) async throws {
        try await flushPendingPersistence()
        if transientCardIDs.remove(id) != nil {
            panels[id]?.hide(flushingPendingChanges: false)
            panels[id] = nil
            cards[id] = nil
            documentCoordinator.remove(id)
            if defaults.string(forKey: Self.lastActiveCardDefaultsKey) == id.uuidString {
                defaults.removeObject(forKey: Self.lastActiveCardDefaultsKey)
            }
            refreshAuxiliarySnapshots()
            return
        }
        guard var card = cards[id] else { throw AgentUIError.cardNotFound(id) }
        card.isVisible = false
        cards[id] = card
        _ = try await repository.upsert(card)
        panels[id]?.hide()
        refreshAuxiliarySnapshots()
    }

    private func updateMarkdown(id: UUID, markdown: String) async throws {
        try await flushPendingPersistence()
        guard cards[id] != nil else { throw AgentUIError.cardNotFound(id) }
        commitMarkdown(
            id: id,
            markdown: markdown,
            incomingRevision: documentCoordinator.revision(for: id) &+ 1,
            source: .commandLine
        )
        if let card = cards[id] { _ = try await repository.upsert(card) }
    }

    private func stageMarkdownUpdate(
        id: UUID,
        markdown: String,
        incomingRevision: UInt64,
        source: EditorSourceID
    ) {
        commitMarkdown(
            id: id,
            markdown: markdown,
            incomingRevision: incomingRevision,
            source: source
        )
        scheduleMarkdownPersistence(for: id)
    }

    private func commitMarkdown(
        id: UUID,
        markdown: String,
        incomingRevision: UInt64,
        source: EditorSourceID
    ) {
        guard var card = cards[id] else { return }
        guard markdown != card.markdown else { return }
        let transaction = documentCoordinator.accept(
            cardID: id,
            markdown: markdown,
            incomingRevision: incomingRevision,
            source: source
        )
        card.updateMarkdown(markdown)
        cards[id] = card
        if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            transientCardIDs.remove(id)
        }
        for panel in panels.values where panel.editorSourceID != source {
            guard panel.card.id == id else { continue }
            panel.update(card: card, revision: transaction.revision)
        }
        refreshAuxiliarySnapshots(excluding: source)
    }

    private func scheduleMarkdownPersistence(for id: UUID) {
        pendingMarkdownPersistence[id]?.cancel()
        pendingMarkdownPersistence[id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(220))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, let card = cards[id] else { return }
            pendingMarkdownPersistence[id] = nil
            enqueuePersistence(card)
        }
    }

    private func flushStagedMarkdownPersistence() {
        let ids = Array(pendingMarkdownPersistence.keys)
        for id in ids {
            pendingMarkdownPersistence[id]?.cancel()
            pendingMarkdownPersistence[id] = nil
            if let card = cards[id], !transientCardIDs.contains(id) {
                enqueuePersistence(card)
            }
        }
    }

    private func stageFrameUpdate(id: UUID, frame: WindowFrame, screenID: String?) {
        guard var card = cards[id] else { return }
        card.windowFrame = frame.isValid ? frame : nil
        card.screenID = screenID
        cards[id] = card
        guard !transientCardIDs.contains(id) else { return }
        enqueuePersistence(card)
    }

    private func stageLayoutUpdate(
        id: UUID,
        mode: CardLayoutMode,
        custom: CustomCardLayout?
    ) {
        guard var card = cards[id] else { return }
        card.layoutMode = mode
        card.customLayout = custom
        card.touch()
        cards[id] = card
        if !transientCardIDs.contains(id) {
            enqueuePersistence(card)
        }
        refreshAuxiliarySnapshots()
    }

    private func markCardActive(_ id: UUID) {
        guard cards[id] != nil else { return }
        defaults.set(id.uuidString, forKey: Self.lastActiveCardDefaultsKey)
    }

    private func recentCardID() -> UUID? {
        if let stored = defaults.string(forKey: Self.lastActiveCardDefaultsKey)
            .flatMap(UUID.init(uuidString:)), cards[stored] != nil
        {
            return stored
        }
        return cards.values.sorted { $0.updatedAt > $1.updatedAt }.first?.id
    }

    private func enqueuePersistence(_ card: CardRecord) {
        guard !transientCardIDs.contains(card.id) else { return }
        persistenceGeneration += 1
        let previous = persistenceTail
        let repository = self.repository
        let persistenceErrorState = self.persistenceErrorState
        persistenceTail = Task.detached(priority: .utility) {
            if let previous {
                await previous.value
            }
            do {
                _ = try await repository.upsert(card)
            } catch {
                await persistenceErrorState.record(error.localizedDescription)
                fputs("Markdown Card autosave failed: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    private func flushPendingPersistence() async throws {
        flushStagedMarkdownPersistence()
        while true {
            let generation = persistenceGeneration
            let task = persistenceTail
            await task?.value
            if generation == persistenceGeneration {
                if let message = await persistenceErrorState.current() {
                    throw AgentUIError.persistenceFailed(message)
                }
                return
            }
        }
    }

    private func deleteCard(id: UUID, force: Bool) async throws {
        try await flushPendingPersistence()
        guard let card = cards[id] else { throw AgentUIError.cardNotFound(id) }
        if !force, card.isVisible {
            throw AgentUIError.protectedCard
        }
        // A visible editor/frame flush stages asynchronous upserts. Drain those
        // writes before deleting, then order the window out without generating
        // a second flush that could recreate the record after deletion.
        panels[id]?.flushPendingChanges()
        try await flushPendingPersistence()
        panels[id]?.hide(flushingPendingChanges: false)
        panels[id] = nil
        _ = try await repository.delete(id: id)
        cards[id] = nil
        documentCoordinator.remove(id)
        if defaults.string(forKey: Self.lastActiveCardDefaultsKey) == id.uuidString {
            defaults.removeObject(forKey: Self.lastActiveCardDefaultsKey)
        }
        refreshAuxiliarySnapshots()
    }

    private func setAppearance(_ mode: AppearanceMode) {
        appearanceController.setMode(mode)
    }

    func apply(resolvedAppearance: ResolvedAppearance) {
        // Window consumers are registered directly with AppearanceController.
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            presentError(error)
        }
    }

    private func handle(_ request: AgentRequest) async -> AgentResponse {
        await withSerializedMutation {
            await handleSerialized(request)
        }
    }

    private func handleSerialized(_ request: AgentRequest) async -> AgentResponse {
        do {
            switch request.command {
            case let .create(options):
                let card = try await createIndependentCard(
                    markdown: options.markdown,
                    title: options.title
                )
                return try .success(
                    requestID: request.requestID,
                    encoding: CardMutationPayload(card: card)
                )
            case let .show(options):
                let card = try await showCard(id: options.cardID)
                return try .success(
                    requestID: request.requestID,
                    encoding: CardMutationPayload(card: card)
                )
            case let .hide(options):
                try await hide(options.selector)
                return .success(requestID: request.requestID)
            case let .update(options):
                try await updateMarkdown(id: options.cardID, markdown: options.markdown)
                guard let card = cards[options.cardID] else { throw AgentUIError.cardNotFound(options.cardID) }
                return try .success(requestID: request.requestID, encoding: CardMutationPayload(card: card))
            case let .list(options):
                let listed = cards.values
                    .filter { options.includeHidden || $0.isVisible }
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .map(CardSummary.init(card:))
                return try .success(
                    requestID: request.requestID,
                    encoding: CardListPayload(cards: listed, appearance: appearanceController.mode)
                )
            case let .delete(options):
                try await deleteCard(id: options.cardID, force: options.force)
                return .success(requestID: request.requestID)
            case let .setAppearance(mode):
                setAppearance(mode)
                return .success(requestID: request.requestID)
            case .quit:
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { NSApp.terminate(nil) }
                return .success(requestID: request.requestID)
            }
        } catch {
            return .failure(requestID: request.requestID, code: "command_failed", message: error.localizedDescription)
        }
    }

    private func hide(_ selector: CardSelector) async throws {
        switch selector {
        case let .card(id):
            try await hideCard(id: id)
        case .all:
            for id in cards.keys where cards[id]?.isVisible == true {
                try await hideCard(id: id)
            }
        }
    }

    private func refreshAuxiliarySnapshots(excluding source: EditorSourceID? = nil) {
        let snapshot = persistentCardsSnapshot()
        commandCenterWindowController?.applySnapshot(snapshot)
        libraryWindowController?.applySnapshot(
            snapshot,
            revisions: documentCoordinator.snapshot(),
            excluding: source
        )
    }

    private func persistentCardsSnapshot() -> [CardRecord] {
        cards.values.filter { !transientCardIDs.contains($0.id) }
    }

    private func applyLocalMenuShortcuts() {
        applyShortcut(KeyboardShortcuts.getShortcut(for: .cardLibrary), to: libraryMenuItem)
        applyShortcut(KeyboardShortcuts.getShortcut(for: .settings), to: settingsMenuItem)
    }

    private func applyShortcut(
        _ shortcut: KeyboardShortcuts.Shortcut?,
        to item: NSMenuItem?
    ) {
        guard let item else { return }
        guard let shortcut,
              let key = shortcut.nsMenuItemKeyEquivalent,
              !key.isEmpty
        else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = shortcut.modifiers.intersection([
            .command,
            .option,
            .control,
            .shift,
        ])
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    @objc private func createNewCardFromMenu(_ sender: Any?) { createNewCard() }

    @objc private func showLibrary(_ sender: Any?) {
        interfacePresence.willShow(.cardLibrary)
        libraryWindowController?.applySnapshot(
            persistentCardsSnapshot(),
            revisions: documentCoordinator.snapshot()
        )
        libraryWindowController?.showLibrary()
    }

    @objc private func showSettings(_ sender: Any?) {
        interfacePresence.willShow(.settings)
        settingsWindowController?.showSettings()
    }

    @objc private func installCLI(_ sender: Any?) {
        do {
            let source = Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("mdcard")
            guard FileManager.default.isExecutableFile(atPath: source.path) else {
                throw AgentUIError.cliNotBundled
            }
            let destinationDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin", isDirectory: true)
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            let destination = destinationDirectory.appendingPathComponent("mdcard")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            let alert = NSAlert()
            alert.messageText = "CLI Installed"
            alert.informativeText = "Installed mdcard to ~/.local/bin/mdcard."
            alert.runModal()
        } catch {
            presentError(error)
        }
    }

    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

    private func withSerializedMutation<T>(
        _ operation: () async throws -> T
    ) async rethrows -> T {
        await mutationGate.acquire()
        do {
            let value = try await operation()
            await mutationGate.release()
            return value
        } catch {
            await mutationGate.release()
            throw error
        }
    }
}

private actor AgentMutationGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            locked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

private actor PersistenceErrorState {
    private var message: String?

    func record(_ message: String) {
        if self.message == nil {
            self.message = message
        }
    }

    func current() -> String? {
        message
    }
}

private enum AgentUIError: LocalizedError {
    case cardNotFound(UUID)
    case protectedCard
    case cliNotBundled
    case persistenceFailed(String)

    var errorDescription: String? {
        switch self {
        case let .cardNotFound(id): "Card \(id.uuidString) was not found."
        case .protectedCard: "Use --force to delete a visible card."
        case .cliNotBundled: "The mdcard helper is not present in this application bundle."
        case let .persistenceFailed(message): "Markdown Card could not save the latest changes: \(message)"
        }
    }
}
