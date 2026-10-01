import AppKit
import DieterAPI
import Foundation
import GRPCCore
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
    func refreshChats(includeArchived: Bool = true) async {
        guard includeArchived else { return }
        chatsRequestGeneration &+= 1
        let generation = chatsRequestGeneration
        chatsLoading = true
        chatsError = nil
        defer { if generation == chatsRequestGeneration { chatsLoading = false } }
        do {
            // Every online machine's archived chats; live ones are in the workspace.
            let archived = try await administer { $0.archivedChats = ClientAdminStep() }.cards.cards
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
            chat || knownChat != nil || card?.scope.caseInsensitiveCompare("chat") == .orderedSame
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
        // Files, terminals, and review still use the attached machine's
        // feature plane, so follow the conversation to its machine.
        guard selectionGeneration == conversationSelectionGeneration, let card, isConversationServerBacked(cardID)
        else { return }
        _ = await ensureConversationConnection(card, reportOffline: false)
    }

    func bindConversation() {
        conversationModel.core = core
        conversationModel.onAccepted = { [weak self] snapshot, _ in
            guard let self else { return }
            self.bindWorktree()
            let harness = self.harnessCatalog.harnesses.first { $0.id == snapshot.detail.card.provider }
            self.composer.draft.reconcileSettings(card: snapshot.detail.card, harness: harness)
        }
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
        DieterRPCFailure.isCancellation(error)
    }

    func sendComposer() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !composerAttachments.isEmpty, let id = selectedCardID ?? selectedChatID
        else { return }
        let draft = composer.draft
        guard !draft.sending else { return }
        draft.sending = true
        defer { draft.sending = false }
        let draftRevision = draft.revision
        var parts = draft.attachments
        if !text.isEmpty {
            var part = Dieter_V1_MessagePart()
            part.type = "text"
            part.text = text
            parts.insert(part, at: 0)
        }
        var settings = Dieter_V1_SendMessageRequest()
        draft.applySettings(to: &settings, fallback: selectedCard ?? selectedDetail?.card)
        let queuesBehindActiveTurn =
            conversationModel.state.activeTurn || !(conversation?.conversation.queue.isEmpty ?? true)
        do {
            try await core.dispatch {
                $0.sendMessage = .with { send in
                    send.cardID = id
                    send.parts = parts
                    send.selection = .with {
                        $0.provider = settings.provider
                        $0.model = settings.model
                        $0.effort = settings.effort
                        $0.providerOptions = settings.providerOptions
                    }
                    send.queue = queuesBehindActiveTurn
                }
            }
            draft.acceptSend(revision: draftRevision)
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

    @discardableResult
    func retryFailedTurn(_ failure: ConversationTurnFailure) async -> Bool {
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
        guard existing.count + providers.count <= AttachmentLoader.maximumCount else {
            throw DieterAttachmentError.tooMany
        }
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

    static func filename(_ value: String, for contentType: UTType) -> String {
        let url = URL(fileURLWithPath: value)
        guard url.pathExtension.isEmpty, let suffix = contentType.preferredFilenameExtension else {
            return value
        }
        return value + "." + suffix
    }

    @discardableResult
    func createConversation(
        title: String,
        prompt: String,
        attachments: [Dieter_V1_MessagePart] = [],
        chat: Bool,
        provider: String,
        model: String,
        effort: String,
        providerOptions: [String: String] = [:],
        deferred: Bool,
        projectID: String? = nil,
        lane: String? = nil,
        labelIDs: [String] = [],
        workspace: ConversationWorkspaceDraft = ConversationWorkspaceDraft(),
        autoGenerateTitle: Bool = false
    ) async -> Bool {
        let destinationProjectID = projectID ?? selectedProjectID
        var request = Dieter_V1_CreateConversationRequest()
        request.projectID = destinationProjectID
        let checkouts = projectDirectory[destinationProjectID]?.checkouts.filter { !$0.detached } ?? []
        let chosen =
            checkouts.first { $0.id == creationCheckoutIDs[destinationProjectID] }
            ?? checkouts.first { $0.daemonID == endpoint.daemonID }
            ?? checkouts.first
        request.checkoutID = chosen?.id ?? ""
        request.boardID = chat ? "" : selectedBoardID
        request.lane = lane ?? selectedBoard?.lanes.first?.id ?? "backlog"
        request.title = title
        request.prompt = prompt
        request.provider = provider
        request.model = model
        request.effort = effort
        request.deferStart = deferred
        request.providerOptions = providerOptions
        request.attachments = attachments
        request.labelIds = labelIDs
        request.autoGenerateTitle = autoGenerateTitle
        workspace.apply(to: &request)
        // The outbox keeps the creation until its machine accepts it, even
        // while that machine is offline.
        guard
            let created = await perform({
                $0.createConversation = .with {
                    $0.request = request
                    $0.chat = chat
                }
            })
        else { return false }
        createConversationPresented = false
        if Self.shouldOpenCreatedConversation(chat: chat, lane: request.lane) {
            await openConversation(cardID: created.card.id, chat: chat)
        }
        section = chat ? .chats : .board
        return true
    }

    nonisolated static func shouldOpenCreatedConversation(chat: Bool, lane: String) -> Bool {
        chat || lane.caseInsensitiveCompare("todo") != .orderedSame
    }

    func move(
        _ card: Dieter_V1_Card, lane: String,
        afterCardID: String = "", beforeCardID: String = ""
    ) async {
        guard pendingCardMoves[card.id] == nil else { return }
        await perform {
            $0.moveCard = .with {
                $0.cardID = card.id
                $0.lane = lane
                $0.afterCardID = afterCardID
                $0.beforeCardID = beforeCardID
            }
        }
    }

    func start(_ card: Dieter_V1_Card) async {
        guard isConversationServerBacked(card.id), pendingCardStarts[card.id] == nil else { return }
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
            await refreshChats(includeArchived: true)
            if generation == archiveRequestGeneration { archiveError = chatsError }
        } catch {
            guard generation == archiveRequestGeneration else { return }
            if !Self.isExpectedCancellation(error) {
                archiveError = (error as? CoreFailure)?.message ?? DieterRPCFailure.message(for: error)
            }
        }
    }
}
