import AppKit
import DieterAPI
import SwiftUI

struct GitOperationSheet: View {
    @Bindable var model: WorktreeChangesModel
    @Environment(\.dismiss) private var dismiss
    let kind: GitOperationKind
    let card: Dieter_V1_Card?
    let operation: Dieter_V1_GitOperation?
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var strategy = "squash"
    @State private var includeUntracked = true
    @State private var validate = true
    @State private var fetch = true
    @State private var draft = false
    @State private var push = true
    @State private var forceWithLease = false
    @State private var expectedRemoteSHA = ""
    @State private var adoptCardID = ""
    @State private var starting = false

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceSheetHeader(
                eyebrow: kind.destructive ? "DESTRUCTIVE WORKSPACE ACTION" : "GIT WORKFLOW",
                title: kind.title,
                detail: operationSubtitle,
                symbol: kind.destructive ? "exclamationmark.triangle.fill" : operationSymbol,
                tint: kind.destructive ? DieterTheme.coral : DieterTheme.shell
            )
            Divider().overlay(DieterTheme.paneSeparator)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    operationFields
                    if kind == .discard {
                        WorkspaceSheetNotice(
                            title: "Recovery is created first",
                            detail:
                                "Dieter saves recovery artifacts before removing this workspace. Its uncommitted changes and managed branch will no longer remain in active use.",
                            symbol: "archivebox.fill",
                            tint: DieterTheme.coral
                        )
                    } else if kind == .cleanup {
                        WorkspaceSheetNotice(
                            title: "Clean, integrated work only",
                            detail: "Cleanup stops if the branch still has changes or has not been integrated.",
                            symbol: "checkmark.shield.fill",
                            tint: DieterTheme.diffAddition
                        )
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 150, maxHeight: 430)
            Divider().overlay(DieterTheme.paneSeparator)
            HStack {
                if starting {
                    ProgressView().controlSize(.small)
                    Text("Starting operation…").font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DieterSecondaryButtonStyle())
                Button(kind.title, role: kind.destructive ? .destructive : nil) { start() }
                    .buttonStyle(
                        kind.destructive
                            ? DieterPrimaryButtonStyle(tint: DieterTheme.coral) : DieterPrimaryButtonStyle()
                    )
                    .disabled(starting || !valid).opacity(starting || !valid ? 0.5 : 1)
            }
            .padding(.horizontal, 20).frame(height: 58).background(DieterTheme.sidebar)
        }
        .frame(width: 560).background(DieterTheme.background)
        .onAppear {
            subject = card?.title ?? ""
            bodyText = card?.initialPrompt ?? ""
            expectedRemoteSHA = card?.pullRequest.headSha ?? ""
        }
    }

    @ViewBuilder private var operationFields: some View {
        switch kind {
        case .commit:
            WorkspaceSheetField(label: "COMMIT SUBJECT", placeholder: "Summarize the change", text: $subject)
            WorkspaceSheetField(
                label: "DESCRIPTION", placeholder: "Optional commit body", text: $bodyText, multiline: true)
            WorkspaceSheetOptions {
                Toggle("Include untracked files", isOn: $includeUntracked)
            }
        case .update:
            WorkspaceSheetNotice(
                title: "Rebase onto the latest base", detail: operationDescription,
                symbol: "arrow.triangle.2.circlepath", tint: DieterTheme.shell)
            WorkspaceSheetOptions {
                Toggle("Fetch the configured base remote", isOn: $fetch)
                Divider().overlay(DieterTheme.border)
                Toggle("Run project validation after rebasing", isOn: $validate)
            }
        case .validate:
            WorkspaceSheetNotice(
                title: "Validate this workspace", detail: operationDescription, symbol: "checkmark.seal.fill",
                tint: DieterTheme.diffAddition)
        case .mergeLocal:
            WorkspaceSheetPickerLabel("MERGE STRATEGY")
            Picker("Merge strategy", selection: $strategy) {
                Text("Squash").tag("squash"); Text("Merge commit").tag("merge_commit");
                Text("Fast-forward").tag("fast_forward")
            }
            .labelsHidden().pickerStyle(.segmented)
            if strategy == "squash" {
                WorkspaceSheetField(
                    label: "SQUASH COMMIT SUBJECT", placeholder: "Summarize the integrated work", text: $subject)
            }
            WorkspaceSheetOptions { Toggle("Validate the isolated integration result", isOn: $validate) }
        case .createPullRequest:
            WorkspaceSheetField(
                label: "PULL REQUEST TITLE", placeholder: "Summarize the proposed change", text: $subject)
            WorkspaceSheetField(
                label: "DESCRIPTION", placeholder: "Explain what changed and how it was verified", text: $bodyText,
                multiline: true)
            WorkspaceSheetOptions {
                Toggle("Push branch before creating", isOn: $push)
                Divider().overlay(DieterTheme.border)
                Toggle("Create as draft", isOn: $draft)
            }
        case .mergePullRequest:
            WorkspaceSheetPickerLabel("MERGE STRATEGY")
            Picker("Merge strategy", selection: $strategy) {
                Text("Squash").tag("squash"); Text("Merge commit").tag("merge"); Text("Rebase").tag("rebase")
            }
            .labelsHidden().pickerStyle(.segmented)
            WorkspaceSheetNotice(
                title: "Head revision is protected",
                detail: "The provider verifies that the pull request head still matches this workspace before merging.",
                symbol: "lock.shield.fill", tint: DieterTheme.diffAddition)
        case .continueConflict:
            WorkspaceSheetNotice(
                title: "Confirm conflicts are resolved",
                detail: "Continue only after every conflict marker has been resolved and the files have been saved.",
                symbol: "exclamationmark.triangle.fill", tint: DieterTheme.amber)
            WorkspaceSheetOptions { Toggle("Run validation after continuing", isOn: $validate) }
        case .abortConflict:
            WorkspaceSheetNotice(
                title: "Restore the previous state", detail: operationDescription,
                symbol: "arrow.uturn.backward.circle.fill", tint: DieterTheme.amber)
        case .adopt:
            WorkspaceSheetField(label: "DESTINATION CARD ID", placeholder: "c_…", text: $adoptCardID)
            WorkspaceSheetNotice(
                title: "Transfer the complete workspace", detail: operationDescription,
                symbol: "arrow.right.arrow.left.circle.fill", tint: DieterTheme.shell)
        case .push:
            WorkspaceSheetNotice(
                title: "Publish the workspace branch", detail: operationDescription, symbol: "arrow.up.circle.fill",
                tint: DieterTheme.shell)
            WorkspaceSheetOptions { Toggle("Force with lease", isOn: $forceWithLease) }
            if forceWithLease {
                WorkspaceSheetField(label: "EXPECTED REMOTE HEAD", placeholder: "Commit SHA", text: $expectedRemoteSHA)
                Text("The push is rejected if the remote branch no longer matches this exact revision.")
                    .font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary).fixedSize(
                        horizontal: false, vertical: true)
            }
        case .refreshPullRequest, .cleanup, .discard:
            WorkspaceSheetNotice(
                title: kind.title, detail: operationDescription, symbol: operationSymbol,
                tint: kind.destructive ? DieterTheme.coral : DieterTheme.shell)
        }
    }

    private var operationSymbol: String {
        switch kind {
        case .commit: "checkmark.circle.fill"
        case .update: "arrow.triangle.2.circlepath"
        case .validate: "checkmark.seal.fill"
        case .push: "arrow.up.circle.fill"
        case .mergeLocal, .mergePullRequest: "arrow.triangle.merge"
        case .createPullRequest, .refreshPullRequest: "arrow.triangle.pull"
        case .continueConflict: "play.circle.fill"
        case .abortConflict: "arrow.uturn.backward.circle.fill"
        case .adopt: "arrow.right.arrow.left.circle.fill"
        case .cleanup, .discard: "trash.fill"
        }
    }

    private var operationSubtitle: String {
        switch kind {
        case .commit: "Create a commit from the current working changes."
        case .createPullRequest: "Publish this branch for review without leaving Dieter."
        case .mergePullRequest: "Integrate the reviewed pull request through its provider."
        case .mergeLocal: "Integrate this workspace into the configured base branch locally."
        case .continueConflict: "Resume the paused Git operation after resolving conflicts."
        case .abortConflict: "Cancel the paused operation and restore its previous state."
        case .cleanup, .discard: "Review the consequences before changing this workspace."
        default: operationDescription
        }
    }

    private var operationDescription: String {
        switch kind {
        case .update: "Fetch the configured base and rebase this workspace onto its latest revision."
        case .validate: "Run every validation command configured for this project inside the conversation workspace."
        case .push: "Push this workspace branch to its configured remote and establish upstream tracking."
        case .refreshPullRequest: "Refresh state, checks, review decision, and head/base revisions from the provider."
        case .cleanup: "Remove this clean, integrated workspace and its managed branch."
        case .discard: "Remove the workspace even when it contains unintegrated work."
        case .abortConflict: "Abort the active rebase or merge and restore the workspace to its previous ready state."
        case .adopt:
            "Move this workspace, branch, recovery history, and terminal ownership to another unstarted conversation."
        default: ""
        }
    }

    private var valid: Bool {
        switch kind {
        case .commit, .createPullRequest: !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .adopt: !adoptCardID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .push: !forceWithLease || !expectedRemoteSHA.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: true
        }
    }

    private var parameters: [String: String] {
        switch kind {
        case .commit: ["subject": subject, "body": bodyText, "include_untracked": String(includeUntracked)]
        case .update: ["fetch": String(fetch), "validate": String(validate)]
        case .push:
            [
                "force_with_lease": String(forceWithLease),
                "expected_remote_sha": expectedRemoteSHA.trimmingCharacters(in: .whitespacesAndNewlines),
            ]
        case .mergeLocal: ["strategy": strategy, "subject": subject, "validate": String(validate)]
        case .createPullRequest: ["title": subject, "body": bodyText, "draft": String(draft), "push": String(push)]
        case .mergePullRequest: ["strategy": strategy, "expected_head_sha": card?.pullRequest.headSha ?? ""]
        case .continueConflict: ["conflicted_operation_id": operation?.id ?? "", "validate": String(validate)]
        case .abortConflict: ["conflicted_operation_id": operation?.id ?? ""]
        case .adopt: ["target_card_id": adoptCardID.trimmingCharacters(in: .whitespacesAndNewlines)]
        default: [:]
        }
    }

    private func start() {
        starting = true
        Task {
            let success = await model.startGitOperation(kind, parameters: parameters)
            starting = false
            if success { dismiss() }
        }
    }
}
