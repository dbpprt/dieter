import AppKit
import DieterAPI
import DieterShared
import SwiftUI
import UniformTypeIdentifiers

struct NewConversationSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var form = CreationFormModel(chat: false)
    @State private var workspacePickerPresented = false
    @State private var fileImporterPresented = false
    @State private var attachmentDropTargeted = false
    @State private var submitting = false
    @State private var workspaceDraft = ConversationWorkspaceDraft()
    @State private var draftInitialized = false
    @FocusState private var focusedField: Field?

    private enum Field { case title, prompt }

    private var preview: ClientCreationPreview { form.preview }
    private var selectedLane: Dieter_V1_Lane? { preview.startLanes.first { $0.id == form.lane } }
    private var project: Dieter_V1_Project? { store.selectedProject }
    private var canSubmit: Bool { !submitting && form.previewed && preview.problem.isEmpty }

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
                    LabeledContent("Title") {
                        TextField(
                            "Title", text: $form.intent.title,
                            prompt: Text(preview.title.isEmpty ? "A short name for this task" : preview.title)
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .focused($focusedField, equals: .title)
                        .onSubmit { focusedField = .prompt }
                        .accessibilityIdentifier("new-card.title")
                        .smokeTarget("new-card.title")
                    }

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
                            .help("Attach files, or drop files and paste images into the task")
                            .accessibilityIdentifier("new-card.attach")
                            .smokeTarget("new-card.attach")
                            Spacer()
                            Text(SharedRules.shared.attachmentLimits()).font(.caption).foregroundStyle(.secondary)
                        }
                        if !form.attachments.isEmpty {
                            AttachmentPreviewStrip(attachments: $form.attachments)
                        }
                    }
                }

                Section {
                    if let project {
                        LabeledContent("Run on") {
                            ProjectCheckoutMenu(
                                projectID: project.id,
                                accessibilityIdentifier: "new-card.machine"
                            )
                        }
                    }
                    Picker("Start in", selection: Binding(get: { form.lane }, set: { form.intent.lane = $0 })) {
                        ForEach(preview.startLanes, id: \.id) { item in
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
                    .help(preview.workspaceDetail)

                    if preview.catalog == .none {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(
                                preview.destinationStatus.isEmpty ? "Loading agent models…" : preview.destinationStatus
                            )
                            .foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("new-card.harness-loading")
                    } else {
                        if !preview.offlineHint.isEmpty {
                            Label(preview.offlineHint, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("new-card.harness-error")
                        }
                        AgentPickerFields(controls: preview.agent) { choice in
                            Task { await form.refresh(choice: choice) }
                        }
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
                Text(
                    !preview.problem.isEmpty
                        ? preview.problem
                        : (preview.defersStart
                            ? "Saves a draft. Run it when you're ready." : "The agent will start right away.")
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if submitting { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .buttonStyle(DieterGlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(submitting)
                    .accessibilityIdentifier("new-card.cancel")
                Button(preview.defersStart ? "Save to \(selectedLane?.name ?? "board")" : "Start task") {
                    Task { await submit() }
                }
                .buttonStyle(DieterGlassButtonStyle(prominent: true))
                .keyboardShortcut(.return, modifiers: .command)
                .help("\(preview.defersStart ? "Save card" : "Start task") (⌘Return)")
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
        .attachmentIntake(store: store, importerPresented: $fileImporterPresented, attachments: $form.attachments)
        .task {
            // Establish focus before the asynchronous preview; its completion
            // must not take focus away from a task being edited.
            if focusedField == nil { focusedField = .title }
            initializeDraft()
        }
        .task(
            id: PreviewKey(intent: form.intent, attachments: form.attachments.count)
        ) {
            form.attach(store.core)
            await form.refresh()
        }
        .onChange(of: store.checkout(forProjectID: project?.id ?? "")?.id, initial: true) { _, id in
            form.intent.checkoutID = id ?? ""
        }
        .onChange(of: workspaceDraft, initial: true) { _, draft in draft.apply(to: &form.intent) }
    }

    /// What a preview depends on: the choices and how many files are attached.
    private struct PreviewKey: Equatable {
        let intent: ClientCreationIntent
        let attachments: Int
    }

    private var taskEditor: some View {
        TextEditor(text: $form.intent.prompt)
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
                if form.intent.prompt.isEmpty {
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
                    do {
                        form.attachments = try await store.attachmentParts(providers, appendingTo: form.attachments)
                    } catch {
                        store.show(error)
                    }
                }
            }
    }

    private func labelSelection(_ id: String) -> Binding<Bool> {
        Binding(
            get: { form.intent.labelIds.contains(id) },
            set: { selected in
                form.intent.labelIds.removeAll { $0 == id }
                if selected { form.intent.labelIds = (form.intent.labelIds + [id]).sorted() }
            })
    }

    private func initializeDraft() {
        guard !draftInitialized else { return }
        draftInitialized = true
        form.attach(store.core)
        form.intent.projectID = store.selectedProjectID
        form.intent.boardID = store.selectedBoardID
        workspaceDraft.mode = ConversationWorkspaceMode.projectMode(store.creationMemory.workspaceMode)
        if workspaceDraft.baseBranch.isEmpty { workspaceDraft.baseBranch = project?.baseBranch ?? "" }
        if workspaceDraft.baseRemote.isEmpty {
            let boardRemote = store.selectedBoard?.baseRemote ?? ""
            workspaceDraft.baseRemote = boardRemote.isEmpty ? (project?.baseRemote ?? "") : boardRemote
        }
        if let configured = store.selectedBoard?.remotePublishMode, !configured.isEmpty {
            workspaceDraft.remotePublishMode = configured
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        submitting = true
        _ = await form.create(using: store)
        submitting = false
    }
}
