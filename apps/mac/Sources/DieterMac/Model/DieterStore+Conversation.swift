import AppKit
import DieterAPI
import Foundation
import GRPCCore
import Observation
import OSLog
import UniformTypeIdentifiers
import UserNotifications

extension DieterStore {
    func refreshChats(includeArchived: Bool = true) async {
        guard let rpc else { return }
        do {
            let response = try await rpc.chats(includeArchived: includeArchived)
            let refreshedChats = reconcilePendingChatPins(response.chats)
            for card in refreshedChats {
                if let previous = notificationStatuses[card.id], previous != card.runtime,
                   ["review", "waiting", "completed", "failed"].contains(card.runtime.lowercased()) {
                    notify(title: card.title, body: "Status changed to \(card.runtime)")
                }
                notificationStatuses[card.id] = card.runtime
            }
            let previousProjectIDs = Set(projectEndpointIDs.compactMap { $0.value == endpoint.id ? $0.key : nil })
            for project in response.projects {
                projectDirectory[project.id] = project
                projectEndpointIDs[project.id] = endpoint.id
            }
            chats.removeAll { previousProjectIDs.contains($0.projectID) }
            chats.append(contentsOf: refreshedChats)
            chats = Array(chats.reduce(into: [String: Dieter_V1_Card]()) { $0[$1.id] = $1 }.values).sorted {
                ($0.lastActivityAt.isEmpty ? $0.updatedAt : $0.lastActivityAt) > ($1.lastActivityAt.isEmpty ? $1.updatedAt : $1.lastActivityAt)
            }
            chatProjects = projects
            updateSelectedState()
            rebuildOutboxOverlays()
            if let selectedChatID, let selected = chats.first(where: { $0.id == selectedChatID }) {
                markChatRead(selected)
            }
        } catch {
            show(error)
        }
    }

    func openConversation(cardID: String, chat: Bool = false) async {
        let knownChat = chats.first(where: { $0.id == cardID })
            ?? state.chats.first(where: { $0.id == cardID })
        let card = knownChat
            ?? state.cards.first(where: { $0.id == cardID })
            ?? navigationCards.values.lazy.compactMap({ $0.first(where: { $0.id == cardID }) }).first
        let opensChat = chat || knownChat != nil || card?.scope.caseInsensitiveCompare("chat") == .orderedSame
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
        if opensChat { newChatProjectID = "" }
        resetConversationHistory()
        conversationTask?.cancel()
        gitOperationTask?.cancel()
        resetWorkspaceSurface()
        conversation = nil
        selectedDetail = nil
        conversationLastRefreshedAt = nil
        guard DieterConversationID.isServerBacked(cardID) else {
            conversationLoading = false
            conversationSyncing = false
            if let entry = syncDiskState.outbox.first(where: { $0.optimisticID == cardID }),
               let request = try? Dieter_V1_CreateConversationRequest(serializedBytes: entry.request) {
                var snapshot = Dieter_V1_ConversationSnapshot()
                snapshot.detail.card = card ?? Dieter_V1_Card()
                snapshot.detail.project = projectDirectory[request.projectID] ?? Dieter_V1_Project()
                if !opensChat { snapshot.detail.board = board(id: request.boardID) ?? Dieter_V1_Board() }
                snapshot.conversation.cardID = cardID
                snapshot.conversation.status = entry.state == .failed ? "failed" : "pending"
                snapshot.conversation.draftAttachments = request.attachments
                conversation = snapshot
                selectedDetail = snapshot.detail
                if entry.state == .failed, let failure = entry.lastError {
                    errorMessage = "Could not create this conversation: \(failure)"
                }
            }
            return
        }

        if let cached = projectedConversation(cardID: cardID, endpointID: endpointID) {
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
        conversationSyncing = true
        if !projectID.isEmpty, !(await ensureProjectConnection(projectID, reportOffline: false)) {
            guard (selectedCardID ?? selectedChatID) == cardID else { return }
            conversationLoading = false
            conversationSyncing = false
            return
        }
        guard (selectedCardID ?? selectedChatID) == cardID else { return }
        guard let rpc else {
            conversationLoading = false
            conversationSyncing = false
            return
        }
        await fetchConversation(cardID: cardID, chat: opensChat, rpc: rpc)
    }

    func fetchConversation(
        cardID: String,
        chat: Bool,
        rpc: DieterRPC,
        cancellationRetries: Int = 0
    ) async {
        do {
            let snapshot = try await rpc.conversation(cardID: cardID, limit: conversationPageSize)
            guard (selectedCardID ?? selectedChatID) == cardID else { return }
            await acceptConversation(snapshot, chat: chat)
            let after = snapshot.conversation.lastSeq
            conversationTask = Task { [weak self] in
                do {
                    try await rpc.watchConversation(cardID: cardID, after: after) { [weak self] update in
                        await self?.applyConversationUpdate(update, cardID: cardID)
                    }
                } catch where Self.isExpectedCancellation(error) { }
                catch {
                    guard let self, (self.selectedCardID ?? self.selectedChatID) == cardID else { return }
                    self.conversationSyncing = false
                    if DieterRPCFailure.isTransient(error) {
                        self.connectionStopped(error, client: rpc)
                    } else {
                        self.errorMessage = "Conversation updates paused: \(DieterRPCFailure.message(for: error))"
                    }
                }
            }
        } catch {
            switch DieterConversationOpenFailurePolicy.disposition(
                for: error,
                selectionMatches: (selectedCardID ?? selectedChatID) == cardID,
                cancellationRetries: cancellationRetries
            ) {
            case .ignore:
                return
            case .retry:
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self,
                          (self.selectedCardID ?? self.selectedChatID) == cardID else { return }
                    guard let currentRPC = self.rpc else {
                        self.conversationLoading = false
                        self.conversationSyncing = false
                        return
                    }
                    await self.fetchConversation(
                        cardID: cardID,
                        chat: chat,
                        rpc: currentRPC,
                        cancellationRetries: cancellationRetries + 1
                    )
                }
            case .report:
                conversationLoading = false
                conversationSyncing = false
                if DieterRPCFailure.isTransient(error) {
                    connectionStopped(error, client: rpc)
                } else {
                    errorMessage = "Could not open this conversation: \(DieterRPCFailure.message(for: error))"
                }
            }
        }
    }

    func acceptConversation(
        _ snapshot: Dieter_V1_ConversationSnapshot,
        chat: Bool,
        refreshedAt: Date? = Date(),
        cache: Bool = true
    ) async {
        if conversation != snapshot {
            resetConversationHistory(from: snapshot)
            conversation = snapshot
        }
        if selectedDetail != snapshot.detail { selectedDetail = snapshot.detail }
        conversationLoading = false
        conversationSyncing = false
        conversationLastRefreshedAt = refreshedAt
        composerProvider = snapshot.detail.card.provider
        composerModel = snapshot.detail.card.model
        composerEffort = snapshot.detail.card.effort
        let selectedHarness = harnessCatalog.harnesses.first { $0.id == composerProvider }
        composerProviderOptions = ProviderOptionValues.defaults(for: selectedHarness)
        composerProviderOptions.merge(snapshot.detail.card.providerOptions) { _, saved in saved }
        if chat, let card = chats.first(where: { $0.id == snapshot.detail.card.id }) { markChatRead(card) }
        if cache, let refreshedAt {
            await cacheConversation(snapshot, endpointID: endpoint.id, refreshedAt: refreshedAt)
        }
    }

    @discardableResult
    func loadEarlierMessages() async -> Bool {
        guard !conversationHistoryLoading,
              conversationHistoryHasMore,
              conversationHistoryStart > 0,
              let cardID = selectedCardID ?? selectedChatID,
              let rpc else { return false }
        let before = conversationHistoryStart
        let requestID = UUID()
        conversationHistoryRequestID = requestID
        conversationHistoryLoading = true
        defer {
            if conversationHistoryRequestID == requestID {
                conversationHistoryRequestID = nil
                conversationHistoryLoading = false
            }
        }
        do {
            let page = try await rpc.conversation(
                cardID: cardID,
                limit: conversationPageSize,
                before: Int32(before)
            )
            guard conversationHistoryRequestID == requestID,
                  (selectedCardID ?? selectedChatID) == cardID else { return false }
            let liveIDs = Set(conversation?.conversation.messages.map(\.id) ?? [])
            var seen = liveIDs
            olderConversationMessages = (page.conversation.messages + olderConversationMessages).filter { message in
                message.id.isEmpty || seen.insert(message.id).inserted
            }
            conversationHistoryStart = Int(page.page.start)
            conversationHistoryTotal = Int(page.page.total)
            conversationHistoryHasMore = page.page.hasMore_p
            return true
        } catch {
            guard conversationHistoryRequestID == requestID,
                  (selectedCardID ?? selectedChatID) == cardID else { return false }
            if DieterRPCFailure.isTransient(error) {
                connectionStopped(error, client: rpc)
            } else {
                errorMessage = "Could not load earlier messages: \(error.localizedDescription)"
            }
            return false
        }
    }

    func resetConversationHistory(from snapshot: Dieter_V1_ConversationSnapshot? = nil) {
        conversationHistoryRequestID = nil
        olderConversationMessages = []
        conversationHistoryStart = Int(snapshot?.page.start ?? 0)
        conversationHistoryTotal = Int(snapshot?.page.total ?? 0)
        conversationHistoryHasMore = snapshot?.page.hasMore_p ?? false
        conversationHistoryLoading = false
    }

    func applyConversationUpdate(_ update: Dieter_V1_ConversationUpdate, cardID: String) async {
        guard (selectedCardID ?? selectedChatID) == cardID else { return }
        apply(update)
        conversationSyncing = false
        if let conversation {
            await cacheConversation(conversation, endpointID: endpoint.id, refreshedAt: Date())
        }
    }

    func closeConversation() {
        if let selectedChatID, let card = chats.first(where: { $0.id == selectedChatID }) { markChatRead(card) }
        conversationTask?.cancel(); conversationTask = nil
        gitOperationTask?.cancel(); gitOperationTask = nil
        resetWorkspaceSurface()
        conversation = nil; selectedDetail = nil; selectedCardID = nil; selectedChatID = nil
        conversationLoading = false
        conversationSyncing = false
        conversationLastRefreshedAt = nil
        resetConversationHistory()
    }

    func resetWorkspaceSurface() {
        conversationWorkspace = nil
        conversationChangeset = nil
        conversationDiff = nil
        conversationChangeComments = []
        conversationSCMCapabilities = nil
        gitOperation = nil
        gitOperationLogs = []
        workspaceLoading = false
        workspaceError = nil
        selectedChangePath = ""
        selectedCommitSHA = ""
    }

    nonisolated static func isExpectedCancellation(_ error: Error) -> Bool {
        if Task.isCancelled || error is CancellationError { return true }
        return (error as? RPCError)?.code == .cancelled
    }

    // Splits the client's contiguous transcript at the first message the
    // replacement window still contains; nil when the windows are disjoint.
    nonisolated static func retainedHistoryPrefix(
        current: [Dieter_V1_UiMessage],
        replacementIDs: Set<String>
    ) -> [Dieter_V1_UiMessage]? {
        guard let overlap = current.firstIndex(where: { !$0.id.isEmpty && replacementIDs.contains($0.id) }) else { return nil }
        return current[..<overlap].filter { !$0.id.isEmpty }
    }

    func apply(_ update: Dieter_V1_ConversationUpdate) {
        if update.hasSnapshot {
            // The replacement snapshot only carries the server's bounded
            // window. Messages the client already has that precede the new
            // window slide into local history so the transcript never loses
            // content; with no overlap the retained prefix would leave an
            // unfillable gap, so history resets to the new page instead.
            let replacementIDs = Set(update.snapshot.conversation.messages.lazy.map(\.id).filter { !$0.isEmpty })
            if let retained = Self.retainedHistoryPrefix(current: conversationMessages, replacementIDs: replacementIDs) {
                olderConversationMessages = retained
            } else {
                olderConversationMessages = []
            }
            conversation = update.snapshot
            selectedDetail = update.snapshot.detail
            if olderConversationMessages.isEmpty {
                conversationHistoryStart = Int(update.snapshot.page.start)
                conversationHistoryHasMore = update.snapshot.page.hasMore_p
            }
            conversationHistoryTotal = max(conversationHistoryTotal, Int(update.snapshot.page.total))
            return
        }
        guard var snapshot = conversation else { return }
        var value = snapshot.conversation
        let removedIDs = Set(update.removedMessageIds)
        // Removed ids are almost always the window sliding forward during a
        // streaming turn, not deletions; keep those messages as history so
        // they don't vanish from the visible transcript.
        if !removedIDs.isEmpty {
            let known = Set(olderConversationMessages.lazy.map(\.id))
            let slidOut = value.messages.filter { removedIDs.contains($0.id) && !known.contains($0.id) }
            olderConversationMessages.append(contentsOf: slidOut)
        }
        var messages = value.messages.filter { !removedIDs.contains($0.id) }
        for changed in update.changedMessages {
            if let index = messages.firstIndex(where: { $0.id == changed.id }) { messages[index] = changed }
            else { messages.append(changed) }
        }
        value.messages = messages
        if !update.status.isEmpty { value.status = update.status }
        value.pendingTools = update.pendingTools; value.queue = update.queue
        value.draftAttachments = update.draftAttachments
        value.lastSeq = update.lastSeq; value.updatedAt = update.updatedAt
        value.subagents = update.subagents; value.taskPlans = update.taskPlans
        snapshot.conversation = value
        if update.hasDetail { snapshot.detail = update.detail; selectedDetail = update.detail }
        if update.hasPage {
            snapshot.page = update.page
            if olderConversationMessages.isEmpty {
                conversationHistoryStart = Int(update.page.start)
                conversationHistoryHasMore = update.page.hasMore_p
            }
            conversationHistoryTotal = max(conversationHistoryTotal, Int(update.page.total))
        }
        conversation = snapshot
    }

    func sendComposer() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !composerAttachments.isEmpty), let id = selectedCardID ?? selectedChatID else { return }
        let projectID = (selectedCard ?? selectedDetail?.card)?.projectID ?? ""
        let targetEndpointID = projectEndpointIDs[projectID] ?? endpoint.id
        composerText = ""
        let attachments = composerAttachments; composerAttachments = []
        var parts = attachments
        if !text.isEmpty { var part = Dieter_V1_MessagePart(); part.type = "text"; part.text = text; parts.insert(part, at: 0) }
        var request = Dieter_V1_SendMessageRequest(); request.cardID = id; request.parts = parts
        request.provider = composerProvider.isEmpty ? (selectedCard?.provider ?? "") : composerProvider
        request.model = composerModel.isEmpty ? (selectedCard?.model ?? "") : composerModel
        request.effort = composerEffort.isEmpty ? (selectedCard?.effort ?? "") : composerEffort
        request.providerOptions = composerProviderOptions
        request.clientID = syncClientID
        request.commandID = UUID().uuidString.lowercased()
        request.messageID = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        do {
            syncDiskState.outbox.append(DieterOutboxEntry(
                commandID: request.commandID,
                clientID: syncClientID,
                endpointID: targetEndpointID,
                kind: .sendMessage,
                request: try request.serializedData(),
                optimisticID: request.messageID,
                attempts: 0,
                createdAt: Date()
            ))
            await persistAndDrainOutbox()
        } catch {
            composerText = text
            composerAttachments = attachments
            show(error)
        }
    }

    @discardableResult
    func retryFailedTurn(_ failure: ConversationTurnFailure) async -> Bool {
        guard !failure.retryParts.isEmpty,
              let id = selectedCardID ?? selectedChatID,
              let card = selectedCard ?? selectedDetail?.card else { return false }
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
        request.messageID = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        do {
            syncDiskState.outbox.append(DieterOutboxEntry(
                commandID: request.commandID,
                clientID: syncClientID,
                endpointID: targetEndpointID,
                kind: .sendMessage,
                request: try request.serializedData(),
                optimisticID: request.messageID,
                attempts: 0,
                createdAt: Date()
            ))
            await persistAndDrainOutbox()
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
              let rpc else { return nil }
        var request = Dieter_V1_GetToolOutputRequest()
        request.cardID = cardID
        request.messageID = messageID
        request.toolCallID = toolCallID
        request.revision = revision
        return try await rpc.toolOutput(request)
    }

    func addAttachments(_ urls: [URL]) {
        let existing = composerAttachments
        Task {
            do { composerAttachments = try await attachmentParts(urls, appendingTo: existing) }
            catch { show(error) }
        }
    }

    func addPastedAttachments(_ providers: [NSItemProvider]) {
        Task {
            do { composerAttachments = try await attachmentParts(providers, appendingTo: composerAttachments) }
            catch { show(error) }
        }
    }

    func attachmentParts(
        _ urls: [URL],
        appendingTo existing: [Dieter_V1_MessagePart] = []
    ) async throws -> [Dieter_V1_MessagePart] {
        try await attachmentLoader.parts(urls: urls, appendingTo: existing)
    }

    func attachmentParts(_ providers: [NSItemProvider], appendingTo existing: [Dieter_V1_MessagePart] = []) async throws -> [Dieter_V1_MessagePart] {
        guard existing.count + providers.count <= AttachmentLoader.maximumCount else {
            throw DieterAttachmentError.tooMany
        }
        var parts = existing
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = try await Self.loadFileURL(provider) {
                parts = try await attachmentLoader.parts(urls: [url], appendingTo: parts)
                continue
            }
            guard let identifier = Self.preferredImageTypeIdentifier(for: provider) else {
                throw DieterAttachmentError.unsupportedPaste
            }
            let sourceData = try await Self.loadData(provider, typeIdentifier: identifier)
            parts = try await attachmentLoader.parts(
                images: [.init(
                    data: sourceData,
                    typeIdentifier: identifier,
                    suggestedName: provider.suggestedName
                )],
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
            do { composerAttachments = try await attachmentParts(input, appendingTo: existing) }
            catch { show(error) }
        }
        return true
    }

    /// Returns nil when the pasteboard has no files or images to attach.
    func pasteboardAttachmentInput(
        _ pasteboard: NSPasteboard,
    ) -> AttachmentPasteboardInput? {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { return .urls(urls) }
        let payloads = Self.pasteboardImagePayloads(pasteboard)
        guard !payloads.isEmpty else { return nil }
        return .images(payloads.map {
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
            guard let type, let data = item.data(forType: NSPasteboard.PasteboardType(type.identifier)) else { return nil }
            return (data, type)
        }
    }

    static func preferredImageTypeIdentifier(for provider: NSItemProvider) -> String? {
        let preferred = [UTType.png, .jpeg, .gif, .heic, .tiff]
        if let type = preferred.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
            return type.identifier
        }
        return provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .image) == true
        }
    }

    static func loadData(_ provider: NSItemProvider, typeIdentifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: DieterAttachmentError.unsupportedPaste) }
            }
        }
    }

    static func loadFileURL(_ provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                if let error { continuation.resume(throwing: error); return }
                if let url = item as? URL { continuation.resume(returning: url); return }
                if let url = item as? NSURL { continuation.resume(returning: url as URL); return }
                if let data = item as? Data,
                   let value = String(data: data, encoding: .utf8),
                   let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    continuation.resume(returning: url)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    static func filename(_ value: String, for contentType: UTType) -> String {
        let url = URL(fileURLWithPath: value)
        guard url.pathExtension.isEmpty, let suffix = contentType.preferredFilenameExtension else { return value }
        return value + "." + suffix
    }

    func addComment() async {
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let id = selectedCardID ?? selectedChatID, let rpc else { return }
        var request = Dieter_V1_AddCommentRequest(); request.cardID = id; request.message = text; request.name = NSFullUserName()
        do {
            _ = try await rpc.addComment(request); commentText = ""
            selectedDetail = try await rpc.card(id: id)
        } catch { show(error) }
    }

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
        workspace: ConversationWorkspaceDraft = ConversationWorkspaceDraft()
    ) async {
        let destinationProjectID = projectID ?? selectedProjectID
        var request = Dieter_V1_CreateConversationRequest()
        request.projectID = destinationProjectID; request.boardID = chat ? "" : selectedBoardID
        request.lane = lane ?? selectedBoard?.lanes.first?.id ?? "backlog"; request.title = title; request.prompt = prompt
        request.provider = provider; request.model = model; request.effort = effort; request.deferStart = deferred
        request.providerOptions = providerOptions
        request.attachments = attachments
        request.labelIds = labelIDs
        workspace.apply(to: &request)
        request.clientID = syncClientID
        request.commandID = UUID().uuidString.lowercased()
        do {
            let shouldOpenConversation = Self.shouldOpenCreatedConversation(chat: chat, lane: request.lane)
            let optimisticID = "local_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
            let target = projectEndpointIDs[destinationProjectID].flatMap { id in endpoints.first { $0.id == id } }
            syncDiskState.outbox.append(DieterOutboxEntry(
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
            await persistAndDrainOutbox()
        } catch { show(error) }
    }

    nonisolated static func shouldOpenCreatedConversation(chat: Bool, lane: String) -> Bool {
        chat || lane.caseInsensitiveCompare("todo") != .orderedSame
    }

    func markChatRead(_ card: Dieter_V1_Card) {
        let activity = card.lastActivityAt.isEmpty ? card.updatedAt : card.lastActivityAt
        guard !activity.isEmpty, readChatActivity[card.id] != activity else { return }
        readChatActivity[card.id] = activity
        UserDefaults.standard.set(readChatActivity, forKey: "DieterReadChatActivity")
    }

    func move(_ card: Dieter_V1_Card, lane: String, position: Int64? = nil) async {
        guard let rpc else { return }
        let original = state.cards.first(where: { $0.id == card.id }) ?? card
        let optimisticPosition = position ?? ((boardCards.filter { $0.id != card.id && $0.lane == lane }.map(\.position).max() ?? 0) + 1_024)

        let operationID = UUID()
        pendingCardMoves[card.id] = OptimisticCardMove(
            operationID: operationID,
            lane: lane,
            position: optimisticPosition,
            confirmsPosition: position != nil || original.lane == lane
        )

        if let index = state.cards.firstIndex(where: { $0.id == card.id }) {
            var next = state
            next.cards[index].lane = lane
            next.cards[index].position = optimisticPosition
            state = next
        }
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
            if let index = state.cards.firstIndex(where: { $0.id == moved.id }) {
                var next = state
                next.cards[index] = moved
                state = next
            }
        } catch {
            guard pendingCardMoves[card.id]?.operationID == operationID else { return }
            pendingCardMoves.removeValue(forKey: card.id)
            movingCardIDs.remove(card.id)
            if let index = state.cards.firstIndex(where: { $0.id == original.id }) {
                var next = state
                next.cards[index] = original
                state = next
            }
            show(error)
        }
    }

    func rename(_ card: Dieter_V1_Card, title: String) async {
        guard await ensureProjectConnection(card.projectID) else { return }
        guard let rpc else { return }
        var request = Dieter_V1_RenameCardRequest(); request.cardID = card.id; request.title = title
        do { _ = try await rpc.renameCard(request); await refreshState(); await refreshChats() } catch { show(error) }
    }

    @discardableResult
    func update(_ card: Dieter_V1_Card, title: String, initialPrompt: String) async -> Bool {
        guard await ensureProjectConnection(card.projectID), let rpc else { return false }
        var request = Dieter_V1_UpdateCardRequest()
        request.cardID = card.id
        request.title = title
        request.initialPrompt = initialPrompt
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
        var request = Dieter_V1_ArchiveCardRequest(); request.cardID = card.id; request.archived = archived
        do { _ = try await rpc.archiveCard(request); closeConversation(); await refreshState(); await refreshChats() } catch { show(error) }
    }

    func pin(_ card: Dieter_V1_Card, pinned: Bool) async {
        guard await ensureProjectConnection(card.projectID) else { return }
        guard let client = chatPinRPCOverride ?? rpc else { return }
        let original = chats.first(where: { $0.id == card.id })
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

        var request = Dieter_V1_PinChatRequest(); request.cardID = card.id; request.pinned = pinned
        do {
            let updated = try await client.pinChat(request)
            guard pendingChatPins[card.id]?.operationID == operationID else { return }
            applyChatMutation(updated)
        } catch {
            guard let pending = pendingChatPins[card.id], pending.operationID == operationID else { return }
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
        do { try await rpc?.cancelCard(id: card.id); await refreshState() } catch { show(error) }
    }

    func setLabels(_ card: Dieter_V1_Card, ids: [String]) async {
        guard let rpc else { return }
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

        var request = Dieter_V1_SetCardLabelsRequest(); request.cardID = card.id; request.labelIds = normalized
        do {
            let updated = try await rpc.setCardLabels(request)
            if let pending = pendingCardLabelUpdates[card.id], pending.operationID != operationID { return }
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
        do {
            archivedProjects = try await rpc.archivedProjects().projects
            if !selectedBoardID.isEmpty { archivedCards = try await rpc.archivedCards(boardID: selectedBoardID).cards }
            await refreshChats(includeArchived: true)
        } catch { show(error) }
    }
}
