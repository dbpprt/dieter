import AppKit
import DieterAPI
import DieterClientAPI
import DieterCore
import Observation
import SwiftUI

/// A card's workspace badge as the shared core words it: compact on board
/// cards and chat rows, the branch in a conversation's header.
struct WorkspaceSummaryBadge: View {
    let card: Dieter_V1_Card
    var compact = false

    var body: some View {
        let badge = WorkspaceBadge.of(card)
        HStack(spacing: 5) {
            Image(systemName: badge.conflicted ? "exclamationmark.triangle.fill" : "arrow.triangle.branch")
                .font(.system(size: compact ? 8 : 9, weight: .semibold))
            Text(compact ? badge.title : badge.fullTitle)
                .font(.system(size: compact ? 9 : 10, weight: .semibold, design: compact ? .default : .monospaced))
        }
        .foregroundStyle(badge.conflicted ? DieterTheme.coral : DieterTheme.shell)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: compact ? nil : 180)
        .padding(.horizontal, compact ? 0 : 8)
        .frame(height: compact ? 14 : 22)
        .background(
            compact ? .clear : (badge.conflicted ? DieterTheme.coral : DieterTheme.shell).opacity(0.1),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay {
            if !compact {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke((badge.conflicted ? DieterTheme.coral : DieterTheme.shell).opacity(0.28))
            }
        }
        .help(badge.accessibilityLabel)
    }
}

enum WorkspaceBadge {
    private struct Key: Hashable, Sendable {
        let mode: String
        let state: String
        let branch: String
        let changedFiles: Int32
        let ahead: Int32
        let behind: Int32
        let cardMode: String
        let cardBranch: String
        let pullRequest: Int32
    }

    /// Board cards and chat rows ask for the same badges on every render.
    private static let badges = SharedRuleMemo<Key, ClientWorkspaceBadgeView>(limit: 1_024)

    /// `card`'s workspace badge from the shared core.
    static func of(_ card: Dieter_V1_Card) -> ClientWorkspaceBadgeView {
        let summary = card.workspace
        let key = Key(
            mode: summary.mode, state: summary.state, branch: summary.branch, changedFiles: summary.changedFiles,
            ahead: summary.ahead, behind: summary.behind, cardMode: card.workspaceMode,
            cardBranch: card.workspaceBranch, pullRequest: card.pullRequest.number)
        return badges.value(key) {
            ClientWorkspaceBadgeView(
                rules: SharedRules.shared.workspaceBadge(
                    mode: key.mode, state: key.state, branch: key.branch, changedFiles: key.changedFiles,
                    ahead: key.ahead, behind: key.behind, cardMode: key.cardMode, cardBranch: key.cardBranch,
                    pullRequest: key.pullRequest))
        }
    }
}

enum WorkspaceCompactPane: String, CaseIterable, Identifiable {
    case files = "Changes"
    case diff = "Diff"
    var id: String { rawValue }
}

enum WorkspaceDiffViewMode: String, CaseIterable, Identifiable {
    case inline = "Inline"
    case split = "Split"
    var id: String { rawValue }
}

/// The review's own state: the sheet or comment it shows, the pane shown while
/// compact, and the files marked viewed in the current revision.
@MainActor @Observable
private final class WorkspaceReviewState {
    var operationKind: GitOperationKind?
    var mergeSheetPresented = false
    var selectedCommentLine: UnifiedDiffLine?
    var commentBody = ""
    var compactPane: WorkspaceCompactPane = .files
    var viewedPaths: Set<String> = []
    @ObservationIgnored private var viewedRevision = ""

    /// Forgets the viewed files once the changes move to another revision.
    func resetViewed(for revision: String) {
        guard viewedRevision != revision else { return }
        viewedRevision = revision
        viewedPaths = []
    }
}

/// A conversation workspace's review. The view is split so that a slice
/// update, an operation's log, typing a comment, or a scroll re-renders only
/// the part that shows it.
struct WorkspaceChangesView: View {
    @Bindable var model: WorktreeChangesModel
    var background: Color = DieterTheme.background
    var active = true
    @State private var review = WorkspaceReviewState()
    @AppStorage("DieterDiffViewMode") private var diffModeRaw = WorkspaceDiffViewMode.inline.rawValue

    private var diffMode: WorkspaceDiffViewMode {
        WorkspaceDiffViewMode(rawValue: diffModeRaw) ?? .inline
    }

    var body: some View {
        @Bindable var review = review
        GeometryReader { geometry in
            let compact = WorkspaceReviewLayout.isCompact(width: geometry.size.width)
            VStack(spacing: 0) {
                WorkspaceReviewToolbar(
                    model: model, review: review, compact: compact, roomy: geometry.size.width >= 900)
                Rectangle().fill(DieterTheme.hairline).frame(height: 1)
                WorkspaceReviewContent(model: model, review: review, compact: compact)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(background)
        .task(id: "\(model.bindingGeneration):\(active)") {
            // The core refreshes an active review, idle checkouts included:
            // external edits and short turns can happen between two reads.
            model.active = active
            guard active, let id = model.card?.id, SharedRules.shared.isServerBacked(conversationId: id) else {
                return
            }
            await model.loadWorkspaceSurface()
        }
        .onDisappear { model.active = false }
        .onChange(of: "\(model.bindingGeneration)|\(diffModeRaw)", initial: true) {
            model.setLayout(split: diffMode == .split)
        }
        .onChange(of: model.conversationChangeset?.revision) { _, revision in
            review.resetViewed(for: revision ?? "")
        }
        .sheet(item: $review.operationKind) { kind in
            GitOperationSheet(model: model, kind: kind, spec: kind.form(card: model.card, baseBranch: model.baseBranch))
        }
        .sheet(isPresented: $review.mergeSheetPresented) {
            MergeIntoBaseSheet(
                model: model, card: model.card,
                availability: model.availability,
                onCreatePullRequestInstead: { review.operationKind = .createPullRequest }
            )

        }
        .popover(item: $review.selectedCommentLine) { line in
            WorkspaceCommentPopover(model: model, review: review, line: line)
        }
    }
}

// MARK: Toolbar

private struct WorkspaceReviewToolbar: View {
    let model: WorktreeChangesModel
    let review: WorkspaceReviewState
    let compact: Bool
    let roomy: Bool
    @AppStorage("DieterDiffViewMode") private var diffModeRaw = WorkspaceDiffViewMode.inline.rawValue

    private var diffMode: WorkspaceDiffViewMode {
        WorkspaceDiffViewMode(rawValue: diffModeRaw) ?? .inline
    }
    private var availability: WorkspaceActionAvailability { model.availability }

    var body: some View {
        let workspace = model.conversationWorkspace
        HStack(spacing: 8) {
            if workspace != nil {
                viewModePicker
                if roomy, let changes = model.conversationChangeset {
                    HStack(spacing: 6) {
                        WorkspaceDeltaLabel(additions: changes.additions, deletions: changes.deletions)
                        Text(
                            "· \(SharedRules.shared.count(count: Int32(clamping: changes.files.count), noun: "local file", plural: ""))"
                        )
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(DieterTheme.tertiary)
                    }
                    .lineLimit(1)
                }
            } else {
                Text("Workspace changes").font(DieterFont.title)
            }
            Spacer(minLength: 6)
            if workspace != nil {
                toolbarActions
            }
            Menu {
                operationMenu(workspace: workspace)
            } label: {
                DieterMenuLabel(symbol: "ellipsis", size: 28)
            }
            .dieterMenuChrome(.circle)
            .help("Workspace actions")
            Button {
                Task { await model.loadWorkspaceSurface() }
            } label: {
                if model.workspaceLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 28)).disabled(model.workspaceLoading).help(
                "Refresh changes")
        }
        .padding(.horizontal, 14).frame(height: 52)
    }

    private var viewModePicker: some View {
        DieterSegmentTrack(height: 28) {
            ForEach(WorkspaceDiffViewMode.allCases) { mode in
                Button(mode.rawValue) { diffModeRaw = mode.rawValue }
                    .buttonStyle(DieterSegmentStyle(selected: diffMode == mode, height: 22))
                    .accessibilityIdentifier("changes.view-mode-\(mode.rawValue.lowercased())")
                    .e2eTarget("changes.view-mode-\(mode.rawValue.lowercased())")
            }
        }
        .fixedSize()
    }

    @ViewBuilder private var toolbarActions: some View {
        let mode = availability.workspaceMode
        let baseBranch = model.baseBranch
        if mode == "project" && !availability.hasReviewBranch {
            if availability.allows(.commit) {
                Button {
                    review.operationKind = .commit
                } label: {
                    Label(compact ? "Commit" : "Commit changes", systemImage: "checkmark.circle").lineLimit(1)
                }
                .buttonStyle(DieterBarButtonStyle(prominent: true, size: 30))
            }
        } else {
            if !compact {
                Button {
                    review.operationKind = .update
                } label: {
                    Label(
                        roomy ? "Update from \(baseBranch)" : "Update",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .lineLimit(1).fixedSize()
                }
                .buttonStyle(DieterBarButtonStyle(size: 30))
                .disabled(!availability.allows(.update))
                .help("Rebase this workspace onto the latest \(baseBranch)")

                if mode == "worktree" {
                    Button("Discard…") { review.operationKind = .discard }
                        .buttonStyle(DieterBarButtonStyle(destructive: true, size: 30))
                        .disabled(!availability.allows(.discard))
                        .help("Remove the worktree and its branch")
                }

                if model.pullRequest == nil {
                    Button {
                        review.operationKind = .createPullRequest
                    } label: {
                        Label("Create PR…", systemImage: "arrow.triangle.pull").lineLimit(1).fixedSize()
                    }
                    .buttonStyle(DieterBarButtonStyle(size: 30))
                    .disabled(!availability.allows(.createPullRequest))
                }
            }
            if mode == "worktree" {
                Button {
                    review.mergeSheetPresented = true
                } label: {
                    Label(
                        !compact && roomy ? "Merge into \(baseBranch)…" : "Merge…",
                        systemImage: "arrow.triangle.merge"
                    )
                    .lineLimit(1).fixedSize()
                }
                .buttonStyle(DieterBarButtonStyle(prominent: true, size: 30))
                .disabled(!availability.allowsMergeFlow)
                .accessibilityIdentifier("changes.merge-into-base")
            } else if availability.allows(.commit) {
                Button {
                    review.operationKind = .commit
                } label: {
                    Label(compact ? "Commit" : "Commit changes", systemImage: "checkmark.circle").lineLimit(1)
                }
                .buttonStyle(DieterBarButtonStyle(prominent: true, size: 30))
            }
        }
    }

    @ViewBuilder private func operationMenu(workspace: Dieter_V1_Workspace?) -> some View {
        let pullRequest = model.pullRequest
        Section("Working copy") {
            Button(GitOperationKind.commit.title, systemImage: "checkmark.circle") {
                review.operationKind = .commit
            }
            .disabled(!availability.allows(.commit))
            Button(GitOperationKind.update.title, systemImage: "arrow.triangle.2.circlepath") {
                review.operationKind = .update
            }
            .disabled(!availability.allows(.update))
            Button(GitOperationKind.validate.title, systemImage: "checkmark.seal") {
                review.operationKind = .validate
            }
            .disabled(!availability.allows(.validate))
            Button(GitOperationKind.push.title, systemImage: "arrow.up.circle") { review.operationKind = .push }
                .disabled(!availability.allows(.push))
        }
        Section("Review and integrate") {
            if pullRequest == nil {
                Button(GitOperationKind.createPullRequest.title, systemImage: "arrow.triangle.pull") {
                    review.operationKind = .createPullRequest
                }
                .disabled(!availability.allows(.createPullRequest))
            } else {
                if let url = URL(string: pullRequest?.url ?? "") {
                    Button("Open pull request", systemImage: "arrow.up.right.square") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button(GitOperationKind.refreshPullRequest.title, systemImage: "arrow.clockwise") {
                    review.operationKind = .refreshPullRequest
                }
                .disabled(!availability.allows(.refreshPullRequest))
                Button(GitOperationKind.mergePullRequest.title, systemImage: "arrow.triangle.merge") {
                    review.operationKind = .mergePullRequest
                }
                .disabled(!availability.allows(.mergePullRequest))
            }
            Button("Merge into \(model.baseBranch)…", systemImage: "arrow.triangle.merge") {
                review.mergeSheetPresented = true
            }
            .disabled(!availability.allowsMergeFlow)
        }
        Section("Workspace") {
            if let card = model.card {
                Button("Open workspace in Files", systemImage: "folder") {
                    Task { await model.openWorkspaceFiles(card: card) }
                }
                Button("New terminal in workspace", systemImage: "terminal") {
                    Task { await model.openWorkspaceTerminal(card: card) }
                }
            }
            if let workspace {
                Button("Reveal in Finder", systemImage: "finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.path)
                }
            }
            Button(GitOperationKind.adopt.title + "…", systemImage: "arrow.right.arrow.left") {
                review.operationKind = .adopt
            }
            .disabled(!availability.allows(.adopt))
            Button(GitOperationKind.cleanup.title, systemImage: "trash") { review.operationKind = .cleanup }
                .disabled(!availability.allows(.cleanup))
            Button(GitOperationKind.discard.title, systemImage: "trash.fill", role: .destructive) {
                review.operationKind = .discard
            }
            .disabled(!availability.allows(.discard))
        }
    }
}

// MARK: Content

private struct WorkspaceReviewContent: View {
    let model: WorktreeChangesModel
    let review: WorkspaceReviewState
    let compact: Bool

    /// The operation strip shows the operation while it runs or after it failed.
    private var visibleOperation: Dieter_V1_GitOperation? {
        model.operationVisible ? model.gitOperation : nil
    }

    var body: some View {
        if model.workspaceLoading && model.conversationWorkspace == nil {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Preparing the conversation workspace…").font(DieterFont.meta).foregroundStyle(
                    DieterTheme.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.workspaceError, model.conversationWorkspace == nil {
            ContentUnavailableView(
                "Workspace unavailable", systemImage: "exclamationmark.triangle", description: Text(error)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let workspace = model.conversationWorkspace {
            VStack(spacing: 0) {
                if model.conflicted { WorkspaceConflictBanner(model: model, review: review) }
                if let operation = visibleOperation { WorkspaceOperationProgress(model: model, operation: operation) }
                if let error = model.workspaceError { errorBanner(error) }
                reviewLayout(workspace: workspace)
            }
        } else if let operation = model.gitOperation,
            operation.status == "succeeded",
            ["cleanup", "discard", "adopt"].contains(operation.kind)
        {
            ContentUnavailableView(
                operation.kind == "adopt" ? "Workspace moved" : "Workspace removed",
                systemImage: operation.kind == "adopt" ? "arrow.right.arrow.left" : "trash",
                description: Text(
                    operation.kind == "adopt"
                        ? "The checkout and its history now belong to card \(operation.result)."
                        : "The conversation workspace is no longer provisioned.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No workspace", systemImage: "arrow.triangle.branch",
                description: Text("Choose workspace settings before starting this conversation.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(DieterTheme.amber)
            Text(error).font(DieterFont.meta).foregroundStyle(DieterTheme.subtle).lineLimit(2)
            Spacer()
            Button("Retry") { Task { await model.loadWorkspaceSurface() } }
                .buttonStyle(DieterBarButtonStyle(size: 26))
        }
        .padding(.horizontal, 14).frame(minHeight: 34).background(DieterTheme.amber.opacity(0.08))
    }

    @ViewBuilder private func reviewLayout(workspace: Dieter_V1_Workspace) -> some View {
        if compact {
            VStack(spacing: 0) {
                WorkspaceCompactPaneBar(model: model, review: review)
                Divider().overlay(DieterTheme.border)
                if review.compactPane == .files {
                    WorkspaceReviewNavigator(model: model, review: review, workspace: workspace)
                } else {
                    WorkspaceReviewDiffPane(model: model, review: review, compact: true)
                }
            }
        } else {
            HSplitView {
                WorkspaceReviewNavigator(model: model, review: review, workspace: workspace).frame(
                    minWidth: 250, idealWidth: 300, maxWidth: 340)
                WorkspaceReviewDiffPane(model: model, review: review, compact: false).frame(minWidth: 360)
            }
        }
    }
}

private struct WorkspaceCompactPaneBar: View {
    let model: WorktreeChangesModel
    let review: WorkspaceReviewState

    var body: some View {
        let changes = model.conversationChangeset
        HStack(spacing: 4) {
            DieterSegmentTrack(height: 28) {
                ForEach(WorkspaceCompactPane.allCases) { pane in
                    Button {
                        review.compactPane = pane
                    } label: {
                        HStack(spacing: 5) {
                            Text(pane.rawValue)
                            if pane == .files {
                                Text("\((changes?.files.count ?? 0) + (changes?.commits.count ?? 0))")
                                    .foregroundStyle(DieterTheme.tertiary)
                            }
                        }
                    }
                    .buttonStyle(DieterSegmentStyle(selected: review.compactPane == pane, height: 22))
                }
            }
            .fixedSize()
            Spacer()
            if review.compactPane == .diff, !model.selectedChangePath.isEmpty {
                Text(ClientChangedFileLabel.of(model.selectedChangePath).filename)
                    .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(
                        DieterTheme.tertiary
                    ).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).frame(height: 38)
    }
}

// MARK: Banners

private struct WorkspaceConflictBanner: View {
    let model: WorktreeChangesModel
    let review: WorkspaceReviewState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DieterTheme.coral)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.conflictTitle).font(.system(size: 12, weight: .semibold))
                Text("Merge is blocked until conflicts are resolved.")
                    .font(DieterFont.subtitle).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
            }
            Spacer()
            Button("Review conflicts…") { review.mergeSheetPresented = true }
                .buttonStyle(DieterBarButtonStyle(prominent: true, tint: DieterTheme.coral, size: 30))
                .disabled(!model.availability.allowsMergeFlow)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(DieterTheme.coral.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle().fill(DieterTheme.coral.opacity(0.22)).frame(height: 1)
        }
    }
}

/// A running or failed operation with its log; only it observes the log.
private struct WorkspaceOperationProgress: View {
    let model: WorktreeChangesModel
    let operation: Dieter_V1_GitOperation

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(model.gitOperationLogs, id: \.sequence) { entry in
                    Text(entry.message).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
                ForEach(operation.validationResults, id: \.name) { result in
                    DisclosureGroup("\(result.name) · exit \(result.exitCode)") {
                        Text(result.output.isEmpty ? "No output" : result.output)
                            .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    }
                }
                if !operation.error.isEmpty {
                    Text(operation.error).foregroundStyle(DieterTheme.coral).textSelection(.enabled)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                if model.operationCancelable || model.conflicted {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(DieterTheme.coral)
                }
                Text(GitOperationKind(rawValue: operation.kind)?.title ?? operation.kind).font(
                    .system(size: 11, weight: .semibold))
                Text(operation.status.replacingOccurrences(of: "_", with: " ").capitalized).font(
                    DieterFont.meta
                )
                .foregroundStyle(DieterTheme.tertiary)
                Spacer()
                if model.operationCancelable {
                    Button("Cancel") { Task { await model.cancelCurrentGitOperation() } }.buttonStyle(
                        DieterBarButtonStyle(destructive: true, size: 30))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9).background(DieterTheme.tile)
        .overlay(alignment: .bottom) { Rectangle().fill(DieterTheme.border).frame(height: 1) }
    }
}

// MARK: Navigator

private struct WorkspaceReviewNavigator: View {
    let model: WorktreeChangesModel
    let review: WorkspaceReviewState
    let workspace: Dieter_V1_Workspace

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let pullRequest = model.pullRequest {
                        WorkspacePullRequestCard(model: model, review: review, pr: pullRequest)
                    }
                    WorkspaceFilesSection(model: model, review: review)
                    if model.conversationChangeset?.commits.isEmpty == false {
                        WorkspaceCommitsSection(model: model, review: review)
                    }
                    WorkspaceSCMNotice(model: model)
                }
                .padding(.horizontal, 10).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Divider().overlay(DieterTheme.border)
            WorkspaceReviewFooter(model: model, workspace: workspace)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DieterTheme.sidebar)
    }
}

private struct WorkspacePullRequestCard: View {
    let model: WorktreeChangesModel
    let review: WorkspaceReviewState
    let pr: ClientPullRequestView

    var body: some View {
        let availability = model.availability
        let workspace = model.conversationWorkspace
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.pull").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        DieterTheme.shell)
                Text("PR #\(pr.number)").font(.system(size: 12, weight: .semibold))
                PullRequestStateBadge(label: pr.stateLabel, tone: pr.stateTone)
                Spacer(minLength: 4)
                Button {
                    if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(spacing: 3) {
                        Text("GitHub")
                        Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
                    }
                }
                .buttonStyle(DieterBarButtonStyle(size: 24))
                .help("View on GitHub")
            }
            if !pr.signals.isEmpty || pr.number > 0 {
                DieterFlowLayout(horizontalSpacing: 10, verticalSpacing: 5) {
                    ForEach(pr.signals, id: \.id) { signal in
                        PullRequestSignalLabel(signal: signal)
                    }
                    if !pr.lastSyncedAt.isEmpty {
                        Text(
                            "synced \(SharedRules.shared.agoSince(value: pr.lastSyncedAt, nowMillis: Date.now.epochMillis))"
                        )
                        .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if pr.canAskAgent {
                    Button {
                        Task {
                            if await model.sendAgentMessage(pr.askAgentPrompt) {
                                model.showWorkspaceToast(
                                    "Asked the agent to address the review on PR #\(pr.number)")
                            }
                        }
                    } label: {
                        Label("Ask agent to address review", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DieterBarButtonStyle(size: 30))
                }
                Button {
                    review.operationKind = .mergePullRequest
                } label: {
                    Text(pr.mergeBlockedReason.isEmpty ? "Merge PR" : "Merge PR · \(pr.mergeBlockedReason)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DieterBarButtonStyle(prominent: true, size: 30))
                .disabled(!availability.allows(.mergePullRequest))
                .opacity(availability.allows(.mergePullRequest) ? 1 : 0.55)
            }
            HStack(spacing: 4) {
                Text(
                    "Pushed from \(workspace?.branch.isEmpty == false ? workspace!.branch : "the workspace branch")"
                )
                Spacer()
                Button {
                    review.operationKind = .refreshPullRequest
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 24))
                .disabled(!availability.allows(.refreshPullRequest))
                .help("Refresh pull request state")
            }
            .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
        }
        .padding(11)
        .dieterTile(radius: 10)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DieterTheme.border))
    }
}

private struct WorkspaceFilesSection: View {
    let model: WorktreeChangesModel
    let review: WorkspaceReviewState

    var body: some View {
        let changes = model.conversationChangeset
        let files = changes?.files ?? []
        let selectedPath = model.selectedCommitSHA.isEmpty ? model.selectedChangePath : nil
        VStack(alignment: .leading, spacing: 6) {
            WorkspaceSectionHeader(
                title: "Local changes", count: files.count, additions: changes?.additions,
                deletions: changes?.deletions)
            if files.isEmpty {
                WorkspaceEmptyRow(symbol: "checkmark.circle", title: "Working tree is clean")
            }
            ForEach(files, id: \.path) { file in
                WorkspaceFileRow(
                    file: file,
                    selected: selectedPath == file.path,
                    viewed: review.viewedPaths.contains(file.path)
                ) {
                    review.compactPane = .diff
                    Task { await model.loadConversationDiff(path: file.path) }
                }
                .equatable()
                .accessibilityIdentifier("changes.file.\(file.path)")
                .e2eTarget("changes.file.\(file.path)")
            }
        }
    }
}

private struct WorkspaceCommitsSection: View {
    let model: WorktreeChangesModel
    let review: WorkspaceReviewState

    var body: some View {
        let commits = model.conversationChangeset?.commits ?? []
        let branch = model.conversationWorkspace?.branch ?? ""
        let baseBranch = model.baseBranch
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Commits").font(.system(size: 12, weight: .semibold))
                Text(subtitle(count: commits.count, branch: branch, baseBranch: baseBranch))
                    .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary).lineLimit(1).truncationMode(
                        .middle)
            }
            .padding(.horizontal, 11).padding(.top, 11).padding(.bottom, 7)
            if commits.isEmpty {
                WorkspaceEmptyRow(
                    symbol: "arrow.triangle.branch", title: "No commits ahead of \(baseBranch)"
                )
                .padding(.horizontal, 3).padding(.bottom, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(commits, id: \.sha) { commit in
                        WorkspaceCommitRow(commit: commit, selected: model.selectedCommitSHA == commit.sha) {
                            review.compactPane = .diff
                            Task { await model.loadConversationDiff(path: "", commitSHA: commit.sha) }
                        }
                        if commit.sha != commits.last?.sha {
                            Divider().overlay(DieterTheme.border).padding(.leading, 11)
                        }
                    }
                }
                Divider().overlay(DieterTheme.border)
                HStack {
                    Text("Click a commit to diff just that step")
                        .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
                    Spacer()
                    Button("Copy shas") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            commits.map(\.sha).joined(separator: "\n"), forType: .string)
                    }
                    .buttonStyle(DieterBarButtonStyle(size: 24))
                    .help("Copy every commit SHA")
                }
                .padding(.horizontal, 11).frame(height: 30)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dieterTile(radius: 10)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DieterTheme.border))
    }

    private func subtitle(count: Int, branch: String, baseBranch: String) -> String {
        guard count > 0 else { return "Ahead of \(baseBranch)" }
        var subtitle = "\(count) on \(branch.isEmpty ? "the workspace branch" : branch)"
        if count > 1 { subtitle += " · squashed to one on merge" }
        return subtitle
    }
}

private struct WorkspaceSCMNotice: View {
    let model: WorktreeChangesModel

    var body: some View {
        if let capabilities = model.conversationSCMCapabilities,
            !capabilities.authenticated,
            !capabilities.unavailableReason.isEmpty
        {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill").foregroundStyle(DieterTheme.amber)
                Text(capabilities.unavailableReason).font(.system(size: 10)).foregroundStyle(
                    DieterTheme.tertiary
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10).background(
                DieterTheme.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct WorkspaceReviewFooter: View {
    let model: WorktreeChangesModel
    let workspace: Dieter_V1_Workspace

    var body: some View {
        HStack(spacing: 7) {
            StatusPill(
                text: model.workspaceState,
                color: model.conflicted ? DieterTheme.coral : DieterTheme.diffAddition)
            Text(SharedRules.shared.workspaceModeShortTitle(mode: workspace.mode))
            if workspace.sizeBytes > 0 {
                Text(
                    "· \(SharedRules.shared.bytes(count: workspace.sizeBytes))")
            }
            Spacer()
            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.path)
            } label: {
                Image(systemName: "finder")
            }
            .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 28)).help("Reveal workspace in Finder")
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(DieterTheme.tertiary)
        .padding(.horizontal, 10).frame(height: 42)
    }
}

// MARK: Diff pane

private struct WorkspaceReviewDiffPane: View {
    let model: WorktreeChangesModel
    let review: WorkspaceReviewState
    let compact: Bool

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceDiffHeader(model: model, review: review, compact: compact)
            Divider().overlay(DieterTheme.border)
            Group {
                if let diff = model.conversationDiff {
                    if diff.binary {
                        ContentUnavailableView(
                            "Binary diff", systemImage: "doc.badge.ellipsis",
                            description: Text("This file cannot be rendered as text.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        WorkspaceDiffContent(
                            layout: model.diff,
                            addComment: { line in review.selectedCommentLine = line },
                            loadMore: {
                                Task {
                                    await model.loadConversationDiff(
                                        path: diff.path, commitSHA: diff.commitSha, append: true)
                                }
                            },
                            loadingMore: model.conversationDiffLoading
                        )
                        .equatable()
                        .id("\(model.selectedChangePath)|\(model.selectedCommitSHA)")
                    }
                } else if model.conversationDiffLoading {
                    ProgressView("Loading diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "Select a change", systemImage: "doc.text.magnifyingglass",
                        description: Text("Choose a changed file or commit to inspect its diff.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().overlay(DieterTheme.border)
            WorkspaceDiffFooter(model: model, review: review)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DieterTheme.background)
    }
}

private struct WorkspaceDiffHeader: View {
    let model: WorktreeChangesModel
    let review: WorkspaceReviewState
    let compact: Bool

    private var title: String {
        if !model.selectedCommitSHA.isEmpty { return "Commit \(model.selectedCommitSHA.prefix(10))" }
        return model.selectedChangePath.isEmpty ? "Diff" : model.selectedChangePath
    }

    var body: some View {
        let path = model.selectedChangePath
        let file = model.conversationChangeset?.files.first(where: { $0.path == path })
        HStack(spacing: 9) {
            Image(systemName: model.selectedCommitSHA.isEmpty ? "doc.text" : "arrow.triangle.branch")
                .foregroundStyle(DieterTheme.shell).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
                    .truncationMode(.middle)
                if !compact, let file {
                    Text(
                        ClientChangedFileLabel.of(
                            file.path, status: file.status, conflicted: file.conflicted, untracked: file.untracked
                        ).title
                    )
                    .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
                }
            }
            Spacer(minLength: 8)
            if let file {
                WorkspaceDeltaLabel(additions: file.additions, deletions: file.deletions)
            }
            if !path.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 28)).help("Copy file path")
                if let card = model.card {
                    Button {
                        Task { await model.openWorkspaceFiles(card: card, opening: model.selectedChangePath) }
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 28)).help("Open file in workspace editor")
                }
                viewedToggle(path: path)
            }
        }
        .padding(.horizontal, 12).frame(height: 46)
    }

    private func viewedToggle(path: String) -> some View {
        let viewed = review.viewedPaths.contains(path)
        return Button {
            if viewed {
                review.viewedPaths.remove(path)
            } else {
                review.viewedPaths.insert(path)
                advanceToNextUnviewedFile(after: path)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: viewed ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11, weight: .semibold))
                Text("Viewed")
            }
        }
        .buttonStyle(DieterBarButtonStyle(prominent: viewed, tint: DieterTheme.running, size: 28))
        .help(viewed ? "Mark as not viewed" : "Mark as viewed and jump to the next file")
        .accessibilityIdentifier("changes.viewed-toggle")
    }

    private func advanceToNextUnviewedFile(after path: String) {
        guard let files = model.conversationChangeset?.files,
            let start = files.firstIndex(where: { $0.path == path })
        else { return }
        let wrapped = files[(start + 1)...] + files[..<start]
        guard let next = wrapped.first(where: { !review.viewedPaths.contains($0.path) }) else { return }
        Task { await model.loadConversationDiff(path: next.path) }
    }
}

private struct WorkspaceDiffFooter: View {
    let model: WorktreeChangesModel
    let review: WorkspaceReviewState

    var body: some View {
        let baseBranch = model.baseBranch
        HStack(spacing: 14) {
            if model.conflicted {
                Label("Conflicts with \(baseBranch)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DieterTheme.coral)
            } else {
                Label("No conflicts with \(baseBranch)", systemImage: "checkmark")
                    .foregroundStyle(DieterTheme.diffAddition)
            }
            let readiness = model.mergeReadiness
            if !readiness.validationSummary.isEmpty {
                let ago = SharedRules.shared.agoSince(value: readiness.validationAt, nowMillis: Date.now.epochMillis)
                Label(
                    ago.isEmpty ? readiness.validationSummary : "\(readiness.validationSummary) · \(ago)",
                    systemImage: readiness.validationPassed ? "checkmark" : "xmark"
                )
                .foregroundStyle(readiness.validationPassed ? DieterTheme.diffAddition : DieterTheme.coral)
            }
            Spacer()
            if let files = model.conversationChangeset?.files, !files.isEmpty {
                Text(
                    "\(files.filter { review.viewedPaths.contains($0.path) }.count) of \(files.count) files viewed"
                )
                .foregroundStyle(DieterTheme.tertiary)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 12).frame(height: 32)
        .background(DieterTheme.sidebar)
    }
}

// MARK: Comments

private struct WorkspaceCommentPopover: View {
    let model: WorktreeChangesModel
    @Bindable var review: WorkspaceReviewState
    let line: UnifiedDiffLine

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add review comment").font(DieterFont.title)
                    Text(
                        "\(ClientChangedFileLabel.of(model.selectedChangePath).filename) · line \(line.newLine ?? line.oldLine ?? 0)"
                    )
                    .font(DieterFont.subtitle).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
            }
            .padding(16).background(DieterTheme.sidebar)
            TextEditor(text: $review.commentBody)
                .font(DieterFont.body).scrollContentBackground(.hidden).padding(10).frame(height: 110)
                .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8)).padding(16)
            HStack {
                Spacer()
                Button("Cancel") {
                    review.selectedCommentLine = nil
                    review.commentBody = ""
                }.buttonStyle(DieterBarButtonStyle(size: 30))
                Button("Add comment") { addComment() }.buttonStyle(DieterBarButtonStyle(prominent: true, size: 30))
                    .disabled(review.commentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
        .frame(width: 410).background(DieterTheme.background)
    }

    private func addComment() {
        let text = review.commentBody
        Task {
            if await model.addChangeComment(line: line, body: text) {
                review.selectedCommentLine = nil
                review.commentBody = ""
            }
        }
    }
}

// MARK: - Diff content

/// AppKit owns the native scroll position. Observe that position directly so
/// both split columns pan together while their gutters stay in the viewport.
