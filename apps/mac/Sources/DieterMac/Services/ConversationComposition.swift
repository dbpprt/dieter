import DieterAPI
import DieterCore
import Foundation

extension DieterStore {
    func makeConversationContext() -> ConversationContext {
        conversationModel.presentSnapshot = { [weak self] snapshot in
            DieterOutboxPolicy.overlayOptimisticMessages(snapshot, entries: self?.syncDiskState.outbox ?? [])
        }
        let context = ConversationContext(
            model: conversationModel, composer: composer, worktreeChanges: worktreeChanges,
            card: { [weak self] in self?.selectedCard }, catalog: { [weak self] in self?.harnessCatalog ?? .init() },
            projectID: { [weak self] in self?.selectedProjectID ?? "" },
            reasoning: { [weak self] in self?.showReasoning ?? false },
            pendingMessage: { [weak self] in self?.isPendingMessage($0) ?? false },
            acceptedItem: { [weak self] in self?.isAcceptedOutboxItem($0) ?? false },
            failedItem: { [weak self] in self?.isFailedOutboxItem($0) ?? false },
            creationError: { [weak self] in self?.failedCreationError($0) })
        context.onAddAttachments = { [weak self] urls in self?.addAttachments(urls) }
        context.onAddComment = { [weak self] in await self?.addComment() }
        context.onAddPastedAttachments = { [weak self] providers in self?.addPastedAttachments(providers) }
        context.onArchive = { [weak self] card, archived in await self?.archive(card, archived: archived) }
        context.onAttachPasteboard = { [weak self] pasteboard in self?.attachPasteboard(pasteboard) ?? false }
        context.onStart = { [weak self] card in await self?.start(card) }
        context.onCancel = { [weak self] card in await self?.cancel(card) }
        context.onCloseConversation = { [weak self] in self?.closeConversation() }
        context.onDiscardOutboxItem = { [weak self] id in await self?.discardOutboxItem(id) }
        context.onFork = { [weak self] card in await self?.fork(card) }
        context.onLoadEarlierMessages = { [weak self] in await self?.loadEarlierMessages() ?? false }
        context.onOpenConversation = { [weak self] cardID, chat in
            await self?.openConversation(cardID: cardID, chat: chat)
        }
        context.onOpenProjectChanges = { [weak self] id in await self?.openProjectChanges(id) }
        context.onOpenWorkspaceFiles = { [weak self] card in await self?.openWorkspaceFiles(card: card) }
        context.onOpenWorkspaceTerminal = { [weak self] card in await self?.openWorkspaceTerminal(card: card) }
        context.onPin = { [weak self] card, pinned in await self?.pin(card, pinned: pinned) }
        context.onRetryFailedTurn = { [weak self] failure in await self?.retryFailedTurn(failure) ?? false }
        context.onRetryOutboxItem = { [weak self] id in await self?.retryOutboxItem(id) }
        context.onRemoveQueuedMessage = { [weak self] message, edit in
            await self?.removeQueuedMessage(message, edit: edit) ?? false
        }
        context.onSendComposer = { [weak self] in await self?.sendComposer() }
        context.onShow = { [weak self] error in self?.show(error) }
        context.onToolOutput = { [weak self] messageID, toolCallID, revision in
            try await self?.toolOutput(messageID: messageID, toolCallID: toolCallID, revision: revision) ?? nil
        }
        onConversationContentConnectionChanged = { [weak self, weak content = context.content] in
            guard let self, let content else { return }
            content.invalidateTransports()
            if self.rpc != nil { content.resume() }
        }
        context.content.currentEndpointID = { [weak self] id in
            guard let self, (self.selectedCardID ?? self.selectedChatID) == id else { return nil }
            return self.endpoint.id
        }
        context.content.resolveExternalLink = { [weak self] url, id in
            guard let self else { return .unavailable("This conversation is no longer available.") }
            return await self.externalConversationLink(url, cardID: id)
        }
        context.content.prepareScope = { [weak self] id in
            guard let self, (self.selectedCardID ?? self.selectedChatID) == id,
                self.isConversationServerBacked(id),
                let card = self.selectedCard ?? self.selectedDetail?.card,
                card.id == id, let rpc = self.rpc,
                (self.projectEndpointIDs[card.projectID] ?? self.endpoint.id) == self.endpoint.id
            else { throw ConversationContentUnavailable() }
            let target = WorkspaceTarget(
                endpointID: self.endpoint.id, projectID: card.projectID, conversationID: id)
            // Ask the owning daemon for the actual root, including managed worktrees.
            // No paths are resolved against the Mac client's checkout.
            let workspace = try await rpc.workspace(cardID: id)
            guard self.rpc === rpc, self.endpoint.id == target.endpointID,
                (self.selectedCardID ?? self.selectedChatID) == id
            else { throw CancellationError() }
            return ConversationContentScope(
                target: target, rootPath: workspace.path, client: rpc,
                card: card, doneLaneID: self.doneLane(for: card), machineName: self.endpoint.name,
                terminalsClient: rpc, worktreeClient: rpc, projectChangesClient: rpc,
                processesClient: rpc,
                workspaceMode: workspace.mode,
                projectName: self.projects.first(where: { $0.id == card.projectID })?.name ?? "Project")
        }
        context.content.onReviewSendMessage = { [weak self] text, card, target in
            await self?.sendAgentMessage(text, card: card, endpointID: target.endpointID) ?? false
        }
        context.content.onReviewCard = { [weak self] card in self?.acceptWorkspaceCard(card) }
        context.content.onReviewTransportFailure = { [weak self] error, client in
            guard let rpc = client as? DieterRPC else { return }
            self?.connectionStopped(error, client: rpc)
        }
        context.content.onReviewOperationFinished = { [weak self] target in
            guard let self, self.endpoint.id == target.endpointID else { return }
            await self.loadProjectWorkspaces()
            guard self.endpoint.id == target.endpointID else { return }
            await self.refreshState()
        }
        context.content.onSaveFailure = { [weak self] message in self?.errorMessage = message }
        context.content.validateWebURL = { [weak self] url, id in
            guard ConversationBrowserModel.isLoopback(url) else { return }
            guard let self, (self.selectedCardID ?? self.selectedChatID) == id,
                let card = self.selectedCard ?? self.selectedDetail?.card,
                (self.projectEndpointIDs[card.projectID] ?? self.endpoint.id) == self.endpoint.id,
                self.rpc?.isLoopbackDataPlane == true
            else { throw ConversationLoopbackUnavailable() }
        }
        return context
    }
}

private struct ConversationContentUnavailable: LocalizedError {
    var errorDescription: String? { "This conversation’s machine is unavailable. Reconnect and try again." }
}

private struct ConversationLoopbackUnavailable: LocalizedError {
    var errorDescription: String? {
        "This address belongs to the conversation’s machine. Remote localhost forwarding is not available yet. Use a reachable web address."
    }
}
