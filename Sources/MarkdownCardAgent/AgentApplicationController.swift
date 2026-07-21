import AppKit
import KeyboardShortcuts
import MarkdownCardCore
import ServiceManagement
import UniformTypeIdentifiers

struct MarkdownFileMenuState: Equatable {
    let activeCardID: UUID?
    let binding: CardFileBinding?

    var canSave: Bool { activeCardID != nil }
    var canSaveAs: Bool { activeCardID != nil }
    var isFileBound: Bool { binding != nil }
}

@MainActor
final class AgentApplicationController: NSObject, AppearanceConsumer, NSMenuItemValidation {
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
    private let placementPreferences: CardPlacementPreferences
    private var persistenceTail: Task<Void, Never>?
    private var persistenceGeneration = 0
    private var pendingMarkdownPersistence: [UUID: Task<Void, Never>] = [:]
    private let persistenceErrorState = PersistenceErrorState()
    private let mutationGate = AgentMutationGate()
    private let documentCoordinator = CardDocumentCoordinator()
    private let externalMarkdownService: ExternalMarkdownDocumentService
    private let fileBindingStore: CardFileBindingStore
    private let cardVersionStore: CardVersionStore
    private let seriesOrderStore: CardSeriesOrderStore
    private let tagPreferencesStore: TagCatalogPreferencesStore
    private let tagManagementJournal: TagManagementTransactionJournal
    private let seriesExportService = CardSeriesExportService()
    private var libraryMenuItem: NSMenuItem?
    private var settingsMenuItem: NSMenuItem?
    private var foldMenuItem: NSMenuItem?
    private var foldedCardStackWindowController: FoldedCardStackWindowController?
    private var foldSession: FoldSession?
    private var foldAnimationGeneration = 0
    private var systemUnavailableReasons: Set<SystemUnavailableReason> = []
    private var hasStarted = false
    private var isSeriesNavigationCommitInFlight = false
    private var deferredSeriesMutations: [DeferredSeriesMutation] = []
    private var deferredSeriesMutationBatches: [DeferredSeriesMutationBatch] = []
    private var isDeferredSeriesReplayRunning = false
    private var isApplyingDeferredSeriesMutation = false
    private var openMarkdownPanel: NSOpenPanel?
    private var saveMarkdownPanel: NSSavePanel?
    private var fileOperationCardIDs: Set<UUID> = []
    private var markdownShortcutFocusGuard: MarkdownFocusedGlobalShortcutGuard?
    private var markdownEditorOwnsShortcutPriority = false
    private var tagManagementRecoveryState = TagManagementRecoveryState.ready

    private enum FoldTrigger: Equatable {
        case manual
        case system
    }

    private enum SystemUnavailableReason: Hashable {
        case session
        case screens
        case system
        case lock
    }

    private struct FoldedCardWindowSnapshot {
        var cardID: UUID
        var frame: NSRect
        var screenID: String?
        var zOrder: Int
        var wasKey: Bool
    }

    private struct FoldSession {
        var snapshots: [FoldedCardWindowSnapshot]
        var keyCardID: UUID?
        var preferredScreenID: String?
    }

    private enum DeferredSeriesMutation {
        case markdown(UUID, String, UInt64, EditorSourceID)
        case tag(UUID, String, String, UInt64, EditorSourceID)
        case removeTag(UUID, String)
        case frame(UUID, WindowFrame, String?)
        case layout(UUID, CardLayoutMode, CustomCardLayout?)
    }

    private struct DeferredSeriesMutationBatch {
        let mutations: [DeferredSeriesMutation]
        let tagOperation: TagManagementOperation?
    }

    private var shouldDeferSeriesMutation: Bool {
        isSeriesNavigationCommitInFlight
            || (isDeferredSeriesReplayRunning && !isApplyingDeferredSeriesMutation)
    }

    private enum TagManagementRecoveryState: Equatable {
        case ready
        case recoveryRequired(String)
    }

    private struct ActiveSeriesContext {
        let card: CardRecord
        let tag: CardTag
        let window: NSWindow?
    }

    static let lastActiveCardDefaultsKey = "lastActiveCardID"

    var isFolded: Bool { foldSession != nil }
    var foldedCardCount: Int { isFolded ? cards.values.filter(\.isVisible).count : 0 }
    var isSystemUnavailable: Bool { !systemUnavailableReasons.isEmpty }
    func cardWindowForTesting(_ id: UUID) -> NSWindow? { panels[id]?.window }
    var isTagManagementRecoveryRequiredForTesting: Bool {
        if case .recoveryRequired = tagManagementRecoveryState { return true }
        return false
    }
    private var suppressesCardPresentation: Bool {
        isFolded || (!systemUnavailableReasons.isEmpty
            && FoldPreferences.foldCardsWhenMacLocks(in: defaults))
    }

    init(
        repository: any CardRepository,
        appearanceController: AppearanceController = AppearanceController(),
        defaults: UserDefaults = .standard,
        externalMarkdownService: ExternalMarkdownDocumentService = ExternalMarkdownDocumentService(),
        fileBindingStore: CardFileBindingStore? = nil,
        cardVersionStore: CardVersionStore? = nil,
        seriesOrderStore: CardSeriesOrderStore? = nil,
        tagPreferencesStore: TagCatalogPreferencesStore? = nil,
        tagManagementJournal: TagManagementTransactionJournal? = nil
    ) {
        self.repository = repository
        self.appearanceController = appearanceController
        self.defaults = defaults
        self.externalMarkdownService = externalMarkdownService
        self.fileBindingStore = fileBindingStore ?? CardFileBindingStore(defaults: defaults)
        self.cardVersionStore = cardVersionStore ?? Self.defaultVersionStore(for: repository)
        self.seriesOrderStore = seriesOrderStore ?? CardSeriesOrderStore(defaults: defaults)
        self.tagPreferencesStore = tagPreferencesStore
            ?? TagCatalogPreferencesStore(defaults: defaults)
        self.tagManagementJournal = tagManagementJournal
            ?? Self.defaultTagManagementJournal(for: repository)
        placementPreferences = CardPlacementPreferences(defaults: defaults)
        super.init()
        appearanceController.register(self)
    }

    private static func defaultVersionStore(for repository: any CardRepository) -> CardVersionStore {
        let storeURL: URL?
        if let swiftDataRepository = repository as? SwiftDataCardRepository {
            storeURL = swiftDataRepository.storeURL
        } else if let jsonRepository = repository as? JSONCardRepository {
            storeURL = jsonRepository.fileURL
        } else {
            storeURL = nil
        }
        guard let storeURL else { return CardVersionStore() }
        return CardVersionStore(
            rootURL: storeURL.deletingLastPathComponent()
                .appendingPathComponent("Versions", isDirectory: true)
        )
    }

    private static func defaultTagManagementJournal(
        for repository: any CardRepository
    ) -> TagManagementTransactionJournal {
        let storeURL: URL?
        if let swiftDataRepository = repository as? SwiftDataCardRepository {
            storeURL = swiftDataRepository.storeURL
        } else if let jsonRepository = repository as? JSONCardRepository {
            storeURL = jsonRepository.fileURL
        } else {
            storeURL = nil
        }
        let journalURL: URL
        if let storeURL {
            journalURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent(TagManagementTransactionJournal.fileName)
        } else {
            // In-memory and probe repositories do not have a stable store to
            // recover across launches. Keep their default journal isolated so
            // tests can never consume the production application's journal.
            journalURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "markdown-card-tag-management-\(UUID().uuidString).json"
                )
        }
        return TagManagementTransactionJournal(fileURL: journalURL)
    }

    func start() async throws {
        try await recoverPendingTagManagementTransaction()
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

        hasStarted = true
        if !systemUnavailableReasons.isEmpty,
           FoldPreferences.foldCardsWhenMacLocks(in: defaults)
        {
            foldAllCards(trigger: .system, animated: false)
        } else {
            let startupScreen = currentScreen()
            for card in cards.values where card.isVisible {
                let panel = panelController(for: card)
                let presentation = Self.startupPresentation(
                    for: card,
                    currentScreen: startupScreen
                )
                panel.show(
                    on: presentation.screen,
                    centerIfNeeded: presentation.centerIfNeeded,
                    activate: false
                )
            }
        }
        updateFoldPresentationState()
    }

    func stop() {
        hasStarted = false
        markdownShortcutFocusGuard?.stop()
        markdownShortcutFocusGuard = nil
        foldAnimationGeneration &+= 1
        foldedCardStackWindowController?.hide(animated: false)
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

    func handleSystemSleepEvent(_ event: SystemSleepEventMonitor.Event) {
        switch event {
        case .sessionDidResignActive:
            beginSystemUnavailable(.session)
        case .sessionDidBecomeActive:
            endSystemUnavailable(.session)
        case .screensDidSleep:
            beginSystemUnavailable(.screens)
        case .screensDidWake:
            endSystemUnavailable(.screens)
        case .willSleep:
            beginSystemUnavailable(.system)
        case .didWake:
            endSystemUnavailable(.system)
        case .screenLocked:
            beginSystemUnavailable(.lock)
        case .screenUnlocked:
            endSystemUnavailable(.lock)
        }
    }

    func foldAllCards(animated: Bool = true) {
        foldAllCards(trigger: .manual, animated: animated)
    }

    func restoreFoldedCards(animated: Bool = true) {
        guard let session = foldSession else { return }
        guard systemUnavailableReasons.isEmpty else {
            NSSound.beep()
            return
        }

        foldAnimationGeneration &+= 1
        let generation = foldAnimationGeneration
        foldSession = nil
        updateFoldPresentationState()
        foldedCardStackWindowController?.hide(animated: animated)

        let visibleIDs = Set(cards.values.lazy.filter(\.isVisible).map(\.id))
        let snapshots = session.snapshots.filter { visibleIDs.contains($0.cardID) }
        let snapshottedIDs = Set(snapshots.map(\.cardID))
        let preferredScreen = screen(named: session.preferredScreenID) ?? currentScreen()

        // Cards created or explicitly shown while folded are restored behind
        // the original z-order, then participate in the same opacity reveal.
        let queuedCards = cards.values
            .filter { $0.isVisible && !snapshottedIDs.contains($0.id) }
            .sorted { $0.updatedAt < $1.updatedAt }
        var revealedWindows: [NSWindow] = []
        for card in queuedCards {
            let panel = panelController(for: card)
            if let window = panel.window {
                window.alphaValue = animated ? 0 : 1
            }
            panel.show(
                on: Self.presentationScreen(for: card, currentScreen: preferredScreen),
                centerIfNeeded: card.windowFrame == nil,
                activate: false
            )
            if let window = panel.window { revealedWindows.append(window) }
        }

        // `NSApp.orderedWindows` is front-to-back. Ordering the captured list
        // back-to-front reconstructs it without moving any window frame.
        for snapshot in snapshots.sorted(by: { $0.zOrder > $1.zOrder }) {
            guard let card = cards[snapshot.cardID], card.isVisible else { continue }
            let panel = panelController(for: card)
            guard let window = panel.window else { continue }
            let targetFrame = restoredFrame(for: snapshot, window: window)
            window.setFrame(targetFrame, display: false)
            window.alphaValue = animated ? 0 : 1
            panel.show(activate: false)
            window.setFrame(targetFrame, display: false)
            window.orderFront(nil)
            revealedWindows.append(window)
        }

        let keyCardID = session.keyCardID.flatMap { visibleIDs.contains($0) ? $0 : nil }
            ?? recentCardID().flatMap { visibleIDs.contains($0) ? $0 : nil }
            ?? snapshots.sorted(by: { $0.zOrder < $1.zOrder }).first?.cardID
            ?? queuedCards.last?.id
        if let keyCardID, let keyPanel = panels[keyCardID] {
            keyPanel.show(activate: true)
        }

        let duration = foldTransitionDuration(animated: animated)
        guard duration > 0 else {
            revealedWindows.forEach { $0.alphaValue = 1 }
            return
        }
        let revealedCardIDs = queuedCards.map(\.id) + snapshots.map(\.cardID)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for window in revealedWindows {
                window.animator().alphaValue = 1
            }
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, foldAnimationGeneration == generation, !isFolded else { return }
                for id in revealedCardIDs {
                    panels[id]?.window?.alphaValue = 1
                }
            }
        }
    }

    private func toggleFoldedCards() {
        if isFolded {
            restoreFoldedCards(animated: true)
        } else {
            foldAllCards(trigger: .manual, animated: true)
        }
    }

    private func foldAllCards(trigger: FoldTrigger, animated: Bool) {
        if foldSession != nil {
            if trigger == .system {
                forceFoldedPresentationHidden()
            }
            return
        }

        let logicallyVisible = cards.values.filter(\.isVisible)
        guard !logicallyVisible.isEmpty else { return }

        let orderedWindowIndices = Dictionary(
            uniqueKeysWithValues: NSApp.orderedWindows.enumerated().map {
                (ObjectIdentifier($0.element), $0.offset)
            }
        )
        let fallbackCards = logicallyVisible.sorted { $0.updatedAt > $1.updatedAt }
        var snapshots: [FoldedCardWindowSnapshot] = []
        for (fallbackIndex, card) in fallbackCards.enumerated() {
            let panel = panelController(for: card)
            panel.flushPendingChanges()
            guard let window = panel.window else { continue }
            snapshots.append(FoldedCardWindowSnapshot(
                cardID: card.id,
                frame: window.frame,
                screenID: window.screen?.localizedName ?? card.screenID,
                zOrder: orderedWindowIndices[ObjectIdentifier(window)]
                    ?? orderedWindowIndices.count + fallbackIndex,
                wasKey: window.isKeyWindow
            ))
        }
        guard !snapshots.isEmpty else { return }

        let storedActiveID = recentCardID().flatMap { id in
            snapshots.contains(where: { $0.cardID == id }) ? id : nil
        }
        let keyCardID = snapshots.first(where: \.wasKey)?.cardID ?? storedActiveID
        let preferredScreenID = snapshots.first(where: { $0.cardID == keyCardID })?.screenID
            ?? snapshots.sorted(by: { $0.zOrder < $1.zOrder }).first?.screenID
        foldSession = FoldSession(
            snapshots: snapshots,
            keyCardID: keyCardID,
            preferredScreenID: preferredScreenID
        )

        foldAnimationGeneration &+= 1
        let generation = foldAnimationGeneration
        commandCenterWindowController?.close(animated: trigger == .manual && animated)
        updateFoldPresentationState()

        if trigger == .system || !systemUnavailableReasons.isEmpty {
            forceFoldedPresentationHidden()
            return
        }

        let preferredScreen = screen(named: preferredScreenID) ?? currentScreen()
        foldedCardStackWindowController?.show(
            count: foldedCardCount,
            on: preferredScreen,
            animated: animated
        )

        let windows = snapshots.compactMap { panels[$0.cardID]?.window }
        let foldedCardIDs = snapshots.map(\.cardID)
        let duration = foldTransitionDuration(animated: animated)
        guard duration > 0 else {
            for id in foldedCardIDs {
                panels[id]?.hide(flushingPendingChanges: false)
                panels[id]?.window?.alphaValue = 1
            }
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windows {
                window.animator().alphaValue = 0
            }
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, foldAnimationGeneration == generation, isFolded else { return }
                for id in foldedCardIDs {
                    panels[id]?.hide(flushingPendingChanges: false)
                    panels[id]?.window?.alphaValue = 1
                }
            }
        }
    }

    private func forceFoldedPresentationHidden() {
        foldAnimationGeneration &+= 1
        for card in cards.values where card.isVisible {
            panels[card.id]?.window?.alphaValue = 1
            panels[card.id]?.hide(flushingPendingChanges: false)
        }
        foldedCardStackWindowController?.hide(animated: false)
    }

    private func beginSystemUnavailable(_ reason: SystemUnavailableReason) {
        let wasInserted = systemUnavailableReasons.insert(reason).inserted
        guard wasInserted else { return }

        if isFolded {
            commandCenterWindowController?.close(animated: false)
            forceFoldedPresentationHidden()
        } else if hasStarted, FoldPreferences.foldCardsWhenMacLocks(in: defaults) {
            commandCenterWindowController?.close(animated: false)
            foldAllCards(trigger: .system, animated: false)
        }
        updateFoldPresentationState()
    }

    private func endSystemUnavailable(_ reason: SystemUnavailableReason) {
        guard systemUnavailableReasons.remove(reason) != nil else { return }
        guard systemUnavailableReasons.isEmpty else { return }
        foldedCardStackWindowController?.constrainToAvailableScreens()
        if isFolded {
            foldedCardStackWindowController?.updateCount(foldedCardCount)
            foldedCardStackWindowController?.reveal()
        }
        updateFoldPresentationState()
    }

    private func removeCardFromFoldSession(_ id: UUID) {
        guard var session = foldSession else { return }
        session.snapshots.removeAll { $0.cardID == id }
        if session.keyCardID == id { session.keyCardID = nil }
        foldSession = session
        reconcileFoldSession()
    }

    private func reconcileFoldSession() {
        guard foldSession != nil else { return }
        let count = cards.values.lazy.filter(\.isVisible).count
        guard count > 0 else {
            foldAnimationGeneration &+= 1
            foldSession = nil
            foldedCardStackWindowController?.hide(animated: true)
            updateFoldPresentationState()
            return
        }
        foldedCardStackWindowController?.updateCount(count)
        updateFoldPresentationState()
    }

    private func updateFoldPresentationState() {
        foldMenuItem?.title = isFolded ? "Restore All Cards" : "Fold All Cards"
        foldMenuItem?.isEnabled = !(isFolded && !systemUnavailableReasons.isEmpty)
        commandCenterWindowController?.setFoldedState(isFolded)
        foldedCardStackWindowController?.updateCount(foldedCardCount)
        if !isFolded {
            foldedCardStackWindowController?.hide(animated: false)
        }
    }

    private func screen(named name: String?) -> NSScreen? {
        guard let name else { return nil }
        return NSScreen.screens.first { $0.localizedName == name }
    }

    private func restoredFrame(
        for snapshot: FoldedCardWindowSnapshot,
        window: NSWindow
    ) -> NSRect {
        let targetScreen = screen(named: snapshot.screenID)
            ?? NSScreen.screens.first { $0.frame.intersects(snapshot.frame) }
            ?? NSScreen.main
        guard let targetScreen else { return snapshot.frame }
        return window.constrainFrameRect(snapshot.frame, to: targetScreen)
    }

    private func foldTransitionDuration(animated: Bool) -> TimeInterval {
        guard animated else { return 0 }
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.06 : 0.13
    }

    func createNewCard() {
        Task { [weak self] in
            guard let self else { return }
            _ = try? await withSerializedMutation {
                _ = try? await createIndependentCard(persistEmpty: false)
            }
        }
    }

    private func loadCards() async throws {
        _ = try await repository.deleteLegacyQuickCards()
        let stored = try await repository.allCards()
        var recovered: [CardRecord] = []
        recovered.reserveCapacity(stored.count)
        for var card in stored {
            if let snapshot = try? cardVersionStore.recoverableSnapshot(for: card) {
                card.titleOverride = snapshot.titleOverride
                card.updateMarkdown(snapshot.markdown, at: snapshot.capturedAt)
                card = try await repository.upsert(card)
            }
            recovered.append(card)
        }
        cards = Dictionary(uniqueKeysWithValues: recovered.map { ($0.id, $0) })
        documentCoordinator.register(recovered)

        if let storedID = defaults.string(forKey: Self.lastActiveCardDefaultsKey)
            .flatMap(UUID.init(uuidString:)), cards[storedID] == nil
        {
            defaults.removeObject(forKey: Self.lastActiveCardDefaultsKey)
        }
    }

    private func configureShortcut() {
        KeyboardShortcuts.onKeyDown(for: .commandCenter) { [weak self] in
            guard let self,
                  Self.shouldExecuteGlobalShortcut(
                    KeyboardShortcuts.getShortcut(for: .commandCenter),
                    editorFocused: markdownEditorOwnsShortcutPriority
                  )
            else { return }
            toggleCommandCenter()
        }
        KeyboardShortcuts.onKeyDown(for: .newCard) { [weak self] in
            guard let self,
                  Self.shouldExecuteGlobalShortcut(
                    KeyboardShortcuts.getShortcut(for: .newCard),
                    editorFocused: markdownEditorOwnsShortcutPriority
                  )
            else { return }
            createNewCard()
        }

        let focusGuard = MarkdownFocusedGlobalShortcutGuard(
            onEditorFocusChange: { [weak self] isFocused in
                guard let self else { return }
                markdownEditorOwnsShortcutPriority = isFocused
                applyLocalMenuShortcuts()
            }
        )
        markdownShortcutFocusGuard = focusGuard
        focusGuard.start()
    }

    static func shouldExecuteGlobalShortcut(
        _ shortcut: KeyboardShortcuts.Shortcut?,
        editorFocused: Bool
    ) -> Bool {
        !MarkdownShortcutContract.takesPriority(
            over: shortcut,
            editorFocused: editorFocused
        )
    }

    private func configureAuxiliaryWindows() {
        let settings = SettingsCenterWindowController(
            appearanceController: appearanceController,
            placementPreferences: placementPreferences,
            defaults: defaults,
            presentationMode: .embedded
        )
        settings.onAppearanceChange = { [weak self] mode in
            self?.setAppearance(mode)
        }
        settings.onLaunchAtLoginChange = { [weak self] enabled in
            self?.setLaunchAtLogin(enabled)
        }
        settings.onInstallCLI = { [weak self] in self?.installCLI(nil) }
        settings.onShortcutChange = { [weak self] in
            self?.markdownShortcutFocusGuard?.refresh()
            self?.applyLocalMenuShortcuts()
        }
        settings.onFoldCardsWhenMacLocksChange = { [weak self] _ in
            // This preference applies to future system events. Changing it
            // never restores or folds the current presentation implicitly.
            self?.updateFoldPresentationState()
        }
        settingsWindowController = settings

        let foldedStack = FoldedCardStackWindowController(
            appearanceController: appearanceController,
            defaults: defaults
        )
        foldedStack.onRestore = { [weak self] in
            self?.restoreFoldedCards(animated: true)
        }
        foldedCardStackWindowController = foldedStack

        let library = CardLibraryWindowController(
            appearanceController: appearanceController,
            defaults: defaults,
            tagPreferencesStore: tagPreferencesStore,
            presentationMode: .embedded
        )
        library.documentRootURLForCard = { [weak self] cardID in
            self?.fileBindingStore.documentRootURL(for: cardID)
        }
        library.seriesOrderByTagID = { [weak self] in
            self?.seriesOrderStore.allOrders() ?? [:]
        }
        library.onOpenCard = { [weak self] id in
            Task { [weak self] in
                guard let self else { return }
                _ = try? await withSerializedMutation { try? await showCard(id: id) }
            }
        }
        library.onDeleteCard = { [weak self] id in
            Task { [weak self] in
                guard let self else { return }
                _ = try? await withSerializedMutation {
                    try? await deleteCard(id: id, force: true)
                }
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
        library.onTagCommandSubmitted = { [weak self] id, name, markdown, revision, source in
            self?.stageTagCommand(
                id: id,
                tagName: name,
                markdown: markdown,
                incomingRevision: revision,
                source: source
            )
        }
        library.onTagSelectionChange = { [weak self] id, tagID in
            guard let self else { return }
            if let tagID {
                activateTag(cardID: id, tagID: tagID)
            } else {
                deactivateTag(cardID: id)
            }
        }
        library.onRemoveTag = { [weak self] id, tagID in
            self?.removeTag(cardID: id, tagID: tagID)
        }
        library.onRenameTag = { [weak self] sourceID, name in
            self?.renameTagGlobally(sourceID: sourceID, name: name)
        }
        library.onMergeTag = { [weak self] sourceID, targetID in
            self?.mergeTagGlobally(sourceID: sourceID, targetID: targetID)
        }
        library.onDeleteTag = { [weak self] tagID in
            self?.deleteTagGlobally(tagID: tagID)
        }
        library.onTagPreferenceError = { [weak self] error in
            self?.presentError(error)
        }
        library.onRequestSaveAs = { [weak self] cardID in
            self?.presentSaveMarkdownPanel(for: cardID)
        }
        libraryWindowController = library

        let commandCenter = CommandCenterWindowController(
            appearanceController: appearanceController,
            defaults: defaults
        )
        commandCenter.onOpenCard = { [weak self] id in
            Task { [weak self] in
                guard let self else { return }
                _ = try? await withSerializedMutation { try? await showCard(id: id) }
            }
        }
        commandCenter.onExecuteCommand = { [weak self] command in
            self?.executeCommandCenterCommand(command)
        }
        commandCenter.configureWorkspace(library: library, settings: settings)
        commandCenter.setFoldedState(isFolded)
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
        case .toggleFoldedCards:
            toggleFoldedCards()
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
        fileItem.submenu = makeFileMenu()
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

        let seriesItem = NSMenuItem()
        let seriesMenu = NSMenu(title: "Series")
        seriesMenu.addItem(menuItem(
            "Move Chapter Earlier",
            action: #selector(moveSeriesChapterEarlier(_:)),
            key: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)),
            modifiers: [.command, .control, .option]
        ))
        seriesMenu.addItem(menuItem(
            "Move Chapter Later",
            action: #selector(moveSeriesChapterLater(_:)),
            key: String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)),
            modifiers: [.command, .control, .option]
        ))
        seriesMenu.addItem(.separator())
        seriesMenu.addItem(menuItem(
            "Validate Series Links…",
            action: #selector(validateActiveSeriesLinks(_:))
        ))
        seriesMenu.addItem(menuItem(
            "Export Series…",
            action: #selector(exportActiveSeries(_:))
        ))
        seriesItem.submenu = seriesMenu
        main.addItem(seriesItem)

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
        let fold = menuItem("Fold All Cards", action: #selector(toggleFoldedCardsFromMenu(_:)))
        let library = menuItem("Card Library", action: #selector(showLibrary(_:)))
        let settings = menuItem("Settings…", action: #selector(showSettings(_:)))
        foldMenuItem = fold
        libraryMenuItem = library
        settingsMenuItem = settings
        windowMenu.addItem(fold)
        windowMenu.addItem(.separator())
        windowMenu.addItem(library)
        windowMenu.addItem(settings)
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        applyLocalMenuShortcuts()
    }

    func makeFileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(menuItem("New Card", action: #selector(createNewCardFromMenu(_:)), key: "n"))
        menu.addItem(menuItem("Open Markdown…", action: #selector(openMarkdownFromMenu(_:)), key: "o"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Save", action: #selector(saveMarkdownFromMenu(_:)), key: "s"))
        menu.addItem(menuItem(
            "Save As…",
            action: #selector(saveMarkdownAsFromMenu(_:)),
            key: "s",
            modifiers: [.command, .option]
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            "Version History…",
            action: #selector(showVersionHistory(_:))
        ))
        return menu
    }

    func currentFileMenuState() -> MarkdownFileMenuState {
        fileMenuState(forActiveCardID: activeCardIDForFileOperation())
    }

    func fileMenuState(forActiveCardID candidate: UUID?) -> MarkdownFileMenuState {
        let activeCardID = candidate.flatMap { cards[$0] == nil ? nil : $0 }
        return MarkdownFileMenuState(
            activeCardID: activeCardID,
            binding: activeCardID.flatMap { fileBindingStore.binding(for: $0) }
        )
    }

    static func localMarkdownMatchesReloadSnapshot(
        _ markdown: String,
        expectedDigest: String
    ) -> Bool {
        ExternalMarkdownDocumentService.digest(Data(markdown.utf8)) == expectedDigest
    }

    static func canApplyPortableSaveAsResult(
        currentMarkdown: String,
        exportedMarkdown: String,
        currentRevision: UInt64,
        exportedRevision: UInt64,
        currentBinding: CardFileBinding?,
        originalBinding: CardFileBinding?
    ) -> Bool {
        currentRevision == exportedRevision
            && currentMarkdown == exportedMarkdown
            && currentBinding == originalBinding
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openMarkdownFromMenu(_:)):
            return openMarkdownPanel == nil
        case #selector(saveMarkdownFromMenu(_:)):
            let state = currentFileMenuState()
            return state.canSave
                && saveMarkdownPanel == nil
                && state.activeCardID.map { !fileOperationCardIDs.contains($0) } == true
        case #selector(saveMarkdownAsFromMenu(_:)):
            let state = currentFileMenuState()
            return state.canSaveAs
                && saveMarkdownPanel == nil
                && state.activeCardID.map { !fileOperationCardIDs.contains($0) } == true
        case #selector(showVersionHistory(_:)):
            return activeCardIDForFileOperation() != nil
        case #selector(moveSeriesChapterEarlier(_:)):
            return canMoveActiveSeriesChapter(.earlier)
        case #selector(moveSeriesChapterLater(_:)):
            return canMoveActiveSeriesChapter(.later)
        case #selector(validateActiveSeriesLinks(_:)):
            return activeSeriesContext(promptForTag: false) != nil
        case #selector(exportActiveSeries(_:)):
            return !seriesExportService.isBusy
                && activeSeriesContext(promptForTag: false) != nil
        default:
            return true
        }
    }

    private func activeCardIDForFileOperation() -> UUID? {
        guard let keyWindow = NSApp.keyWindow else { return nil }
        if let keyCardID = panels.first(where: { $0.value.window === keyWindow })?.key,
           cards[keyCardID] != nil {
            return keyCardID
        }
        if commandCenterWindowController?.window === keyWindow,
           let selectedCardID = commandCenterWindowController?.activeLibraryCardSelection(),
           cards[selectedCardID] != nil {
            return selectedCardID
        }
        return nil
    }

    private func panelController(for card: CardRecord) -> CardPanelController {
        let fileBinding = fileBindingStore.binding(for: card.id)
        if let existing = panels[card.id] {
            existing.setFileBinding(fileBinding)
            existing.update(card: card, revision: documentCoordinator.revision(for: card.id))
            applySeriesContext(to: existing, animated: false)
            return existing
        }
        let controller = CardPanelController(
            card: card,
            appearanceController: appearanceController,
            placementPreferences: placementPreferences,
            fileBinding: fileBinding
        )
        controller.onMarkdownChange = { [weak self] id, markdown, revision, source in
            self?.stageMarkdownUpdate(
                id: id,
                markdown: markdown,
                incomingRevision: revision,
                source: source
            )
        }
        controller.onTagCommandSubmitted = { [weak self] id, name, markdown, revision, source in
            self?.stageTagCommand(
                id: id,
                tagName: name,
                markdown: markdown,
                incomingRevision: revision,
                source: source
            )
        }
        controller.onActivateTag = { [weak self] id, tagID in
            self?.activateTag(cardID: id, tagID: tagID)
        }
        controller.onRemoveTag = { [weak self] id, tagID in
            self?.removeTag(cardID: id, tagID: tagID)
        }
        controller.onNavigateSeries = { [weak self] id, tagID, direction in
            Task { [weak self] in
                guard let self else { return }
                _ = try? await withSerializedMutation {
                    try? await navigateSeries(from: id, tagID: tagID, direction: direction)
                }
            }
        }
        controller.onRequestHide = { [weak self] id in
            Task { [weak self] in
                guard let self else { return }
                _ = try? await withSerializedMutation { try? await hideCard(id: id) }
            }
        }
        controller.onCreateCard = { [weak self] in self?.createNewCard() }
        controller.onFrameChange = { [weak self] id, frame, screenID in
            self?.stageFrameUpdate(id: id, frame: frame, screenID: screenID)
        }
        controller.onLayoutChange = { [weak self] id, mode, custom in
            self?.stageLayoutUpdate(id: id, mode: mode, custom: custom)
        }
        controller.onRequestPresetPlacement = { [weak self] id in
            self?.moveCardToPresetPlacement(id: id)
        }
        controller.onRequestFoldAllCards = { [weak self] in
            self?.foldAllCards(animated: true)
        }
        controller.onRequestSaveAs = { [weak self] cardID in
            self?.presentSaveMarkdownPanel(for: cardID)
        }
        controller.onBecameKey = { [weak self] id in self?.markCardActive(id) }
        restoreFrame(of: card, to: controller.window)
        controller.update(card: card, revision: documentCoordinator.revision(for: card.id))
        applySeriesContext(to: controller, animated: false)
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

    private func moveCardToPresetPlacement(id: UUID) {
        guard let controller = panels[id],
              let targetWindow = controller.window,
              targetWindow.isVisible,
              targetWindow.isKeyWindow,
              let targetScreen = targetWindow.screen
        else { return }

        let occupiedFrames = panels.compactMap { candidateID, candidate -> NSRect? in
            guard candidateID != id,
                  let candidateWindow = candidate.window,
                  candidateWindow.isVisible,
                  candidateWindow.frame.intersects(targetScreen.visibleFrame)
            else { return nil }
            return candidateWindow.frame
        }
        controller.moveToPresetPlacement(avoiding: occupiedFrames)
    }

    @discardableResult
    func createIndependentCard(
        markdown: String = "",
        title: String? = nil,
        tags: [CardTag] = [],
        show: Bool = true,
        persistEmpty: Bool = true
    ) async throws -> CardRecord {
        try await flushPendingPersistence()
        var card = CardRecord(
            title: title,
            markdown: markdown,
            isVisible: true,
            layoutMode: .sticky,
            tags: tags
        )
        card.isQuick = false
        cards[card.id] = card
        documentCoordinator.register([card])
        if persistEmpty
            || !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !tags.isEmpty
        {
            card = try await repository.upsert(card)
            cards[card.id] = card
        } else {
            transientCardIDs.insert(card.id)
        }
        let shouldSuppressPresentation = suppressesCardPresentation
        if show {
            let panel = panelController(for: card)
            if !shouldSuppressPresentation {
                panel.show(on: currentScreen(), centerIfNeeded: true)
            }
        }
        markCardActive(card.id)
        if shouldSuppressPresentation, !isFolded {
            foldAllCards(trigger: .system, animated: false)
        } else {
            reconcileFoldSession()
        }
        refreshAuxiliarySnapshots()
        return card
    }

    /// Adds app-owned Tag metadata without routing through the renderer's
    /// `/tag` transaction, which also carries a Markdown revision.
    @discardableResult
    func addTag(id: UUID, name: String) async throws -> CardRecord {
        let tag = canonicalTag(for: try CardTag(name))
        try await flushPendingPersistence()
        guard var card = cards[id] else { throw AgentUIError.cardNotFound(id) }

        // A duplicate is a true no-op: do not touch the timestamp, persist, or
        // refresh any UI snapshots.
        guard card.addTag(tag) else { return card }

        cards[id] = card
        let wasTransient = transientCardIDs.contains(id)

        // Publish the metadata to in-memory state before suspending so editor
        // callbacks that arrive during the repository write retain the Tag in
        // their later Markdown snapshot. Do not overwrite that newer state
        // with the repository's returned pre-callback snapshot.
        _ = try await repository.upsert(card)
        if wasTransient {
            transientCardIDs.remove(id)
        }

        guard let latestCard = cards[id] else {
            throw AgentUIError.cardNotFound(id)
        }
        for panel in panels.values where panel.card.id == id {
            let activeTagID = panel.activeTagID
            panel.applyTagMetadata(
                card: latestCard,
                activeTagID: activeTagID,
                neighbors: activeTagID.flatMap {
                    seriesNeighbors(cardID: id, tagID: $0)
                },
                animated: true
            )
        }
        refreshPanelSeriesContexts(animated: true)
        refreshAuxiliarySnapshots()
        return latestCard
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
        let shouldSuppressPresentation = suppressesCardPresentation
        if !shouldSuppressPresentation {
            panel.show(
                on: Self.presentationScreen(
                    for: card,
                    currentScreen: currentScreen()
                ),
                centerIfNeeded: shouldCenter
            )
        }
        markCardActive(id)
        if shouldSuppressPresentation, !isFolded {
            foldAllCards(trigger: .system, animated: false)
        } else {
            reconcileFoldSession()
        }
        refreshAuxiliarySnapshots()
        return card
    }

    static func presentationScreen(
        for card: CardRecord,
        currentScreen: NSScreen?
    ) -> NSScreen? {
        card.windowFrame == nil ? currentScreen : nil
    }

    static func startupPresentation(
        for card: CardRecord,
        currentScreen: NSScreen?
    ) -> (screen: NSScreen?, centerIfNeeded: Bool) {
        (
            screen: presentationScreen(for: card, currentScreen: currentScreen),
            centerIfNeeded: card.windowFrame == nil
        )
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
            removeCardFromFoldSession(id)
            refreshAuxiliarySnapshots()
            return
        }
        guard var card = cards[id] else { throw AgentUIError.cardNotFound(id) }
        card.isVisible = false
        cards[id] = card
        _ = try await repository.upsert(card)
        panels[id]?.hide()
        removeCardFromFoldSession(id)
        refreshAuxiliarySnapshots()
    }

    private func updateMarkdown(id: UUID, markdown: String) async throws {
        try await flushPendingPersistence()
        guard let previous = cards[id] else { throw AgentUIError.cardNotFound(id) }
        _ = try cardVersionStore.record(previous, capturedAt: Date())
        commitMarkdown(
            id: id,
            markdown: markdown,
            incomingRevision: documentCoordinator.revision(for: id) &+ 1,
            source: .commandLine
        )
        if let card = cards[id] {
            _ = try cardVersionStore.record(card, capturedAt: card.updatedAt)
            _ = try await repository.upsert(card)
        }
    }

    func stageMarkdownUpdate(
        id: UUID,
        markdown: String,
        incomingRevision: UInt64,
        source: EditorSourceID
    ) {
        guard !shouldDeferSeriesMutation else {
            deferredSeriesMutations.append(
                .markdown(id, markdown, incomingRevision, source)
            )
            return
        }
        commitMarkdown(
            id: id,
            markdown: markdown,
            incomingRevision: incomingRevision,
            source: source
        )
        scheduleMarkdownPersistence(for: id)
    }

    func stageTagCommand(
        id: UUID,
        tagName: String,
        markdown: String,
        incomingRevision: UInt64,
        source: EditorSourceID
    ) {
        guard !shouldDeferSeriesMutation else {
            deferredSeriesMutations.append(
                .tag(id, tagName, markdown, incomingRevision, source)
            )
            return
        }
        guard var card = cards[id] else { return }
        let tag: CardTag
        do {
            tag = canonicalTag(for: try CardTag(tagName))
        } catch {
            NSSound.beep()
            return
        }

        let markdownChanged = markdown != card.markdown
        let isNewTag = !card.tags.contains(where: { $0.id == tag.id })
        guard markdownChanged || isNewTag else { return }

        let transaction = documentCoordinator.accept(
            cardID: id,
            markdown: markdown,
            incomingRevision: incomingRevision,
            source: source
        )
        let timestamp = Date()
        if markdownChanged {
            card.updateMarkdown(markdown, at: timestamp)
        }
        if isNewTag {
            _ = card.addTag(tag, at: timestamp)
        }
        cards[id] = card
        if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !card.tags.isEmpty {
            transientCardIDs.remove(id)
        }

        for panel in panels.values where panel.card.id == id {
            let requestedTagID = panel.activeTagID
            let neighbors = requestedTagID.flatMap {
                seriesNeighbors(cardID: id, tagID: $0)
            }
            if panel.editorSourceID == source || !markdownChanged {
                panel.applyTagMetadata(
                    card: card,
                    activeTagID: requestedTagID,
                    neighbors: neighbors,
                    animated: true
                )
            } else {
                panel.update(card: card, revision: transaction.revision)
                panel.applySeriesContext(
                    activeTagID: requestedTagID,
                    neighbors: neighbors,
                    animated: true
                )
            }
        }
        refreshPanelSeriesContexts(animated: true)
        refreshAuxiliarySnapshots(excluding: source)
        scheduleMarkdownPersistence(for: id)
    }

    private func removeTag(cardID: UUID, tagID: String) {
        guard !shouldDeferSeriesMutation else {
            deferredSeriesMutations.append(.removeTag(cardID, tagID))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await withSerializedMutation {
                    try await performCardTagRemoval(cardID: cardID, tagID: tagID)
                }
            } catch {
                presentError(error)
            }
        }
    }

    private func performCardTagRemoval(cardID: UUID, tagID: String) async throws {
        if case let .recoveryRequired(details) = tagManagementRecoveryState {
            throw AgentUIError.tagManagementRecoveryRequired(details)
        }
        guard !isSeriesNavigationCommitInFlight else {
            throw AgentUIError.tagManagementBusy
        }
        isSeriesNavigationCommitInFlight = true
        libraryWindowController?.setGlobalTagMutationInFlight(true)
        defer {
            isSeriesNavigationCommitInFlight = false
            if case .ready = tagManagementRecoveryState {
                libraryWindowController?.setGlobalTagMutationInFlight(false)
                replayDeferredSeriesMutations()
            }
        }

        try await flushPendingPersistence()
        guard let mutation = CardTagRemovalMutation(
            cards: cards,
            transientCardIDs: transientCardIDs,
            cardID: cardID,
            tagID: tagID
        ) else { return }

        let journalEntry = TagManagementTransactionJournal.Entry(
            previousCards: persistentCardsSnapshot(),
            previousSeries: seriesOrderStore.snapshot(),
            previousPreferences: tagPreferencesStore.snapshot()
        )
        do {
            try await writeTagManagementJournal(journalEntry)
        } catch {
            if await tagManagementJournalHasPendingTransaction() {
                throw markTagManagementRecoveryRequired(error)
            }
            throw error
        }

        do {
            try await repository.replaceAll(with: mutation.persistentCards)
            if let explicitOrder = seriesOrderStore.allOrders()[tagID],
               explicitOrder.isEmpty || explicitOrder.contains(cardID),
               !seriesOrderStore.removeCard(cardID, fromTagID: tagID) {
                throw AgentUIError.tagManagementPersistenceFailed
            }
            try await clearTagManagementJournal()
        } catch let operationError {
            do {
                try await restoreTagManagementState(from: journalEntry)
                try await clearTagManagementJournal()
                tagManagementRecoveryState = .ready
            } catch let rollbackError {
                throw markTagManagementRecoveryRequired(
                    TagManagementRollbackFailure(
                        failures: [
                            "Card Tag removal: \(operationError.localizedDescription)",
                            "Rollback: \(rollbackError.localizedDescription)",
                        ]
                    )
                )
            }
            throw operationError
        }

        cards = mutation.cards
        let card = mutation.updatedCard
        for panel in panels.values where panel.card.id == cardID {
            let resolvedTagID = panel.activeTagID == tagID ? nil : panel.activeTagID
            panel.applyTagMetadata(
                card: card,
                activeTagID: resolvedTagID,
                neighbors: resolvedTagID.flatMap {
                    seriesNeighbors(cardID: cardID, tagID: $0)
                },
                animated: true
            )
        }
        refreshPanelSeriesContexts(animated: true)
        refreshAuxiliarySnapshots()
    }

    private func canonicalTag(for proposed: CardTag) -> CardTag {
        TagCatalogSnapshot(cards: Array(cards.values)).entry(tagID: proposed.id)?.tag
            ?? proposed
    }

    private func renameTagGlobally(sourceID: String, name: String) {
        submitTagManagementOperation { [weak self] in
            guard let self else { return nil }
            let replacement = try CardTag(name)
            let catalog = TagCatalogSnapshot(cards: persistentCardsSnapshot())
            guard catalog.entry(tagID: sourceID) != nil else {
                throw AgentUIError.tagNotFound(sourceID)
            }
            if replacement.id != sourceID,
               let existing = catalog.entry(tagID: replacement.id) {
                return .merge(sourceID: sourceID, target: existing.tag)
            }
            return .rename(sourceID: sourceID, replacement: replacement)
        }
    }

    private func mergeTagGlobally(sourceID: String, targetID: String) {
        submitTagManagementOperation { [weak self] in
            guard let self else { return nil }
            let catalog = TagCatalogSnapshot(cards: persistentCardsSnapshot())
            guard catalog.entry(tagID: sourceID) != nil else {
                throw AgentUIError.tagNotFound(sourceID)
            }
            guard let target = catalog.entry(tagID: targetID), sourceID != targetID else {
                throw AgentUIError.tagNotFound(targetID)
            }
            return .merge(sourceID: sourceID, target: target.tag)
        }
    }

    private func deleteTagGlobally(tagID: String) {
        submitTagManagementOperation { [weak self] in
            guard let self else { return nil }
            let catalog = TagCatalogSnapshot(cards: persistentCardsSnapshot())
            guard catalog.entry(tagID: tagID) != nil else {
                throw AgentUIError.tagNotFound(tagID)
            }
            return .delete(tagID: tagID)
        }
    }

    private func submitTagManagementOperation(
        _ resolve: @escaping @MainActor () throws -> TagManagementOperation?
    ) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await withSerializedMutation {
                    guard let operation = try resolve() else { return }
                    try await performTagManagementOperation(operation)
                }
            } catch {
                presentError(error)
            }
        }
    }

    private func performTagManagementOperation(
        _ operation: TagManagementOperation
    ) async throws {
        if case let .recoveryRequired(details) = tagManagementRecoveryState {
            throw AgentUIError.tagManagementRecoveryRequired(details)
        }
        guard !isSeriesNavigationCommitInFlight else {
            throw AgentUIError.tagManagementBusy
        }
        var committedOperation: TagManagementOperation?
        isSeriesNavigationCommitInFlight = true
        libraryWindowController?.setGlobalTagMutationInFlight(true)
        defer {
            isSeriesNavigationCommitInFlight = false
            if case .ready = tagManagementRecoveryState {
                libraryWindowController?.setGlobalTagMutationInFlight(false)
                replayDeferredSeriesMutations(after: committedOperation)
            }
        }

        try await flushPendingPersistence()
        guard let mutation = TagManagementMutation(
            cards: cards,
            transientCardIDs: transientCardIDs,
            operation: operation
        ) else { return }

        let previousPersistentCards = persistentCardsSnapshot()
            .sorted { $0.id.uuidString < $1.id.uuidString }
        let previousSeries = seriesOrderStore.snapshot()
        let previousPreferences = tagPreferencesStore.snapshot()
        let journalEntry = TagManagementTransactionJournal.Entry(
            previousCards: previousPersistentCards,
            previousSeries: previousSeries,
            previousPreferences: previousPreferences
        )

        do {
            try await writeTagManagementJournal(journalEntry)
        } catch {
            if await tagManagementJournalHasPendingTransaction() {
                throw markTagManagementRecoveryRequired(error)
            }
            throw error
        }

        do {
            try await mutation.persist(to: repository)
            guard migrateSeriesOrder(
                for: operation,
                previous: previousSeries,
                cardsBeforeMutation: previousPersistentCards
            ) else {
                throw AgentUIError.tagManagementPersistenceFailed
            }
            let validTagIDs = TagCatalogSnapshot(cards: mutation.persistentCards).validTagIDs
            guard tagPreferencesStore.migrateTag(
                fromID: operation.sourceID,
                toID: operation.destinationID,
                validTagIDs: validTagIDs
            ) else {
                throw AgentUIError.tagManagementPersistenceFailed
            }
            try await clearTagManagementJournal()
        } catch let operationError {
            do {
                try await restoreTagManagementState(from: journalEntry)
                try await clearTagManagementJournal()
                tagManagementRecoveryState = .ready
            } catch let rollbackError {
                throw markTagManagementRecoveryRequired(
                    TagManagementRollbackFailure(
                        failures: [
                            "Tag catalog change: \(operationError.localizedDescription)",
                            "Rollback: \(rollbackError.localizedDescription)",
                        ]
                    )
                )
            }
            throw operationError
        }

        cards = mutation.cards
        let sourceID = operation.sourceID
        let destinationID = operation.destinationID
        for panel in panels.values {
            guard let card = cards[panel.card.id] else { continue }
            let requestedTagID = panel.activeTagID == sourceID
                ? destinationID
                : panel.activeTagID
            panel.applyTagMetadata(
                card: card,
                activeTagID: requestedTagID,
                neighbors: requestedTagID.flatMap {
                    seriesNeighbors(cardID: card.id, tagID: $0)
                },
                animated: true
            )
        }
        libraryWindowController?.migrateActiveTag(fromID: sourceID, toID: destinationID)
        refreshPanelSeriesContexts(animated: true)
        refreshAuxiliarySnapshots()
        committedOperation = operation
    }

    private func recoverPendingTagManagementTransaction() async throws {
        do {
            guard let entry = try await loadTagManagementJournal() else {
                tagManagementRecoveryState = .ready
                return
            }
            try await restoreTagManagementState(from: entry)
            try await clearTagManagementJournal()
            tagManagementRecoveryState = .ready
        } catch {
            throw markTagManagementRecoveryRequired(error)
        }
    }

    private func restoreTagManagementState(
        from entry: TagManagementTransactionJournal.Entry
    ) async throws {
        var failures: [String] = []

        do {
            try await repository.replaceAll(with: entry.previousCards)
        } catch {
            failures.append("cards restore failed: \(error.localizedDescription)")
        }
        if !seriesOrderStore.restore(entry.previousSeries) {
            failures.append("series order restore failed")
        }
        if !tagPreferencesStore.restore(entry.previousPreferences) {
            failures.append("Tag preferences restore failed")
        }

        do {
            let restoredCards = try await repository.allCards()
                .sorted { $0.id.uuidString < $1.id.uuidString }
            if !Self.tagManagementCardsExactlyEqual(
                restoredCards,
                entry.previousCards
            ) {
                failures.append("cards restore verification failed")
            }
        } catch {
            failures.append("cards restore verification failed: \(error.localizedDescription)")
        }
        if seriesOrderStore.snapshot() != entry.previousSeries {
            failures.append("series order restore verification failed")
        }
        if tagPreferencesStore.snapshot() != entry.previousPreferences {
            failures.append("Tag preferences restore verification failed")
        }

        guard failures.isEmpty else {
            throw TagManagementRollbackFailure(failures: failures)
        }
    }

    private static func tagManagementCardsExactlyEqual(
        _ lhs: [CardRecord],
        _ rhs: [CardRecord]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) {
            guard left == right, left.tags.count == right.tags.count else {
                return false
            }
            for (leftTag, rightTag) in zip(left.tags, right.tags) {
                guard leftTag.id == rightTag.id, leftTag.name == rightTag.name else {
                    return false
                }
            }
        }
        return true
    }

    private func loadTagManagementJournal() async throws
        -> TagManagementTransactionJournal.Entry?
    {
        let journal = tagManagementJournal
        return try await Task.detached(priority: .utility) {
            try journal.load()
        }.value
    }

    private func writeTagManagementJournal(
        _ entry: TagManagementTransactionJournal.Entry
    ) async throws {
        let journal = tagManagementJournal
        try await Task.detached(priority: .utility) {
            try journal.write(entry)
        }.value
    }

    private func clearTagManagementJournal() async throws {
        let journal = tagManagementJournal
        try await Task.detached(priority: .utility) {
            try journal.clear()
        }.value
    }

    private func tagManagementJournalHasPendingTransaction() async -> Bool {
        let journal = tagManagementJournal
        return await Task.detached(priority: .utility) {
            journal.hasPendingTransaction
        }.value
    }

    private func markTagManagementRecoveryRequired(_ error: Error) -> AgentUIError {
        let details = "\(error.localizedDescription) Recovery journal: \(tagManagementJournal.fileURL.path)"
        tagManagementRecoveryState = .recoveryRequired(details)
        return .tagManagementRecoveryRequired(details)
    }

    func performTagManagementOperationForTesting(
        _ operation: TagManagementOperation
    ) async throws {
        try await performTagManagementOperation(operation)
    }

    func performCardTagRemovalForTesting(cardID: UUID, tagID: String) async throws {
        try await performCardTagRemoval(cardID: cardID, tagID: tagID)
    }

    func stageCardTagRemovalForTesting(cardID: UUID, tagID: String) {
        removeTag(cardID: cardID, tagID: tagID)
    }

    func waitForDeferredSeriesReplayForTesting() async {
        while isDeferredSeriesReplayRunning
            || !deferredSeriesMutationBatches.isEmpty
            || !deferredSeriesMutations.isEmpty
        {
            await Task.yield()
        }
    }

    func recoverPendingTagManagementTransactionForTesting() async throws {
        try await recoverPendingTagManagementTransaction()
    }

    private func migrateSeriesOrder(
        for operation: TagManagementOperation,
        previous: CardSeriesOrderStore.Snapshot,
        cardsBeforeMutation: [CardRecord]
    ) -> Bool {
        let existingOrders = seriesOrderStore.allOrders()
        let succeeded: Bool
        switch operation {
        case let .rename(sourceID, replacement):
            if sourceID == replacement.id {
                succeeded = true
            } else {
                // A destination with no catalog entry can still have an orphan
                // order left by an older per-card removal. It is not a live
                // series and must not block a legitimate global rename.
                if existingOrders[replacement.id] != nil,
                   !seriesOrderStore.removeTag(replacement.id) {
                    return false
                }
                if existingOrders[sourceID] == nil {
                    succeeded = true
                } else {
                    succeeded = seriesOrderStore.renameTag(
                        fromID: sourceID,
                        toID: replacement.id
                    )
                }
            }
        case let .merge(sourceID, target):
            let index = CardSeriesIndex(
                cards: cardsBeforeMutation,
                preferredOrderByTagID: existingOrders
            )
            succeeded = seriesOrderStore.mergeTag(
                sourceID: sourceID,
                targetID: target.id,
                targetCardIDs: index.cardIDs(tagID: target.id),
                sourceCardIDs: index.cardIDs(tagID: sourceID)
            )
        case let .delete(tagID):
            succeeded = existingOrders[tagID] == nil
                || seriesOrderStore.removeTag(tagID)
        }
        if !succeeded {
            _ = seriesOrderStore.restore(previous)
        }
        return succeeded
    }

    private func seriesNeighbors(cardID: UUID, tagID: String) -> CardSeriesNeighbors? {
        CardSeriesIndex(
            cards: Array(cards.values),
            preferredOrderByTagID: seriesOrderStore.allOrders()
        ).neighbors(of: cardID, tagID: tagID)
    }

    private func applySeriesContext(
        to panel: CardPanelController,
        requestedTagID: String? = nil,
        animated: Bool
    ) {
        let card = panel.card
        let activeTagID: String?
        if let requestedTagID,
           card.tags.contains(where: { $0.id == requestedTagID }) {
            activeTagID = requestedTagID
        } else if let current = panel.activeTagID,
                  card.tags.contains(where: { $0.id == current }) {
            activeTagID = current
        } else {
            activeTagID = nil
        }
        panel.applySeriesContext(
            activeTagID: activeTagID,
            neighbors: activeTagID.flatMap { seriesNeighbors(cardID: card.id, tagID: $0) },
            animated: animated
        )
    }

    private func refreshPanelSeriesContexts(animated: Bool) {
        for panel in panels.values {
            applySeriesContext(to: panel, animated: animated)
        }
    }

    private func activateTag(cardID: UUID, tagID: String) {
        guard let panel = panels[cardID],
              panel.card.tags.contains(where: { $0.id == tagID })
        else { return }
        applySeriesContext(to: panel, requestedTagID: tagID, animated: true)
    }

    private func deactivateTag(cardID: UUID) {
        guard let panel = panels[cardID] else { return }
        panel.applySeriesContext(activeTagID: nil, neighbors: nil, animated: true)
    }

    private func navigateSeries(
        from cardID: UUID,
        tagID: String,
        direction: SeriesNavigationDirection
    ) async throws {
        guard let controller = panels[cardID],
              controller.card.tags.contains(where: { $0.id == tagID }),
              let neighbors = seriesNeighbors(cardID: cardID, tagID: tagID)
        else { return }
        let targetID: UUID?
        switch direction {
        case .newer:
            targetID = neighbors.newerCardID
        case .older:
            targetID = neighbors.olderCardID
        }
        guard let targetID, targetID != cardID, cards[targetID] != nil else { return }

        await controller.flushLatestMarkdownForTermination()
        let otherController = panels[targetID].flatMap { $0 !== controller ? $0 : nil }
        if let otherController {
            await otherController.flushLatestMarkdownForTermination()
        }
        try await flushPendingPersistence()

        let currentFrame = controller.logicalWindowFrame()
        let currentScreenID = controller.window?.screen?.localizedName
        let currentLayout = controller.card.layoutMode
        let currentCustomLayout = controller.card.customLayout
        let transitionDate = Date()

        // UI editor callbacks run directly on MainActor and may arrive while a
        // repository actor call suspends this method, even though the outer
        // command owns mutationGate. Hold those synchronous callbacks in their
        // original order until the atomic snapshot is durable, then replay
        // them through the normal single-state pipeline.
        guard let committed = AgentSeriesNavigationCommit(
            cards: cards,
            transientCardIDs: transientCardIDs,
            sourceID: cardID,
            targetID: targetID,
            frame: currentFrame,
            screenID: currentScreenID,
            layoutMode: currentLayout,
            customLayout: currentCustomLayout,
            transitionDate: transitionDate
        ) else { return }
        isSeriesNavigationCommitInFlight = true
        defer {
            isSeriesNavigationCommitInFlight = false
            replayDeferredSeriesMutations()
        }
        try await committed.persist(to: repository)

        cards = committed.cards
        transientCardIDs.remove(targetID)

        if let otherController {
            otherController.hide(flushingPendingChanges: false)
            panels[targetID] = nil
        }

        panels[cardID] = nil
        let targetNeighbors = seriesNeighbors(cardID: targetID, tagID: tagID)
        controller.rebind(
            card: committed.targetCard,
            revision: documentCoordinator.revision(for: targetID),
            activeTagID: tagID,
            neighbors: targetNeighbors,
            fileBinding: fileBindingStore.binding(for: targetID)
        )
        panels[targetID] = controller
        markCardActive(targetID)
        refreshPanelSeriesContexts(animated: false)
        refreshAuxiliarySnapshots()
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
        guard !shouldDeferSeriesMutation else {
            deferredSeriesMutations.append(.frame(id, frame, screenID))
            return
        }
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
        guard !shouldDeferSeriesMutation else {
            deferredSeriesMutations.append(.layout(id, mode, custom))
            return
        }
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

    private func replayDeferredSeriesMutations(
        after tagOperation: TagManagementOperation? = nil
    ) {
        guard !deferredSeriesMutations.isEmpty else { return }
        deferredSeriesMutationBatches.append(
            DeferredSeriesMutationBatch(
                mutations: deferredSeriesMutations,
                tagOperation: tagOperation
            )
        )
        deferredSeriesMutations.removeAll(keepingCapacity: true)
        guard !isDeferredSeriesReplayRunning else { return }
        isDeferredSeriesReplayRunning = true
        Task { @MainActor [weak self] in
            await self?.drainDeferredSeriesMutationBatches()
        }
    }

    private func drainDeferredSeriesMutationBatches() async {
        while !deferredSeriesMutationBatches.isEmpty {
            let batch = deferredSeriesMutationBatches.removeFirst()
            await replayDeferredSeriesMutationBatch(batch)
        }
        isDeferredSeriesReplayRunning = false

        // A recovery-required failure can reject a replay before its nested
        // transaction gets a defer block. Keep any callbacks that arrived
        // during that await ordered for a later successful recovery instead
        // of letting them bypass the queue.
        if case .ready = tagManagementRecoveryState,
           !deferredSeriesMutations.isEmpty {
            replayDeferredSeriesMutations()
        }
    }

    private func replayDeferredSeriesMutationBatch(
        _ batch: DeferredSeriesMutationBatch
    ) async {
        var droppedDeletedTagEdit = false
        for mutation in batch.mutations {
            switch mutation {
            case let .markdown(id, markdown, revision, source):
                applyDeferredSeriesMutation {
                    stageMarkdownUpdate(
                        id: id,
                        markdown: markdown,
                        incomingRevision: revision,
                        source: source
                    )
                }
            case let .tag(id, name, markdown, revision, source):
                if let tagOperation = batch.tagOperation,
                   let resolvedName = Self.resolvedDeferredTagName(
                       name,
                       after: tagOperation
                   ) {
                    applyDeferredSeriesMutation {
                        stageTagCommand(
                            id: id,
                            tagName: resolvedName,
                            markdown: markdown,
                            incomingRevision: revision,
                            source: source
                        )
                    }
                } else if batch.tagOperation != nil {
                    // Preserve the editor's Markdown transaction, but do not
                    // resurrect a Tag that was globally deleted while this
                    // callback was waiting for the commit.
                    applyDeferredSeriesMutation {
                        stageMarkdownUpdate(
                            id: id,
                            markdown: markdown,
                            incomingRevision: revision,
                            source: source
                        )
                    }
                    droppedDeletedTagEdit = true
                } else {
                    applyDeferredSeriesMutation {
                        stageTagCommand(
                            id: id,
                            tagName: name,
                            markdown: markdown,
                            incomingRevision: revision,
                            source: source
                        )
                    }
                }
            case let .removeTag(id, tagID):
                if let resolvedTagID = Self.resolvedDeferredRemovalTagID(
                    tagID,
                    after: batch.tagOperation
                ) {
                    do {
                        try await withSerializedMutation {
                            try await performCardTagRemoval(
                                cardID: id,
                                tagID: resolvedTagID
                            )
                        }
                    } catch {
                        presentError(error)
                    }
                }
            case let .frame(id, frame, screenID):
                applyDeferredSeriesMutation {
                    stageFrameUpdate(id: id, frame: frame, screenID: screenID)
                }
            case let .layout(id, mode, custom):
                applyDeferredSeriesMutation {
                    stageLayoutUpdate(id: id, mode: mode, custom: custom)
                }
            }
        }
        if droppedDeletedTagEdit {
            presentError(AgentUIError.tagDeletedDuringConcurrentEdit)
        }
    }

    private func applyDeferredSeriesMutation(_ operation: () -> Void) {
        isApplyingDeferredSeriesMutation = true
        defer { isApplyingDeferredSeriesMutation = false }
        operation()
    }

    nonisolated static func resolvedDeferredTagName(
        _ name: String,
        after operation: TagManagementOperation
    ) -> String? {
        guard (try? CardTag(name))?.id == operation.sourceID else { return name }
        return operation.destinationTag?.name
    }

    nonisolated static func resolvedDeferredRemovalTagID(
        _ tagID: String,
        after operation: TagManagementOperation?
    ) -> String? {
        guard let operation, tagID == operation.sourceID else { return tagID }
        return operation.destinationID
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
        guard case .ready = tagManagementRecoveryState else { return }
        persistenceGeneration += 1
        let previous = persistenceTail
        let repository = self.repository
        let persistenceErrorState = self.persistenceErrorState
        let cardVersionStore = self.cardVersionStore
        persistenceTail = Task.detached(priority: .utility) {
            if let previous {
                await previous.value
            }
            do {
                do {
                    _ = try cardVersionStore.record(card, capturedAt: card.updatedAt)
                } catch {
                    fputs("Markdown Card recovery snapshot failed: \(error.localizedDescription)\n", stderr)
                }
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
        fileBindingStore.removeBinding(for: id)
        cardVersionStore.delete(cardID: id)
        seriesOrderStore.removeCard(id)
        if defaults.string(forKey: Self.lastActiveCardDefaultsKey) == id.uuidString {
            defaults.removeObject(forKey: Self.lastActiveCardDefaultsKey)
        }
        removeCardFromFoldSession(id)
        refreshPanelSeriesContexts(animated: true)
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

    func handle(_ request: AgentRequest) async -> AgentResponse {
        do {
            return try await withSerializedMutation {
                await handleSerialized(request)
            }
        } catch {
            return .failure(
                requestID: request.requestID,
                code: "recovery_required",
                message: error.localizedDescription
            )
        }
    }

    private func handleSerialized(_ request: AgentRequest) async -> AgentResponse {
        do {
            switch request.command {
            case let .create(options):
                // Validate every raw value before creating or persisting a
                // card, so one invalid Tag makes the whole create atomic.
                let tags = try options.tags.map { try CardTag($0) }
                let card = try await createIndependentCard(
                    markdown: options.markdown,
                    title: options.title,
                    tags: tags
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
            case let .tag(options):
                let card = try await addTag(id: options.cardID, name: options.name)
                return try .success(
                    requestID: request.requestID,
                    encoding: CardMutationPayload(card: card)
                )
            case .fold:
                foldAllCards(trigger: .manual, animated: true)
                return .success(requestID: request.requestID)
            case .unfold:
                guard systemUnavailableReasons.isEmpty else {
                    return .failure(
                        requestID: request.requestID,
                        code: "screen_locked",
                        message: "Cards cannot be restored while the Mac session is unavailable."
                    )
                }
                restoreFoldedCards(animated: true)
                return .success(requestID: request.requestID)
            case let .list(options):
                let listed = cards.values
                    .filter { options.includeHidden || $0.isVisible }
                    .sorted { $0.updatedAt > $1.updatedAt }
                    .map(CardSummary.init(card:))
                return try .success(
                    requestID: request.requestID,
                    encoding: CardListPayload(
                        cards: listed,
                        appearance: appearanceController.mode,
                        isFolded: isFolded
                    )
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
        commandCenterWindowController?.setFoldedState(isFolded)
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
              !MarkdownShortcutContract.takesPriority(
                  over: shortcut,
                  editorFocused: markdownEditorOwnsShortcutPriority
              ),
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

    private func activeSeriesContext(promptForTag: Bool) -> ActiveSeriesContext? {
        let selectedCard: CardRecord?
        let selectedTagID: String?
        let sourceWindow: NSWindow?

        if let keyWindow = NSApp.keyWindow,
           let pair = panels.first(where: { $0.value.window === keyWindow }),
           let card = cards[pair.key] {
            selectedCard = card
            selectedTagID = pair.value.activeTagID
            sourceWindow = keyWindow
        } else if let selection = commandCenterWindowController?.activeLibrarySeriesSelection(),
                  let card = cards[selection.cardID] {
            selectedCard = card
            selectedTagID = selection.tagID
            sourceWindow = commandCenterWindowController?.window
        } else if let recentID = recentCardID(), let card = cards[recentID] {
            selectedCard = card
            selectedTagID = panels[recentID]?.activeTagID
            sourceWindow = panels[recentID]?.window
        } else {
            return nil
        }

        guard let card = selectedCard, !card.tags.isEmpty else { return nil }
        let tag: CardTag?
        if let selectedTagID {
            tag = card.tags.first(where: { $0.id == selectedTagID })
        } else if card.tags.count == 1 {
            tag = card.tags[0]
        } else if promptForTag {
            tag = chooseSeriesTag(from: card.tags, window: sourceWindow)
        } else {
            // Menu validation must not disable Series commands merely because
            // a multi-Tag card has not selected one yet. The action itself
            // presents the explicit Tag picker.
            tag = card.tags.first
        }
        guard let tag else { return nil }
        return ActiveSeriesContext(card: card, tag: tag, window: sourceWindow)
    }

    private func chooseSeriesTag(from tags: [CardTag], window: NSWindow?) -> CardTag? {
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
        tags.forEach { picker.addItem(withTitle: $0.name) }
        picker.setAccessibilityLabel("Card series Tag")
        let alert = NSAlert()
        alert.messageText = "Choose a Card Series"
        alert.informativeText = "This card belongs to more than one Tag. Choose the tutorial series to use."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        let response = window?.isVisible == true
            ? alert.runModal()
            : alert.runModal()
        guard response == .alertFirstButtonReturn,
              tags.indices.contains(picker.indexOfSelectedItem)
        else { return nil }
        return tags[picker.indexOfSelectedItem]
    }

    private func orderedSeries(tagID: String) -> [CardRecord] {
        seriesOrderStore.orderedCards(tagID: tagID, cards: Array(cards.values))
    }

    private func canMoveActiveSeriesChapter(_ direction: CardSeriesMoveDirection) -> Bool {
        guard case .ready = tagManagementRecoveryState,
              !isSeriesNavigationCommitInFlight
        else { return false }
        guard let context = activeSeriesContext(promptForTag: false) else { return false }
        let ordered = orderedSeries(tagID: context.tag.id)
        guard let index = ordered.firstIndex(where: { $0.id == context.card.id }) else {
            return false
        }
        switch direction {
        case .earlier:
            return index > ordered.startIndex
        case .later:
            return ordered.indices.contains(index + 1)
        }
    }

    @objc private func moveSeriesChapterEarlier(_ sender: Any?) {
        moveActiveSeriesChapter(.earlier)
    }

    @objc private func moveSeriesChapterLater(_ sender: Any?) {
        moveActiveSeriesChapter(.later)
    }

    private func moveActiveSeriesChapter(_ direction: CardSeriesMoveDirection) {
        guard case .ready = tagManagementRecoveryState,
              !isSeriesNavigationCommitInFlight
        else { return }
        guard let context = activeSeriesContext(promptForTag: true),
              seriesOrderStore.move(
                cardID: context.card.id,
                tagID: context.tag.id,
                direction: direction,
                cards: Array(cards.values)
              )
        else { return }
        refreshPanelSeriesContexts(animated: true)
        refreshAuxiliarySnapshots()
        let announcement = direction == .earlier
            ? "Chapter moved earlier in \(context.tag.name)"
            : "Chapter moved later in \(context.tag.name)"
        if let element = context.window?.contentView {
            NSAccessibility.post(
                element: element,
                notification: .announcementRequested,
                userInfo: [.announcement: announcement]
            )
        }
    }

    @objc private func validateActiveSeriesLinks(_ sender: Any?) {
        guard let context = activeSeriesContext(promptForTag: true) else { return }
        Task { [weak self] in
            guard let self else { return }
            await validateSeries(context)
        }
    }

    @objc private func exportActiveSeries(_ sender: Any?) {
        guard let context = activeSeriesContext(promptForTag: true) else { return }
        Task { [weak self] in
            guard let self else { return }
            await exportSeries(context)
        }
    }

    private func seriesDocument(_ context: ActiveSeriesContext) throws -> CardSeriesDocument {
        let ordered = orderedSeries(tagID: context.tag.id)
        let fileURLs = Dictionary(uniqueKeysWithValues: ordered.compactMap { card in
            fileBindingStore.fileURL(for: card.id).map { (card.id, $0) }
        })
        return try CardSeriesDocumentBuilder.build(
            tag: context.tag,
            cards: ordered,
            fileURLsByCardID: fileURLs
        )
    }

    private func validateSeries(_ context: ActiveSeriesContext) async {
        for panel in panels.values {
            await panel.flushLatestMarkdownForTermination()
        }
        await libraryWindowController?.flushLatestMarkdownForTermination()
        do {
            try await flushPendingPersistence()
            let document = try seriesDocument(context)
            let alert = NSAlert()
            if document.issues.isEmpty {
                alert.messageText = "Series Links Are Valid"
                alert.informativeText = "No missing or escaping local file links were found in \(context.tag.name)."
            } else {
                alert.alertStyle = .warning
                alert.messageText = "Series Link Issues"
                let visible = document.issues.prefix(20).map {
                    "• \($0.cardTitle): \($0.destination) — \($0.reason)"
                }.joined(separator: "\n")
                let remainder = document.issues.count > 20
                    ? "\n… and \(document.issues.count - 20) more"
                    : ""
                alert.informativeText = visible + remainder
            }
            alert.runModal()
        } catch {
            presentError(error)
        }
    }

    private func exportSeries(_ context: ActiveSeriesContext) async {
        for panel in panels.values {
            await panel.flushLatestMarkdownForTermination()
        }
        await libraryWindowController?.flushLatestMarkdownForTermination()
        do {
            try await flushPendingPersistence()
            let ordered = orderedSeries(tagID: context.tag.id)
            let fileURLs = Dictionary(uniqueKeysWithValues: ordered.compactMap { card in
                fileBindingStore.fileURL(for: card.id).map { (card.id, $0) }
            })
            let document = try CardSeriesDocumentBuilder.build(
                tag: context.tag,
                cards: ordered,
                fileURLsByCardID: fileURLs
            )
            seriesExportService.present(
                document: document,
                tag: context.tag,
                cards: ordered,
                fileURLsByCardID: fileURLs,
                from: context.window
            ) { [weak self] result in
                guard let self, let result else { return }
                switch result {
                case let .success(export):
                    if !document.issues.isEmpty || !export.unresolvedResourcePaths.isEmpty {
                        let alert = NSAlert()
                        alert.alertStyle = .warning
                        alert.messageText = "Series Exported with Portability Warnings"
                        var notes: [String] = []
                        if !document.issues.isEmpty {
                            notes.append("\(document.issues.count) local link issue(s) should be reviewed.")
                        }
                        if !export.unresolvedResourcePaths.isEmpty {
                            notes.append("\(export.unresolvedResourcePaths.count) relative image(s) could not be copied.")
                        }
                        alert.informativeText = notes.joined(separator: " ")
                        alert.runModal()
                    }
                case let .failure(error):
                    presentError(error)
                }
            }
        } catch {
            presentError(error)
        }
    }

    @objc private func showVersionHistory(_ sender: Any?) {
        guard let cardID = activeCardIDForFileOperation() else { return }
        Task { [weak self] in
            guard let self else { return }
            await presentVersionHistory(cardID: cardID)
        }
    }

    private func presentVersionHistory(cardID: UUID) async {
        do {
            _ = try await latestFileOperationSnapshot(for: cardID)
            guard let card = cards[cardID] else { throw AgentUIError.cardNotFound(cardID) }
            _ = try cardVersionStore.record(card, capturedAt: card.updatedAt)
            let currentDigest = CardVersionSnapshot.digest(card.markdown)
            let snapshots = try cardVersionStore.snapshots(cardID: cardID).filter {
                $0.digest != currentDigest || $0.titleOverride != card.titleOverride
            }
            guard !snapshots.isEmpty else {
                let alert = NSAlert()
                alert.messageText = "No Earlier Versions"
                alert.informativeText = "Markdown Card will keep up to \(CardVersionStore.maximumSnapshotsPerCard) distinct versions as you edit."
                alert.runModal()
                return
            }
            let picker = VersionHistoryPickerController(
                snapshots: snapshots,
                currentMarkdown: card.markdown
            )
            let alert = NSAlert()
            alert.messageText = "Version History"
            alert.informativeText = "Choose a saved version to compare with the current card. Restoring creates a new recoverable version of the current text first."
            alert.accessoryView = picker.view
            alert.addButton(withTitle: "Restore Version")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn,
                  let snapshot = picker.selectedSnapshot
            else { return }
            try restoreVersion(snapshot, cardID: cardID)
        } catch {
            presentError(error)
        }
    }

    private func restoreVersion(_ snapshot: CardVersionSnapshot, cardID: UUID) throws {
        guard var card = cards[cardID] else { throw AgentUIError.cardNotFound(cardID) }
        _ = try cardVersionStore.record(card, capturedAt: Date())
        card.titleOverride = snapshot.titleOverride
        card.updateMarkdown(snapshot.markdown, at: Date())
        let transaction = documentCoordinator.accept(
            cardID: cardID,
            markdown: card.markdown,
            incomingRevision: documentCoordinator.revision(for: cardID) &+ 1,
            source: .commandLine
        )
        cards[cardID] = card
        for panel in panels.values where panel.card.id == cardID {
            panel.update(card: card, revision: transaction.revision)
        }
        refreshAuxiliarySnapshots()
        enqueuePersistence(card)
    }

    @objc private func openMarkdownFromMenu(_ sender: Any?) {
        guard openMarkdownPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Markdown"
        panel.message = "Open a UTF-8 Markdown file as a linked card."
        panel.prompt = "Open"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.allowedContentTypes = Self.markdownContentTypes
        openMarkdownPanel = panel

        panel.begin { [weak self] response in
            guard let self else { return }
            let sourceURL = response == .OK ? panel.url : nil
            openMarkdownPanel = nil
            guard let sourceURL else { return }
            Task { [weak self] in
                await self?.openMarkdownDocument(at: sourceURL)
            }
        }
    }

    @objc private func saveMarkdownFromMenu(_ sender: Any?) {
        Task { [weak self] in
            await self?.saveActiveMarkdown()
        }
    }

    @objc private func saveMarkdownAsFromMenu(_ sender: Any?) {
        guard let cardID = activeCardIDForFileOperation() else { return }
        presentSaveMarkdownPanel(for: cardID)
    }

    private static var markdownContentTypes: [UTType] {
        let types = ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.plainText] : types
    }

    private func openMarkdownDocument(at sourceURL: URL) async {
        do {
            let service = externalMarkdownService
            let document = try await Task.detached(priority: .userInitiated) {
                try service.open(sourceURL)
            }.value
            try await withSerializedMutation {
                let title = document.fileURL.deletingPathExtension().lastPathComponent
                let card = try await createIndependentCard(
                    markdown: document.markdown,
                    title: title.isEmpty ? nil : title,
                    show: false,
                    persistEmpty: true
                )
                fileBindingStore.set(
                    CardFileBinding(fileURL: document.fileURL, baseDigest: document.digest),
                    for: card.id
                )
                _ = try await showCard(id: card.id)
            }
        } catch {
            presentError(error)
        }
    }

    private func saveActiveMarkdown() async {
        guard let cardID = activeCardIDForFileOperation(),
              fileOperationCardIDs.insert(cardID).inserted
        else { return }
        defer { fileOperationCardIDs.remove(cardID) }

        do {
            let snapshot = try await withSerializedMutation {
                try await latestFileOperationSnapshot(for: cardID)
            }
            guard let binding = fileBindingStore.binding(for: cardID) else {
                presentSaveMarkdownPanel(for: cardID)
                return
            }

            let service = externalMarkdownService
            let result = try await Task.detached(priority: .userInitiated) {
                try service.save(snapshot.markdown, binding: binding)
            }.value
            switch result {
            case let .unchanged(updatedBinding), let .saved(updatedBinding):
                guard cards[cardID] != nil,
                      fileBindingStore.binding(for: cardID) == binding
                else { return }
                fileBindingStore.set(updatedBinding, for: cardID)
                panels[cardID]?.setFileBinding(updatedBinding)
                libraryWindowController?.refreshDocumentRoot(for: cardID)
            case let .conflict(conflict):
                await resolveFileConflict(conflict, cardID: cardID)
            }
        } catch {
            if Self.shouldOfferSaveAs(for: error) {
                presentRecoverableFileError(error, cardID: cardID)
            } else {
                presentError(error)
            }
        }
    }

    private func latestFileOperationSnapshot(
        for cardID: UUID,
        includeExportBundle: Bool = false
    ) async throws -> (
        markdown: String,
        title: String,
        revision: UInt64,
        exportBundle: MarkdownExportBundle?
    ) {
        guard cards[cardID] != nil else { throw AgentUIError.cardNotFound(cardID) }
        var exportBundle: MarkdownExportBundle?
        let keyWindow = NSApp.keyWindow
        let libraryWindow = commandCenterWindowController?.window
        let libraryOwnsOperation = commandCenterWindowController?.activeLibraryCardSelection() == cardID
            && (keyWindow === libraryWindow || keyWindow?.sheetParent === libraryWindow)
        if libraryOwnsOperation {
            if includeExportBundle {
                exportBundle = try await commandCenterWindowController?
                    .latestLibraryExportBundleForFileOperation(cardID: cardID)
            } else {
                _ = try await commandCenterWindowController?
                    .latestLibraryMarkdownForFileOperation(cardID: cardID)
            }
        } else if let panel = panels[cardID] {
            if includeExportBundle {
                exportBundle = try await panel.latestMarkdownExportBundleForFileOperation()
            } else {
                _ = try await panel.latestMarkdownForFileOperation()
            }
            panel.flushPendingChanges()
        } else if commandCenterWindowController?.activeLibraryCardSelection() == cardID {
            if includeExportBundle {
                exportBundle = try await commandCenterWindowController?
                    .latestLibraryExportBundleForFileOperation(cardID: cardID)
            } else {
                _ = try await commandCenterWindowController?
                    .latestLibraryMarkdownForFileOperation(cardID: cardID)
            }
        }
        try await flushPendingPersistence()
        guard var card = cards[cardID] else { throw AgentUIError.cardNotFound(cardID) }
        if transientCardIDs.contains(cardID) {
            card = try await repository.upsert(card)
            cards[cardID] = card
            transientCardIDs.remove(cardID)
            refreshAuxiliarySnapshots()
        }
        return (
            card.markdown,
            card.title,
            documentCoordinator.revision(for: cardID),
            exportBundle
        )
    }

    private func presentSaveMarkdownPanel(for cardID: UUID) {
        guard cards[cardID] != nil, saveMarkdownPanel == nil else { return }
        let panel = NSSavePanel()
        panel.title = "Save Markdown"
        panel.message = "Save this card as a linked Markdown file."
        panel.prompt = "Save"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = Self.markdownContentTypes
        panel.nameFieldStringValue = fileBindingStore.fileURL(for: cardID)?.lastPathComponent
            ?? MarkdownExportService.suggestedFilename(for: cards[cardID]?.title ?? CardRecord.untitledTitle)
        saveMarkdownPanel = panel

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            let destinationURL = response == .OK ? panel.url : nil
            saveMarkdownPanel = nil
            guard let destinationURL else { return }
            Task { [weak self] in
                await self?.saveMarkdownAs(cardID: cardID, destination: destinationURL)
            }
        }
        let selectedLibraryWindow = commandCenterWindowController?.activeLibraryCardSelection() == cardID
            && NSApp.keyWindow === commandCenterWindowController?.window
            ? commandCenterWindowController?.window
            : nil
        let sourceWindow = selectedLibraryWindow
            ?? (panels[cardID]?.window?.isVisible == true ? panels[cardID]?.window : nil)
            ?? (commandCenterWindowController?.activeLibraryCardSelection() == cardID
                ? commandCenterWindowController?.window
                : nil)
        if let window = sourceWindow, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func saveMarkdownAs(cardID: UUID, destination: URL) async {
        guard fileOperationCardIDs.insert(cardID).inserted else { return }
        defer { fileOperationCardIDs.remove(cardID) }

        do {
            let snapshot = try await withSerializedMutation {
                try await latestFileOperationSnapshot(
                    for: cardID,
                    includeExportBundle: true
                )
            }
            let bundle = snapshot.exportBundle
                ?? MarkdownExportBundle(markdown: snapshot.markdown, attachmentIDs: [])
            let originalBinding = fileBindingStore.binding(for: cardID)
            let sourceDocumentRoot = fileBindingStore.documentRootURL(for: cardID)
            let service = externalMarkdownService
            let result = try await Task.detached(priority: .userInitiated) {
                try service.saveAs(
                    bundle,
                    sourceDocumentRoot: sourceDocumentRoot,
                    to: destination
                )
            }.value
            let current = try await withSerializedMutation {
                try await latestFileOperationSnapshot(for: cardID)
            }
            guard Self.canApplyPortableSaveAsResult(
                currentMarkdown: current.markdown,
                exportedMarkdown: bundle.markdown,
                currentRevision: current.revision,
                exportedRevision: snapshot.revision,
                currentBinding: fileBindingStore.binding(for: cardID),
                originalBinding: originalBinding
            ) else {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Copy Saved; Card Kept Editing"
                alert.informativeText = "The Markdown copy was written to \(result.fileURL.path), but this card changed while resources were being copied. Its newer text and original file link were preserved. Save As again when you are ready to link the current version."
                alert.runModal()
                return
            }
            if let current = cards[cardID], current.markdown != result.markdown {
                commitMarkdown(
                    id: cardID,
                    markdown: result.markdown,
                    incomingRevision: snapshot.revision &+ 1,
                    source: .commandLine
                )
                if let rewritten = cards[cardID] { enqueuePersistence(rewritten) }
            }
            fileBindingStore.set(result.binding, for: cardID)
            panels[cardID]?.setFileBinding(result.binding)
            libraryWindowController?.refreshDocumentRoot(for: cardID)
            if !result.unresolvedResourcePaths.isEmpty {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Markdown Saved with Unresolved Images"
                let listed = result.unresolvedResourcePaths.prefix(12).joined(separator: "\n• ")
                alert.informativeText = "The Markdown file was saved, but these relative images could not be copied because this card had no linked source folder:\n• \(listed)"
                alert.runModal()
            }
        } catch {
            presentError(error)
        }
    }

    private func resolveFileConflict(
        _ conflict: ExternalMarkdownConflict,
        cardID: UUID
    ) async {
        guard cards[cardID] != nil,
              fileBindingStore.binding(for: cardID) == conflict.binding
        else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Linked Markdown File Changed"
        alert.informativeText = conflict.localChanged
            ? "Both this card and the file on disk changed. Compare them before choosing which content to keep. Nothing is overwritten until you explicitly confirm."
            : "The file on disk changed since it was opened. Compare it with the card, reload it, or explicitly keep the card version."
        alert.addButton(withTitle: "Reload File")
        alert.addButton(withTitle: "Compare…")
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: "Keep Mine…")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            await reloadLinkedFile(
                cardID: cardID,
                expectedBinding: conflict.binding,
                expectedLocalDigest: conflict.localDigest
            )
        case .alertSecondButtonReturn:
            await presentFileConflictComparison(conflict, cardID: cardID)
            if cards[cardID] != nil,
               fileBindingStore.binding(for: cardID) == conflict.binding {
                await resolveFileConflict(conflict, cardID: cardID)
            }
        case .alertThirdButtonReturn:
            presentSaveMarkdownPanel(for: cardID)
        default:
            guard response.rawValue == NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 3
            else { return }
            await keepLocalFileVersion(after: conflict, cardID: cardID)
        }
    }

    private func presentFileConflictComparison(
        _ conflict: ExternalMarkdownConflict,
        cardID: UUID
    ) async {
        do {
            let local = try await latestFileOperationSnapshot(for: cardID).markdown
            let service = externalMarkdownService
            let disk = try await Task.detached(priority: .userInitiated) {
                try service.open(conflict.binding.fileURL)
            }.value
            let alert = NSAlert()
            alert.messageText = "Compare Linked Markdown"
            alert.informativeText = "Lines removed from the disk file start with −; card additions start with +. This preview is read-only."
            alert.accessoryView = makeMarkdownComparisonAccessory(
                original: disk.markdown,
                modified: local,
                originalLabel: "File on Disk",
                modifiedLabel: "Current Card"
            )
            alert.addButton(withTitle: "Back")
            alert.runModal()
        } catch {
            presentRecoverableFileError(error, cardID: cardID)
        }
    }

    private func keepLocalFileVersion(
        after conflict: ExternalMarkdownConflict,
        cardID: UUID
    ) async {
        let confirmation = NSAlert()
        confirmation.alertStyle = .critical
        confirmation.messageText = "Overwrite the Linked File?"
        confirmation.informativeText = "The current card will replace the disk version only if the file has not changed again. The disk version is added to this card's recoverable history first."
        confirmation.addButton(withTitle: "Overwrite with Card")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }

        do {
            let local = try await latestFileOperationSnapshot(for: cardID).markdown
            let service = externalMarkdownService
            let disk = try await Task.detached(priority: .userInitiated) {
                try service.open(conflict.binding.fileURL)
            }.value
            if let current = cards[cardID] {
                var recoverableDiskVersion = current
                recoverableDiskVersion.titleOverride = current.titleOverride
                recoverableDiskVersion.updateMarkdown(disk.markdown, at: Date())
                _ = try cardVersionStore.record(recoverableDiskVersion, capturedAt: Date())
            }
            let result = try await Task.detached(priority: .userInitiated) {
                try service.keepLocalVersion(local, after: conflict)
            }.value
            switch result {
            case let .unchanged(binding), let .saved(binding):
                guard cards[cardID] != nil,
                      fileBindingStore.binding(for: cardID) == conflict.binding
                else { return }
                fileBindingStore.set(binding, for: cardID)
                panels[cardID]?.setFileBinding(binding)
                libraryWindowController?.refreshDocumentRoot(for: cardID)
            case let .conflict(freshConflict):
                await resolveFileConflict(freshConflict, cardID: cardID)
            }
        } catch {
            presentRecoverableFileError(error, cardID: cardID)
        }
    }

    private func reloadLinkedFile(
        cardID: UUID,
        expectedBinding: CardFileBinding,
        expectedLocalDigest: String
    ) async {
        do {
            let service = externalMarkdownService
            let document = try await Task.detached(priority: .userInitiated) {
                try service.open(expectedBinding.fileURL)
            }.value
            try await withSerializedMutation {
                guard cards[cardID] != nil else { throw AgentUIError.cardNotFound(cardID) }
                guard fileBindingStore.binding(for: cardID) == expectedBinding else { return }
                if let panel = panels[cardID] {
                    _ = try await panel.latestMarkdownForFileOperation()
                }
                guard let latestCard = cards[cardID] else {
                    throw AgentUIError.cardNotFound(cardID)
                }
                guard Self.localMarkdownMatchesReloadSnapshot(
                    latestCard.markdown,
                    expectedDigest: expectedLocalDigest
                ) else {
                    throw AgentUIError.cardChangedDuringReload
                }
                commitMarkdown(
                    id: cardID,
                    markdown: document.markdown,
                    incomingRevision: documentCoordinator.revision(for: cardID) &+ 1,
                    source: .commandLine
                )
                transientCardIDs.remove(cardID)
                guard let card = cards[cardID] else { throw AgentUIError.cardNotFound(cardID) }
                cards[cardID] = try await repository.upsert(card)
                fileBindingStore.set(
                    CardFileBinding(fileURL: document.fileURL, baseDigest: document.digest),
                    for: cardID
                )
                let refreshedBinding = fileBindingStore.binding(for: cardID)
                panels[cardID]?.setFileBinding(refreshedBinding)
                libraryWindowController?.refreshDocumentRoot(for: cardID)
                refreshAuxiliarySnapshots()
            }
        } catch {
            presentRecoverableFileError(error, cardID: cardID)
        }
    }

    private func presentRecoverableFileError(_ error: Error, cardID: UUID) {
        guard cards[cardID] != nil else {
            presentError(error)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unable to Save Linked File"
        alert.informativeText = "\(error.localizedDescription) You can save the card to another Markdown file or keep it in Markdown Card."
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: "Keep Card")
        if alert.runModal() == .alertFirstButtonReturn {
            presentSaveMarkdownPanel(for: cardID)
        }
    }

    private static func shouldOfferSaveAs(for error: Error) -> Bool {
        error is ExternalMarkdownDocumentError
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    @objc private func createNewCardFromMenu(_ sender: Any?) { createNewCard() }

    @objc private func toggleFoldedCardsFromMenu(_ sender: Any?) { toggleFoldedCards() }

    @objc private func showLibrary(_ sender: Any?) {
        libraryWindowController?.applySnapshot(
            persistentCardsSnapshot(),
            revisions: documentCoordinator.snapshot()
        )
        commandCenterWindowController?.show(
            route: .library,
            cards: persistentCardsSnapshot(),
            on: currentScreen()
        )
    }

    @objc private func showSettings(_ sender: Any?) {
        commandCenterWindowController?.show(
            route: .settings(nil),
            cards: persistentCardsSnapshot(),
            on: currentScreen()
        )
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
    ) async throws -> T {
        await mutationGate.acquire()
        do {
            if case let .recoveryRequired(details) = tagManagementRecoveryState {
                throw AgentUIError.tagManagementRecoveryRequired(details)
            }
            let value = try await operation()
            await mutationGate.release()
            return value
        } catch {
            await mutationGate.release()
            throw error
        }
    }
}

/// Value snapshot for an atomic, two-card series page transition.
///
/// `replaceAll` is intentionally used instead of two independent upserts: both
/// visibility changes either reach the repository together or neither does.
struct AgentSeriesNavigationCommit: Sendable {
    let cards: [UUID: CardRecord]
    let persistentCards: [CardRecord]
    let sourceCard: CardRecord
    let targetCard: CardRecord

    init?(
        cards currentCards: [UUID: CardRecord],
        transientCardIDs: Set<UUID>,
        sourceID: UUID,
        targetID: UUID,
        frame: WindowFrame?,
        screenID: String?,
        layoutMode: CardLayoutMode,
        customLayout: CustomCardLayout?,
        transitionDate: Date
    ) {
        guard var sourceCard = currentCards[sourceID],
              var targetCard = currentCards[targetID],
              sourceID != targetID
        else { return nil }

        sourceCard.isVisible = false
        if let frame { sourceCard.windowFrame = frame }
        sourceCard.screenID = screenID

        targetCard.isVisible = true
        targetCard.layoutMode = layoutMode
        targetCard.customLayout = customLayout
        targetCard.windowFrame = frame
        targetCard.screenID = screenID
        targetCard.touch(at: transitionDate)

        var committedCards = currentCards
        committedCards[sourceID] = sourceCard
        committedCards[targetID] = targetCard
        let forcedPersistentIDs = Set([sourceID, targetID])
        persistentCards = committedCards.values
            .filter { card in
                forcedPersistentIDs.contains(card.id)
                    || !transientCardIDs.contains(card.id)
            }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        cards = committedCards
        self.sourceCard = sourceCard
        self.targetCard = targetCard
    }

    func persist(to repository: any CardRepository) async throws {
        try await repository.replaceAll(with: persistentCards)
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

private struct TagManagementRollbackFailure: LocalizedError, Sendable {
    let failures: [String]

    var errorDescription: String? {
        failures.joined(separator: "; ")
    }
}

private enum AgentUIError: LocalizedError {
    case cardNotFound(UUID)
    case protectedCard
    case cliNotBundled
    case persistenceFailed(String)
    case cardChangedDuringReload
    case tagNotFound(String)
    case tagManagementBusy
    case tagManagementPersistenceFailed
    case tagManagementRecoveryRequired(String)
    case tagDeletedDuringConcurrentEdit

    var errorDescription: String? {
        switch self {
        case let .cardNotFound(id): "Card \(id.uuidString) was not found."
        case .protectedCard: "Use --force to delete a visible card."
        case .cliNotBundled: "The mdcard helper is not present in this application bundle."
        case let .persistenceFailed(message): "Markdown Card could not save the latest changes: \(message)"
        case .cardChangedDuringReload:
            "The card changed again while the file was reloading, so Markdown Card kept the newer card content."
        case let .tagNotFound(tagID): "Tag \(tagID) was not found."
        case .tagManagementBusy: "Another Tag or series operation is still finishing."
        case .tagManagementPersistenceFailed:
            "Markdown Card could not save the Tag catalog change, so the previous state was restored."
        case let .tagManagementRecoveryRequired(details):
            "Markdown Card could not verify the Tag catalog rollback. Saving is paused and Tag management is disabled. Quit and reopen the app to retry recovery; the recovery journal was retained. \(details)"
        case .tagDeletedDuringConcurrentEdit:
            "A Tag command was waiting while that Tag was deleted globally. Its Markdown was kept, but the deleted Tag was not recreated. Add it again if that was intentional."
        }
    }
}
