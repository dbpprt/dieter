import AppKit
import DieterAPI
import DieterShared
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
    @State private var selection: Dieter_V1_HarnessSelection
    @State private var saving = false
    @FocusState private var focusedField: Field?

    private enum Field { case title, task }

    init(card: Dieter_V1_Card, availableHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 800) {
        self.card = card
        self.availableHeight = availableHeight
        _selection = State(
            initialValue: .with {
                $0.provider = card.provider
                $0.model = card.model
                $0.effort = card.effort
                $0.providerOptions = card.providerOptions
            })
        _title = State(initialValue: card.title)
        _task = State(initialValue: card.initialPrompt)
        _workspaceDraft = State(
            initialValue: .init(
                mode: ConversationWorkspaceMode.selectable(card.workspaceMode),
                branch: card.workspaceBranch,
                baseBranch: card.workspaceBaseBranch,
                baseRemote: card.workspaceBaseRemote,
                remotePublishMode: card.remotePublishMode.isEmpty
                    ? AdminChoices.options.defaultPublishMode : card.remotePublishMode
            ))
    }

    private var hasChanges: Bool {
        selection.provider != card.provider || selection.model != card.model || selection.effort != card.effort
            || selection.providerOptions != card.providerOptions || title != card.title
            || task != card.initialPrompt
            || workspaceDraft
                != ConversationWorkspaceDraft(
                    mode: ConversationWorkspaceMode.selectable(card.workspaceMode),
                    branch: card.workspaceBranch, baseBranch: card.workspaceBaseBranch,
                    baseRemote: card.workspaceBaseRemote,
                    remotePublishMode: card.remotePublishMode.isEmpty
                        ? AdminChoices.options.defaultPublishMode : card.remotePublishMode)
    }

    /// Why the form cannot save yet, as the core checks the card when saving
    /// it: a never-started todo card takes its title, task, and agent; a
    /// started one only a new title. Empty when it can.
    private var problem: String {
        let current = store.state.cards.first { $0.id == card.id } ?? card
        return SharedRules.shared.cardDraftProblem(
            card: current.rulesData, title: title, task: task, selection: selection.rulesData)
    }

    private var canSave: Bool { !saving && problem.isEmpty }

    /// The agents of the machine that runs the card.
    private var catalog: Dieter_V1_HarnessCatalog {
        store.harnessCatalog(forDaemon: card.ownerDaemonID)
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
                .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 28))
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
                    AgentControlFields(catalog: catalog, selection: $selection)
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
                            ForEach(AdminChoices.options.publishModes, id: \.id) { mode in Text(mode.title).tag(mode.id)
                            }
                        }
                        .foregroundStyle(DieterTheme.text)
                        Text(workspaceDraft.mode.detail).font(.caption).foregroundStyle(DieterTheme.tertiary)
                    } else {
                        Text(
                            "\(SharedRules.shared.workspaceModeTitle(mode: card.workspace.mode)) · \(card.workspace.branch)"
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
                    .buttonStyle(DieterBarButtonStyle(size: 30)).disabled(saving)
                    .smokeTarget("card-editor.cancel")
                Button {
                    Task { await save() }
                } label: {
                    HStack(spacing: 7) {
                        if saving { ProgressView().controlSize(.mini) } else { Image(systemName: "checkmark") }
                        Text("Save changes")
                    }
                }
                .buttonStyle(DieterBarButtonStyle(prominent: true, size: 30))
                .disabled(!canSave)
                .help(problem)
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityIdentifier("edit-card.save")
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 620, height: min(700, max(360, availableHeight - 80)))
        .smokeTarget("card-editor.\(card.id)")
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
        settings.provider = selection.provider
        settings.model = selection.model
        settings.effort = selection.effort
        settings.providerOptions = selection.providerOptions
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
