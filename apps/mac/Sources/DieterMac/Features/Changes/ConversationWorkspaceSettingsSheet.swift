import AppKit
import DieterAPI
import SwiftUI

struct ConversationWorkspaceSettingsSheet: View {
    @Bindable var model: WorktreeChangesModel
    @Environment(\.dismiss) private var dismiss
    let card: Dieter_V1_Card
    @State private var mode: ConversationWorkspaceMode = .worktree
    @State private var branch = ""
    @State private var baseBranch = ""
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceSheetHeader(
                eyebrow: "CONVERSATION SETUP",
                title: "Workspace",
                detail: "Choose where this conversation will work before its first prompt starts.",
                symbol: "arrow.triangle.branch",
                tint: DieterTheme.shell
            )
            Divider().overlay(DieterTheme.paneSeparator)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    WorkspaceSheetPickerLabel("WORKSPACE MODE")
                    VStack(spacing: 8) {
                        ForEach(ConversationWorkspaceMode.allCases) { value in
                            Button {
                                mode = value
                            } label: {
                                HStack(alignment: .top, spacing: 11) {
                                    Image(systemName: mode == value ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(
                                            mode == value ? DieterTheme.shell : DieterTheme.tertiary
                                        )
                                        .padding(.top, 1)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(value.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(
                                            DieterTheme.text)
                                        Text(value.detail).font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    mode == value ? DieterTheme.selection : DieterTheme.input,
                                    in: RoundedRectangle(cornerRadius: 9)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9).stroke(
                                        mode == value ? DieterTheme.shell.opacity(0.35) : DieterTheme.border))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if mode == .worktree {
                        WorkspaceSheetField(
                            label: "BRANCH NAME", placeholder: "Optional — Dieter can generate one", text: $branch)
                        WorkspaceSheetField(
                            label: "BASE BRANCH", placeholder: "Optional — uses the project default", text: $baseBranch)
                    }
                    WorkspaceSheetNotice(
                        title: "Locked when work begins",
                        detail: "The workspace choice cannot be changed after the first prompt starts.",
                        symbol: "lock.fill",
                        tint: DieterTheme.amber
                    )
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: 520)
            Divider().overlay(DieterTheme.paneSeparator)
            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DieterSecondaryButtonStyle())
                Button("Save workspace") { save() }.buttonStyle(DieterPrimaryButtonStyle())
                    .disabled(saving || !card.workspace.revision.isEmpty).opacity(
                        saving || !card.workspace.revision.isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 20).frame(height: 58).background(DieterTheme.sidebar)
        }
        .frame(width: 540).background(DieterTheme.background)
        .onAppear {
            mode = ConversationWorkspaceMode.selectable(card.workspaceMode)
            branch = card.workspaceBranch
            baseBranch = card.workspaceBaseBranch
        }
    }

    private func save() {
        saving = true
        Task {
            if await model.updateConversationWorkspace(.init(mode: mode, branch: branch, baseBranch: baseBranch)) {
                await model.loadWorkspaceSurface()
                dismiss()
            }
            saving = false
        }
    }
}

// MARK: - Toast
