import DieterAPI
import DieterCore
import Foundation

extension DieterStore {
    func makeConversationContext() -> ConversationContext {
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
            guard let self else { return }
            await self.openConversation(cardID: cardID, chat: chat, fromInbox: self.section == .inbox)
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
        context.content.core = core
        onConversationContentConnectionChanged = { [weak self, weak content = context.content] in
            guard let self, let content else { return }
            content.invalidateTransports()
            if self.phase.isConnected { content.resume() }
        }
        context.content.currentEndpointID = { [weak self] id in
            guard let self, (self.selectedCardID ?? self.selectedChatID) == id,
                let card = self.selectedCard ?? self.selectedDetail?.card,
                card.id == id
            else { return nil }
            return self.conversationWorkspaceRoute(for: card)?.endpointID
        }
        context.content.resolveExternalLink = { [weak self] url, id in
            guard let self else { return .unavailable("This conversation is no longer available.") }
            return await self.externalConversationLink(url, cardID: id)
        }
        context.content.prepareScope = { [weak self] id in
            guard let self, (self.selectedCardID ?? self.selectedChatID) == id,
                self.isConversationServerBacked(id),
                let card = self.selectedCard ?? self.selectedDetail?.card,
                card.id == id,
                let route = self.conversationWorkspaceRoute(for: card),
                route.endpointID == self.endpoint.id, self.phase.isConnected
            else { throw ConversationContentUnavailable() }
            let generation = self.connectionGeneration
            let target = WorkspaceTarget(
                endpointID: route.endpointID, projectID: card.projectID, conversationID: id)
            // Ask the owning daemon for the actual root, including managed worktrees.
            // No paths are resolved against the Mac client's checkout.
            let workspace = try await self.conversationWorkspace(cardID: id)
            guard self.connectionGeneration == generation, self.endpoint.id == target.endpointID,
                (self.selectedCardID ?? self.selectedChatID) == id
            else { throw CancellationError() }
            return ConversationContentScope(
                target: target, rootPath: workspace.path,
                card: card, doneLaneID: self.doneLane(for: card), machineName: route.machineName,
                workspaceMode: workspace.mode,
                projectName: self.projects.first(where: { $0.id == card.projectID })?.name ?? "Project")
        }
        context.content.onReviewSendMessage = { [weak self] text, card, target in
            await self?.sendAgentMessage(text, card: card, endpointID: target.endpointID) ?? false
        }
        context.content.onReviewCard = { [weak self] card in self?.acceptWorkspaceCard(card) }
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
                let route = self.conversationWorkspaceRoute(for: card),
                self.isLocalMachine(route.endpointID)
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
