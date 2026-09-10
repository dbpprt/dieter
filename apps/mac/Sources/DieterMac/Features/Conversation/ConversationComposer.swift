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

    private var harness: Dieter_V1_Harness? {
        context.harnessCatalog.harnesses.first { $0.id == context.composerProvider }
    }
    private var model: Dieter_V1_HarnessModel? {
        harness?.models.first { $0.id == context.composerModel }
    }
    private var working: Bool {
        ConversationActivityPresentation.isActive(
            conversationStatus: context.conversation?.conversation.status ?? "",
            cardRuntime: (context.selectedCard ?? context.selectedDetail?.card)?.runtime ?? ""
        )
    }
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
                    agentIsWorking: working,
                    onEdit: { message in
                        await editQueuedMessage(message)
                    },
                    onRemove: { message in
                        _ = await context.removeQueuedMessage(message, edit: false)
                    },
                    onSteer: {
                        if let card = context.selectedCard ?? context.selectedDetail?.card {
                            await context.cancel(card)
                        }
                    }
                )
                .disabled(!context.composer.draft.pendingQueueMessageIDs.isEmpty || queueRecallID != nil)
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
                    guard press.modifiers.isEmpty else { return .ignored }
                    if recallQueuedMessage() { return .handled }
                    return navigateHistory(.older) ? .handled : .ignored
                }
                .onKeyPress(.downArrow, phases: .down) { press in
                    guard press.modifiers.isEmpty else { return .ignored }
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
                    providerMenu(compact: metrics.compact)
                    modelMenu(compact: metrics.compact)
                        .layoutPriority(1)
                    if let efforts = model?.efforts, !efforts.isEmpty {
                        reasoningMenu(efforts: efforts, compact: metrics.compact)
                    }
                    ComposerProviderOptions(
                        options: ProviderOptionValues.options(for: harness, model: context.composerModel),
                        values: Binding(
                            get: { context.composerProviderOptions },
                            set: { context.composerProviderOptions = $0 }
                        ),
                        conversationLocked: context.composerProviderLocked,
                        identity: conversationID,
                        identifierPrefix: "conversation"
                    )
                    .smokeTarget("conversation.provider-options")
                    .fixedSize()
                    Spacer(minLength: 0)
                    if metrics.width >= 560,
                        let usage = ConversationContextUsage.latest(
                            messages: context.conversation?.conversation.messages ?? [],
                            fallbackWindow: Int64(model?.contextWindow ?? 0)
                        )
                    {
                        ContextUsageIndicator(usage: usage)
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

    private func providerMenu(compact: Bool) -> some View {
        ComposerSelectionMenu(
            title: harness?.name ?? context.composerProvider, symbol: "cpu", help: "Provider", compact: compact,
            maximumWidth: 100
        ) {
            ForEach(context.harnessCatalog.harnesses, id: \.id) { item in
                Button(item.name) {
                    guard let selection = HarnessSelection(provider: item.id).resolved(in: [item]) else {
                        return
                    }
                    context.composerProvider = selection.provider
                    context.composerModel = selection.model
                    context.composerEffort = selection.effort
                    context.composerProviderOptions = selection.providerOptions
                }
            }
        }
        .accessibilityLabel("Provider: \(harness?.name ?? context.composerProvider)")
        .accessibilityIdentifier("conversation.provider")
        .smokeTarget("conversation.provider")
        .disabled(context.composerProviderLocked)
    }

    private func modelMenu(compact: Bool) -> some View {
        let name = model?.name ?? context.composerModel
        return ComposerSelectionMenu(
            title: compact ? name.replacingOccurrences(of: "GPT-", with: "") : name,
            symbol: "sparkles", help: "Model"
        ) {
            ForEach(harness?.models ?? [], id: \.id) { item in
                Button(item.name) {
                    context.selectComposerModel(item)
                }
            }
        }
        .accessibilityLabel("Model: \(model?.name ?? context.composerModel)")
        .accessibilityIdentifier("conversation.model")
        .smokeTarget("conversation.model")
        .disabled(!context.canChangeComposerSelection("model-selection"))
    }

    private func reasoningMenu(efforts: [String], compact: Bool) -> some View {
        ComposerSelectionMenu(
            title: context.composerEffort.isEmpty ? "Default" : context.composerEffort.capitalized,
            symbol: "sparkles", help: "Reasoning", compact: compact, maximumWidth: 80
        ) {
            ForEach(efforts, id: \.self) { value in
                Button(value.capitalized) { context.composerEffort = value }
            }
        }
        .accessibilityLabel(
            "Reasoning: \(context.composerEffort.isEmpty ? "Default" : context.composerEffort.capitalized)"
        )
        .accessibilityIdentifier("conversation.reasoning")
        .smokeTarget("conversation.reasoning")
        .disabled(!context.canChangeComposerSelection("effort-selection"))
    }
}
