import AppKit
import DieterAPI
import SwiftUI

struct ConversationWorkspacePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: Dieter_V1_Project?
    @Binding var draft: ConversationWorkspaceDraft
    @State private var draftMode: ConversationWorkspaceMode
    @State private var draftBranch: String
    @State private var draftBaseBranch: String
    @State private var draftBaseRemote: String
    @State private var draftRemotePublishMode: String

    init(
        project: Dieter_V1_Project?,
        draft: Binding<ConversationWorkspaceDraft>
    ) {
        self.project = project
        _draft = draft
        _draftMode = State(initialValue: draft.wrappedValue.mode)
        _draftBranch = State(initialValue: draft.wrappedValue.branch)
        _draftBaseBranch = State(
            initialValue: draft.wrappedValue.baseBranch.isEmpty
                ? (project?.baseBranch ?? "") : draft.wrappedValue.baseBranch)
        _draftBaseRemote = State(
            initialValue: draft.wrappedValue.baseRemote.isEmpty
                ? (project?.baseRemote ?? "") : draft.wrappedValue.baseRemote)
        _draftRemotePublishMode = State(initialValue: draft.wrappedValue.remotePublishMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Workspace options")
                        .font(.title2.weight(.semibold))
                    Text(project?.name ?? "Project")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 4)

            Form {
                Section {
                    Picker("Work in", selection: $draftMode) {
                        ForEach(ConversationWorkspaceMode.allCases) { mode in
                            Text(mode == .worktree ? "New worktree" : "Project directory")
                                .tag(mode)
                                .accessibilityIdentifier("workspace.mode.\(mode.rawValue)")
                                .smokeTarget("workspace.mode.\(mode.rawValue)")
                        }
                    }
                    .pickerStyle(.radioGroup)
                } footer: {
                    Text(workspaceDetail)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if draftMode == .worktree {
                    Section {
                        TextField("New branch", text: $draftBranch, prompt: Text("Automatic"))
                            .accessibilityIdentifier("workspace.branch")
                            .smokeTarget("workspace.branch")
                        TextField("Base branch", text: $draftBaseBranch, prompt: Text("Current branch"))
                            .accessibilityIdentifier("workspace.base-branch")
                            .smokeTarget("workspace.base-branch")
                    } header: {
                        Text("Worktree")
                    } footer: {
                        Text("Leave the new branch empty to generate its name. \(baseDetail)")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    TextField("Remote", text: $draftBaseRemote, prompt: Text("None"))
                        .accessibilityIdentifier("workspace.base-remote")
                        .smokeTarget("workspace.base-remote")
                    Picker("Publishing", selection: $draftRemotePublishMode) {
                        ForEach(RemotePublishMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("workspace.publishing")
                    .smokeTarget("workspace.publishing")
                } header: {
                    Text("Remote")
                } footer: {
                    Text(RemotePublishMode(rawValue: draftRemotePublishMode)?.detail ?? "")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(height: draftMode == .worktree ? 390 : 290)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("workspace.close")
                    .smokeTarget("workspace.close")
                Button("Done") { applySelection() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("workspace.confirm")
                    .smokeTarget("workspace.confirm")
            }
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
        .frame(width: 540)
    }

    private var baseDetail: String {
        if let base = project?.baseBranch, !base.isEmpty { return "Project base: \(base)." }
        return "An empty base uses the current branch."
    }

    private var abbreviatedProjectPath: String {
        guard let path = project?.path, !path.isEmpty else { return "the registered Git checkout" }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private var workspaceDetail: String {
        switch draftMode {
        case .worktree:
            "Create an isolated checkout and branch for this conversation."
        case .project:
            "Use \(abbreviatedProjectPath) on its current branch. Conversations in this directory share file changes."
        }
    }

    private func applySelection() {
        draft.mode = draftMode
        draft.branch =
            draftMode == .worktree ? draftBranch.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        draft.baseBranch =
            draftMode == .worktree ? draftBaseBranch.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        draft.baseRemote = draftBaseRemote.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.remotePublishMode = draftRemotePublishMode
        dismiss()
    }
}
