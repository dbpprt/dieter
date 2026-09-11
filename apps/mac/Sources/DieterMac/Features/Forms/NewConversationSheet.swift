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
    @State private var draftInitialized = false
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
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New card").font(.title2.weight(.semibold))
                    Text("\(project?.name ?? "Project") · \(store.selectedBoard?.name ?? "Board")")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)

            Form {
                Section {
                    TextField("Title", text: $title, prompt: Text("A short name for this task"))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .title)
                        .onSubmit { focusedField = .prompt }
                        .accessibilityIdentifier("new-card.title")
                        .smokeTarget("new-card.title")

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Task")
                            Text("Optional").foregroundStyle(.tertiary)
                        }
                        taskEditor
                        HStack(spacing: 10) {
                            Button {
                                fileImporterPresented = true
                            } label: {
                                Label("Attach files…", systemImage: "paperclip")
                            }
                            .buttonStyle(.bordered).controlSize(.small)
                            .help("Attach up to 4 files, or drop files and paste images into the task")
                            .accessibilityIdentifier("new-card.attach")
                            .smokeTarget("new-card.attach")
                            Spacer()
                            Text("4 files · 6 MB total").font(.caption).foregroundStyle(.secondary)
                        }
                        if !attachments.isEmpty {
                            AttachmentPreviewStrip(attachments: $attachments)
                        }
                    }
                }

                Section {
                    Picker("Start in", selection: $lane) {
                        ForEach(store.selectedBoard?.lanes ?? [], id: \.id) { item in
                            Text(item.name).tag(item.id)
                        }
                    }
                    .accessibilityIdentifier("new-card.lane")
                    .smokeTarget("new-card.lane")
                    LabeledContent("Workspace") {
                        Picker("Workspace", selection: $workspaceDraft.mode) {
                            Text("New worktree").tag(ConversationWorkspaceMode.worktree)
                            Text("Project folder").tag(ConversationWorkspaceMode.project)
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("new-card.workspace-mode")
                        Button("Options…") { workspacePickerPresented = true }
                            .controlSize(.small)
                            .accessibilityIdentifier("new-card.workspace")
                            .smokeTarget("new-card.workspace")
                            .help("Configure the branch, base and publishing options")
                    }
                    .help(workspaceDraft.mode.detail)

                    if harnessCatalogLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading available models…").foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("new-card.harness-loading")
                    } else if let harnessCatalogError {
                        HStack(alignment: .top) {
                            Label(harnessCatalogError, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Retry") { Task { await loadDestinationHarnesses() } }
                                .accessibilityIdentifier("new-card.harness-retry")
                        }
                        .accessibilityIdentifier("new-card.harness-error")
                    } else {
                        Picker("Provider", selection: providerSelection) {
                            ForEach(destinationHarnesses, id: \.id) { item in
                                Text(item.name).tag(item.id)
                            }
                        }
                        .disabled(destinationHarnesses.count < 2)
                        .accessibilityIdentifier("new-card.provider")
                        .smokeTarget("new-card.provider")
                        Picker("Model", selection: modelSelection) {
                            if harness?.models.isEmpty != false { Text("Provider default").tag("") }
                            ForEach(harness?.models ?? [], id: \.id) { item in
                                Text(item.name).tag(item.id)
                            }
                        }
                        .disabled(harness?.models.isEmpty != false)
                        .accessibilityIdentifier("new-card.model")
                        .smokeTarget("new-card.model")
                        if let efforts = selectedModel?.efforts, !efforts.isEmpty {
                            Picker("Reasoning", selection: $effort) {
                                Text("Default").tag("")
                                ForEach(efforts, id: \.self) { Text($0.capitalized).tag($0) }
                            }
                            .accessibilityIdentifier("new-card.reasoning")
                            .smokeTarget("new-card.reasoning")
                        }
                        ProviderOptionFields(
                            options: ProviderOptionValues.options(for: harness, model: model),
                            values: $providerOptions
                        )
                        .toggleStyle(.switch)
                    }

                    if let labels = store.selectedBoard?.labels, !labels.isEmpty {
                        LabeledContent("Labels") {
                            DieterFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                                ForEach(labels, id: \.id) { label in
                                    Toggle(isOn: labelSelection(label.id)) {
                                        HStack(spacing: 5) {
                                            Circle().fill(Color(hex: label.color) ?? .accentColor)
                                                .frame(width: 6, height: 6)
                                            Text(label.name)
                                        }
                                    }
                                    .toggleStyle(.button).controlSize(.small)
                                    .accessibilityIdentifier("new-card.label.\(label.id)")
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .pickerStyle(.menu)
            .scrollContentBackground(.hidden)
            .disabled(submitting)

            Divider()
            HStack(spacing: 10) {
                Text(deferred ? "Saves a draft. Run it when you're ready." : "The agent will start right away.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if submitting { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                    .disabled(submitting)
                    .accessibilityIdentifier("new-card.cancel")
                Button(deferred ? "Save to \(selectedLane?.name ?? "board")" : "Start task") {
                    Task { await submit() }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .help("\(deferred ? "Save card" : "Start task") (⌘Return)")
                .disabled(!canSubmit)
                .accessibilityIdentifier("new-card.create")
                .smokeTarget("new-card.create")
            }
            .padding(20)
        }
        .frame(width: 600, height: 680)
        .interactiveDismissDisabled(submitting)
        .sheet(isPresented: $workspacePickerPresented) {
            ConversationWorkspacePickerSheet(project: project, draft: $workspaceDraft)
        }
        .attachmentIntake(store: store, importerPresented: $fileImporterPresented, attachments: $attachments)
        .task {
            // Establish focus before the asynchronous catalog request; its
            // completion must not take focus away from a task being edited.
            if focusedField == nil { focusedField = .title }
            initializeDraft()
            await loadDestinationHarnesses()
        }
    }

    private var taskEditor: some View {
        TextEditor(text: $prompt)
            .font(.body)
            .focused($focusedField, equals: .prompt)
            .onKeyPress(.tab, phases: .down) { event in
                guard !event.modifiers.contains(.option) else { return .ignored }
                if event.modifiers.contains(.shift) {
                    NSApp.keyWindow?.selectPreviousKeyView(nil)
                } else {
                    NSApp.keyWindow?.selectNextKeyView(nil)
                }
                return .handled
            }
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: 96)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("Describe the outcome, context, and anything the agent should know…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        attachmentDropTargeted || focusedField == .prompt
                            ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: attachmentDropTargeted || focusedField == .prompt ? 1.5 : 1
                    )
                    .allowsHitTesting(false)
            }
            .accessibilityLabel("Initial task")
            .accessibilityIdentifier("new-card.prompt")
            .smokeTarget("new-card.prompt")
            .attachmentDropTarget(isTargeted: $attachmentDropTargeted) { providers in
                Task {
                    do { attachments = try await store.attachmentParts(providers, appendingTo: attachments) } catch {
                        store.show(error)
                    }
                }
            }
    }

    private var providerSelection: Binding<String> {
        Binding(
            get: { provider },
            set: { id in
                guard let item = destinationHarnesses.first(where: { $0.id == id }),
                    let selection = HarnessSelection(provider: id).resolved(in: [item])
                else { return }
                provider = selection.provider
                model = selection.model
                effort =
                    item.models.first(where: { $0.id == model })?.efforts.contains(selection.effort) == true
                    ? selection.effort : ""
                providerOptions = selection.providerOptions
            })
    }

    private var modelSelection: Binding<String> {
        Binding(
            get: { model },
            set: { id in
                model = id
                effort = harness?.models.first(where: { $0.id == id })?.defaultEffort ?? ""
                providerOptions = ProviderOptionValues.normalized(for: harness, model: id, saved: providerOptions)
            })
    }

    private func labelSelection(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selectedLabelIDs.contains(id) },
            set: { selected in
                if selected { selectedLabelIDs.insert(id) } else { selectedLabelIDs.remove(id) }
            })
    }

    private func initializeDraft() {
        guard !draftInitialized else { return }
        draftInitialized = true
        workspaceDraft.mode =
            ConversationCreationPreferences.load(from: DieterAppearance.applicationDefaults()).workspaceMode
        if lane.isEmpty { lane = store.selectedBoard?.lanes.first?.id ?? "todo" }
        if workspaceDraft.baseBranch.isEmpty { workspaceDraft.baseBranch = project?.baseBranch ?? "" }
        if workspaceDraft.baseRemote.isEmpty {
            let boardRemote = store.selectedBoard?.baseRemote ?? ""
            workspaceDraft.baseRemote = boardRemote.isEmpty ? (project?.baseRemote ?? "") : boardRemote
        }
        if let configured = store.selectedBoard?.remotePublishMode, !configured.isEmpty {
            workspaceDraft.remotePublishMode = configured
        }
    }

    private func loadDestinationHarnesses() async {
        guard let projectID = project?.id, !projectID.isEmpty else {
            harnessCatalogError = "Choose a project before creating a card."
            return
        }
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
        guard !destinationHarnesses.isEmpty else {
            harnessCatalogError = "No providers are available on this project's machine."
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
        effort =
            harness.models.first(where: { $0.id == model })?.efforts.contains(selection.effort) == true
            ? selection.effort : ""
        providerOptions = ProviderOptionValues.normalized(
            for: harness,
            model: model,
            saved: previousProvider == selection.provider ? providerOptions : [:]
        )
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
