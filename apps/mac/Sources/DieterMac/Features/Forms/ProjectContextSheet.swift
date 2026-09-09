import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct ProjectContextSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var summary = ""
    @State private var prompt = ""
    @State private var baseRemote = "origin"
    @State private var baseBranch = "main"
    @State private var validationCommands: [ValidationCommandDraft] = []
    @State private var workspacesPresented = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                if let project = store.selectedProject {
                    Section("Git working tree") {
                        LabeledContent(
                            "Host", value: store.machine(forProjectID: project.id)?.name ?? store.endpoint.name)
                        Text(project.path)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .accessibilityLabel("Git working tree path")
                    }
                }
                Section("Project") {
                    TextField("Name", text: $name); TextField("Short summary", text: $summary)
                }
                Section("Persistent context") {
                    TextEditor(text: $prompt).font(.body.monospaced()).frame(height: 260);
                    Text(
                        "This context is owned by Dieter and supplied to new work without writing into the repository."
                    ).font(.caption).foregroundStyle(.secondary)
                }
                Section("Agent workspaces") {
                    TextField("Base remote", text: $baseRemote)
                    TextField("Base branch", text: $baseBranch)
                    Text("Workspace mode is selected independently when each chat or card is created.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Manage existing workspaces…") { workspacesPresented = true }
                }
                Section("Workspace validation") {
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
                                TextField("Timeout in seconds", value: $command.timeoutSeconds, format: .number)
                                Button("Remove command", role: .destructive) {
                                    validationCommands.removeAll { $0.id == command.id }
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    Button("Add validation command", systemImage: "plus") { validationCommands.append(.init()) }
                    Text(
                        "Validation runs directly inside the conversation workspace before merge when requested. Arguments are passed literally, one line per argument."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).navigationTitle("Project context")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }.disabled(
                            saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || baseBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || validationCommands.contains(where: {
                                    $0.executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                }))
                    }
                }
        }
        .frame(width: 700, height: 790)
        .onAppear {
            guard let project = store.selectedProject else { return }
            name = project.name; summary = project.summary; prompt = project.prompt
            baseRemote = project.baseRemote.isEmpty ? "origin" : project.baseRemote
            baseBranch = project.baseBranch.isEmpty ? "main" : project.baseBranch
            validationCommands = project.validationCommands.map(ValidationCommandDraft.init)
        }
        .sheet(isPresented: $workspacesPresented) { ProjectWorkspacesSheet().environment(store) }
    }

    private func save() {
        saving = true
        Task {
            let workspaceSaved = await store.updateProjectWorkspaceSettings(
                remote: baseRemote,
                branch: baseBranch,
                validationCommands: validationCommands.map(\.value)
            )
            if workspaceSaved { await store.updateProject(name: name, summary: summary, prompt: prompt) }
            saving = false
        }
    }
}

struct ProjectWorkspacesSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var candidate: Dieter_V1_Workspace?
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
                }.buttonStyle(DieterIconButtonStyle())
                Button("Done") { dismiss() }
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
                            systemName: workspace.state == "conflicted"
                                ? "exclamationmark.triangle.fill" : "point.3.connected.trianglepath.dotted"
                        )
                        .foregroundStyle(workspace.state == "conflicted" ? DieterTheme.coral : DieterTheme.shell)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cardTitle(workspace.cardID)).font(.system(size: 12, weight: .semibold))
                            Text(
                                "\(workspace.branch.isEmpty ? ConversationWorkspaceMode.projectMode(workspace.mode).title : workspace.branch) · \(workspace.state.replacingOccurrences(of: "_", with: " "))"
                            )
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(DieterTheme.tertiary)
                            Text(workspace.path).font(.system(size: 9, design: .monospaced)).foregroundStyle(
                                DieterTheme.tertiary
                            ).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("\(workspace.changedFiles) files · +\(workspace.additions) −\(workspace.deletions)")
                            Text(ByteCountFormatter.string(fromByteCount: workspace.sizeBytes, countStyle: .file))
                        }
                        .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
                        if store.gitOperation?.cardID == workspace.cardID,
                            GitOperationStatus.active(store.gitOperation?.status ?? "")
                        {
                            ProgressView().controlSize(.mini).help(store.gitOperation?.status ?? "Working")
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
                            .disabled(workspace.changedFiles > 0)
                            Button("Discard…", role: .destructive) {
                                candidate = workspace; candidateKind = .discard
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .disabled(store.gitOperation.map { GitOperationStatus.active($0.status) } ?? false)
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
                Button(candidateKind.title, role: candidateKind.destructive ? .destructive : nil) {
                    let cardID = candidate.cardID
                    let kind = candidateKind
                    self.candidate = nil
                    Task {
                        if await store.startGitOperation(kind, cardID: cardID) { await store.loadProjectWorkspaces() }
                    }
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

    private func cardTitle(_ id: String) -> String {
        store.state.cards.first(where: { $0.id == id })?.title
            ?? store.chats.first(where: { $0.id == id })?.title
            ?? String(id.prefix(12))
    }

    private func open(_ id: String) {
        let chat = store.chats.contains(where: { $0.id == id })
        dismiss()
        Task { await store.openConversation(cardID: id, chat: chat) }
    }
}
