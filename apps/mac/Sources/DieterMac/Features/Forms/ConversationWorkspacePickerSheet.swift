import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct ConversationWorkspacePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: Dieter_V1_Project?
    @Binding var draft: ConversationWorkspaceDraft
    @State private var draftMode: ConversationWorkspaceMode
    @State private var draftBranch: String
    @State private var draftBaseBranch: String
    @FocusState private var branchFocused: Bool

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
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("AGENT WORKSPACE  /  \(project?.name.uppercased() ?? "PROJECT")")
                        .font(DieterFont.sectionLabel).tracking(1.4)
                        .foregroundStyle(DieterTheme.tertiary)
                    Text("Where should the agent work?")
                        .font(.system(size: 20, weight: .semibold))
                    Text(
                        "Choose whether this conversation gets a new isolated worktree or uses the registered project directory."
                    )
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(DieterIconButtonStyle()).help("Close")
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 12) {
                    workspaceOption(
                        .worktree,
                        badge: "Recommended",
                        detail:
                            "Creates a new isolated checkout and branch. The project directory stays untouched for concurrent work and review."
                    )
                    workspaceOption(
                        .project,
                        badge: "Direct",
                        detail:
                            "Works directly in the registered project directory on its current branch. Dieter never switches it."
                    )
                }

                if draftMode == .worktree {
                    HStack(alignment: .top, spacing: 12) {
                        workspaceField(
                            title: "Branch",
                            detail: "Leave empty and Dieter will generate one from the card ID and title."
                        ) {
                            HStack(spacing: 8) {
                                Image(systemName: "point.3.connected.trianglepath.dotted")
                                    .foregroundStyle(DieterTheme.shell)
                                TextField("Generated automatically", text: $draftBranch)
                                    .textFieldStyle(.plain)
                                    .focused($branchFocused)
                                    .accessibilityIdentifier("workspace.branch")
                            }
                            .padding(.horizontal, 12).frame(height: 42)
                            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9).stroke(
                                    branchFocused ? DieterTheme.shellDeep.opacity(0.8) : DieterTheme.strongBorder,
                                    lineWidth: branchFocused ? 1.5 : 1
                                ))
                        }
                        workspaceField(title: "Base", detail: baseDetail) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.triangle.branch").foregroundStyle(DieterTheme.shell)
                                TextField("Current branch", text: $draftBaseBranch)
                                    .textFieldStyle(.plain)
                                    .accessibilityIdentifier("workspace.base-branch")
                            }
                            .padding(.horizontal, 12).frame(height: 42)
                            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.strongBorder))
                        }
                        .frame(maxWidth: 220)
                    }
                }

                workspaceNotice
            }
            .padding(.horizontal, 24).padding(.bottom, 22)

            Divider().overlay(DieterTheme.border)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DieterSecondaryButtonStyle())
                Button {
                    applySelection()
                } label: {
                    Label(
                        draftMode == .worktree ? "Create worktree" : "Use project directory",
                        systemImage: draftMode.symbol)
                }
                .buttonStyle(DieterPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("workspace.confirm")
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 680)
        .background(DieterTheme.background)
    }

    private var baseDetail: String {
        if let base = project?.baseBranch, !base.isEmpty { return "Project base: \(base)" }
        return "Leave empty to use the current branch."
    }

    private var abbreviatedProjectPath: String {
        guard let path = project?.path, !path.isEmpty else { return "the registered Git checkout" }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    @ViewBuilder private var workspaceNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: draftMode == .worktree ? "checkmark.shield" : "exclamationmark.triangle")
                .foregroundStyle(draftMode == .worktree ? DieterTheme.shell : DieterTheme.amber)
                .frame(width: 16)
            Text(
                draftMode == .worktree
                    ? "Dieter creates a lightweight Git worktree that shares the repository’s object store—no second clone."
                    : "The agent uses \(abbreviatedProjectPath). Other conversations can see its changes, so concurrent work is restricted."
            )
            .font(.caption).foregroundStyle(DieterTheme.subtle).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(
            (draftMode == .worktree ? DieterTheme.shellDeep : DieterTheme.amber).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9).stroke(
                (draftMode == .worktree ? DieterTheme.shellDeep : DieterTheme.amber).opacity(0.26)
            ))
    }

    private func workspaceOption(
        _ option: ConversationWorkspaceMode,
        badge: String,
        detail: String
    ) -> some View {
        let selected = draftMode == option
        return Button {
            draftMode = option
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: option.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(selected ? DieterTheme.shell : DieterTheme.tertiary)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? DieterTheme.shell : DieterTheme.tertiary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title).font(.system(size: 15, weight: .semibold))
                    Text(badge).font(.caption2.weight(.medium)).foregroundStyle(
                        selected ? DieterTheme.shell : DieterTheme.tertiary)
                }
                Text(detail)
                    .font(.caption).foregroundStyle(DieterTheme.subtle)
                    .multilineTextAlignment(.leading).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
            .background(
                selected ? DieterTheme.shellDeep.opacity(0.1) : DieterTheme.surface.opacity(0.52),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12).stroke(
                    selected ? DieterTheme.shell.opacity(0.75) : DieterTheme.strongBorder,
                    lineWidth: selected ? 1.5 : 1
                ))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workspace.mode.\(option.rawValue)")
    }

    private func workspaceField<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(DieterTheme.subtle)
            content()
            Text(detail).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func applySelection() {
        draft.mode = draftMode
        draft.branch = draftMode == .worktree ? draftBranch.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        draft.baseBranch = draftMode == .worktree ? draftBaseBranch.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        dismiss()
    }
}
