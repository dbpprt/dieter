import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct NewConversationSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var prompt = ""
    @State private var provider = ""
    @State private var model = ""
    @State private var effort = ""
    @State private var providerOptions: [String: String] = [:]
    @State private var lane = ""
    @State private var workspacePickerPresented = false
    @State private var selectedLabelIDs: Set<String> = []
    @State private var attachments: [Dieter_V1_MessagePart] = []
    @State private var fileImporterPresented = false
    @State private var attachmentDropTargeted = false
    @State private var submitting = false
    @State private var workspaceDraft = ConversationWorkspaceDraft()
    @State private var destinationHarnesses: [Dieter_V1_Harness] = []
    @State private var harnessCatalogLoading = false
    @State private var harnessCatalogError: String?
    @FocusState private var focusedField: Field?

    private enum Field { case title, prompt }

    private var harness: Dieter_V1_Harness? { destinationHarnesses.first { $0.id == provider } }
    private var selectedModel: Dieter_V1_HarnessModel? { harness?.models.first { $0.id == model } }
    private var selectedLane: Dieter_V1_Lane? { store.selectedBoard?.lanes.first { $0.id == lane } }
    private var project: Dieter_V1_Project? { store.selectedProject }
    private var deferred: Bool { lane.lowercased() != "running" }
    private var canSubmit: Bool {
        !submitting && !harnessCatalogLoading && harnessCatalogError == nil && harness != nil
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("BOARD  /  AGENT WORKSPACE")
                        .font(DieterFont.sectionLabel).tracking(1.4)
                        .foregroundStyle(DieterTheme.tertiary)
                    Text("New conversation").font(.system(size: 20, weight: .semibold))
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(DieterIconButtonStyle()).help("Close")
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 15)

            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    newCardLabel("Conversation title")
                    TextField("What should this agent accomplish?", text: $title)
                        .textFieldStyle(.plain).font(.system(size: 15, weight: .medium))
                        .focused($focusedField, equals: .title)
                        .padding(.horizontal, 14).frame(height: 46)
                        .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10).stroke(
                                focusedField == .title ? DieterTheme.shellDeep.opacity(0.85) : DieterTheme.strongBorder,
                                lineWidth: focusedField == .title ? 2 : 1)
                        )
                        .accessibilityIdentifier("new-card.title")

                    newCardLabel("Initial task")
                    TextField(
                        "Give the agent a concrete outcome, context, and acceptance criteria…", text: $prompt,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 14)).lineSpacing(3).lineLimit(1...7)
                    .focused($focusedField, equals: .prompt)
                    .padding(.horizontal, 13).padding(.vertical, 14)
                    .frame(height: 135, alignment: .topLeading)
                    .background(
                        attachmentDropTargeted ? DieterTheme.shellDeep.opacity(0.12) : DieterTheme.input,
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10).stroke(
                            attachmentDropTargeted
                                ? DieterTheme.shell
                                : (focusedField == .prompt
                                    ? DieterTheme.shellDeep.opacity(0.72) : DieterTheme.strongBorder),
                            lineWidth: attachmentDropTargeted || focusedField == .prompt ? 1.5 : 1
                        )
                    )
                    .accessibilityIdentifier("new-card.prompt")
                    .attachmentDropTarget(isTargeted: $attachmentDropTargeted) { providers in
                        Task {
                            do {
                                attachments = try await store.attachmentParts(providers, appendingTo: attachments)
                            } catch { store.show(error) }
                        }
                    }

                    HStack(spacing: 9) {
                        Button {
                            fileImporterPresented = true
                        } label: {
                            Label("Attach images or files", systemImage: "paperclip")
                        }
                        .buttonStyle(DieterSecondaryButtonStyle())
                        Text("or drop files above · paste an image with ⌘V · 4 files, 6 MB total")
                            .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    }
                    if !attachments.isEmpty {
                        AttachmentPreviewStrip(attachments: $attachments)
                    }

                    if let labels = store.selectedBoard?.labels, !labels.isEmpty {
                        newCardLabel("Labels")
                        DieterFlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                            ForEach(labels, id: \.id) { label in
                                let selected = selectedLabelIDs.contains(label.id)
                                let tint = Color(hex: label.color) ?? DieterTheme.shell
                                Button {
                                    if selected {
                                        selectedLabelIDs.remove(label.id)
                                    } else {
                                        selectedLabelIDs.insert(label.id)
                                    }
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: selected ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(selected ? tint : DieterTheme.tertiary)
                                        Circle().fill(tint).frame(width: 6, height: 6)
                                        Text(label.name)
                                    }
                                    .font(.caption.weight(.medium)).foregroundStyle(
                                        selected ? DieterTheme.text : DieterTheme.subtle
                                    )
                                    .padding(.horizontal, 9).frame(height: 28)
                                    .background(tint.opacity(selected ? 0.17 : 0.08), in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .top, spacing: 11) {
                            newCardMenu(title: "Start in", value: laneTitle, symbol: "arrow.right.circle") {
                                ForEach(store.selectedBoard?.lanes ?? [], id: \.id) { item in
                                    Button(item.name) { lane = item.id }
                                }
                            }
                            newCardWorkspaceButton
                            newCardMenu(title: "Provider", value: harness?.name ?? "Server default", symbol: "cpu") {
                                ForEach(destinationHarnesses, id: \.id) { item in
                                    Button(item.name) {
                                        guard let selection = HarnessSelection(provider: item.id).resolved(in: [item])
                                        else { return }
                                        provider = selection.provider; model = selection.model
                                        effort = selection.effort; providerOptions = selection.providerOptions
                                    }
                                }
                            }
                            newCardMenu(
                                title: "Model", value: selectedModel?.name ?? "Agent default", symbol: "terminal"
                            ) {
                                ForEach(harness?.models ?? [], id: \.id) { item in
                                    Button(item.name) {
                                        model = item.id; effort = item.defaultEffort
                                    }
                                }
                            }
                            newCardMenu(
                                title: "Reasoning", value: effort.isEmpty ? "Default" : effort.capitalized,
                                symbol: "sparkles"
                            ) {
                                ForEach(selectedModel?.efforts ?? [], id: \.self) { value in
                                    Button(value.capitalized) { effort = value }
                                }
                            }
                        }
                        Text(workspaceDraft.mode.detail)
                            .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    }

                    if !(harness?.options ?? []).isEmpty {
                        HStack(spacing: 7) {
                            ProviderOptionChips(options: harness?.options ?? [], values: $providerOptions)
                            Spacer()
                        }
                    }

                    if harnessCatalogLoading {
                        Label("Loading models from this project's machine…", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption).foregroundStyle(DieterTheme.tertiary)
                            .accessibilityIdentifier("new-card.harness-loading")
                    } else if let harnessCatalogError {
                        Label(harnessCatalogError, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(DieterTheme.coral)
                            .accessibilityIdentifier("new-card.harness-error")
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "lock").foregroundStyle(DieterTheme.shell)
                        Text(
                            "Dieter persists one local harness session and transcript for this card on \(store.endpoint.name)."
                        )
                        .font(.caption).foregroundStyle(DieterTheme.shell)
                        Spacer()
                    }
                    .padding(.horizontal, 13).frame(minHeight: 42)
                    .background(DieterTheme.shellDeep.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.shellDeep.opacity(0.28)))
                }
                .padding(.horizontal, 24).padding(.bottom, 18)
            }

            Divider().overlay(DieterTheme.border)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DieterSecondaryButtonStyle())
                Button {
                    Task { await submit() }
                } label: {
                    HStack(spacing: 7) {
                        if submitting { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles") }
                        Text(
                            deferred
                                ? "Save to \(selectedLane?.name ?? "board")"
                                : "Start in \(selectedLane?.name ?? "Running")")
                    }
                }
                .buttonStyle(DieterPrimaryButtonStyle()).disabled(!canSubmit)
                .accessibilityIdentifier("new-card.create")
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 700, height: 660)
        .background(DieterTheme.background)
        .sheet(isPresented: $workspacePickerPresented) {
            ConversationWorkspacePickerSheet(
                project: project,
                draft: $workspaceDraft
            )
        }
        .attachmentIntake(
            store: store,
            importerPresented: $fileImporterPresented,
            attachments: $attachments
        )
        .task {
            await loadDestinationHarnesses()
            await Task.yield()
            focusedField = .title
        }
    }

    private func loadDestinationHarnesses() async {
        if lane.isEmpty { lane = store.selectedBoard?.lanes.first?.id ?? "todo" }
        if workspaceDraft.baseBranch.isEmpty { workspaceDraft.baseBranch = project?.baseBranch ?? "" }
        guard let projectID = project?.id, !projectID.isEmpty else { return }
        harnessCatalogLoading = true
        harnessCatalogError = nil
        defer { harnessCatalogLoading = false }
        do {
            destinationHarnesses = try await store.loadHarnessCatalog(forProjectID: projectID).harnesses
        } catch {
            harnessCatalogError = DieterRPCFailure.message(for: error)
            destinationHarnesses = []
            return
        }
        let initializing = provider.isEmpty
        let preferences =
            initializing
            ? ConversationCreationPreferences.load(from: DieterAppearance.applicationDefaults())
            : ConversationCreationPreferences(
                provider: provider, model: model, effort: effort, workspaceMode: workspaceDraft.mode)
        guard let selection = preferences.resolved(in: destinationHarnesses),
            let harness = destinationHarnesses.first(where: { $0.id == selection.provider })
        else { return }
        let previousProvider = provider
        provider = selection.provider
        model = selection.model
        effort = selection.effort
        if initializing { workspaceDraft.mode = selection.workspaceMode }
        providerOptions = ProviderOptionValues.resolved(
            for: harness,
            existing: previousProvider == selection.provider ? providerOptions : [:]
        )
    }

    private var laneTitle: String {
        let title = selectedLane?.name ?? "Todo"
        return deferred ? "\(title) · draft" : "\(title) · starts agent"
    }

    private var newCardWorkspaceButton: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Workspace").font(.system(size: 11, weight: .semibold)).foregroundStyle(DieterTheme.subtle)
            Button {
                workspacePickerPresented = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: workspaceChoice.symbol)
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(DieterTheme.shell)
                    Text(workspaceChoice.title).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 7, weight: .bold)).foregroundStyle(DieterTheme.tertiary)
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(DieterTheme.text)
                .padding(.horizontal, 10).frame(height: 38)
                .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.strongBorder))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("new-card.workspace")
            .help("Choose where this agent should work")
        }
        .frame(maxWidth: .infinity)
    }

    private var workspaceChoice: ConversationWorkspaceMode {
        workspaceDraft.mode
    }

    private func newCardLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DieterTheme.subtle)
            .padding(.bottom, -10)
    }

    private func newCardMenu<Content: View>(
        title: String,
        value: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(DieterTheme.subtle)
            // The borderless menu style strips background/overlay chrome from its
            // label, so the field chrome has to live on the Menu itself.
            Menu(content: content) {
                HStack(spacing: 7) {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(
                        DieterTheme.shell)
                    Text(value).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(
                        DieterTheme.tertiary)
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(DieterTheme.subtle)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.strongBorder))
        }
        .frame(maxWidth: .infinity)
    }

    private func submit() async {
        guard canSubmit else { return }
        submitting = true
        ConversationCreationPreferences(
            provider: provider,
            model: model,
            effort: effort,
            workspaceMode: workspaceDraft.mode
        ).save(to: DieterAppearance.applicationDefaults())
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        await store.createConversation(
            title: cleanTitle,
            prompt: cleanPrompt.isEmpty ? cleanTitle : cleanPrompt,
            attachments: attachments,
            chat: false,
            provider: provider,
            model: model,
            effort: effort,
            providerOptions: providerOptions,
            deferred: deferred,
            lane: lane,
            labelIDs: Array(selectedLabelIDs).sorted(),
            workspace: workspaceDraft
        )
        submitting = false
    }
}
