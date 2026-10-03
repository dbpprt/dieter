import AppKit
import DieterAPI
import DieterShared
import Foundation
import OSLog
import Observation
import SharedCore
import UniformTypeIdentifiers
import UserNotifications

/// Conversations and board cards: the shared core delivers, queues, and
/// reconciles every change; these adapt the app's selection to it.
extension DieterStore {
    /// Loads archived chats, which the live workspace omits. Unarchived chats
    /// come from the core.
    func loadArchivedChats() async {
        chatsRequestGeneration &+= 1
        let generation = chatsRequestGeneration
        chatsLoading = true
        chatsError = nil
        defer { if generation == chatsRequestGeneration { chatsLoading = false } }
        do {
            // Every online machine's archived chats; live ones are in the workspace.
            let archived = try await administer { $0.archivedChats = ClientStep() }.cards.cards
            guard generation == chatsRequestGeneration else { return }
            if archivedChats != archived {
                archivedChats = archived
                foldWorkspace(coreWorkspace)
            }
        } catch {
            guard generation == chatsRequestGeneration else { return }
            if !Self.isExpectedCancellation(error) {
                chatsError = (error as? CoreFailure)?.message ?? error.localizedDescription
            }
        }
    }

    func openConversation(cardID: String, chat: Bool = false, fromInbox: Bool = false) async {
        let previousConversationID = selectedCardID ?? selectedChatID
        conversationSelectionGeneration &+= 1
        let selectionGeneration = conversationSelectionGeneration
        let knownChat =
            chats.first(where: { $0.id == cardID })
            ?? state.chats.first(where: { $0.id == cardID })
        let card =
            knownChat
            ?? state.cards.first(where: { $0.id == cardID })
            ?? navigationCards.values.lazy.compactMap({ $0.first(where: { $0.id == cardID }) }).first
        let opensChat =
            chat || knownChat != nil
            || card.map { SharedRules.shared.isChat(scope: $0.scope, boardId: $0.boardID) } == true
        let projectID = card?.projectID ?? ""
        stopTerminalWatch()
        section = fromInbox ? .inbox : (opensChat ? .chats : .board)
        if !projectID.isEmpty {
            selectedProjectID = projectID
            if !opensChat, let boardID = card?.boardID, !boardID.isEmpty {
                selectedBoardID = boardID
            }
            updateSelectedState()
        }
        selectedCardID = opensChat ? nil : cardID
        selectedChatID = opensChat ? cardID : nil
        if previousConversationID != cardID {
            conversationContext.content.applyDefaultMode(defaultConversationMode, conversationID: cardID)
            conversationModel.resetConversationHistory()
            conversation = nil
            selectedDetail = nil
            conversationLastRefreshedAt = nil
            conversationError = nil
            conversationLoading = true
        }
        if opensChat { lastUsedChatID = cardID }
        if opensChat { newChatProjectID = "" }
        resetWorkspaceSurface()
        // The core opens the conversation on the machine that runs it and
        // shows its cached transcript at once.
        bindConversation()
        conversationModel.observe(cardID)
        await perform { $0.setVisibleConversation = .with { $0.cardID = cardID } }
        // The composer's agents and the machine settings are the attached
        // machine's, so follow the conversation to its machine.
        guard selectionGeneration == conversationSelectionGeneration, let card, isConversationServerBacked(cardID)
        else { return }
        _ = await ensureConversationConnection(card, reportOffline: false)
    }

    func bindConversation() {
        conversationModel.core = core
        conversationModel.onAccepted = { [weak self] _, _ in self?.bindWorktree() }
        conversationModel.onContentPresentation = { [weak self] presentation, cardID in
            guard let self, let url = ConversationPresentedContent.url(for: presentation) else { return }
            self.conversationContext.content.requestPresentation(
                url, conversationID: cardID, presentationTitle: presentation.title)
        }
    }

    @discardableResult func loadEarlierMessages() async -> Bool {
        await conversationModel.loadEarlierMessages()
    }

    func closeConversation() {
        conversationSelectionGeneration &+= 1
        resetWorkspaceSurface()
        conversationModel.observe(nil)
        conversation = nil
        selectedDetail = nil
        selectedCardID = nil
        selectedChatID = nil
        conversationLoading = false
        conversationSyncing = false
        conversationLastRefreshedAt = nil
        conversationModel.resetConversationHistory()
        Task { await perform { $0.setVisibleConversation = ClientSetVisibleConversation() } }
    }

    func resetWorkspaceSurface() { worktreeChanges.resetWorkspaceSurface() }

    nonisolated static func isExpectedCancellation(_ error: Error) -> Bool {
        Task.isCancelled || error is CancellationError
    }

    func sendComposer() async {
        guard let id = selectedCardID ?? selectedChatID else { return }
        do {
            // The core sends the trimmed text ahead of the attachments, with the
            // composer's agent choice, else the conversation's agent.
            try await composer.draft.send { text, attachments in
                try await self.core.dispatch {
                    $0.sendMessage = .with { send in
                        send.cardID = id
                        send.text = text
                        send.parts = attachments
                    }
                }
            }
        } catch {
            show(error)
        }
    }

    /// Dequeues a not-yet-started message. Editing restores its text and every
    /// attachment ahead of any draft already in the composer, so neither
    /// queued nor in-progress input is lost.
    @discardableResult
    func removeQueuedMessage(_ message: Dieter_V1_QueuedMessage, edit: Bool) async -> Bool {
        guard let cardID = selectedCardID ?? selectedChatID else { return false }
        let draft = composer.draft
        do {
            return try await draft.removeQueuedMessage(message, edit: edit) { messageID in
                try await self.core.dispatch {
                    $0.removeQueuedMessage = .with {
                        $0.cardID = cardID
                        $0.messageID = messageID
                        $0.edit = edit
                    }
                }.queuedMessage
            }
        } catch {
            show(error)
            return false
        }
    }

    /// Changes the selected conversation's composer agent. The core keeps the
    /// choice in its draft and checks the pickers allow it.
    func chooseAgent(_ choice: ClientAgentChoice.OneOf_Choice) async {
        guard let id = selectedCardID ?? selectedChatID else { return }
        #if DIETER_UI_SMOKE
            if let fixture = conversationModel.agentFixture {
                conversationModel.agentFixture = AgentControlFields.controls(
                    fixture.selection, catalog: harnessCatalog, choice: choice)
                return
            }
        #endif
        await perform {
            $0.chooseAgent = .with {
                $0.cardID = id
                $0.choice = .with { $0.choice = choice }
            }
        }
    }

    /// Lets the queued message `messageID` interrupt the running turn now;
    /// the core checks it is the one that may.
    func steerConversation(messageID: String) async {
        guard let id = selectedCardID ?? selectedChatID, !messageID.isEmpty else { return }
        await perform {
            $0.steerConversation = .with {
                $0.cardID = id
                $0.messageID = messageID
            }
        }
    }

    @discardableResult
    func retryFailedTurn(_ failure: ClientTurnFailure) async -> Bool {
        guard failure.retryable, let id = selectedCardID ?? selectedChatID else { return false }
        guard let result = await perform({ $0.retryFailedTurn = .with { $0.cardID = id } }) else { return false }
        return !result.messageQueued.messageID.isEmpty
    }

    func toolOutput(
        messageID: String,
        toolCallID: String,
        revision: String
    ) async throws -> Dieter_V1_ToolOutput? {
        guard !toolCallID.isEmpty, let cardID = selectedCardID ?? selectedChatID else { return nil }
        return try await core.dispatch {
            $0.loadToolOutput = .with {
                $0.cardID = cardID
                $0.messageID = messageID
                $0.toolCallID = toolCallID
                $0.revision = revision
            }
        }.toolOutput
    }

    func addAttachments(_ urls: [URL]) {
        let draft = composer.draft
        let generation = draft.intakeGeneration
        Task {
            do {
                let parts = try await attachmentParts(urls, appendingTo: [])
                guard draft.intakeGeneration == generation else { return }
                draft.attachments = try AttachmentLoader.validate(parts, appendingTo: draft.attachments)
            } catch { if composer.draft === draft { show(error) } }
        }
    }

    func addPastedAttachments(_ providers: [NSItemProvider]) {
        let draft = composer.draft
        let generation = draft.intakeGeneration
        Task {
            do {
                let parts = try await attachmentParts(providers, appendingTo: [])
                guard draft.intakeGeneration == generation else { return }
                draft.attachments = try AttachmentLoader.validate(parts, appendingTo: draft.attachments)
            } catch { if composer.draft === draft { show(error) } }
        }
    }

    func attachmentParts(
        _ urls: [URL],
        appendingTo existing: [Dieter_V1_MessagePart] = []
    ) async throws -> [Dieter_V1_MessagePart] {
        try await attachmentLoader.parts(urls: urls, appendingTo: existing)
    }

    func attachmentParts(
        _ providers: [NSItemProvider], appendingTo existing: [Dieter_V1_MessagePart] = []
    ) async throws
        -> [Dieter_V1_MessagePart]
    {
        // Rule out too many attachments before reading any; sizes are checked as they load.
        try AttachmentLoader.checkLimits(
            names: existing.map(\.filename) + providers.map { _ in "" },
            sizes: existing.map { Int64($0.data.count) } + providers.map { _ in 1 })
        var parts = existing
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                let url = try await Self.loadFileURL(provider)
            {
                parts = try await attachmentLoader.parts(urls: [url], appendingTo: parts)
                continue
            }
            guard let identifier = Self.preferredImageTypeIdentifier(for: provider) else {
                throw DieterAttachmentError.unsupportedPaste
            }
            let sourceData = try await Self.loadData(provider, typeIdentifier: identifier)
            parts = try await attachmentLoader.parts(
                images: [
                    .init(
                        data: sourceData,
                        typeIdentifier: identifier,
                        suggestedName: provider.suggestedName
                    )
                ],
                appendingTo: parts
            )
        }
        return parts
    }

    /// Attaches whatever attachable content is on the pasteboard to the composer.
    /// Returns false when the pasteboard holds nothing attachable (plain text),
    /// so the caller can let the focused text view handle ⌘V normally.
    @discardableResult
    func attachPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard let input = pasteboardAttachmentInput(pasteboard) else { return false }
        let existing = composerAttachments
        Task {
            do { composerAttachments = try await attachmentParts(input, appendingTo: existing) } catch {
                show(error)
            }
        }
        return true
    }

    /// Returns nil when the pasteboard has no files or images to attach.
    func pasteboardAttachmentInput(
        _ pasteboard: NSPasteboard,
    ) -> AttachmentPasteboardInput? {
        let urls =
            (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                as? [URL]) ?? []
        if !urls.isEmpty { return .urls(urls) }
        let payloads = Self.pasteboardImagePayloads(pasteboard)
        guard !payloads.isEmpty else { return nil }
        return .images(
            payloads.map {
                AttachmentImageInput(data: $0.data, typeIdentifier: $0.type.identifier, suggestedName: nil)
            })
    }

    func attachmentParts(
        _ input: AttachmentPasteboardInput,
        appendingTo existing: [Dieter_V1_MessagePart] = []
    ) async throws -> [Dieter_V1_MessagePart] {
        switch input {
        case .urls(let urls):
            try await attachmentLoader.parts(urls: urls, appendingTo: existing)
        case .images(let images):
            try await attachmentLoader.parts(images: images, appendingTo: existing)
        }
    }

    static func pasteboardImagePayloads(_ pasteboard: NSPasteboard) -> [(data: Data, type: UTType)] {
        let preferred: [UTType] = [.png, .jpeg, .gif, .heic, .tiff]
        return (pasteboard.pasteboardItems ?? []).compactMap { item in
            let types = item.types.compactMap { UTType($0.rawValue) }
            let type = preferred.first(where: types.contains) ?? types.first { $0.conforms(to: .image) }
            guard let type, let data = item.data(forType: NSPasteboard.PasteboardType(type.identifier))
            else {
                return nil
            }
            return (data, type)
        }
    }

    static func preferredImageTypeIdentifier(for provider: NSItemProvider) -> String? {
        let preferred = [UTType.png, .jpeg, .gif, .heic, .tiff]
        if let type = preferred.first(where: {
            provider.hasItemConformingToTypeIdentifier($0.identifier)
        }) {
            return type.identifier
        }
        return provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true
        }
    }

    static func loadData(_ provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: DieterAttachmentError.unsupportedPaste)
                }
            }
        }
    }

    static func loadFileURL(_ provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }
                if let url = item as? NSURL {
                    continuation.resume(returning: url as URL)
                    return
                }
                if let data = item as? Data,
                    let value = String(data: data, encoding: .utf8),
                    let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
                {
                    continuation.resume(returning: url)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    /// Creates a conversation from a form's choices. The core applies the
    /// defaults, checks the choices, queues the creation until its machine
    /// accepts it (even while that machine is offline), and remembers them.
    /// Chats and started tasks open.
    @discardableResult
    func createConversation(
        _ intent: ClientCreationIntent, chat: Bool, submissionID: String = UUID().uuidString
    ) async -> Bool {
        guard
            let created = await perform({
                $0.createConversation = .with {
                    $0.intent = intent
                    $0.chat = chat
                    $0.submissionID = submissionID
                }
            })
        else { return false }
        createConversationPresented = false
        if SharedRules.shared.opensAfterCreate(chat: chat, lane: created.card.lane) {
            await openConversation(cardID: created.card.id, chat: chat)
        }
        section = chat ? .chats : .board
        return true
    }

    func move(
        _ card: Dieter_V1_Card, lane: String,
        afterCardID: String = "", beforeCardID: String = ""
    ) async {
        guard !movingCardIDs.contains(card.id) else { return }
        await perform {
            $0.moveCard = .with {
                $0.cardID = card.id
                $0.lane = lane
                $0.afterCardID = afterCardID
                $0.beforeCardID = beforeCardID
            }
        }
    }

    /// Moves a card to its board's done lane, as the core finds that lane.
    func finish(_ card: Dieter_V1_Card) async {
        guard !movingCardIDs.contains(card.id) else { return }
        await perform { $0.finishCard = .with { $0.cardID = card.id } }
    }

    func start(_ card: Dieter_V1_Card) async {
        guard isConversationServerBacked(card.id), boardState.operations[card.id] != "STARTING" else { return }
        let hasDraftAttachments =
            conversation?.detail.card.id == card.id
            && !(conversation?.conversation.draftAttachments.isEmpty ?? true)
        await perform {
            $0.startCard = .with {
                $0.cardID = card.id
                $0.hasDraftAttachments_p = hasDraftAttachments
            }
        }
    }

    func rename(_ card: Dieter_V1_Card, title: String) async {
        await perform {
            $0.renameCard = .with {
                $0.cardID = card.id
                $0.title = title
            }
        }
    }

    func merge(_ source: Dieter_V1_Card, into target: Dieter_V1_Card) async {
        await perform {
            $0.mergeCard = .with {
                $0.sourceCardID = source.id
                $0.targetCardID = target.id
            }
        }
    }

    @discardableResult
    func update(
        _ card: Dieter_V1_Card, title: String, initialPrompt: String,
        agentSettings: Dieter_V1_DraftAgentSettings? = nil
    ) async -> Bool {
        await perform {
            $0.updateCardDraft = .with { update in
                update.cardID = card.id
                update.title = title
                update.prompt = initialPrompt
                if let agentSettings { update.agent = agentSettings }
            }
        } != nil
    }

    func archive(_ card: Dieter_V1_Card, archived: Bool) async {
        let generation = conversationSelectionGeneration
        if archived {
            guard await perform({ $0.archiveCard = .with { $0.cardID = card.id } }) != nil else { return }
            if generation == conversationSelectionGeneration, (selectedCardID ?? selectedChatID) == card.id {
                closeConversation()
            }
        } else if !card.boardID.isEmpty {
            await perform {
                $0.restoreCard = .with {
                    $0.cardID = card.id
                    $0.boardID = card.boardID
                }
            }
            archivedCards.removeAll { $0.id == card.id }
        } else {
            // A chat has no board; the core restores it on its own machine.
            guard await perform({ $0.restoreCard = .with { $0.cardID = card.id } }) != nil else { return }
            archivedChats.removeAll { $0.id == card.id }
            foldWorkspace(coreWorkspace)
        }
    }

    func pin(_ card: Dieter_V1_Card, pinned: Bool) async {
        guard card.pinned != pinned else { return }
        await perform {
            $0.setCardPinned = .with {
                $0.cardID = card.id
                $0.pinned = pinned
            }
        }
    }

    func fork(_ card: Dieter_V1_Card, at messageID: String = "") async {
        guard
            let fork = await perform({
                $0.forkCard = .with {
                    $0.cardID = card.id
                    $0.messageID = messageID
                }
            })
        else { return }
        await openConversation(cardID: fork.card.id, chat: true)
    }

    func cancel(_ card: Dieter_V1_Card) async {
        await perform { $0.cancelCard = .with { $0.cardID = card.id } }
    }

    /// Adds a label to `card`; a label it has already changes nothing.
    func addLabel(_ card: Dieter_V1_Card, labelID: String) async {
        await perform {
            $0.addCardLabel = .with {
                $0.cardID = card.id
                $0.labelID = labelID
            }
        }
    }

    func setLabels(_ card: Dieter_V1_Card, ids: [String]) async {
        let normalized = ids.reduce(into: [String]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        guard card.labelIds != normalized else { return }
        await perform {
            $0.setCardLabels = .with {
                $0.cardID = card.id
                $0.labelIds = normalized
            }
        }
    }

    func loadArchive() async {
        archiveRequestGeneration &+= 1
        let generation = archiveRequestGeneration
        let boardID = selectedBoardID
        archiveLoading = true
        archiveError = nil
        defer { if generation == archiveRequestGeneration { archiveLoading = false } }
        do {
            let cards =
                boardID.isEmpty
                ? [] : try await core.dispatch { $0.listArchivedCards = .with { $0.boardID = boardID } }.cards.cards
            let projects = try await administer { $0.archivedProjects = ClientAdminMachine() }.projects.projects
            guard generation == archiveRequestGeneration, boardID == selectedBoardID else { return }
            archivedProjects = projects
            archivedCards = cards
            await loadArchivedChats()
            if generation == archiveRequestGeneration { archiveError = chatsError }
        } catch {
            guard generation == archiveRequestGeneration else { return }
            if !Self.isExpectedCancellation(error) {
                archiveError = (error as? CoreFailure)?.message ?? error.localizedDescription
            }
        }
    }
}
