import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct ConversationComposer: View {
    @Environment(ConversationContext.self) private var context
    var background: Color = DieterTheme.sidebar
    var onUploadFile: () -> Void
    @FocusState private var composerFocused: Bool
    @State private var attachmentDropTargeted = false
    @State private var captureInProgress = false
    @State private var historyNavigation = ComposerHistoryNavigation()
    @State private var queueRecallID: UUID?

    private var working: Bool { context.model.state.activeTurn }
    private var hasDraft: Bool {
        !context.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !context.composerAttachments.isEmpty
    }
    private var conversationID: String { context.selectedCardID ?? context.selectedChatID ?? "" }
    private var historyEntries: [String] {
        ComposerHistoryNavigation.entries(
            messages: context.conversationMessages,
            queuedMessages: context.conversation?.conversation.queue ?? []
        )
    }
    var body: some View {
        @Bindable var context = context
        VStack(spacing: 8) {
            if let queue = context.conversation?.conversation.queue, !queue.isEmpty {
                QueuedMessageTray(
                    messages: queue,
                    steerableID: context.model.state.steerableID,
                    onEdit: { message in
                        await editQueuedMessage(message)
                    },
                    onRemove: { message in
                        _ = await context.removeQueuedMessage(message, edit: false)
                    },
                    onSteer: { await context.steer(messageID: context.model.state.steerableID) }
                )
                .disabled(
                    queue.contains { context.isPendingMessage($0.id) }
                        || !context.composer.draft.pendingQueueMessageIDs.isEmpty || queueRecallID != nil)
            }
            ComposerSurface(focused: composerFocused, dropTargeted: attachmentDropTargeted) {
                ComposerTextInput(
                    placeholder: "Message the local agent…", text: $context.composerText, focus: $composerFocused
                )
                .accessibilityIdentifier("conversation.composer")
                .smokeTarget("conversation.composer")
                .onKeyPress(.return, phases: .down) { press in
                    if !ComposerReturnPolicy.sendsMessage(shiftPressed: press.modifiers.contains(.shift)) {
                        return .ignored
                    }
                    if hasDraft { submitComposer() }
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
                    var navigation = historyNavigation
                    navigation.observeTextChange(text)
                    historyNavigation = navigation
                }

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
                    let controls = context.agentControls ?? ClientAgentControlsState()
                    AgentComposerMenus(
                        controls: controls, compact: metrics.compact, identifierPrefix: "conversation",
                        identity: conversationID
                    ) { choice in Task { await context.chooseAgent(choice) } }
                    Spacer(minLength: 0)
                    if metrics.width >= 560, context.model.state.contextUsedTokens > 0,
                        context.model.state.contextWindowTokens > 0
                    {
                        ContextUsageIndicator(state: context.model.state)
                    }
                    composerActions
                }
            }
            .smokeTarget("conversation.composer-shell")
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

    private func recallQueuedMessage() -> Bool {
        guard context.composerText.isEmpty, context.composerAttachments.isEmpty else { return false }
        if queueRecallID != nil || !context.composer.draft.pendingQueueMessageIDs.isEmpty { return true }
        guard
            let message = ComposerQueueRecall.newestMessage(
                text: context.composerText, attachments: context.composerAttachments,
                queue: context.conversation?.conversation.queue ?? []
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
            await editQueuedMessage(message)
        }
        return true
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

    private func navigateHistory(_ direction: ComposerHistoryDirection) -> Bool {
        guard
            historyNavigation.isBrowsing
                || (context.composerText.isEmpty && context.composerAttachments.isEmpty)
        else { return false }
        guard !historyEntries.isEmpty else { return false }
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
                entries: historyEntries,
                currentText: context.composerText
            )
        else { return false }
        historyNavigation = navigation
        context.composerText = text
        return true
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

    private var composerActions: some View {
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
                .smokeTarget("conversation.stop")
            }

            ComposerSendButton(isEnabled: hasDraft, queuesMessage: working, action: submitComposer)
                .accessibilityIdentifier("conversation.send")
                .smokeTarget("conversation.send")
        }
        .fixedSize()
    }
}
