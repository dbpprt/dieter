import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct ConversationComposer: View {
    @Environment(ConversationContext.self) private var context
    @Binding var fileImporterPresented: Bool
    @FocusState private var composerFocused: Bool
    @State private var attachmentDropTargeted = false

    private var harness: Dieter_V1_Harness? {
        context.harnessCatalog.harnesses.first { $0.id == context.composerProvider }
    }
    private var model: Dieter_V1_HarnessModel? { harness?.models.first { $0.id == context.composerModel } }
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
    var body: some View {
        @Bindable var context = context
        VStack(spacing: 8) {
            if let queue = context.conversation?.conversation.queue, !queue.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "clock.fill")
                        .font(.caption)
                        .foregroundStyle(DieterTheme.amber)
                    Text("\(queue.count) message\(queue.count == 1 ? "" : "s") queued")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DieterTheme.text)
                    Text("Sends after the current turn")
                        .font(.caption2)
                        .foregroundStyle(DieterTheme.subtle)
                    Spacer()
                }
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)
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
                    .onKeyPress(.return, phases: .down) { press in
                        if !ComposerReturnPolicy.sendsMessage(shiftPressed: press.modifiers.contains(.shift)) {
                            return .ignored
                        }
                        if hasDraft { Task { await context.sendComposer() } }
                        return .handled
                    }
                    .frame(minHeight: 54, alignment: .topLeading)

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
                        Task { await context.sendComposer() }
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
            .background(
                attachmentDropTargeted ? DieterTheme.shellDeep.opacity(0.12) : DieterTheme.surface,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
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
    }

    private func composerSettings(showContext: Bool) -> some View {
        HStack(spacing: 7) {
            Button {
                fileImporterPresented = true
            } label: {
                Image(systemName: "paperclip")
            }
            .buttonStyle(DieterIconButtonStyle())
            .help("Attach files")

            Menu {
                ForEach(context.harnessCatalog.harnesses, id: \.id) { item in
                    Button(item.name) {
                        guard let selection = HarnessSelection(provider: item.id).resolved(in: [item]) else { return }
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

            Menu {
                ForEach(harness?.models ?? [], id: \.id) { item in
                    Button(item.name) {
                        context.composerModel = item.id
                        context.composerEffort = item.defaultEffort
                    }
                }
            } label: {
                DieterChipLabel(title: model?.name ?? context.composerModel, symbol: "terminal", maximumTitleWidth: 190)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

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
            }

            ProviderOptionChips(
                options: harness?.options ?? [],
                values: Binding(
                    get: { context.composerProviderOptions },
                    set: { context.composerProviderOptions = $0 }
                ))

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
