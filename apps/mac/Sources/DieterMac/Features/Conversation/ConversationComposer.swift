import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct ConversationComposer: View {
    @Environment(ConversationContext.self) private var context
    var onUploadFile: () -> Void
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

                GeometryReader { geometry in
                    let compact = geometry.size.width < 360
                    HStack(spacing: compact ? 4 : 6) {
                        attachmentButton
                        providerMenu(compact: compact)
                            .frame(width: compact ? 24 : min(100, max(66, geometry.size.width * 0.16)))
                        modelMenu(compact: compact)
                            .frame(minWidth: 40, maxWidth: 180)
                            .layoutPriority(1)
                        if let efforts = model?.efforts, !efforts.isEmpty {
                            reasoningMenu(efforts: efforts, compact: compact)
                                .frame(width: compact ? 24 : 64)
                        }
                        ComposerProviderOptions(
                            options: ProviderOptionValues.options(for: harness, model: context.composerModel),
                            values: Binding(
                                get: { context.composerProviderOptions },
                                set: { context.composerProviderOptions = $0 }
                            ),
                            conversationLocked: context.composerProviderLocked,
                            conversationID: conversationID
                        )
                        .smokeTarget("conversation.provider-options")
                        .fixedSize()
                        Spacer(minLength: 0)
                        if geometry.size.width >= 560,
                            let usage = ConversationContextUsage.latest(
                                messages: context.conversation?.conversation.messages ?? [],
                                fallbackWindow: Int64(model?.contextWindow ?? 0)
                            )
                        {
                            ContextUsageIndicator(usage: usage)
                        }
                        composerActions
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DieterTheme.subtle)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 30)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            }
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(attachmentDropTargeted ? DieterTheme.shellDeep.opacity(0.12) : DieterTheme.surface)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        attachmentDropTargeted
                            ? DieterTheme.shell
                            : (composerFocused ? DieterTheme.shellDeep.opacity(0.55) : DieterTheme.border),
                        lineWidth: attachmentDropTargeted ? 1.5 : 1
                    )
                    .allowsHitTesting(false)
            }
            .smokeTarget("conversation.composer-shell")
            .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
            .animation(.easeOut(duration: 0.16), value: composerFocused)
            .animation(.easeOut(duration: 0.12), value: attachmentDropTargeted)
            .attachmentDropTarget(isTargeted: $attachmentDropTargeted) { providers in
                context.addPastedAttachments(providers)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(DieterTheme.sidebar)
        .onChange(of: conversationID) { _, _ in
            historyNavigation.reset()
            attachmentMenuPresented = false
        }
        .onDisappear { attachmentMenuPresented = false }
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

    private var attachmentButton: some View {
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
        .nativeHelp("Attach a file or capture an area of your screen to include with your message.")
        .popover(isPresented: $attachmentMenuPresented) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    attachmentMenuPresented = false
                    onUploadFile()
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
                .nativeHelp("Stop agent")
                .accessibilityIdentifier("conversation.stop")
                .smokeTarget("conversation.stop")
            }

            Button {
                submitComposer()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(hasDraft ? Color.white : DieterTheme.tertiary)
                    .frame(width: 30, height: 30)
                    .background(
                        hasDraft ? DieterTheme.primary : DieterTheme.elevated,
                        in: Circle()
                    )
                    .overlay(Circle().stroke(Color.white.opacity(hasDraft ? 0.14 : 0.055)))
                    .shadow(color: DieterTheme.shellDeep.opacity(hasDraft ? 0.3 : 0), radius: 9, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(!hasDraft)
            .nativeHelp(working ? "Queue message" : "Send message")
            .accessibilityIdentifier("conversation.send")
            .smokeTarget("conversation.send")
        }
        .fixedSize()
    }

    private func providerMenu(compact: Bool) -> some View {
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
            ComposerMenuLabel(
                title: harness?.name ?? context.composerProvider, symbol: "cpu", iconOnly: compact)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("Provider: \(harness?.name ?? context.composerProvider)")
        .accessibilityIdentifier("conversation.provider")
        .smokeTarget("conversation.provider")
        .disabled(context.composerProviderLocked)
        .nativeHelp(
            context.composerProviderLocked
                ? "Provider: \(harness?.name ?? context.composerProvider). This conversation keeps its original agent service. Model and reasoning changes apply to your next message."
                : "Provider: \(harness?.name ?? context.composerProvider). The agent service that runs this conversation and its tools."
        )
    }

    private func modelMenu(compact: Bool) -> some View {
        Menu {
            ForEach(harness?.models ?? [], id: \.id) { item in
                Button(item.name) {
                    context.selectComposerModel(item)
                }
            }
        } label: {
            let name = model?.name ?? context.composerModel
            ComposerMenuLabel(
                title: compact ? name.replacingOccurrences(of: "GPT-", with: "") : name,
                symbol: "sparkles", iconOnly: false)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("Model: \(model?.name ?? context.composerModel)")
        .accessibilityIdentifier("conversation.model")
        .smokeTarget("conversation.model")
        .disabled(!context.canChangeComposerSelection("model-selection"))
        .nativeHelp(
            context.canChangeComposerSelection("model-selection")
                ? "Model: \(model?.name ?? context.composerModel). The AI model used for your next message. The current turn keeps its settings; models differ in capability, speed, and cost."
                : "Model: \(model?.name ?? context.composerModel). This provider or daemon version does not support changing models in an existing conversation."
        )
    }

    private func reasoningMenu(efforts: [String], compact: Bool) -> some View {
        Menu {
            ForEach(efforts, id: \.self) { value in
                Button(value.capitalized) { context.composerEffort = value }
            }
        } label: {
            ComposerMenuLabel(
                title: context.composerEffort.isEmpty ? "Default" : context.composerEffort.capitalized,
                symbol: "sparkles", iconOnly: compact)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(
            "Reasoning: \(context.composerEffort.isEmpty ? "Default" : context.composerEffort.capitalized)"
        )
        .accessibilityIdentifier("conversation.reasoning")
        .smokeTarget("conversation.reasoning")
        .disabled(!context.canChangeComposerSelection("effort-selection"))
        .nativeHelp(
            context.canChangeComposerSelection("effort-selection")
                ? "Reasoning: \(context.composerEffort.isEmpty ? "Default" : context.composerEffort.capitalized). How much effort the model spends thinking on your next message. Higher effort can improve difficult answers but takes longer. The current turn keeps its settings."
                : "Reasoning: this provider or daemon version keeps the original reasoning effort for an existing conversation."
        )
    }
}

/// Only the menu's visual label adapts; its native presenter stays in place.
private struct ComposerMenuLabel: View {
    let title: String
    let symbol: String
    let iconOnly: Bool

    var body: some View {
        HStack(spacing: 3) {
            if iconOnly {
                Image(systemName: symbol)
                    .frame(width: 14)
            } else {
                Text(title).lineLimit(1).truncationMode(.tail)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// Keep Fast directly accessible while bounding every provider's other settings
/// to one persistent popover, including providers with text or choice options.
private struct ComposerProviderOptions: View {
    let options: [Dieter_V1_ProviderOption]
    @Binding var values: [String: String]
    let conversationLocked: Bool
    let conversationID: String
    @State private var presented = false

    private var additionalOptions: [Dieter_V1_ProviderOption] { options.filter { $0.id != "fast_mode" } }

    var body: some View {
        HStack(spacing: 4) {
            if let fast = options.first(where: { $0.id == "fast_mode" }) {
                ProviderOptionChip(
                    option: fast, values: $values,
                    isEnabled: ProviderOptionValues.isEnabled(fast, conversationLocked: conversationLocked)
                )
                .smokeTarget("conversation.fast-mode")
            }
            if !additionalOptions.isEmpty {
                Button {
                    presented = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Provider options")
                .accessibilityIdentifier("conversation.additional-options")
                .smokeTarget("conversation.additional-options")
                .nativeHelp("Provider options: additional settings supported by this agent service.")
                .popover(isPresented: $presented) {
                    Form {
                        ForEach(additionalOptions, id: \.id) { option in
                            ProviderOptionField(option: option, values: $values)
                                .disabled(
                                    !ProviderOptionValues.isEnabled(option, conversationLocked: conversationLocked)
                                )
                                .smokeTarget("conversation.other-option.\(option.id)")
                        }
                    }
                    .formStyle(.grouped)
                    .frame(width: 320)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onChange(of: conversationID) { _, _ in presented = false }
        .onChange(of: options) { _, _ in presented = false }
        .onDisappear { presented = false }
    }
}
