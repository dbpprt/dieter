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
        let copy = spec.copy
        if SharedRules.shared.gitOperationShows(form: form.rulesData, input: Int32(input.rawValue)) {
            switch input {
            case .subject:
                WorkspaceSheetField(
                    label: copy.subject.uppercased(), placeholder: copy.subjectPlaceholder, text: $form.subject)
            case .body:
                WorkspaceSheetField(
                    label: copy.body.uppercased(), placeholder: copy.bodyPlaceholder, text: $form.body,
                    multiline: true)
            case .strategy:
                WorkspaceSheetPickerLabel(copy.strategy.uppercased())
                Picker(copy.strategy, selection: $form.strategy) {
                    ForEach(spec.strategies, id: \.strategy) { Text($0.title).tag($0.strategy) }
                }
                .labelsHidden().pickerStyle(.segmented)
            case .stageAll:
                WorkspaceSheetOptions { Toggle(copy.stageAll, isOn: $form.stageAll) }
            case .fetch:
                WorkspaceSheetOptions { Toggle(copy.fetch, isOn: $form.fetch) }
            case .validate:
                WorkspaceSheetOptions { Toggle(copy.validate, isOn: $form.validate) }
            case .push:
                WorkspaceSheetOptions { Toggle(copy.push, isOn: $form.push) }
            case .draft:
                WorkspaceSheetOptions { Toggle(copy.draft, isOn: $form.draft) }
            case .forceWithLease:
                WorkspaceSheetOptions { Toggle(copy.forceWithLease, isOn: $form.forceWithLease) }
            case .expectedRemoteSha:
                WorkspaceSheetField(
                    label: copy.expectedRemoteSha.uppercased(), placeholder: copy.expectedRemoteShaPlaceholder,
                    text: $form.expectedRemoteSha)
                Text(copy.expectedRemoteShaHelp)
                    .font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary).fixedSize(
                        horizontal: false, vertical: true)
            case .targetCardID:
                WorkspaceSheetField(
                    label: copy.targetCardID.uppercased(), placeholder: copy.targetCardIDPlaceholder,
                    text: $form.targetCardID)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var notice: some View {
        if spec.hasNotice {
            WorkspaceSheetNotice(
                title: spec.notice.title, detail: spec.notice.detail, symbol: noticeSymbol,
                tint: WorkspaceToneStyle.color(spec.notice.tone))
        }
    }

    private var noticeSymbol: String {
        switch spec.notice.tone {
        case .danger: "archivebox.fill"
        case .warning: "exclamationmark.triangle.fill"
        default: "checkmark.shield.fill"
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
