import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct ConversationComposer: View {
    @Environment(ConversationContext.self) private var context
    @Binding var fileImporterPresented: Bool
    @FocusState private var composerFocused: Bool
    @State private var attachmentDropTargeted = false
    @State private var attachmentMenuPresented = false
    @State private var captureInProgress = false
    @State private var historyNavigation = ComposerHistoryNavigation()

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
                        if await context.removeQueuedMessage(message, edit: true) {
                            composerFocused = true
                        }
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
            }
            VStack(alignment: .leading, spacing: 0) {
                TextField("Message the local agent…", text: $context.composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
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
                    .frame(minHeight: 54, alignment: .topLeading)
                    .background {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { composerFocused = true }
                    }

                if !context.composerAttachments.isEmpty {
                    AttachmentPreviewStrip(attachments: $context.composerAttachments)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }

                HStack(alignment: .center, spacing: 9) {
                    ViewThatFits(in: .horizontal) {
                        composerSettings(showContext: true)
                        composerSettings(showContext: false)
                    }
                    .frame(maxWidth: .infinity)

                    if working {
                        Button {
                            if let card = context.selectedCard ?? context.selectedDetail?.card {
                                Task { await context.cancel(card) }
                            }
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.white)
                                .frame(width: 30, height: 30)
                                .background(DieterTheme.coral, in: Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                        .help("Stop agent")
                        .accessibilityIdentifier("conversation.stop")
                    }

                    Button {
                        submitComposer()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(hasDraft ? Color.white : DieterTheme.tertiary)
                            .frame(width: 36, height: 36)
                            .background(
                                hasDraft ? DieterTheme.primary : DieterTheme.elevated,
                                in: Circle()
                            )
                            .overlay(Circle().stroke(Color.white.opacity(hasDraft ? 0.14 : 0.055)))
                            .shadow(color: DieterTheme.shellDeep.opacity(hasDraft ? 0.3 : 0), radius: 9, y: 3)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasDraft)
                    .help(working ? "Queue message" : "Send message")
                    .accessibilityIdentifier("conversation.send")
                }
                .padding(.leading, 10)
                .padding(.trailing, 9)
                .padding(.bottom, 9)

            }
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(attachmentDropTargeted ? DieterTheme.shellDeep.opacity(0.12) : DieterTheme.surface)
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onTapGesture { composerFocused = true }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        attachmentDropTargeted
                            ? DieterTheme.shell
                            : (composerFocused ? DieterTheme.shellDeep.opacity(0.55) : DieterTheme.border),
                        lineWidth: attachmentDropTargeted ? 1.5 : 1)
            }
            .shadow(color: Color.black.opacity(0.24), radius: 12, y: 5)
            .animation(.easeOut(duration: 0.16), value: composerFocused)
            .animation(.easeOut(duration: 0.12), value: attachmentDropTargeted)
            .attachmentDropTarget(isTargeted: $attachmentDropTargeted) { providers in
                context.addPastedAttachments(providers)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(DieterTheme.sidebar)
        .onChange(of: conversationID) { _, _ in historyNavigation.reset() }
    }

    private func navigateHistory(_ direction: ComposerHistoryDirection) -> Bool {
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

    private func composerSettings(showContext: Bool) -> some View {
        HStack(spacing: 7) {
            Button {
                attachmentMenuPresented = true
            } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(DieterIconButtonStyle())
            .disabled(captureInProgress)
            .accessibilityLabel("Attach")
            .accessibilityIdentifier("conversation.attach")
            .smokeTarget("conversation.attach")
            .help("Attach a file or capture an area of your screen to include with your message.")
            .popover(isPresented: $attachmentMenuPresented) {
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        attachmentMenuPresented = false
                        fileImporterPresented = true
                    } label: {
                        Label("Upload file…", systemImage: "doc.badge.plus")
                    }
                    .accessibilityIdentifier("conversation.attach.upload")
                    .smokeTarget("conversation.attach.upload")
                    Button {
                        attachmentMenuPresented = false
                        captureScreenshot()
                    } label: {
                        Label("Take screenshot…", systemImage: "viewfinder")
                    }
                    .accessibilityIdentifier("conversation.attach.capture")
                    .smokeTarget("conversation.attach.capture")
                }
                .buttonStyle(.borderless)
                .padding(14)
            }

            Menu {
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
            } label: {
                DieterChipLabel(title: harness?.name ?? context.composerProvider, symbol: "cpu")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Provider: the agent service that runs this conversation and its tools.")

            Menu {
                ForEach(harness?.models ?? [], id: \.id) { item in
                    Button(item.name) {
                        context.composerModel = item.id
                        context.composerEffort = item.defaultEffort
                        context.composerProviderOptions = ProviderOptionValues.normalized(
                            for: harness,
                            model: context.composerModel,
                            saved: context.composerProviderOptions
                        )
                    }
                }
            } label: {
                DieterChipLabel(
                    title: model?.name ?? context.composerModel, symbol: "terminal", maximumTitleWidth: 190)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Model: the AI model used for your next message; models differ in capability, speed, and cost.")

            if let efforts = model?.efforts, !efforts.isEmpty {
                Menu {
                    ForEach(efforts, id: \.self) { value in
                        Button(value.capitalized) { context.composerEffort = value }
                    }
                } label: {
                    DieterChipLabel(
                        title: context.composerEffort.isEmpty ? "Default" : context.composerEffort.capitalized,
                        symbol: "sparkles")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(
                    "Reasoning: how much effort the model spends thinking. Higher effort can improve difficult answers but takes longer."
                )
            }

            ProviderOptionChips(
                options: ProviderOptionValues.options(for: harness, model: context.composerModel),
                values: Binding(
                    get: { context.composerProviderOptions },
                    set: { context.composerProviderOptions = $0 }
                ),
                conversationLocked: (context.selectedCard ?? context.selectedDetail?.card)?.initialPromptSentAt
                    .isEmpty == false)

            Spacer(minLength: 0)
            if showContext,
                let usage = ConversationContextUsage.latest(
                    messages: context.conversation?.conversation.messages ?? [],
                    fallbackWindow: Int64(model?.contextWindow ?? 0)
                )
            {
                ContextUsageIndicator(usage: usage)
            }
        }
    }
}
