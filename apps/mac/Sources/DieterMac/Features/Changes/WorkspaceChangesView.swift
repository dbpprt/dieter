import AppKit
import DieterAPI
import SwiftUI

struct WorkspaceSummaryBadge: View {
    let card: Dieter_V1_Card
    var compact = false

    private var summary: Dieter_V1_WorkspaceSummary { card.workspace }
    private var mode: String { summary.mode.isEmpty ? card.workspaceMode : summary.mode }
    private var conflicted: Bool { summary.state == "conflicted" }
    private var branch: String {
        let value = summary.branch.isEmpty ? card.workspaceBranch : summary.branch
        return value.isEmpty ? ConversationWorkspaceMode.projectMode(mode).shortTitle : value
    }
    private var title: String {
        if conflicted { return "Conflicts" }
        if compact, card.pullRequest.number > 0 { return "PR #\(card.pullRequest.number)" }
        if compact, summary.changedFiles > 0 { return "\(summary.changedFiles) changed" }
        return branch
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: conflicted ? "exclamationmark.triangle.fill" : "arrow.triangle.branch")
                .font(.system(size: compact ? 8 : 9, weight: .semibold))
            Text(title)
                .font(.system(size: compact ? 9 : 10, weight: .semibold, design: compact ? .default : .monospaced))
        }
        .foregroundStyle(conflicted ? DieterTheme.coral : DieterTheme.shell)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: compact ? nil : 180)
        .padding(.horizontal, compact ? 0 : 8)
        .frame(height: compact ? 14 : 22)
        .background(
            compact ? .clear : (conflicted ? DieterTheme.coral : DieterTheme.shell).opacity(0.1),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay {
            if !compact {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke((conflicted ? DieterTheme.coral : DieterTheme.shell).opacity(0.28))
            }
        }
        .help(workspaceHelp)
    }

    private var workspaceHelp: String {
        var pieces = [ConversationWorkspaceMode.projectMode(mode).title]
        let branch = summary.branch.isEmpty ? card.workspaceBranch : summary.branch
        if !branch.isEmpty { pieces.append(branch) }
        if summary.ahead > 0 || summary.behind > 0 { pieces.append("↑\(summary.ahead) ↓\(summary.behind)") }
        if card.pullRequest.number > 0 { pieces.append("PR #\(card.pullRequest.number)") }
        return pieces.joined(separator: " · ")
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

struct WorkspaceChangesView: View {
    @Bindable var model: WorktreeChangesModel
    var background: Color = DieterTheme.background
    var active = true
    @State private var operationKind: GitOperationKind?
    @State private var mergeSheetPresented = false
    @State private var selectedCommentLine: UnifiedDiffLine?
    @State private var commentBody = ""
    @State private var compactPane: WorkspaceCompactPane = .files
    @AppStorage("DieterDiffViewMode") private var diffModeRaw = WorkspaceDiffViewMode.inline.rawValue
    @State private var viewedPaths: Set<String> = []
    @State private var viewedRevision = ""

    private var diffMode: WorkspaceDiffViewMode {
        WorkspaceDiffViewMode(rawValue: diffModeRaw) ?? .inline
    }
    private var card: Dieter_V1_Card? { model.card }
    private var workspace: Dieter_V1_Workspace? { model.conversationWorkspace }
    private var changes: Dieter_V1_Changeset? { model.conversationChangeset }
    private var pullRequest: Dieter_V1_PullRequestSummary? {
        guard let card, card.pullRequest.number > 0 else { return nil }
        return card.pullRequest
    }
    private var baseBranch: String {
        let value = workspace?.baseBranch ?? card?.workspace.baseBranch ?? ""
        return value.isEmpty ? "base" : value
    }
    private var selectedFile: Dieter_V1_ChangedFile? {
        changes?.files.first { $0.path == model.selectedChangePath }
    }
    private var operationActive: Bool {
        model.gitOperationSubmitting || model.gitOperationNeedsReconciliation
            || (model.gitOperation.map { GitOperationStatus.active($0.status) } ?? false)
    }
    private var visibleOperation: Dieter_V1_GitOperation? {
        guard let operation = model.gitOperation else { return nil }
        return GitOperationStatus.active(operation.status) || operation.status == "failed"
            ? operation : nil
    }
    private var availability: WorkspaceActionAvailability {
        let mode = ConversationWorkspaceMode.projectMode(
            workspace?.mode ?? card?.workspace.mode ?? card?.workspaceMode ?? "project"
        ).rawValue
        return WorkspaceActionAvailability(
            agentActive: [
                "starting", "running", "working", "streaming", "waiting", "waiting_for_user", "cancelling",
            ]
            .contains((card?.runtime ?? "").lowercased()),
            operationActive: operationActive,
            workspaceState: workspace?.state ?? card?.workspace.state ?? "",
            workspaceMode: mode,
            changedFiles: Int(changes?.files.count ?? Int(card?.workspace.changedFiles ?? 0)),
            hasCommits: !(changes?.commits.isEmpty ?? true)
                || (workspace?.ahead ?? card?.workspace.ahead ?? 0) > 0,
            hasRemote: model.conversationSCMCapabilities?.pushAvailable ?? false,
            scmAuthenticated: model.conversationSCMCapabilities?.authenticated ?? false,
            hasPullRequest: pullRequest != nil,
            workspaceBranch: workspace?.branch ?? card?.workspace.branch ?? "",
            baseBranch: workspace?.baseBranch ?? card?.workspace.baseBranch ?? "",
            dirty: workspace?.dirty ?? false,
            remotePublishMode: workspace?.remotePublishMode ?? card?.remotePublishMode
                ?? RemotePublishMode.manual.rawValue
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = WorkspaceReviewLayout.isCompact(width: geometry.size.width)
            VStack(spacing: 0) {
                workspaceToolbar(compact: compact, roomy: geometry.size.width >= 900)
                Divider().overlay(DieterTheme.paneSeparator)
                workspaceContent(compact: compact)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(background)
        .task(id: "\(model.bindingGeneration):\(active)") {
            guard active, let id = card?.id, DieterConversationID.isServerBacked(id) else { return }
            await model.loadWorkspaceSurface()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, model.target.conversationID == id else { return }
                // Include idle checkouts: external edits and short turns can
                // start and finish entirely between two polls.
                await model.loadWorkspaceSurface()
            }
        }
        .onChange(of: changes?.revision) { _, revision in
            guard viewedRevision != (revision ?? "") else { return }
            viewedRevision = revision ?? ""
            viewedPaths = []
        }
        #if DIETER_UI_SMOKE
            .onReceive(
                NotificationCenter.default.publisher(for: WorkspaceUISmokeRunner.openMergeSheetNotification)
            ) {
                _ in
                mergeSheetPresented = true
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: WorkspaceUISmokeRunner.closeMergeSheetNotification)
            ) {
                _ in
                mergeSheetPresented = false
            }
        #endif
        .sheet(item: $operationKind) { kind in
            GitOperationSheet(model: model, kind: kind, card: card, operation: model.gitOperation)
        }
        .sheet(isPresented: $mergeSheetPresented) {
            MergeIntoBaseSheet(
                model: model, card: card,
                availability: availability,
                onCreatePullRequestInstead: { operationKind = .createPullRequest }
            )

        }
        .popover(item: $selectedCommentLine) { line in commentPopover(line) }
    }

    @ViewBuilder private func workspaceContent(compact: Bool) -> some View {
        if model.workspaceLoading && workspace == nil {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Preparing the conversation workspace…").font(DieterFont.meta).foregroundStyle(
                    DieterTheme.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.workspaceError, workspace == nil {
            ContentUnavailableView(
                "Workspace unavailable", systemImage: "exclamationmark.triangle", description: Text(error)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let workspace {
            VStack(spacing: 0) {
                if workspace.state == "conflicted" || model.gitOperation?.status == "waiting_for_resolution" {
                    conflictBanner
                }
                if let operation = visibleOperation { operationProgress(operation) }
                if let error = model.workspaceError { workspaceErrorBanner(error) }
                reviewLayout(workspace: workspace, compact: compact)
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

    // MARK: Toolbar

    private func workspaceToolbar(compact: Bool, roomy: Bool) -> some View {
        HStack(spacing: 8) {
            if workspace != nil {
                viewModePicker
                if roomy, let changes {
                    HStack(spacing: 6) {
                        WorkspaceDeltaLabel(additions: changes.additions, deletions: changes.deletions)
                        Text("· \(changes.files.count) local file\(changes.files.count == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(DieterTheme.tertiary)
                    }
                    .lineLimit(1)
                }
            } else {
                Text("Workspace changes").font(DieterFont.title)
            }
            Spacer(minLength: 6)
            if workspace != nil {
                toolbarActions(compact: compact, roomy: roomy)
            }
            Menu {
                operationMenu
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().buttonStyle(
                DieterIconButtonStyle()
            )
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
            .buttonStyle(DieterIconButtonStyle()).disabled(model.workspaceLoading).help("Refresh changes")
        }
        .padding(.horizontal, 14).frame(height: 52).background(DieterTheme.sidebar)
    }

    private var viewModePicker: some View {
        HStack(spacing: 2) {
            ForEach(WorkspaceDiffViewMode.allCases) { mode in
                Button {
                    diffModeRaw = mode.rawValue
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 11, weight: diffMode == mode ? .semibold : .medium))
                        .foregroundStyle(diffMode == mode ? DieterTheme.text : DieterTheme.tertiary)
                        .padding(.horizontal, 9).frame(height: 24)
                        .background(
                            diffMode == mode ? DieterTheme.elevated : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("changes.view-mode-\(mode.rawValue.lowercased())")
                .smokeTarget("changes.view-mode-\(mode.rawValue.lowercased())")
            }
        }
        .padding(2)
        .background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(DieterTheme.border))
    }

    @ViewBuilder private func toolbarActions(compact: Bool, roomy: Bool) -> some View {
        let mode = availability.workspaceMode
        if mode == "project" && !availability.hasReviewBranch {
            if availability.allows(.commit) {
                Button {
                    operationKind = .commit
                } label: {
                    Label(compact ? "Commit" : "Commit changes", systemImage: "checkmark.circle").lineLimit(1)
                }
                .buttonStyle(DieterPrimaryButtonStyle())
            }
        } else {
            if !compact {
                Button {
                    operationKind = .update
                } label: {
                    Label(
                        roomy ? "Update from \(baseBranch)" : "Update",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .lineLimit(1).fixedSize()
                }
                .buttonStyle(DieterSecondaryButtonStyle())
                .disabled(!availability.allows(.update))
                .help("Rebase this workspace onto the latest \(baseBranch)")

                if mode == "worktree" {
                    Button("Discard…") { operationKind = .discard }
                        .buttonStyle(DieterSecondaryButtonStyle(destructive: true))
                        .disabled(!availability.allows(.discard))
                        .help("Remove the worktree and its branch")
                }

                if pullRequest == nil {
                    Button {
                        operationKind = .createPullRequest
                    } label: {
                        Label("Create PR…", systemImage: "arrow.triangle.pull").lineLimit(1).fixedSize()
                    }
                    .buttonStyle(DieterSecondaryButtonStyle())
                    .disabled(!availability.allows(.createPullRequest))
                }
            }
            if mode == "worktree" {
                Button {
                    mergeSheetPresented = true
                } label: {
                    Label(
                        !compact && roomy ? "Merge into \(baseBranch)…" : "Merge…",
                        systemImage: "arrow.triangle.merge"
                    )
                    .lineLimit(1).fixedSize()
                }
                .buttonStyle(DieterPrimaryButtonStyle())
                .disabled(!availability.allowsMergeFlow)
                .accessibilityIdentifier("changes.merge-into-base")
            } else if availability.allows(.commit) {
                Button {
                    operationKind = .commit
                } label: {
                    Label(compact ? "Commit" : "Commit changes", systemImage: "checkmark.circle").lineLimit(1)
                }
                .buttonStyle(DieterPrimaryButtonStyle())
            }
        }
    }

    @ViewBuilder private var operationMenu: some View {
        Section("Working copy") {
            Button(GitOperationKind.commit.title, systemImage: "checkmark.circle") {
                operationKind = .commit
            }
            .disabled(!availability.allows(.commit))
            Button(GitOperationKind.update.title, systemImage: "arrow.triangle.2.circlepath") {
                operationKind = .update
            }
            .disabled(!availability.allows(.update))
            Button(GitOperationKind.validate.title, systemImage: "checkmark.seal") {
                operationKind = .validate
            }
            .disabled(!availability.allows(.validate))
            Button(GitOperationKind.push.title, systemImage: "arrow.up.circle") { operationKind = .push }
                .disabled(!availability.allows(.push))
        }
        Section("Review and integrate") {
            if pullRequest == nil {
                Button(GitOperationKind.createPullRequest.title, systemImage: "arrow.triangle.pull") {
                    operationKind = .createPullRequest
                }
                .disabled(!availability.allows(.createPullRequest))
            } else {
                if let url = URL(string: pullRequest?.url ?? "") {
                    Button("Open pull request", systemImage: "arrow.up.right.square") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button(GitOperationKind.refreshPullRequest.title, systemImage: "arrow.clockwise") {
                    operationKind = .refreshPullRequest
                }
                .disabled(!availability.allows(.refreshPullRequest))
                Button(GitOperationKind.mergePullRequest.title, systemImage: "arrow.triangle.merge") {
                    operationKind = .mergePullRequest
                }
                .disabled(!availability.allows(.mergePullRequest))
            }
            Button("Merge into \(baseBranch)…", systemImage: "arrow.triangle.merge") {
                mergeSheetPresented = true
            }
            .disabled(!availability.allowsMergeFlow)
        }
        Section("Workspace") {
            if let card {
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
                operationKind = .adopt
            }
            .disabled(!availability.allows(.adopt))
            Button(GitOperationKind.cleanup.title, systemImage: "trash") { operationKind = .cleanup }
                .disabled(!availability.allows(.cleanup))
            Button(GitOperationKind.discard.title, systemImage: "trash.fill", role: .destructive) {
                operationKind = .discard
            }
            .disabled(!availability.allows(.discard))
        }
    }

    // MARK: Banners

    private var conflictBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DieterTheme.coral)
            VStack(alignment: .leading, spacing: 2) {
                Text(conflictBannerTitle).font(.system(size: 12, weight: .semibold))
                Text("Merge is blocked until conflicts are resolved.")
                    .font(DieterFont.subtitle).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
            }
            Spacer()
            Button("Review conflicts…") { mergeSheetPresented = true }
                .buttonStyle(DieterPrimaryButtonStyle(tint: DieterTheme.coral))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(DieterTheme.coral.opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle().fill(DieterTheme.coral.opacity(0.22)).frame(height: 1)
        }
    }

    private var conflictBannerTitle: String {
        let count = model.gitOperation?.conflicts.count ?? 0
        if count > 0 { return "\(count) file\(count == 1 ? "" : "s") conflict with \(baseBranch)" }
        return "This workspace conflicts with \(baseBranch)"
    }

    private func workspaceErrorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(DieterTheme.amber)
            Text(error).font(DieterFont.meta).foregroundStyle(DieterTheme.subtle).lineLimit(2)
            Spacer()
            Button("Retry") { Task { await model.loadWorkspaceSurface() } }.buttonStyle(.plain)
                .foregroundStyle(
                    DieterTheme.shell)
        }
        .padding(.horizontal, 14).frame(minHeight: 34).background(DieterTheme.amber.opacity(0.08))
    }

    @ViewBuilder private func operationProgress(_ operation: Dieter_V1_GitOperation) -> some View {
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
                if GitOperationStatus.active(operation.status) {
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
                if GitOperationStatus.active(operation.status)
                    && operation.status != "waiting_for_resolution"
                {
                    Button("Cancel") { Task { await model.cancelCurrentGitOperation() } }.buttonStyle(
                        DieterSecondaryButtonStyle(destructive: true))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9).background(DieterTheme.raised)
        .overlay(alignment: .bottom) { Rectangle().fill(DieterTheme.border).frame(height: 1) }
    }

    // MARK: Review layout

    @ViewBuilder private func reviewLayout(workspace: Dieter_V1_Workspace, compact: Bool) -> some View {
        if compact {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(WorkspaceCompactPane.allCases) { pane in
                        Button {
                            compactPane = pane
                        } label: {
                            HStack(spacing: 5) {
                                Text(pane.rawValue)
                                if pane == .files {
                                    Text("\((changes?.files.count ?? 0) + (changes?.commits.count ?? 0))")
                                        .foregroundStyle(DieterTheme.tertiary)
                                }
                            }
                            .font(.system(size: 11, weight: compactPane == pane ? .semibold : .medium))
                            .padding(.horizontal, 10).frame(height: 27)
                            .background(
                                compactPane == pane ? DieterTheme.selection : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    if compactPane == .diff, !model.selectedChangePath.isEmpty {
                        Text(WorkspaceChangePresentation.filename(model.selectedChangePath))
                            .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(
                                DieterTheme.tertiary
                            ).lineLimit(1)
                    }
                }
                .padding(.horizontal, 10).frame(height: 38).background(DieterTheme.sidebar)
                Divider().overlay(DieterTheme.border)
                if compactPane == .files {
                    reviewNavigator(workspace: workspace, compact: true)
                } else {
                    diffView(compact: true)
                }
            }
        } else {
            HSplitView {
                reviewNavigator(workspace: workspace, compact: false).frame(
                    minWidth: 250, idealWidth: 300, maxWidth: 340)
                diffView(compact: false).frame(minWidth: 360)
            }
        }
    }

    // MARK: Navigator

    private func reviewNavigator(workspace: Dieter_V1_Workspace, compact: Bool) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let pullRequest { pullRequestCard(pullRequest) }
                    filesSection(compact: compact)
                    if changes?.commits.isEmpty == false { commitsSection(compact: compact) }
                    scmNotice
                }
                .padding(.horizontal, 10).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Divider().overlay(DieterTheme.border)
            workspaceFooter(workspace)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DieterTheme.sidebar)
    }

    private func pullRequestCard(_ pr: Dieter_V1_PullRequestSummary) -> some View {
        let presentation = PullRequestPresentation.from(
            state: pr.state,
            draft: pr.draft,
            mergeable: pr.mergeable,
            checksState: pr.checksState,
            reviewDecision: pr.reviewDecision
        )
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.pull").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        DieterTheme.shell)
                Text("PR #\(pr.number)").font(.system(size: 12, weight: .semibold))
                PullRequestStateBadge(label: presentation.stateLabel, tone: presentation.stateTone)
                Spacer(minLength: 4)
                Button {
                    if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                } label: {
                    HStack(spacing: 3) {
                        Text("GitHub")
                        Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(DieterTheme.shell)
                }
                .buttonStyle(.plain)
                .help("View on GitHub")
            }
            if !presentation.signals.isEmpty || pr.number > 0 {
                DieterFlowLayout(horizontalSpacing: 10, verticalSpacing: 5) {
                    ForEach(presentation.signals) { signal in
                        PullRequestSignalLabel(signal: signal)
                    }
                    if !pr.lastSyncedAt.isEmpty {
                        Text("synced \(WorkspaceRelativeTime.compact(pr.lastSyncedAt))")
                            .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                if presentation.canAskAgent {
                    Button {
                        let prompt = WorkspaceAgentPrompt.addressReview(
                            number: pr.number,
                            checksState: pr.checksState,
                            reviewDecision: pr.reviewDecision
                        )
                        Task {
                            if await model.sendAgentMessage(prompt) {
                                model.showWorkspaceToast(
                                    "Asked the agent to address the review on PR #\(pr.number)")
                            }
                        }
                    } label: {
                        Label("Ask agent to address review", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DieterSecondaryButtonStyle())
                }
                Button {
                    operationKind = .mergePullRequest
                } label: {
                    Text(presentation.mergeBlockedReason.map { "Merge PR · \($0)" } ?? "Merge PR")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DieterPrimaryButtonStyle())
                .disabled(presentation.mergeBlockedReason != nil || !availability.allows(.mergePullRequest))
                .opacity(
                    presentation.mergeBlockedReason != nil || !availability.allows(.mergePullRequest)
                        ? 0.55 : 1)
            }
            HStack(spacing: 4) {
                Text(
                    "Pushed from \(workspace?.branch.isEmpty == false ? workspace!.branch : "the workspace branch")"
                )
                Spacer()
                Button {
                    operationKind = .refreshPullRequest
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(DieterTheme.tertiary)
                .disabled(!availability.allows(.refreshPullRequest))
                .help("Refresh pull request state")
            }
            .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
        }
        .padding(11)
        .background(DieterTheme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DieterTheme.border))
    }

    private func filesSection(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkspaceSectionHeader(
                title: "Local changes", count: changes?.files.count ?? 0, additions: changes?.additions,
                deletions: changes?.deletions)
            if changes?.files.isEmpty != false {
                WorkspaceEmptyRow(symbol: "checkmark.circle", title: "Working tree is clean")
            }
            ForEach(changes?.files ?? [], id: \.path) { file in
                WorkspaceFileRow(
                    file: file,
                    selected: model.selectedChangePath == file.path && model.selectedCommitSHA.isEmpty,
                    viewed: viewedPaths.contains(file.path)
                ) {
                    compactPane = .diff
                    Task { await model.loadConversationDiff(path: file.path) }
                }
                .accessibilityIdentifier("changes.file.\(file.path)")
                .smokeTarget("changes.file.\(file.path)")
            }
        }
    }

    private func commitsSection(compact: Bool) -> some View {
        let commits = changes?.commits ?? []
        let branch = workspace?.branch ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Commits").font(.system(size: 12, weight: .semibold))
                Text(commitsSubtitle(count: commits.count, branch: branch))
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
                            compactPane = .diff
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
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(DieterTheme.subtle)
                    .help("Copy every commit SHA")
                }
                .padding(.horizontal, 11).frame(height: 30)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DieterTheme.raised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DieterTheme.border))
    }

    private func commitsSubtitle(count: Int, branch: String) -> String {
        guard count > 0 else { return "Ahead of \(baseBranch)" }
        var subtitle = "\(count) on \(branch.isEmpty ? "the workspace branch" : branch)"
        if count > 1 { subtitle += " · squashed to one on merge" }
        return subtitle
    }

    @ViewBuilder private var scmNotice: some View {
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

    private func workspaceFooter(_ workspace: Dieter_V1_Workspace) -> some View {
        HStack(spacing: 7) {
            StatusPill(
                text: workspace.state,
                color: workspace.state == "conflicted" ? DieterTheme.coral : DieterTheme.diffAddition)
            Text(ConversationWorkspaceMode.projectMode(workspace.mode).shortTitle)
            if workspace.sizeBytes > 0 {
                Text(
                    "· \(ByteCountFormatter.string(fromByteCount: workspace.sizeBytes, countStyle: .file))")
            }
            Spacer()
            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.path)
            } label: {
                Image(systemName: "finder")
            }
            .buttonStyle(DieterIconButtonStyle()).help("Reveal workspace in Finder")
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(DieterTheme.tertiary)
        .padding(.horizontal, 10).frame(height: 42)
    }

    // MARK: Diff pane

    private func diffView(compact: Bool) -> some View {
        VStack(spacing: 0) {
            diffHeader(compact: compact)
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
                            diff: diff,
                            split: diffMode == .split,
                            comments: model.conversationChangeComments.filter {
                                $0.path == model.selectedChangePath
                            },
                            canComment: model.selectedCommitSHA.isEmpty,
                            addComment: { line in selectedCommentLine = line },
                            loadMore: {
                                Task {
                                    await model.loadConversationDiff(
                                        path: diff.path, commitSHA: diff.commitSha, append: true)
                                }
                            },
                            loadingMore: model.conversationDiffLoading
                        )
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
            diffFooter
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DieterTheme.background)
    }

    private func diffHeader(compact: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: model.selectedCommitSHA.isEmpty ? "doc.text" : "arrow.triangle.branch")
                .foregroundStyle(DieterTheme.shell).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(diffTitle).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
                    .truncationMode(.middle)
                if !compact, let file = selectedFile {
                    Text(
                        WorkspaceChangePresentation.title(
                            status: file.status, conflicted: file.conflicted, untracked: file.untracked)
                    )
                    .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
                }
            }
            Spacer(minLength: 8)
            if let file = selectedFile {
                WorkspaceDeltaLabel(additions: file.additions, deletions: file.deletions)
            }
            if !model.selectedChangePath.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.selectedChangePath, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(DieterIconButtonStyle()).help("Copy file path")
                if let card {
                    Button {
                        Task { await model.openWorkspaceFiles(card: card, opening: model.selectedChangePath) }
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(DieterIconButtonStyle()).help("Open file in workspace editor")
                }
                viewedToggle
            }
        }
        .padding(.horizontal, 12).frame(height: 46).background(DieterTheme.sidebar)
    }

    private var viewedToggle: some View {
        let path = model.selectedChangePath
        let viewed = viewedPaths.contains(path)
        return Button {
            if viewed {
                viewedPaths.remove(path)
            } else {
                viewedPaths.insert(path)
                advanceToNextUnviewedFile(after: path)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: viewed ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(viewed ? DieterTheme.diffAddition : DieterTheme.tertiary)
                Text("Viewed").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(viewed ? DieterTheme.text : DieterTheme.subtle)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(
                viewed ? DieterTheme.selection : DieterTheme.surface,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(DieterTheme.border))
        }
        .buttonStyle(.plain)
        .help(viewed ? "Mark as not viewed" : "Mark as viewed and jump to the next file")
        .accessibilityIdentifier("changes.viewed-toggle")
    }

    private func advanceToNextUnviewedFile(after path: String) {
        guard let files = changes?.files,
            let start = files.firstIndex(where: { $0.path == path })
        else { return }
        let wrapped = files[(start + 1)...] + files[..<start]
        guard let next = wrapped.first(where: { !viewedPaths.contains($0.path) }) else { return }
        Task { await model.loadConversationDiff(path: next.path) }
    }

    private var diffFooter: some View {
        HStack(spacing: 14) {
            if (workspace?.state ?? "") == "conflicted" {
                Label("Conflicts with \(baseBranch)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DieterTheme.coral)
            } else {
                Label("No conflicts with \(baseBranch)", systemImage: "checkmark")
                    .foregroundStyle(DieterTheme.diffAddition)
            }
            if let validation = lastValidationSummary {
                Label(validation.text, systemImage: validation.passed ? "checkmark" : "xmark")
                    .foregroundStyle(validation.passed ? DieterTheme.diffAddition : DieterTheme.coral)
            }
            Spacer()
            if let files = changes?.files, !files.isEmpty {
                Text(
                    "\(files.filter { viewedPaths.contains($0.path) }.count) of \(files.count) files viewed"
                )
                .foregroundStyle(DieterTheme.tertiary)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 12).frame(height: 32)
        .background(DieterTheme.sidebar)
    }

    private var lastValidationSummary: (text: String, passed: Bool)? {
        guard let operation = model.gitOperation,
            operation.cardID == card?.id,
            GitOperationStatus.terminal(operation.status),
            !operation.validationResults.isEmpty
        else { return nil }
        let passed = operation.validationResults.allSatisfy { $0.exitCode == 0 }
        let name =
            operation.validationResults.count == 1
            ? operation.validationResults[0].name
            : "\(operation.validationResults.count) validations"
        let ago = WorkspaceRelativeTime.compact(operation.finishedAt)
        let suffix = ago.isEmpty ? "" : " · \(ago)"
        return ("\(name) \(passed ? "passed" : "failed")\(suffix)", passed)
    }

    private var diffTitle: String {
        if !model.selectedCommitSHA.isEmpty { return "Commit \(model.selectedCommitSHA.prefix(10))" }
        return model.selectedChangePath.isEmpty ? "Diff" : model.selectedChangePath
    }

    // MARK: Comments

    private func commentPopover(_ line: UnifiedDiffLine) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add review comment").font(DieterFont.title)
                    Text(
                        "\(WorkspaceChangePresentation.filename(model.selectedChangePath)) · line \(line.newLine ?? line.oldLine ?? 0)"
                    )
                    .font(DieterFont.subtitle).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
            }
            .padding(16).background(DieterTheme.sidebar)
            TextEditor(text: $commentBody)
                .font(DieterFont.body).scrollContentBackground(.hidden).padding(10).frame(height: 110)
                .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8)).padding(16)
            HStack {
                Spacer()
                Button("Cancel") {
                    selectedCommentLine = nil
                    commentBody = ""
                }.buttonStyle(DieterSecondaryButtonStyle())
                Button("Add comment") { addComment(line) }.buttonStyle(DieterPrimaryButtonStyle())
                    .disabled(commentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
        .frame(width: 410).background(DieterTheme.background)
    }

    private func addComment(_ line: UnifiedDiffLine) {
        let side = line.kind == .deletion ? "old" : "new"
        let number = Int32(line.kind == .deletion ? line.oldLine ?? 0 : line.newLine ?? 0)
        let body = commentBody
        Task {
            if await model.addChangeComment(
                path: model.selectedChangePath, side: side, line: number, body: body)
            {
                selectedCommentLine = nil
                commentBody = ""
            }
        }
    }
}

// MARK: - Diff content

/// AppKit owns the native scroll position. Observe that position directly so
/// both split columns pan together while their gutters stay in the viewport.
