import DieterAPI

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
        context.onAddComment = { [weak self] in await self?.addComment() }
        context.onAddPastedAttachments = { [weak self] providers in self?.addPastedAttachments(providers) }
        context.onArchive = { [weak self] card, archived in await self?.archive(card, archived: archived) }
        context.onAttachPasteboard = { [weak self] pasteboard in self?.attachPasteboard(pasteboard) ?? false }
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
        context.onSendComposer = { [weak self] in await self?.sendComposer() }
        context.onShow = { [weak self] error in self?.show(error) }
        context.onToolOutput = { [weak self] messageID, toolCallID, revision in
            try await self?.toolOutput(messageID: messageID, toolCallID: toolCallID, revision: revision) ?? nil
        }
        return context
    }
}
