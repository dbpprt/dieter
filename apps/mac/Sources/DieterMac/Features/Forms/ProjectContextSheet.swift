import AppKit
import DieterAPI
import DieterShared
import SwiftUI
import UniformTypeIdentifiers

struct ProjectContextSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ProjectSettingsDraft()
    @State private var workspacesPresented = false
    @State private var saving = false
    @State private var destinationID = ""
    @State private var confirmConsolidation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Project context").font(.title2.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 4)

            Form {
                SharedConflictsButton(keys: store.selectedProject?.conflictKeys ?? [])
                    .buttonStyle(DieterBarButtonStyle(size: 26))
                ProjectContextFields(
                    name: $draft.name, summary: $draft.summary, prompt: $draft.prompt,
                    baseRemote: $draft.baseRemote, baseBranch: $draft.baseBranch,
                    validationCommands: $draft.validationCommands, workspacesPresented: $workspacesPresented)
                Section("Checkouts & machines") {
                    ProjectCheckoutMenu(projectID: store.selectedProjectID, size: 28)
                    ForEach(store.selectedProject?.checkoutChoices ?? [], id: \.id) { checkout in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(
                                    "\(store.endpoints.first(where: { $0.daemonID == checkout.daemonID })?.name ?? checkout.daemonID) · \(checkout.name)"
                                )
                                if !checkout.path.isEmpty { Text(checkout.path).font(.caption.monospaced()) }
                            }
                            Spacer()
                            Button("Detach", role: .destructive) { Task { await store.detachCheckout(checkout) } }
                                .buttonStyle(DieterBarButtonStyle(destructive: true, size: 26))
                        }
                    }
                    Text("Attach another checkout from Add project by choosing this existing project.").font(.caption)
                }
                Section("Consolidate projects") {
                    Picker("Destination", selection: $destinationID) {
                        Text("Choose project").tag("")
                        ForEach(
                            store.projectDirectory.values.filter { $0.id != store.selectedProjectID }.sorted {
                                $0.name < $1.name
                            }, id: \.id
                        ) { project in
                            Text(project.name).tag(project.id)
                        }
                    }
                    Text(
                        "Keep destination settings. Move all boards and checkout registrations into that project, preserving conversations and their machines."
                    ).font(.caption)
                    Button("Consolidate…") { confirmConsolidation = true }
                        .buttonStyle(DieterBarButtonStyle(size: 26)).disabled(destinationID.isEmpty)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(DieterBarButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .smokeTarget("project.context.cancel")
                Button("Save") { save() }
                    .buttonStyle(DieterBarButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || !draft.isValid)
            }
            .padding(20)
        }
        .confirmationDialog("Consolidate into the selected project?", isPresented: $confirmConsolidation) {
            Button("Consolidate") {
                Task {
                    if await store.consolidateProject(source: store.selectedProjectID, destination: destinationID) {
                        dismiss()
                    }
                }
            }
        }
        .frame(width: 620, height: 620)
        .onAppear {
            guard let project = store.selectedProject else { return }
            draft = ProjectSettingsDraft(project: project)
            draft.validationCommands = (store.checkout(forProjectID: project.id)?.validationCommands ?? []).map(
                ValidationCommandDraft.init)
        }
        .onChange(of: store.checkout(forProjectID: store.selectedProjectID)?.validationCommands) { _, commands in
            draft.validationCommands = (commands ?? []).map(ValidationCommandDraft.init)
        }
        .sheet(isPresented: $workspacesPresented) { ProjectWorkspacesSheet().environment(store) }
    }

    private func save() {
        saving = true
        Task {
            let workspaceSaved = await store.updateProjectWorkspaceSettings(
                remote: draft.baseRemote,
                branch: draft.baseBranch,
                validationCommands: draft.validationCommands.map(\.value)
            )
            if workspaceSaved {
                await store.updateProject(name: draft.name, summary: draft.summary, prompt: draft.prompt)
            }
            saving = false
        }
    }
}

struct ProjectContextFields: View {
    @Environment(DieterStore.self) private var store
    @Binding var name: String
    @Binding var summary: String
    @Binding var prompt: String
    @Binding var baseRemote: String
    @Binding var baseBranch: String
    @Binding var validationCommands: [ValidationCommandDraft]
    @Binding var workspacesPresented: Bool

    var body: some View {
        Group {
            Section {
                TextEditor(text: $prompt)
                    .accessibilityIdentifier("project.context.instructions")
                    .smokeTarget("project.context.instructions")
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 200)
                    .dieterInset(radius: 8)
            } header: {
                Text("Agent instructions")
            } footer: {
                Text("Shared by every board in this project. Supplied to new work without changing repository files.")
            }
            Section {
                DisclosureGroup("Project details") {
                    TextField("Name", text: $name)
                    TextField("Short summary", text: $summary)
                    if let project = store.selectedProject {
                        ForEach(project.checkoutChoices, id: \.id) { checkout in
                            LabeledContent(
                                checkout.name,
                                value: store.endpoints.first(where: { $0.daemonID == checkout.daemonID })?.name
                                    ?? checkout.daemonID)
                            if !checkout.path.isEmpty {
                                Text(checkout.path).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            Section {
                DisclosureGroup("Workspace defaults") {
                    TextField("Base remote", text: $baseRemote)
                    TextField("Base branch", text: $baseBranch)
                    Text("Workspace mode is selected independently when each chat or card is created.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Manage existing workspaces…") { workspacesPresented = true }
                        .buttonStyle(DieterBarButtonStyle(size: 26))
                }
            }
            Section {
                DisclosureGroup("Validation commands") {
                    ForEach($validationCommands) { $command in
                        DisclosureGroup(
                            command.name.isEmpty
                                ? (command.executable.isEmpty ? "New command" : command.executable) : command.name
                        ) {
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("Name", text: $command.name)
                                TextField("Executable", text: $command.executable)
                                TextField("Arguments — one per line", text: $command.arguments, axis: .vertical)
                                    .lineLimit(2...6)
                                TextField("Working directory (relative)", text: $command.workingDirectory)
                                TextField(
                                    "Environment — KEY=VALUE per line", text: $command.environment, axis: .vertical
                                ).lineLimit(2...5)
                                TextField("Timeout in seconds", text: $command.timeoutSeconds)
                                Button("Remove command", role: .destructive) {
                                    validationCommands.removeAll { $0.id == command.id }
                                }
                                .buttonStyle(DieterBarButtonStyle(destructive: true, size: 26))
                            }
                            .padding(.top, 8)
                        }
                    }
                    Button("Add validation command", systemImage: "plus") { validationCommands.append(.init()) }
                        .buttonStyle(DieterBarButtonStyle(size: 26))
                    Text(
                        "Validation runs directly inside the conversation workspace before merge when requested. Arguments are passed literally, one line per argument."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ProjectSettingsDraft: Equatable {
    var name = ""
    var summary = ""
    var prompt = ""
    var baseRemote = AdminChoices.options.defaultBaseRemote
    var baseBranch = AdminChoices.options.defaultBaseBranch
    var validationCommands: [ValidationCommandDraft] = []

    init() {}
    init(project: Dieter_V1_Project) {
        name = project.name
        summary = project.summary
        prompt = project.prompt
        baseRemote = project.baseRemote.isEmpty ? AdminChoices.options.defaultBaseRemote : project.baseRemote
        baseBranch = project.baseBranch.isEmpty ? AdminChoices.options.defaultBaseBranch : project.baseBranch
        validationCommands = project.validationCommands.map(ValidationCommandDraft.init)
    }

    var isValid: Bool {
        SharedRules.shared.canSaveProject(
            name: name, baseBranch: baseBranch, drafts: ValidationCommandDraft.encoded(validationCommands))
    }
}

struct ProjectWorkspacesSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var candidate: ClientProjectWorkspaceRow?
    @State private var candidateKind: GitOperationKind = .cleanup

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Project workspaces").font(.title2.weight(.bold))
                    Text("Conversation-owned checkouts, branches, and recovery state").font(.caption).foregroundStyle(
                        DieterTheme.tertiary)
                }
                Spacer()
                Button {
                    Task { await store.loadProjectWorkspaces() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(DieterBarButtonStyle(shape: .circle, size: 28))
                Button("Done") { dismiss() }.buttonStyle(DieterBarButtonStyle(size: 28))
            }
            .padding(18).background(DieterTheme.sidebar)
            if store.projectWorkspaces.isEmpty {
                ContentUnavailableView(
                    "No provisioned workspaces", systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text(
                        "A workspace appears when a conversation first uses Git, Files, or a scoped terminal.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.projectWorkspaces, id: \.cardID) { workspace in
                    HStack(spacing: 12) {
                        Image(
                            systemName: workspace.conflicted
                                ? "exclamationmark.triangle.fill" : "point.3.connected.trianglepath.dotted"
                        )
                        .foregroundStyle(workspace.conflicted ? DieterTheme.coral : DieterTheme.shell)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(workspace.title).font(.system(size: 12, weight: .semibold))
                            Text(workspace.detail)
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(DieterTheme.tertiary)
                            Text(workspace.path).font(.system(size: 9, design: .monospaced)).foregroundStyle(
                                DieterTheme.tertiary
                            ).lineLimit(1).truncationMode(.middle)
                            if !workspace.error.isEmpty {
                                Text(workspace.error).font(.system(size: 9)).foregroundStyle(DieterTheme.coral)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Text(workspace.stats)
                            .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
                        if workspace.pending {
                            ProgressView().controlSize(.mini)
                        }
                        Menu {
                            Button("Open conversation") { open(workspace.cardID) }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.path)
                            }
                            Divider()
                            Button("Clean up…") {
                                candidate = workspace; candidateKind = .cleanup
                            }
                            .disabled(!workspace.canCleanUp)
                            Button("Discard…", role: .destructive) {
                                candidate = workspace; candidateKind = .discard
                            }
                            .disabled(!workspace.canDiscard)
                        } label: {
                            DieterMenuLabel(symbol: "ellipsis", size: 26)
                        }
                        .dieterMenuChrome(.circle)
                        .disabled(workspace.pending)
                    }
                    .padding(.vertical, 5)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 760, height: 560)
        .task { await store.loadProjectWorkspaces() }
        .confirmationDialog(
            candidateKind.title,
            isPresented: Binding(get: { candidate != nil }, set: { if !$0 { candidate = nil } })
        ) {
            if let candidate {
                Button(candidateKind.title, role: candidateKind == .discard ? .destructive : nil) {
                    let cardID = candidate.cardID
                    let discard = candidateKind == .discard
                    self.candidate = nil
                    Task { await store.removeProjectWorkspace(cardID: cardID, discard: discard) }
                }
            }
            Button("Cancel", role: .cancel) { candidate = nil }
        } message: {
            Text(
                candidateKind == .discard
                    ? "Dieter records recovery artifacts, then removes the checkout and managed branch."
                    : "Only clean, integrated workspaces can be cleaned up.")
        }
    }

    private func open(_ id: String) {
        let chat = store.chats.contains(where: { $0.id == id })
        dismiss()
        Task { await store.openConversation(cardID: id, chat: chat) }
    }
}
