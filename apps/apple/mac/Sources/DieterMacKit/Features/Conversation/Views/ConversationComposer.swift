import DieterAPI
import DieterClientAPI
import SwiftUI
import UniformTypeIdentifiers

/// The conversation's composer. The draft text, the agent's state and the
/// queue are read by the small views that show them, so typing or a streaming
/// turn re-evaluates those views rather than the whole composer.
struct ConversationComposer: View {
    @Environment(ConversationContext.self) private var context
    var background: Color = DieterTheme.sidebar
    var onUploadFile: () -> Void
    @FocusState private var composerFocused: Bool
    @State private var attachmentDropTargeted = false
    @State private var captureInProgress = false
    @State private var historyNavigation = ComposerHistoryNavigation()
    @State private var queueRecallID: UUID?

    private var conversationID: String { context.selectedCardID ?? context.selectedChatID ?? "" }

    var body: some View {
        @Bindable var context = context
        VStack(spacing: 8) {
            ComposerQueuedMessages(recalling: queueRecallID != nil) { message in
                await editQueuedMessage(message)
            }
            ComposerSurface(focused: composerFocused, dropTargeted: attachmentDropTargeted) {
                ComposerDraftField(
                    historyNavigation: $historyNavigation, queueRecallID: $queueRecallID, focus: $composerFocused,
                    edit: { message in await editQueuedMessage(message) }, submit: submitComposer
                )

                if !context.composerAttachments.isEmpty {
                    AttachmentPreviewStrip(attachments: $context.composerAttachments)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }

                ComposerToolbar { metrics in
                    ComposerAttachmentButton(
                        identifierPrefix: "conversation", identity: conversationID,
                        isEnabled: !captureInProgress, onUpload: onUploadFile, onCapture: captureScreenshot
                    )
                    ComposerAgentControls(compact: metrics.compact, identity: conversationID)
                    Spacer(minLength: 0)
                    ComposerContextUsage(width: metrics.width)
                    ComposerActions(submit: submitComposer)
                }
            }
            .e2eTarget("conversation.composer-shell")
            .attachmentDropTarget(isTargeted: $attachmentDropTargeted) { providers in
                context.addPastedAttachments(providers)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(background)
        .onChange(of: conversationID) { _, _ in
            historyNavigation.reset()
            queueRecallID = nil
        }
    }

    private func editQueuedMessage(_ message: Dieter_V1_QueuedMessage) async {
        let originID = conversationID
        let originDraft = context.composer.draft
        if await context.removeQueuedMessage(message, edit: true),
            conversationID == originID, context.composer.draft === originDraft
        {
            historyNavigation.reset()
            composerFocused = true
        }
    }

    private func submitComposer() {
        historyNavigation.reset()
        Task { await context.sendComposer() }
    }

    private func captureScreenshot() {
        guard !captureInProgress else { return }
        captureInProgress = true
        let capturedConversationID = conversationID
        Task { @MainActor in
            defer {
                captureInProgress = false
                NSApp.activate(ignoringOtherApps: true)
            }
            do {
                try await DieterTaskSleep.milliseconds(300)
                NSApp.hide(nil)
                guard let file = try await TaskScreenCapture.region() else { return }
                defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
                let parts = try await AttachmentLoader().parts(urls: [file])
                guard conversationID == capturedConversationID else { return }
                context.composerAttachments = try AttachmentLoader.validate(
                    parts, appendingTo: context.composerAttachments)
            } catch {
                NSApp.activate(ignoringOtherApps: true)
                NSAlert(error: error).runModal()
            }
        }
    }
}

/// The draft's text field. It alone reads the text, so typing re-evaluates
/// only this field and the send button.
private struct ComposerDraftField: View {
    @Environment(ConversationContext.self) private var context
    @Binding var historyNavigation: ComposerHistoryNavigation
    @Binding var queueRecallID: UUID?
    let focus: FocusState<Bool>.Binding
    let edit: (Dieter_V1_QueuedMessage) async -> Void
    let submit: () -> Void

    private var conversationID: String { context.selectedCardID ?? context.selectedChatID ?? "" }

    var body: some View {
        @Bindable var context = context
        ComposerTextInput(
            placeholder: "Message the local agent…", text: $context.composerText, focus: focus
        )
        .accessibilityIdentifier("conversation.composer")
        .e2eTarget("conversation.composer")
        .onKeyPress(.return, phases: .down) { press in
            if !ComposerReturnPolicy.sendsMessage(shiftPressed: press.modifiers.contains(.shift)) {
                return .ignored
            }
            if context.composer.draft.hasContent { submit() }
            return .handled
        }
        .onKeyPress(.upArrow, phases: .down) { press in
            guard ComposerHistoryNavigation.acceptsArrow(modifiers: press.modifiers) else { return .ignored }
            if recallQueuedMessage() { return .handled }
            return navigateHistory(.older) ? .handled : .ignored
        }
        .onKeyPress(.downArrow, phases: .down) { press in
            guard ComposerHistoryNavigation.acceptsArrow(modifiers: press.modifiers) else { return .ignored }
            return navigateHistory(.newer) ? .handled : .ignored
        }
        .onChange(of: context.composerText) { _, text in
            // Only browsing history reacts to typing; skip the state write per keystroke.
            guard historyNavigation.isBrowsing else { return }
            var navigation = historyNavigation
            navigation.observeTextChange(text)
            historyNavigation = navigation
        }
    }

    private func recallQueuedMessage() -> Bool {
        guard context.composerText.isEmpty, context.composerAttachments.isEmpty else { return false }
        if queueRecallID != nil || !context.composer.draft.pendingQueueMessageIDs.isEmpty { return true }
        guard
            let message = ComposerQueueRecall.newestMessage(
                text: context.composerText, attachments: context.composerAttachments,
                queue: context.model.queue
            ), !context.composer.draft.sending
        else { return false }
        let requestID = UUID()
        let originID = conversationID
        let originDraft = context.composer.draft
        queueRecallID = requestID
        historyNavigation.reset()
        Task { @MainActor in
            defer { if queueRecallID == requestID { queueRecallID = nil } }
            guard conversationID == originID, context.composer.draft === originDraft else { return }
            await edit(message)
        }
        return true
    }

    private func navigateHistory(_ direction: ComposerHistoryDirection) -> Bool {
        guard
            historyNavigation.isBrowsing
                || (context.composerText.isEmpty && context.composerAttachments.isEmpty)
        else { return false }
        let entries = ComposerHistoryNavigation.entries(
            messages: context.conversationMessages, queuedMessages: context.model.queue)
        guard !entries.isEmpty else { return false }
        let selection = (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectedRange()
        guard
            historyNavigation.isBrowsing
                || ComposerHistoryNavigation.isAtBoundary(
                    direction,
                    text: context.composerText,
                    selection: selection
                )
        else { return false }

        var navigation = historyNavigation
        guard
            let text = navigation.navigate(
                direction,
                entries: entries,
                currentText: context.composerText
            )
        else { return false }
        historyNavigation = navigation
        context.composerText = text
        return true
    }
}

/// Messages queued behind the running turn, above the composer.
private struct ComposerQueuedMessages: View {
    @Environment(ConversationContext.self) private var context
    let recalling: Bool
    let edit: (Dieter_V1_QueuedMessage) async -> Void

    var body: some View {
        let queue = context.model.queue
        if !queue.isEmpty {
            QueuedMessageTray(
                messages: queue,
                steerableID: context.model.chrome.steerableID,
                onEdit: edit,
                onRemove: { message in
                    _ = await context.removeQueuedMessage(message, edit: false)
                },
                onSteer: { await context.steer(messageID: context.model.state.steerableID) }
            )
            .disabled(
                queue.contains { context.isPendingMessage($0.id) }
                    || !context.composer.draft.pendingQueueMessageIDs.isEmpty || recalling)
        }
    }
}

/// The composer's agent pickers, as the core shows them.
private struct ComposerAgentControls: View {
    @Environment(ConversationContext.self) private var context
    let compact: Bool
    let identity: String

    var body: some View {
        let controls = context.agentControls ?? ClientAgentControlsState()
        AgentComposerMenus(
            controls: controls, compact: compact, identifierPrefix: "conversation",
            identity: identity
        ) { choice in Task { await context.chooseAgent(choice) } }
    }
}

/// How much of the context window the conversation used, when there is room.
private struct ComposerContextUsage: View {
    @Environment(ConversationContext.self) private var context
    let width: CGFloat

    var body: some View {
        if width >= 560 {
            let state = context.model.state
            if state.contextUsedTokens > 0, state.contextWindowTokens > 0 {
                ContextUsageIndicator(state: state)
            }
        }
    }
}

/// Stop while the agent works, and send or queue the draft.
private struct ComposerActions: View {
    @Environment(ConversationContext.self) private var context
    let submit: () -> Void

    var body: some View {
        let working = context.model.chrome.activeTurn
        HStack(spacing: 7) {
            if working {
                Button {
                    if let card = context.selectedCard ?? context.selectedDetail?.card {
                        Task { await context.cancel(card) }
                    }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DieterTheme.coral)
                        .frame(width: 30, height: 30)
                        .background(DieterTheme.coral.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .quickHelp("Stop")
                .accessibilityLabel("Stop agent")
                .accessibilityIdentifier("conversation.stop")
                .e2eTarget("conversation.stop")
            }

            ComposerSendButton(isEnabled: context.composer.draft.hasContent, queuesMessage: working, action: submit)
                .accessibilityIdentifier("conversation.send")
                .e2eTarget("conversation.send")
        }
        .fixedSize()
    }
}
