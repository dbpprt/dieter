import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct EditCardSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let card: Dieter_V1_Card
    let availableHeight: CGFloat
    @State private var title: String
    @State private var task: String
    @State private var workspaceDraft: ConversationWorkspaceDraft
    @State private var provider: String
    @State private var model: String
    @State private var effort: String
    @State private var providerOptions: [String: String]
    @State private var saving = false
    @FocusState private var focusedField: Field?

    private enum Field { case title, task }

    init(card: Dieter_V1_Card, availableHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 800) {
        self.card = card
        self.availableHeight = availableHeight
        _provider = State(initialValue: card.provider)
        _model = State(initialValue: card.model)
        _effort = State(initialValue: card.effort)
        _providerOptions = State(initialValue: card.providerOptions)
        _title = State(initialValue: card.title)
        _task = State(initialValue: card.initialPrompt)
        _workspaceDraft = State(
            initialValue: .init(
                mode: ConversationWorkspaceMode.selectable(card.workspaceMode),
                branch: card.workspaceBranch,
                baseBranch: card.workspaceBaseBranch,
                baseRemote: card.workspaceBaseRemote,
                remotePublishMode: card.remotePublishMode.isEmpty
                    ? RemotePublishMode.manual.rawValue : card.remotePublishMode
            ))
    }

    private var hasChanges: Bool {
        provider != card.provider || model != card.model || effort != card.effort
            || providerOptions != card.providerOptions || title != card.title
            || task != card.initialPrompt
            || workspaceDraft
                != ConversationWorkspaceDraft(
                    mode: ConversationWorkspaceMode.selectable(card.workspaceMode),
                    branch: card.workspaceBranch, baseBranch: card.workspaceBaseBranch,
                    baseRemote: card.workspaceBaseRemote,
                    remotePublishMode: card.remotePublishMode.isEmpty
                        ? RemotePublishMode.manual.rawValue : card.remotePublishMode)
    }

    private var canSave: Bool {
        !saving && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("TODO  /  DRAFT")
                        .font(DieterFont.sectionLabel).tracking(1.4)
                        .foregroundStyle(DieterTheme.tertiary)
                    Text("Edit card").font(.system(size: 20, weight: .semibold))
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(DieterIconButtonStyle())
                .disabled(saving)
                .help("Close")
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 17)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("You can change this draft until its initial task is sent to the agent.")
                        .font(.caption).foregroundStyle(DieterTheme.tertiary)

                    Text("Card title")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(DieterTheme.subtle)
                    TextField("What should this agent accomplish?", text: $title)
                        .textFieldStyle(.plain).font(.system(size: 15, weight: .medium))
                        .focused($focusedField, equals: .title)
                        .padding(.horizontal, 14).frame(height: 46)
                        .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10).stroke(
                                focusedField == .title
                                    ? DieterTheme.shellDeep.opacity(0.85) : DieterTheme.strongBorder,
                                lineWidth: focusedField == .title ? 2 : 1
                            )
                        )
                        .accessibilityIdentifier("edit-card.title")

                    Text("Agent task")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(DieterTheme.subtle)
                    TextEditor(text: $task)
                        .font(.system(size: 14)).lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .focused($focusedField, equals: .task)
                        .padding(10)
                        .frame(height: 190)
                        .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10).stroke(
                                focusedField == .task
                                    ? DieterTheme.shellDeep.opacity(0.85) : DieterTheme.strongBorder,
                                lineWidth: focusedField == .task ? 2 : 1
                            )
                        )
                        .accessibilityIdentifier("edit-card.task")

                    Divider().overlay(DieterTheme.border)
                    Text("Agent settings")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(DieterTheme.subtle)
                    HarnessFields(
                        catalog: store.harnessCatalog,
                        provider: $provider, model: $model, effort: $effort, providerOptions: $providerOptions
                    )
                    .accessibilityIdentifier("edit-card.agent-settings")
                    .smokeTarget("edit-card.agent-settings")
                    Divider().overlay(DieterTheme.border)
                    Text("Agent workspace")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(DieterTheme.subtle)
                    if card.workspace.revision.isEmpty {
                        Picker("Workspace", selection: $workspaceDraft.mode) {
                            ForEach(ConversationWorkspaceMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }
                        .pickerStyle(.menu)
                        .foregroundStyle(DieterTheme.text)
                        if workspaceDraft.mode == .worktree {
                            HStack {
                                TextField("Optional branch", text: $workspaceDraft.branch)
                                TextField("Optional base branch", text: $workspaceDraft.baseBranch)
                            }
                            .textFieldStyle(.plain)
                            .padding(8)
                            .foregroundStyle(DieterTheme.text)
                            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 6))
                        }
                        TextField("Base remote", text: $workspaceDraft.baseRemote)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .foregroundStyle(DieterTheme.text)
                            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 6))
                        Picker("Publishing", selection: $workspaceDraft.remotePublishMode) {
                            ForEach(RemotePublishMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
                        }
                        .foregroundStyle(DieterTheme.text)
                        Text(workspaceDraft.mode.detail).font(.caption).foregroundStyle(DieterTheme.tertiary)
                    } else {
                        Text(
                            "\(ConversationWorkspaceMode.projectMode(card.workspace.mode).title) · \(card.workspace.branch)"
                        )
                        Text("The workspace is already provisioned, so its checkout and branch are locked.")
                            .font(.caption).foregroundStyle(DieterTheme.tertiary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            .frame(maxHeight: .infinity)

            Divider().overlay(DieterTheme.border)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(DieterSecondaryButtonStyle()).disabled(saving)
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 7) {
                        if saving { ProgressView().controlSize(.mini) } else { Image(systemName: "checkmark") }
                        Text("Save changes")
                    }
                }
                .buttonStyle(DieterPrimaryButtonStyle())
                .disabled(!canSave)
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityIdentifier("edit-card.save")
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 620, height: min(700, max(360, availableHeight - 80)))
        .background(DieterTheme.background)
        .background(SheetOutsideClickDismissal(enabled: !saving && !hasChanges) { dismiss() })
        .interactiveDismissDisabled(saving || hasChanges)
        .task {
            await Task.yield()
            focusedField = .title
        }
    }

    private func save() async {
        guard canSave else { return }
        saving = true
        var settings = Dieter_V1_DraftAgentSettings()
        settings.provider = provider
        settings.model = model
        settings.effort = effort.isEmpty ? "default" : effort
        settings.providerOptions = providerOptions
        let updated = await store.update(
            card,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            initialPrompt: task.trimmingCharacters(in: .whitespacesAndNewlines),
            agentSettings: settings
        )
        let workspaceUpdated =
            updated
            ? (card.workspace.revision.isEmpty
                ? await store.updateConversationWorkspace(workspaceDraft, cardID: card.id) : true) : false
        saving = false
        if updated && workspaceUpdated { dismiss() }
    }
}
