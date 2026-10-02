import AppKit
import DieterAPI
import DieterShared
import SwiftUI

/// One Git operation's form, as the shared core describes it: which inputs
/// it shows, their values filled from the conversation, and when it may start.
struct GitOperationSheet: View {
    @Bindable var model: WorktreeChangesModel
    @Environment(\.dismiss) private var dismiss
    let kind: GitOperationKind
    let card: Dieter_V1_Card?
    private let spec: ClientGitOperationFormSpec
    @State private var form: ClientGitOperationForm
    @State private var starting = false

    init(model: WorktreeChangesModel, kind: GitOperationKind, card: Dieter_V1_Card?, baseBranch: String) {
        self.model = model
        self.kind = kind
        self.card = card
        let spec = kind.form(card: card, baseBranch: baseBranch)
        self.spec = spec
        _form = State(initialValue: spec.initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceSheetHeader(
                eyebrow: spec.destructive ? "DESTRUCTIVE WORKSPACE ACTION" : "GIT WORKFLOW",
                title: spec.title,
                detail: spec.summary,
                symbol: spec.destructive ? "exclamationmark.triangle.fill" : operationSymbol,
                tint: spec.destructive ? DieterTheme.coral : DieterTheme.shell
            )
            Divider().overlay(DieterTheme.paneSeparator)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(spec.inputs, id: \.self) { input in field(input) }
                    notice
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
                Button(spec.title, role: spec.destructive ? .destructive : nil) { start() }
                    .buttonStyle(
                        spec.destructive
                            ? DieterPrimaryButtonStyle(tint: DieterTheme.coral) : DieterPrimaryButtonStyle()
                    )
                    .disabled(starting || !ready).opacity(starting || !ready ? 0.5 : 1)
            }
            .padding(.horizontal, 20).frame(height: 58).background(DieterTheme.sidebar)
        }
        .frame(width: 560).background(DieterTheme.background)
    }

    private var ready: Bool { SharedRules.shared.gitOperationReady(form: form.rulesData) }

    @ViewBuilder private func field(_ input: ClientGitOperationFormSpec.Input) -> some View {
        switch input {
        case .subject:
            // A local merge takes a subject only for its squash commit.
            if kind != .mergeLocal || form.strategy == "squash" {
                WorkspaceSheetField(label: subjectLabel, placeholder: subjectPlaceholder, text: $form.subject)
            }
        case .body:
            WorkspaceSheetField(
                label: "DESCRIPTION",
                placeholder: kind == .createPullRequest
                    ? "Explain what changed and how it was verified" : "Optional commit body",
                text: $form.body, multiline: true)
        case .strategy:
            WorkspaceSheetPickerLabel("MERGE STRATEGY")
            Picker("Merge strategy", selection: $form.strategy) {
                ForEach(spec.strategies, id: \.strategy) { Text($0.title).tag($0.strategy) }
            }
            .labelsHidden().pickerStyle(.segmented)
        case .stageAll:
            WorkspaceSheetOptions { Toggle("Stage all changes", isOn: $form.stageAll) }
        case .fetch:
            WorkspaceSheetOptions { Toggle("Fetch the configured base remote", isOn: $form.fetch) }
        case .validate:
            WorkspaceSheetOptions { Toggle(validateTitle, isOn: $form.validate) }
        case .push:
            WorkspaceSheetOptions { Toggle("Push branch before creating", isOn: $form.push) }
        case .draft:
            WorkspaceSheetOptions { Toggle("Create as draft", isOn: $form.draft) }
        case .forceWithLease:
            WorkspaceSheetOptions { Toggle("Force with lease", isOn: $form.forceWithLease) }
        case .expectedRemoteSha:
            if form.forceWithLease {
                WorkspaceSheetField(
                    label: "EXPECTED REMOTE HEAD", placeholder: "Commit SHA", text: $form.expectedRemoteSha)
                Text("The push is rejected if the remote branch no longer matches this exact revision.")
                    .font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary).fixedSize(
                        horizontal: false, vertical: true)
            }
        case .targetCardID:
            WorkspaceSheetField(label: "DESTINATION CARD ID", placeholder: "c_…", text: $form.targetCardID)
        default:
            EmptyView()
        }
    }

    private var subjectLabel: String {
        switch kind {
        case .createPullRequest: "PULL REQUEST TITLE"
        case .mergeLocal: "SQUASH COMMIT SUBJECT"
        default: "COMMIT SUBJECT"
        }
    }

    private var subjectPlaceholder: String {
        switch kind {
        case .createPullRequest: "Summarize the proposed change"
        case .mergeLocal: "Summarize the integrated work"
        default: "Summarize the change"
        }
    }

    private var validateTitle: String {
        switch kind {
        case .update: "Run project validation after rebasing"
        case .mergeLocal: "Validate the isolated integration result"
        case .continueConflict: "Run validation after continuing"
        default: "Run validation"
        }
    }

    @ViewBuilder private var notice: some View {
        switch kind {
        case .discard:
            WorkspaceSheetNotice(
                title: "Recovery is created first",
                detail:
                    "Dieter saves recovery artifacts before removing this workspace. Its uncommitted changes and managed branch will no longer remain in active use.",
                symbol: "archivebox.fill",
                tint: DieterTheme.coral
            )
        case .cleanup:
            WorkspaceSheetNotice(
                title: "Clean, integrated work only",
                detail: "Cleanup stops if the branch still has changes or has not been integrated.",
                symbol: "checkmark.shield.fill",
                tint: DieterTheme.diffAddition
            )
        case .mergePullRequest:
            WorkspaceSheetNotice(
                title: "Head revision is protected",
                detail: "The provider verifies that the pull request head still matches this workspace before merging.",
                symbol: "lock.shield.fill", tint: DieterTheme.diffAddition)
        case .continueConflict:
            WorkspaceSheetNotice(
                title: "Confirm conflicts are resolved",
                detail: "Continue only after every conflict marker has been resolved and the files have been saved.",
                symbol: "exclamationmark.triangle.fill", tint: DieterTheme.amber)
        default:
            EmptyView()
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

    private func start() {
        starting = true
        let form = form
        Task {
            let success = await model.startGitOperation(form: form)
            starting = false
            if success { dismiss() }
        }
    }
}
