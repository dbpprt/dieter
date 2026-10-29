import AppKit
import DieterClientAPI
import DieterCore
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
    private var canSubmit: Bool { !submitting && form.previewed && preview.problem.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New card").font(.title2.weight(.semibold))
                    Text("\(store.selectedProject?.name ?? "Project") · \(store.selectedBoard?.name ?? "Board")")
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
                        .e2eTarget("new-card.title")
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
                            .buttonStyle(DieterBarButtonStyle(size: 26))
                            .help("Attach files, or drop files and paste images into the task")
                            .accessibilityIdentifier("new-card.attach")
                            .e2eTarget("new-card.attach")
                            Spacer()
                            Text(CreationCopy.attachmentLimits).font(.caption).foregroundStyle(.secondary)
                        }
                        if !form.attachments.isEmpty {
                            AttachmentPreviewStrip(attachments: $form.attachments)
                        }
                    }
                }

                Section {
                    if let project = store.selectedProject {
                        LabeledContent("Run on") {
                            ProjectCheckoutMenu(
                                projectID: project.id,
                                accessibilityIdentifier: "new-card.machine",
                                size: 28
                            )
                        }
                    }
                    Picker("Start in", selection: Binding(get: { form.lane }, set: { form.intent.lane = $0 })) {
                        ForEach(preview.startLanes, id: \.id) { item in
                            Text(item.name).tag(item.id)
                        }
                    }
                    .accessibilityIdentifier("new-card.lane")
                    .e2eTarget("new-card.lane")
                    LabeledContent("Workspace") {
                        Picker("Workspace", selection: $workspaceDraft.mode) {
                            Text("New worktree").tag(ConversationWorkspaceMode.worktree)
                            Text("Project folder").tag(ConversationWorkspaceMode.project)
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("new-card.workspace-mode")
                        Button("Options…") { workspacePickerPresented = true }
                            .buttonStyle(DieterBarButtonStyle(size: 26))
                            .accessibilityIdentifier("new-card.workspace")
                            .e2eTarget("new-card.workspace")
                            .help("Configure the branch, base and publishing options")
                    }
                    .help(preview.workspaceDetail)
                    LabeledContent("Vault") {
                        Toggle("Allow vault access", isOn: $form.intent.vaultAccess)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityIdentifier("new-card.vault-access")
                    }
                    .help(
                        "Let this task's agent use the account vault's passwords and TOTP codes. "
                            + "Set only when creating."
                    )
                    LabeledContent("Mail") {
                        Toggle("Allow the agent to send you mail", isOn: $form.intent.mailAccess)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityIdentifier("new-card.mail-access")
                            .e2eTarget("new-card.mail-access")
                    }
                    .help("Let this task's agent send you reports in Mail. Set only when creating.")

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
                                    let tint = Color(hex: label.color) ?? .accentColor
                                    let selected = form.intent.labelIds.contains(label.id)
                                    Toggle(
                                        isOn: Binding(
                                            get: { form.intent.labelIds.contains(label.id) },
                                            set: { form.setLabel(label.id, selected: $0) })
                                    ) {
                                        HStack(spacing: 5) {
                                            Circle().fill(selected ? Color.white : tint).frame(width: 6, height: 6)
                                            Text(label.name)
                                        }
                                    }
                                    .toggleStyle(DieterChipToggleStyle(tint: tint, size: 24))
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
                    .buttonStyle(DieterBarButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(submitting)
                    .accessibilityIdentifier("new-card.cancel")
                    .e2eTarget("new-card.cancel")
                let startLane = preview.startLanes.first { $0.id == form.lane }
                Button(preview.defersStart ? "Save to \(startLane?.name ?? "board")" : "Start task") {
                    Task { await submit() }
                }
                .buttonStyle(DieterBarButtonStyle(prominent: true))
                .keyboardShortcut(.return, modifiers: .command)
                .help("\(preview.defersStart ? "Save card" : "Start task") (⌘Return)")
                .disabled(!canSubmit)
                .accessibilityIdentifier("new-card.create")
                .e2eTarget("new-card.create")
            }
            .padding(20)
        }
        .frame(width: 600, height: 680)
        .interactiveDismissDisabled(submitting)
        .sheet(isPresented: $workspacePickerPresented) {
            ConversationWorkspacePickerSheet(project: store.selectedProject, draft: $workspaceDraft)
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
        .background { CreationCheckoutBinder(projectID: store.selectedProject?.id ?? "", form: form) }
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
            .dieterInset(radius: 6)
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
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .opacity(attachmentDropTargeted || focusedField == .prompt ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .accessibilityLabel("Initial task")
            .accessibilityIdentifier("new-card.prompt")
            .e2eTarget("new-card.prompt")
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

    private func initializeDraft() {
        guard !draftInitialized else { return }
        draftInitialized = true
        form.attach(store.core)
        form.intent.projectID = store.selectedProjectID
        form.intent.boardID = store.selectedBoardID
        if !store.newCardLaneID.isEmpty {
            form.intent.lane = store.newCardLaneID
            store.newCardLaneID = ""
        }
        workspaceDraft.mode = ConversationWorkspaceMode.projectMode(store.creationMemory.workspaceMode)
        if workspaceDraft.baseBranch.isEmpty { workspaceDraft.baseBranch = store.selectedProject?.baseBranch ?? "" }
        if workspaceDraft.baseRemote.isEmpty {
            let boardRemote = store.selectedBoard?.baseRemote ?? ""
            workspaceDraft.baseRemote = boardRemote.isEmpty ? (store.selectedProject?.baseRemote ?? "") : boardRemote
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

/// Keeps a creation form on its project's chosen checkout. Asking for it
/// reads the project's checkouts through the core, so only this view does,
/// and typing in the form does not.
struct CreationCheckoutBinder: View {
    @Environment(DieterStore.self) private var store
    let projectID: String
    let form: CreationFormModel

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: store.checkout(forProjectID: projectID)?.id, initial: true) { _, id in
                form.intent.checkoutID = id ?? ""
            }
    }
}

/// Fixed wording of the creation forms, read from the core once.
@MainActor
enum CreationCopy {
    static let attachmentLimits = SharedRules.shared.attachmentLimits()
}
