import AppKit
import DieterAPI
import Foundation
import GRPCCore
import OSLog
import Observation
import UniformTypeIdentifiers
import UserNotifications

extension DieterStore {
    func refreshChats(includeArchived: Bool = true) async {
        guard let rpc else { return }
        chatsRequestGeneration &+= 1
        let generation = chatsRequestGeneration
        chatsLoading = true
        chatsError = nil
        defer { if generation == chatsRequestGeneration { chatsLoading = false } }
        do {
            let response = try await chatsRead.value(key: "\(ObjectIdentifier(rpc)):\(includeArchived)") {
                try await rpc.chats(includeArchived: includeArchived)
            }
            guard self.rpc === rpc, generation == chatsRequestGeneration else { return }
            let refreshedChats = reconcilePendingChatPins(response.chats)
            notifyTransitions(refreshedChats, endpointID: endpoint.id)
            let previousProjectIDs = Set(
                projectEndpointIDs.compactMap { $0.value == endpoint.id ? $0.key : nil })
            for project in response.projects {
                projectDirectory[project.id] = project
                projectEndpointIDs[project.id] = endpoint.id
            }
            let combined = chats.filter { !previousProjectIDs.contains($0.projectID) } + refreshedChats
            let nextChats = Array(
                combined.reduce(into: [String: Dieter_V1_Card]()) { $0[$1.id] = $1 }.values
            ).sorted {
                ($0.lastActivityAt.isEmpty ? $0.updatedAt : $0.lastActivityAt)
                    > ($1.lastActivityAt.isEmpty ? $1.updatedAt : $1.lastActivityAt)
            }
            if chats != nextChats { chats = nextChats }
            chatProjects = projects
            updateSelectedState()
            rebuildOutboxOverlays()
            if let selectedChatID, let selected = chats.first(where: { $0.id == selectedChatID }) {
                markChatRead(selected)
            }
        } catch {
            guard self.rpc === rpc, generation == chatsRequestGeneration else { return }
            if !Self.isExpectedCancellation(error) { chatsError = DieterRPCFailure.message(for: error) }
        }
    }

    func openConversation(cardID: String, chat: Bool = false) async {
        conversationSelectionGeneration &+= 1
        let selectionGeneration = conversationSelectionGeneration
        conversationError = nil
        conversationRead.cancel()
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
        let endpointID = projectEndpointIDs[projectID] ?? endpoint.id
        stopTerminalWatch()
        section = opensChat ? .chats : .board
        if !projectID.isEmpty {
            selectedProjectID = projectID
            if !opensChat, let boardID = card?.boardID, !boardID.isEmpty {
                selectedBoardID = boardID
            }
            updateSelectedState()
        }
        selectedCardID = opensChat ? nil : cardID
        selectedChatID = opensChat ? cardID : nil
        if opensChat { lastUsedChatID = cardID }
        if opensChat { newChatProjectID = "" }
        resetConversationHistory()
        conversationTask?.cancel()
        gitOperationTask?.cancel()
        resetWorkspaceSurface()
        conversation = nil
        selectedDetail = nil
        conversationLastRefreshedAt = nil
        guard isConversationServerBacked(cardID) else {
            conversationLoading = false
            conversationSyncing = false
            if let entry = outbox.entries.first(where: { $0.optimisticID == cardID }),
                let request = try? Dieter_V1_CreateConversationRequest(serializedBytes: entry.request)
            {
                var snapshot = Dieter_V1_ConversationSnapshot()
                snapshot.detail.card = card ?? Dieter_V1_Card()
                snapshot.detail.project = projectDirectory[request.projectID] ?? Dieter_V1_Project()
                if !opensChat { snapshot.detail.board = board(id: request.boardID) ?? Dieter_V1_Board() }
                snapshot.conversation.cardID = cardID
                snapshot.conversation.status = entry.state == .failed ? "failed" : "pending"
                snapshot.conversation.draftAttachments = request.attachments
                conversation = snapshot
                selectedDetail = snapshot.detail
            }
            return
        }

        conversationLoading = true
        let cached = await projectedConversation(cardID: cardID, endpointID: endpointID)
        guard selectionGeneration == conversationSelectionGeneration else { return }
        if let cached {
            await acceptConversation(
                cached,
                chat: opensChat,
                refreshedAt: conversationRefreshDate(cardID: cardID, endpointID: endpointID),
                cache: false
            )
            conversationLoading = false
        } else {
            conversationLoading = true
        }
        guard selectionGeneration == conversationSelectionGeneration else { return }
        conversationSyncing = true
        if !projectID.isEmpty, !(await ensureProjectConnection(projectID, reportOffline: false)) {
            guard selectionGeneration == conversationSelectionGeneration,
                (selectedCardID ?? selectedChatID) == cardID
            else { return }
            conversationLoading = false
            conversationSyncing = false
            conversationError = "This machine is unavailable. Cached messages remain readable."
            return
        }
        guard selectionGeneration == conversationSelectionGeneration,
            (selectedCardID ?? selectedChatID) == cardID
        else { return }
        guard let rpc else {
            conversationLoading = false
            conversationSyncing = false
            conversationError = "This machine is unavailable. Reconnect and retry."
            return
        }
        await fetchConversation(cardID: cardID, chat: opensChat, rpc: rpc)
    }

    func bindConversation() {
        conversationModel.bind(client: rpc, endpointID: endpoint.id)
        conversationModel.onAccepted = { [weak self] snapshot, chat in
            guard let self else { return }
            self.bindWorktree()
            let draft = self.composer.draft
            let harness = self.harnessCatalog.harnesses.first { $0.id == snapshot.detail.card.provider }
            draft.reconcileSettings(card: snapshot.detail.card, harness: harness)
            if chat, let card = self.chats.first(where: { $0.id == snapshot.detail.card.id }) {
                self.markChatRead(card)
            }
        }
        conversationModel.onSnapshot = { [weak self] snapshot, endpointID, refreshedAt in
            guard let self else { return }
            if self.endpoint.id == endpointID,
                (self.selectedCardID ?? self.selectedChatID) == snapshot.detail.card.id
            {
                let harness = self.harnessCatalog.harnesses.first { $0.id == snapshot.detail.card.provider }
                self.composer.draft.reconcileSettings(card: snapshot.detail.card, harness: harness)
            }
            await self.cacheConversation(snapshot, endpointID: endpointID, refreshedAt: refreshedAt)
        }
        conversationModel.onTransportFailure = { [weak self] error, client in
            guard let rpc = client as? DieterRPC else { return }
            self?.connectionStopped(error, client: rpc)
        }
        conversationModel.onContentPresentation = { [weak self] presentation, cardID in
            guard let self, let url = ConversationPresentedContent.url(for: presentation) else { return }
            self.conversationContext.content.requestOpen(
                url, conversationID: cardID, presentationTitle: presentation.title)
        }
    }

    func fetchConversation(cardID: String, chat: Bool, rpc: DieterRPC, cancellationRetries: Int = 0)
        async
    {
        bindConversation()
        await conversationModel.fetchConversation(
            cardID: cardID, chat: chat, rpc: rpc, cancellationRetries: cancellationRetries)
    }
    func acceptConversation(
        _ snapshot: Dieter_V1_ConversationSnapshot, chat: Bool, refreshedAt: Date? = Date(),
        cache: Bool = true
    ) async {
        bindConversation()
        await conversationModel.acceptConversation(
            snapshot, chat: chat, refreshedAt: refreshedAt, cache: cache)
    }
    @discardableResult func loadEarlierMessages() async -> Bool {
        bindConversation()
        return await conversationModel.loadEarlierMessages()
    }
    func resetConversationHistory(from snapshot: Dieter_V1_ConversationSnapshot? = nil) {
        conversationModel.resetConversationHistory(from: snapshot)
    }
    func applyConversationUpdate(
        _ update: Dieter_V1_ConversationUpdate, cardID: String, client: DieterRPC? = nil,
        selectionGeneration: UInt64? = nil
    ) async {
        await conversationModel.applyConversationUpdate(
            update, cardID: cardID, client: client, selectionGeneration: selectionGeneration)
    }

    func closeConversation() {
        conversationSelectionGeneration &+= 1
        conversationRead.cancel()
        if let selectedChatID, let card = chats.first(where: { $0.id == selectedChatID }) {
            markChatRead(card)
        }
        conversationTask?.cancel()
        conversationTask = nil
        gitOperationTask?.cancel()
        gitOperationTask = nil
        resetWorkspaceSurface()
        conversation = nil
        selectedDetail = nil
        selectedCardID = nil
        selectedChatID = nil
        conversationLoading = false
        conversationSyncing = false
        conversationLastRefreshedAt = nil
        resetConversationHistory()
    }

    func resetWorkspaceSurface() { worktreeChanges.resetWorkspaceSurface() }

    nonisolated static func isExpectedCancellation(_ error: Error) -> Bool {
        DieterRPCFailure.isCancellation(error)
    }

    nonisolated static func retainedHistoryPrefix(
        current: [Dieter_V1_UiMessage], replacementIDs: Set<String>
    )
        -> [Dieter_V1_UiMessage]?
    {
        ConversationModel.retainedHistoryPrefix(current: current, replacementIDs: replacementIDs)
    }
    func apply(_ update: Dieter_V1_ConversationUpdate) { conversationModel.apply(update) }

    func sendComposer() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !composerAttachments.isEmpty, let id = selectedCardID ?? selectedChatID
        else { return }
        let projectID = (selectedCard ?? selectedDetail?.card)?.projectID ?? ""
        let targetEndpointID = projectEndpointIDs[projectID] ?? endpoint.id
        let draft = composer.draft
        guard !draft.sending else { return }
        draft.sending = true
        defer { draft.sending = false }
        let draftRevision = draft.revision
        let attachments = draft.attachments
        var parts = attachments
        if !text.isEmpty {
            var part = Dieter_V1_MessagePart()
            part.type = "text"
            part.text = text
            parts.insert(part, at: 0)
        }
        var request = Dieter_V1_SendMessageRequest()
        request.cardID = id
        request.parts = parts
        draft.applySettings(to: &request, fallback: selectedCard ?? selectedDetail?.card)
        request.clientID = syncClientID
        request.commandID = UUID().uuidString.lowercased()
        request.messageID =
            "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        do {
            try await enqueueMessage(request, endpointID: targetEndpointID)
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
        guard let cardID = selectedCardID ?? selectedChatID, let rpc else { return false }
        let draft = composer.draft
        do {
            return try await draft.removeQueuedMessage(message, edit: edit) { messageID in
                let removed = try await rpc.removeQueuedMessage(cardID: cardID, messageID: messageID)
                if (self.selectedCardID ?? self.selectedChatID) == cardID, var snapshot = self.conversation {
                    snapshot.conversation.queue.removeAll { $0.id == removed.id }
                    self.conversation = snapshot
                }
                return removed
            }
        } catch {
            show(error)
            return false
        }
    }

    @discardableResult
    func retryFailedTurn(_ failure: ConversationTurnFailure) async -> Bool {
        guard !failure.retryParts.isEmpty,
            let id = selectedCardID ?? selectedChatID,
            let card = selectedCard ?? selectedDetail?.card
        else { return false }
        let targetEndpointID = projectEndpointIDs[card.projectID] ?? endpoint.id
        var request = Dieter_V1_SendMessageRequest()
        request.cardID = id
        request.parts = failure.retryParts
        request.provider = card.provider
        request.model = card.model
        request.effort = card.effort
        request.providerOptions = card.providerOptions
        request.clientID = syncClientID
        request.commandID = UUID().uuidString.lowercased()
        request.messageID =
            "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        do {
            try await enqueueMessage(request, endpointID: targetEndpointID)
            return true
        } catch {
            show(error)
            return false
        }
    }

    func toolOutput(
        messageID: String,
        toolCallID: String,
        revision: String
    ) async throws -> Dieter_V1_ToolOutput? {
        guard !toolCallID.isEmpty,
            let cardID = selectedCardID ?? selectedChatID,
            let rpc
        else { return nil }
        var request = Dieter_V1_GetToolOutputRequest()
        request.cardID = cardID
        request.messageID = messageID
        request.toolCallID = toolCallID
        request.revision = revision
        return try await rpc.toolOutput(request)
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

    func addComment() async {
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = selectedCardID ?? selectedChatID, let rpc else { return }
        var request = Dieter_V1_AddCommentRequest()
        request.cardID = id
        request.message = text
        request.name = NSFullUserName()
        let draft = composer.draft
        let generation = conversationSelectionGeneration
        do {
            _ = try await rpc.addComment(request)
            if draft.comment.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                draft.comment = ""
            }
            let detail = try await rpc.card(id: id)
            guard self.rpc === rpc, generation == conversationSelectionGeneration,
                (selectedCardID ?? selectedChatID) == id
            else { return }
            selectedDetail = detail
        } catch {
            if self.rpc === rpc, generation == conversationSelectionGeneration { show(error) }
        }
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
        request.clientID = syncClientID
        request.commandID = UUID().uuidString.lowercased()
        do {
            let shouldOpenConversation = Self.shouldOpenCreatedConversation(
                chat: chat, lane: request.lane)
            guard
                let optimisticID = DieterOutboxPolicy.expectedConversationID(
                    clientID: request.clientID, commandID: request.commandID)
            else { throw CocoaError(.validationMissingMandatoryProperty) }
            let target = projectEndpointIDs[destinationProjectID].flatMap { id in
                endpoints.first { $0.id == id }
            }
            try await enqueueOutbox(
                DieterOutboxEntry(
                    commandID: request.commandID,
                    clientID: syncClientID,
                    endpointID: target?.id ?? endpoint.id,
                    kind: chat ? .createChat : .createCard,
                    request: try request.serializedData(),
                    optimisticID: optimisticID,
                    attempts: 0,
                    createdAt: Date()
                ))
            createConversationPresented = false
            rebuildOutboxOverlays()
            if shouldOpenConversation {
                let card = (chat ? chats : state.cards).first { $0.id == optimisticID } ?? Dieter_V1_Card()
                var local = Dieter_V1_ConversationSnapshot()
                local.detail.card = card
                local.detail.project = projectDirectory[destinationProjectID] ?? Dieter_V1_Project()
                if !chat { local.detail.board = board(id: request.boardID) ?? Dieter_V1_Board() }
                local.conversation.cardID = optimisticID
                local.conversation.status = "pending"
                local.conversation.draftAttachments = attachments
                conversation = local
                selectedDetail = local.detail
                selectedCardID = chat ? nil : optimisticID
                selectedChatID = chat ? optimisticID : nil
            }
            section = chat ? .chats : .board
            return true
        } catch {
            show(error)
            return false
        }
    }

    nonisolated static func shouldOpenCreatedConversation(chat: Bool, lane: String) -> Bool {
        chat || lane.caseInsensitiveCompare("todo") != .orderedSame
    }

    func markChatRead(_ card: Dieter_V1_Card) {
        let activity = card.lastActivityAt.isEmpty ? card.updatedAt : card.lastActivityAt
        guard !activity.isEmpty, readChatActivity[card.id] != activity else { return }
        readChatActivity[card.id] = activity
        environment.defaults.set(readChatActivity, forKey: "DieterReadChatActivity")
    }

    func move(_ card: Dieter_V1_Card, lane: String, position: Int64? = nil) async {
        guard selectedProjectIsLive, let rpc else { return }
        let original = state.cards.first(where: { $0.id == card.id }) ?? card
        let optimisticPosition =
            position
            ?? ((boardCards.filter { $0.id != card.id && $0.lane == lane }.map(\.position).max() ?? 0)
                + 1_024)

        let operationID = UUID()
        pendingCardMoves[card.id] = OptimisticCardMove(
            operationID: operationID,
            lane: lane,
            position: optimisticPosition,
            confirmsPosition: position != nil || original.lane == lane
        )

        var optimistic = original
        optimistic.lane = lane
        optimistic.position = optimisticPosition
        acceptWorkspaceCard(optimistic)
        movingCardIDs.insert(card.id)

        var request = Dieter_V1_MoveCardRequest()
        request.cardID = card.id
        request.lane = lane
        if let position { request.position = position }
        do {
            let moved = try await rpc.moveCard(request)
            if var pending = pendingCardMoves[card.id], pending.operationID == operationID {
                pending.position = moved.position
                pending.confirmsPosition = pending.confirmsPosition || original.lane == lane
                pendingCardMoves[card.id] = pending
            } else if pendingCardMoves[card.id] != nil {
                return
            }
            guard self.rpc === rpc else { return }
            acceptWorkspaceCard(moved)
        } catch {
            guard pendingCardMoves[card.id]?.operationID == operationID else { return }
            pendingCardMoves.removeValue(forKey: card.id)
            movingCardIDs.remove(card.id)
            if self.rpc === rpc { acceptWorkspaceCard(original) }
            show(error)
        }
    }

    func start(_ card: Dieter_V1_Card) async {
        guard isConversationServerBacked(card.id) else { return }
        guard await ensureProjectConnection(card.projectID) else { return }
        guard let client = cardStartRPCOverride ?? rpc else { return }
        let current = state.cards.first(where: { $0.id == card.id }) ?? card
        let board = board(id: current.boardID)
        let hasDraftAttachments =
            conversation?.detail.card.id == current.id
            && !(conversation?.conversation.draftAttachments.isEmpty ?? true)
        guard
            let optimistic = BoardCardStartPolicy.optimisticCard(
                current,
                board: board,
                hasDraftAttachments: hasDraftAttachments
            ), pendingCardStarts[current.id] == nil
        else { return }

        let operationID = UUID()
        pendingCardStarts[current.id] = .init(
            operationID: operationID,
            runningLaneID: optimistic.lane
        )
        applyBoardCardMutation(optimistic)

        var request = Dieter_V1_StartCardRequest()
        request.cardID = current.id
        request.clientID = syncClientID
        request.commandID = UUID().uuidString.lowercased()
        do {
            let response = try await client.startCard(request)
            guard pendingCardStarts[current.id]?.operationID == operationID else { return }
            applyBoardCardMutation(response.card)
        } catch {
            guard pendingCardStarts[current.id]?.operationID == operationID else { return }
            pendingCardStarts.removeValue(forKey: current.id)
            applyBoardCardMutation(current)
            show(error)
        }
    }

    func applyBoardCardMutation(_ updated: Dieter_V1_Card) {
        if let index = state.cards.firstIndex(where: { $0.id == updated.id }) {
            var next = state
            next.cards[index] = updated
            state = next
        }
        if var cards = navigationCards[updated.projectID],
            let index = cards.firstIndex(where: { $0.id == updated.id })
        {
            cards[index] = updated
            navigationCards[updated.projectID] = cards
        }
        if var detail = selectedDetail, detail.card.id == updated.id {
            detail.card = updated
            selectedDetail = detail
        }
        if var snapshot = conversation, snapshot.detail.card.id == updated.id {
            snapshot.detail.card = updated
            snapshot.conversation.status = updated.runtime
            conversation = snapshot
        }
    }

    func rename(_ card: Dieter_V1_Card, title: String) async {
        guard await ensureProjectConnection(card.projectID) else { return }
        guard let rpc else { return }
        var request = Dieter_V1_RenameCardRequest()
        request.cardID = card.id
        request.title = title
        do {
            _ = try await rpc.renameCard(request)
            await refreshState()
            await refreshChats()
        } catch { show(error) }
    }

    func merge(_ source: Dieter_V1_Card, into target: Dieter_V1_Card) async {
        guard await ensureProjectConnection(source.projectID), let rpc else { return }
        var request = Dieter_V1_MergeCardRequest()
        request.cardID = source.id
        request.targetCardID = target.id
        do {
            _ = try await rpc.mergeCard(request)
            await refreshState()
        } catch { show(error) }
    }

    @discardableResult
    func update(
        _ card: Dieter_V1_Card, title: String, initialPrompt: String,
        agentSettings: Dieter_V1_DraftAgentSettings? = nil
    ) async -> Bool {
        guard await ensureProjectConnection(card.projectID), let rpc else { return false }
        var request = Dieter_V1_UpdateCardRequest()
        request.cardID = card.id
        request.title = title
        request.initialPrompt = initialPrompt
        if let agentSettings { request.agentSettings = agentSettings }
        do {
            _ = try await rpc.updateCard(request)
            await refreshState()
            return true
        } catch {
            show(error)
            return false
        }
    }

    func archive(_ card: Dieter_V1_Card, archived: Bool) async {
        guard await ensureProjectConnection(card.projectID) else { return }
        guard let rpc else { return }
        var request = Dieter_V1_ArchiveCardRequest()
        request.cardID = card.id
        request.archived = archived
        let generation = conversationSelectionGeneration
        do {
            let updated = try await rpc.archiveCard(request)
            guard self.rpc === rpc else { return }
            acceptWorkspaceCard(updated)
            if generation == conversationSelectionGeneration,
                (selectedCardID ?? selectedChatID) == card.id
            {
                closeConversation()
            }
            await refreshState()
            guard self.rpc === rpc else { return }
            await refreshChats()
        } catch { if self.rpc === rpc { show(error) } }
    }

    func pin(_ card: Dieter_V1_Card, pinned: Bool) async {
        guard await ensureProjectConnection(card.projectID) else { return }
        guard let client = chatPinRPCOverride ?? rpc else { return }
        let original =
            chats.first(where: { $0.id == card.id })
            ?? state.chats.first(where: { $0.id == card.id })
            ?? card
        guard original.pinned != pinned else { return }
        let operationID = UUID()
        pendingChatPins[card.id] = PendingChatPin(
            operationID: operationID,
            pinned: pinned,
            original: original
        )
        var optimistic = original
        optimistic.pinned = pinned
        applyChatMutation(optimistic)

        var request = Dieter_V1_PinChatRequest()
        request.cardID = card.id
        request.pinned = pinned
        do {
            let updated = try await client.pinChat(request)
            guard pendingChatPins[card.id]?.operationID == operationID else { return }
            applyChatMutation(updated)
        } catch {
            guard let pending = pendingChatPins[card.id], pending.operationID == operationID else {
                return
            }
            pendingChatPins.removeValue(forKey: card.id)
            applyChatMutation(pending.original)
            show(error)
        }
    }

    func applyChatMutation(_ updated: Dieter_V1_Card) {
        if let index = chats.firstIndex(where: { $0.id == updated.id }) {
            chats[index] = updated
        } else if updated.scope == "chat", updated.boardID.isEmpty {
            chats.append(updated)
        }
        if var detail = selectedDetail, detail.card.id == updated.id {
            detail.card = updated
            selectedDetail = detail
        }
        if var snapshot = conversation, snapshot.detail.card.id == updated.id {
            snapshot.detail.card = updated
            conversation = snapshot
        }
        updateSelectedState()
    }

    func reconcilePendingChatPins(_ serverChats: [Dieter_V1_Card]) -> [Dieter_V1_Card] {
        serverChats.map { serverChat in
            guard let pending = pendingChatPins[serverChat.id] else { return serverChat }
            if serverChat.pinned == pending.pinned {
                pendingChatPins.removeValue(forKey: serverChat.id)
                return serverChat
            }
            var optimistic = serverChat
            optimistic.pinned = pending.pinned
            return optimistic
        }
    }

    func fork(_ card: Dieter_V1_Card, at messageID: String = "") async {
        guard await ensureProjectConnection(card.projectID), let rpc else { return }
        var request = Dieter_V1_ForkChatRequest()
        request.sourceCardID = card.id
        request.messageID = messageID
        do {
            let fork = try await rpc.forkChat(request)
            await refreshChats()
            await openConversation(cardID: fork.id, chat: true)
        } catch {
            show(error)
        }
    }

    func cancel(_ card: Dieter_V1_Card) async {
        guard await ensureProjectConnection(card.projectID), workspaceIsLive else { return }
        do {
            try await rpc?.cancelCard(id: card.id)
            await refreshState()
        } catch { show(error) }
    }

    func setLabels(_ card: Dieter_V1_Card, ids: [String]) async {
        guard selectedProjectIsLive, let rpc else { return }
        let normalized = ids.reduce(into: [String]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        let original = state.cards.first(where: { $0.id == card.id }) ?? card
        guard original.labelIds != normalized else { return }

        let operationID = UUID()
        pendingCardLabelUpdates[card.id] = .init(operationID: operationID, labelIDs: normalized)

        if let index = state.cards.firstIndex(where: { $0.id == card.id }) {
            var next = state
            next.cards[index].labelIds = normalized
            state = next
        }
        labelUpdatingCardIDs.insert(card.id)

        var request = Dieter_V1_SetCardLabelsRequest()
        request.cardID = card.id
        request.labelIds = normalized
        do {
            let updated = try await rpc.setCardLabels(request)
            if let pending = pendingCardLabelUpdates[card.id], pending.operationID != operationID {
                return
            }
            if let index = state.cards.firstIndex(where: { $0.id == updated.id }) {
                var next = state
                next.cards[index] = updated
                state = next
            }
        } catch {
            guard pendingCardLabelUpdates[card.id]?.operationID == operationID else { return }
            pendingCardLabelUpdates.removeValue(forKey: card.id)
            labelUpdatingCardIDs.remove(card.id)
            if let index = state.cards.firstIndex(where: { $0.id == original.id }) {
                var next = state
                next.cards[index] = original
                state = next
            }
            show(error)
        }
    }

    func loadArchive() async {
        guard let rpc else { return }
        archiveRequestGeneration &+= 1
        let generation = archiveRequestGeneration
        let boardID = selectedBoardID
        archiveLoading = true
        archiveError = nil
        defer { if generation == archiveRequestGeneration { archiveLoading = false } }
        do {
            async let projects = rpc.archivedProjects().projects
            let cards = boardID.isEmpty ? [] : try await rpc.archivedCards(boardID: boardID).cards
            let loadedProjects = try await projects
            guard self.rpc === rpc, generation == archiveRequestGeneration, boardID == selectedBoardID
            else { return }
            archivedProjects = loadedProjects
            archivedCards = cards
            await refreshChats(includeArchived: true)
            if generation == archiveRequestGeneration { archiveError = chatsError }
        } catch {
            guard self.rpc === rpc, generation == archiveRequestGeneration else { return }
            if !Self.isExpectedCancellation(error) { archiveError = DieterRPCFailure.message(for: error) }
        }
    }
}
