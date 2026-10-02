import AppKit
import DieterAPI
import DieterShared
import SwiftUI

struct MergeIntoBaseSheet: View {
    @Bindable var model: WorktreeChangesModel
    @Environment(\.dismiss) private var dismiss
    let card: Dieter_V1_Card?
    let availability: WorkspaceActionAvailability
    let onCreatePullRequestInstead: () -> Void

    @State private var subject = ""
    @State private var bodyText = ""
    @State private var strategy = "squash"
    @State private var validate = true
    @State private var removeWorkspace = true
    @State private var startingUpdate = false

    private var workspace: Dieter_V1_Workspace? { model.conversationWorkspace }
    private var changes: Dieter_V1_Changeset? { model.conversationChangeset }
    private var branch: String {
        let value = workspace?.branch ?? card?.workspace.branch ?? ""
        return value.isEmpty ? "workspace" : value
    }
    private var baseBranch: String {
        let value = workspace?.baseBranch ?? card?.workspace.baseBranch ?? ""
        return value.isEmpty ? "base" : value
    }
    private var conflicted: Bool { model.conflicted }
    private var running: Bool { model.mergeFlowStep != nil }
    private var readiness: ClientMergeReadiness { model.mergeReadiness }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(DieterTheme.paneSeparator)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if conflicted {
                        conflictContent
                    } else {
                        readinessCard
                        if readiness.mergeFailed { mergeFailedNotice }
                        messageFields
                        strategyAndAfterMerge
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: 180, maxHeight: 480)
            Divider().overlay(DieterTheme.paneSeparator)
            footer
        }
        .frame(width: 620)
        .background(DieterTheme.background)
        .onAppear {
            subject = card?.title ?? ""
            bodyText = card?.initialPrompt ?? ""
            strategy = readiness.strategies.first?.strategy ?? strategy
        }
        .interactiveDismissDisabled(running)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Merge into \(baseBranch)").font(.custom("Sora", size: 19).weight(.semibold))
            HStack(spacing: 8) {
                branchChip(branch, tinted: true)
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(
                    DieterTheme.tertiary)
                branchChip(baseBranch, tinted: false)
                Spacer()
                if let changes {
                    HStack(spacing: 6) {
                        WorkspaceDeltaLabel(additions: changes.additions, deletions: changes.deletions)
                        Text(
                            "· \(changes.files.count) files · \(changes.commits.count) commit\(changes.commits.count == 1 ? "" : "s")"
                        )
                        .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(
                            DieterTheme.tertiary)
                    }
                }
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(DieterTheme.sidebar)
    }

    private func branchChip(_ name: String, tinted: Bool) -> some View {
        HStack(spacing: 5) {
            if tinted {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
            }
            Text(name).font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(tinted ? DieterTheme.shell : DieterTheme.text)
        .lineLimit(1).truncationMode(.middle)
        .padding(.horizontal, 9).frame(height: 26)
        .background(
            tinted ? DieterTheme.shell.opacity(0.1) : DieterTheme.surface,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(
                tinted ? DieterTheme.shell.opacity(0.3) : DieterTheme.border))
    }

    // MARK: Ready mode

    private var readinessCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(readiness.items, id: \.id) { item in
                let detail =
                    item.at.isEmpty
                    ? item.detail : SharedRules.shared.agoSince(value: item.at, nowMillis: Date.now.epochMillis)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(for: item.tone))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(WorkspaceToneStyle.color(item.tone))
                        .frame(width: 14)
                    Text(item.text).font(.system(size: 11, weight: .medium)).foregroundStyle(DieterTheme.text)
                    if !detail.isEmpty {
                        Text("· \(detail)").font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DieterTheme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(DieterTheme.border))
    }

    private func symbol(for tone: ClientWorkspaceTone) -> String {
        switch tone {
        case .success: "checkmark"
        case .danger: "exclamationmark.triangle.fill"
        default: "exclamationmark.circle"
        }
    }

    private var mergeFailedNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DieterTheme.coral).frame(
                width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text("The last merge attempt failed").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        DieterTheme.text)
                Text(
                    model.gitOperation?.error.isEmpty == false
                        ? model.gitOperation!.error
                        : "Update from \(baseBranch) first — conflicts surface there with the files that need attention."
                )
                .font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary).fixedSize(
                    horizontal: false, vertical: true)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(DieterTheme.coral.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.coral.opacity(0.18)))
    }

    private var messageFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text("COMMIT MESSAGE").font(DieterFont.sectionLabel).tracking(0.45).foregroundStyle(
                    DieterTheme.tertiary)
                TextField("Summarize the change", text: $subject)
                    .textFieldStyle(.plain).font(DieterFont.body)
                    .padding(.horizontal, 11)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.strongBorder))
                    .disabled(running)
                    .accessibilityIdentifier("merge.subject")
            }
            TextField(
                "Optional description — drafted from the card, edit freely.", text: $bodyText,
                axis: .vertical
            )
            .lineLimit(3...6)
            .textFieldStyle(.plain).font(DieterFont.body)
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.border))
            .disabled(running)
        }
    }

    private var strategyAndAfterMerge: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 7) {
                Text("STRATEGY").font(DieterFont.sectionLabel).tracking(0.45).foregroundStyle(
                    DieterTheme.tertiary)
                Picker("Merge strategy", selection: $strategy) {
                    ForEach(readiness.strategies, id: \.strategy) { Text($0.title).tag($0.strategy) }
                }
                .labelsHidden().pickerStyle(.segmented).disabled(running)
                Text(readiness.strategies.first { $0.strategy == strategy }?.caption ?? "")
                    .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                Toggle("Validate the merge result", isOn: $validate)
                    .font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini).disabled(running)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 7) {
                Text("AFTER MERGE").font(DieterFont.sectionLabel).tracking(0.45).foregroundStyle(
                    DieterTheme.tertiary)
                Toggle("Remove worktree & branch", isOn: $removeWorkspace)
                    .font(.system(size: 11, weight: .medium)).toggleStyle(.switch).controlSize(.small)
                    .disabled(running)
                Text(
                    removeWorkspace
                        ? (model.movesToDone ? "Card moves to Done." : "The chat keeps its full history.")
                        : "The worktree stays for follow-up work."
                )
                .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
            }
            .frame(width: 210, alignment: .leading)
        }
    }

    // MARK: Conflict mode

    private var conflictContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(DieterTheme.coral).font(
                    .system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.conflictTitle).font(.system(size: 12, weight: .semibold)).foregroundStyle(
                        DieterTheme.coral)
                    Text("Merge is blocked until conflicts are resolved.")
                        .font(DieterFont.meta).foregroundStyle(DieterTheme.coral.opacity(0.8))
                }
            }
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(DieterTheme.coral.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.coral.opacity(0.22)))

            ForEach(model.gitOperation?.conflicts ?? [], id: \.path) { conflict in
                HStack(spacing: 9) {
                    Text("!")
                        .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(
                            DieterTheme.coral
                        )
                        .frame(width: 20, height: 20).background(
                            DieterTheme.coral.opacity(0.11), in: RoundedRectangle(cornerRadius: 5))
                    Text(conflict.path).font(.system(size: 11, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if conflict.hunkCount > 0 {
                        Text("\(conflict.hunkCount) conflicting hunk\(conflict.hunkCount == 1 ? "" : "s")")
                            .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                    }
                    if let card {
                        Button("Open in editor") {
                            Task { await model.openWorkspaceFiles(card: card, opening: conflict.path) }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(DieterTheme.shell)
                    }
                }
                .padding(.horizontal, 11).frame(height: 38)
                .background(DieterTheme.raised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.border))
            }

            HStack(spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(DieterTheme.shell)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let the agent resolve the conflicts").font(.system(size: 11, weight: .semibold))
                    Text("Resolves every conflicting file, re-runs validation, reports back.")
                        .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
                Button("Resolve with agent") {
                    let prompt = model.conflictPrompt
                    Task {
                        if await model.sendAgentMessage(prompt) {
                            model.showWorkspaceToast("Asked the agent to resolve the conflicts")
                            dismiss()
                        }
                    }
                }
                .buttonStyle(DieterPrimaryButtonStyle())
                .accessibilityIdentifier("merge.resolve-with-agent")
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(DieterTheme.shell.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.shell.opacity(0.18)))
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack(spacing: 10) {
            if running {
                ProgressView().controlSize(.small)
                Text(model.mergeFlowStep?.progressLabel ?? "Working…")
                    .font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary)
                Spacer()
            } else if conflicted {
                Text("Resolve the markers, then continue — or hand it to the agent.")
                    .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                Spacer()
                Button("Abort") { startOperationAndDismiss(.abortConflict) }
                    .buttonStyle(DieterSecondaryButtonStyle(destructive: true))
                    .disabled(!availability.allows(.abortConflict))
                Button("Continue after resolving") { startOperationAndDismiss(.continueConflict) }
                    .buttonStyle(DieterSecondaryButtonStyle())
                    .disabled(!availability.allows(.continueConflict))
                Button("Merge blocked") {}
                    .buttonStyle(DieterPrimaryButtonStyle())
                    .disabled(true).opacity(0.45)
            } else {
                Text(availability.mergeDestination)
                    .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                Spacer()
                if readiness.mergeFailed {
                    Button {
                        startOperationAndDismiss(.update)
                    } label: {
                        Label("Update from \(baseBranch)", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(DieterSecondaryButtonStyle())
                }
                if availability.allows(.createPullRequest) {
                    Button("Create PR instead…") {
                        dismiss()
                        onCreatePullRequestInstead()
                    }
                    .buttonStyle(DieterSecondaryButtonStyle())
                }
                Button("Cancel") { dismiss() }.buttonStyle(DieterSecondaryButtonStyle())
                Button {
                    startMerge()
                } label: {
                    Label(readiness.mergeTitle, systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(DieterPrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canMerge)
                .opacity(canMerge ? 1 : 0.5)
                .accessibilityIdentifier("merge.confirm")
            }
        }
        .padding(.horizontal, 20).frame(height: 58).background(DieterTheme.sidebar)
    }

    private var canMerge: Bool {
        !running && !readiness.blocked
            && !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (availability.allowsMergeFlow || availability.allows(.mergeLocal))
    }

    private func startMerge() {
        guard canMerge else { return }
        Task {
            let merged = await model.performMergeFlow(
                strategy: strategy,
                subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
                body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
                validate: validate,
                removeWorkspace: removeWorkspace,
                moveCardToDone: removeWorkspace && model.movesToDone
            )
            if merged { dismiss() }
        }
    }

    private func startOperationAndDismiss(_ kind: GitOperationKind) {
        var form = kind.form(card: card).initial
        // An update from here only catches up; this sheet's toggle decides a continue's validation.
        form.validate = kind == .continueConflict ? validate : kind == .update ? false : form.validate
        Task { if await model.startGitOperation(form: form) { dismiss() } }
    }
}

// MARK: - Operation sheet (secondary flows)
