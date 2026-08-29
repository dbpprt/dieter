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

private enum WorkspaceCompactPane: String, CaseIterable, Identifiable {
    case files = "Changes"
    case diff = "Diff"
    var id: String { rawValue }
}

private enum WorkspaceDiffViewMode: String, CaseIterable, Identifiable {
    case inline = "Inline"
    case split = "Split"
    var id: String { rawValue }
}

struct WorkspaceChangesView: View {
    @Environment(DieterStore.self) private var store
    @State private var operationKind: GitOperationKind?
    @State private var mergeSheetPresented = false
    @State private var selectedCommentLine: UnifiedDiffLine?
    @State private var commentBody = ""
    @State private var compactPane: WorkspaceCompactPane = .files
    @AppStorage("DieterDiffViewMode") private var diffModeRaw = WorkspaceDiffViewMode.inline.rawValue
    @State private var viewedPaths: Set<String> = []
    @State private var viewedRevision = ""

    private var diffMode: WorkspaceDiffViewMode { WorkspaceDiffViewMode(rawValue: diffModeRaw) ?? .inline }
    private var card: Dieter_V1_Card? { store.selectedCard ?? store.selectedDetail?.card }
    private var workspace: Dieter_V1_Workspace? { store.conversationWorkspace }
    private var changes: Dieter_V1_Changeset? { store.conversationChangeset }
    private var pullRequest: Dieter_V1_PullRequestSummary? {
        guard let card, card.pullRequest.number > 0 else { return nil }
        return card.pullRequest
    }
    private var baseBranch: String {
        let value = workspace?.baseBranch ?? card?.workspace.baseBranch ?? ""
        return value.isEmpty ? "base" : value
    }
    private var selectedFile: Dieter_V1_ChangedFile? {
        changes?.files.first { $0.path == store.selectedChangePath }
    }
    private var operationActive: Bool { store.gitOperation.map { GitOperationStatus.active($0.status) } ?? false }
    private var visibleOperation: Dieter_V1_GitOperation? {
        guard let operation = store.gitOperation else { return nil }
        return GitOperationStatus.active(operation.status) || operation.status == "failed" ? operation : nil
    }
    private var availability: WorkspaceActionAvailability {
        let mode = workspace?.mode ?? card?.workspace.mode ?? card?.workspaceMode ?? "main"
        return WorkspaceActionAvailability(
            agentActive: ["starting", "running", "working", "streaming", "waiting", "waiting_for_user", "cancelling"].contains((card?.runtime ?? "").lowercased()),
            operationActive: operationActive,
            workspaceState: workspace?.state ?? card?.workspace.state ?? "",
            workspaceMode: mode.isEmpty ? "main" : mode,
            changedFiles: Int(changes?.files.count ?? Int(card?.workspace.changedFiles ?? 0)),
            hasCommits: !(changes?.commits.isEmpty ?? true) || (workspace?.ahead ?? card?.workspace.ahead ?? 0) > 0,
            hasRemote: store.conversationSCMCapabilities?.pushAvailable ?? false,
            scmAuthenticated: store.conversationSCMCapabilities?.authenticated ?? false,
            hasPullRequest: pullRequest != nil,
            dirty: workspace?.dirty ?? false
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
        .background(DieterTheme.background)
        .task(id: card?.id) {
            guard let id = card?.id, DieterConversationID.isServerBacked(id) else { return }
            await store.loadWorkspaceSurface()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, (store.selectedCardID ?? store.selectedChatID) == id else { return }
                let runtime = (store.selectedCard ?? store.selectedDetail?.card)?.runtime.lowercased() ?? ""
                let gitOperationActive = store.gitOperation?.cardID == id
                    && GitOperationStatus.active(store.gitOperation?.status ?? "")
                if gitOperationActive || ["starting", "running", "working", "streaming", "waiting", "waiting_for_user", "cancelling"].contains(runtime) {
                    await store.loadWorkspaceSurface()
                }
            }
        }
        .onChange(of: changes?.revision) { _, revision in
            guard viewedRevision != (revision ?? "") else { return }
            viewedRevision = revision ?? ""
            viewedPaths = []
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceUISmokeRunner.openMergeSheetNotification)) { _ in
            mergeSheetPresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceUISmokeRunner.closeMergeSheetNotification)) { _ in
            mergeSheetPresented = false
        }
        .sheet(item: $operationKind) { kind in
            GitOperationSheet(kind: kind, card: card, operation: store.gitOperation).environment(store)
        }
        .sheet(isPresented: $mergeSheetPresented) {
            MergeIntoBaseSheet(
                card: card,
                availability: availability,
                onCreatePullRequestInstead: { operationKind = .createPullRequest }
            )
            .environment(store)
        }
        .popover(item: $selectedCommentLine) { line in commentPopover(line) }
    }

    @ViewBuilder private func workspaceContent(compact: Bool) -> some View {
        if store.workspaceLoading && workspace == nil {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Preparing the conversation workspace…").font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.workspaceError, workspace == nil {
            ContentUnavailableView("Workspace unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let workspace {
            VStack(spacing: 0) {
                if workspace.state == "conflicted" || store.gitOperation?.status == "waiting_for_resolution" { conflictBanner }
                if let operation = visibleOperation { operationProgress(operation) }
                if let error = store.workspaceError { workspaceErrorBanner(error) }
                reviewLayout(workspace: workspace, compact: compact)
            }
        } else if let operation = store.gitOperation,
                  operation.status == "succeeded",
                  ["cleanup", "discard", "adopt"].contains(operation.kind) {
            ContentUnavailableView(
                operation.kind == "adopt" ? "Workspace moved" : "Workspace removed",
                systemImage: operation.kind == "adopt" ? "arrow.right.arrow.left" : "trash",
                description: Text(operation.kind == "adopt" ? "The checkout and its history now belong to card \(operation.result)." : "The conversation workspace is no longer provisioned.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No workspace", systemImage: "arrow.triangle.branch", description: Text("Choose workspace settings before starting this conversation."))
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
                        Text("· \(changes.files.count) file\(changes.files.count == 1 ? "" : "s") vs \(baseBranch)")
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
            Menu { operationMenu } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().buttonStyle(DieterIconButtonStyle())
                .help("Workspace actions")
            Button { Task { await store.loadWorkspaceSurface() } } label: {
                if store.workspaceLoading { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(DieterIconButtonStyle()).disabled(store.workspaceLoading).help("Refresh changes")
        }
        .padding(.horizontal, 14).frame(height: 52).background(DieterTheme.sidebar)
    }

    private var viewModePicker: some View {
        HStack(spacing: 2) {
            ForEach(WorkspaceDiffViewMode.allCases) { mode in
                Button { diffModeRaw = mode.rawValue } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 11, weight: diffMode == mode ? .semibold : .medium))
                        .foregroundStyle(diffMode == mode ? DieterTheme.text : DieterTheme.tertiary)
                        .padding(.horizontal, 9).frame(height: 24)
                        .background(diffMode == mode ? DieterTheme.elevated : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("changes.view-mode-\(mode.rawValue.lowercased())")
            }
        }
        .padding(2)
        .background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(DieterTheme.border))
    }

    @ViewBuilder private func toolbarActions(compact: Bool, roomy: Bool) -> some View {
        let mode = availability.workspaceMode
        if mode == "main" {
            if availability.allows(.commit) {
                Button { operationKind = .commit } label: {
                    Label(compact ? "Commit" : "Commit changes", systemImage: "checkmark.circle").lineLimit(1)
                }
                .buttonStyle(DieterPrimaryButtonStyle())
            }
        } else {
            if !compact {
                Button {
                    operationKind = .update
                } label: {
                    Label(roomy ? "Update from \(baseBranch)" : "Update", systemImage: "arrow.triangle.2.circlepath")
                        .lineLimit(1).fixedSize()
                }
                .buttonStyle(DieterSecondaryButtonStyle())
                .disabled(!availability.allows(.update))
                .help("Rebase this workspace onto the latest \(baseBranch)")

                Button("Discard…") { operationKind = .discard }
                    .buttonStyle(DieterSecondaryButtonStyle(destructive: true))
                    .disabled(!availability.allows(.discard))
                    .help("Remove the workspace and its branch")

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
            Button {
                mergeSheetPresented = true
            } label: {
                Label(!compact && roomy ? "Merge into \(baseBranch)…" : "Merge…", systemImage: "arrow.triangle.merge")
                    .lineLimit(1).fixedSize()
            }
            .buttonStyle(DieterPrimaryButtonStyle())
            .disabled(!availability.allowsMergeFlow)
            .accessibilityIdentifier("changes.merge-into-base")
        }
    }

    @ViewBuilder private var operationMenu: some View {
        Section("Working copy") {
            Button(GitOperationKind.commit.title, systemImage: "checkmark.circle") { operationKind = .commit }
                .disabled(!availability.allows(.commit))
            Button(GitOperationKind.update.title, systemImage: "arrow.triangle.2.circlepath") { operationKind = .update }
                .disabled(!availability.allows(.update))
            Button(GitOperationKind.validate.title, systemImage: "checkmark.seal") { operationKind = .validate }
                .disabled(!availability.allows(.validate))
            Button(GitOperationKind.push.title, systemImage: "arrow.up.circle") { operationKind = .push }
                .disabled(!availability.allows(.push))
        }
        Section("Review and integrate") {
            if pullRequest == nil {
                Button(GitOperationKind.createPullRequest.title, systemImage: "arrow.triangle.pull") { operationKind = .createPullRequest }
                    .disabled(!availability.allows(.createPullRequest))
            } else {
                if let url = URL(string: pullRequest?.url ?? "") {
                    Button("Open pull request", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
                }
                Button(GitOperationKind.refreshPullRequest.title, systemImage: "arrow.clockwise") { operationKind = .refreshPullRequest }
                    .disabled(!availability.allows(.refreshPullRequest))
                Button(GitOperationKind.mergePullRequest.title, systemImage: "arrow.triangle.merge") { operationKind = .mergePullRequest }
                    .disabled(!availability.allows(.mergePullRequest))
            }
            Button("Merge into \(baseBranch)…", systemImage: "arrow.triangle.merge") { mergeSheetPresented = true }
                .disabled(!availability.allowsMergeFlow)
        }
        Section("Workspace") {
            if let card {
                Button("Open workspace in Files", systemImage: "folder") { Task { await store.openWorkspaceFiles(card: card) } }
                Button("New terminal in workspace", systemImage: "terminal") { Task { await store.openWorkspaceTerminal(card: card) } }
            }
            if let workspace {
                Button("Reveal in Finder", systemImage: "finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.path) }
            }
            if workspace?.mode == "branch" {
                Button(GitOperationKind.migrate.title, systemImage: "rectangle.on.rectangle.angled") { operationKind = .migrate }
                    .disabled(!availability.allows(.migrate))
            }
            Button(GitOperationKind.adopt.title + "…", systemImage: "arrow.right.arrow.left") { operationKind = .adopt }
                .disabled(!availability.allows(.adopt))
            Button(GitOperationKind.cleanup.title, systemImage: "trash") { operationKind = .cleanup }
                .disabled(!availability.allows(.cleanup))
            Button(GitOperationKind.discard.title, systemImage: "trash.fill", role: .destructive) { operationKind = .discard }
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
        .overlay(alignment: .bottom) { Rectangle().fill(DieterTheme.coral.opacity(0.22)).frame(height: 1) }
    }

    private var conflictBannerTitle: String {
        let count = store.gitOperation?.conflicts.count ?? 0
        if count > 0 { return "\(count) file\(count == 1 ? "" : "s") conflict with \(baseBranch)" }
        return "This workspace conflicts with \(baseBranch)"
    }

    private func workspaceErrorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(DieterTheme.amber)
            Text(error).font(DieterFont.meta).foregroundStyle(DieterTheme.subtle).lineLimit(2)
            Spacer()
            Button("Retry") { Task { await store.loadWorkspaceSurface() } }.buttonStyle(.plain).foregroundStyle(DieterTheme.shell)
        }
        .padding(.horizontal, 14).frame(minHeight: 34).background(DieterTheme.amber.opacity(0.08))
    }

    @ViewBuilder private func operationProgress(_ operation: Dieter_V1_GitOperation) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(store.gitOperationLogs, id: \.sequence) { entry in
                    Text(entry.message).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                }
                ForEach(operation.validationResults, id: \.name) { result in
                    DisclosureGroup("\(result.name) · exit \(result.exitCode)") {
                        Text(result.output.isEmpty ? "No output" : result.output)
                            .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    }
                }
                if !operation.error.isEmpty { Text(operation.error).foregroundStyle(DieterTheme.coral).textSelection(.enabled) }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                if GitOperationStatus.active(operation.status) { ProgressView().controlSize(.mini) }
                else { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(DieterTheme.coral) }
                Text(GitOperationKind(rawValue: operation.kind)?.title ?? operation.kind).font(.system(size: 11, weight: .semibold))
                Text(operation.status.replacingOccurrences(of: "_", with: " ").capitalized).font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary)
                Spacer()
                if GitOperationStatus.active(operation.status) && operation.status != "waiting_for_resolution" {
                    Button("Cancel") { Task { await store.cancelCurrentGitOperation() } }.buttonStyle(DieterSecondaryButtonStyle(destructive: true))
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
                        Button { compactPane = pane } label: {
                            HStack(spacing: 5) {
                                Text(pane.rawValue)
                                if pane == .files { Text("\((changes?.files.count ?? 0) + (changes?.commits.count ?? 0))").foregroundStyle(DieterTheme.tertiary) }
                            }
                            .font(.system(size: 11, weight: compactPane == pane ? .semibold : .medium))
                            .padding(.horizontal, 10).frame(height: 27)
                            .background(compactPane == pane ? DieterTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    if compactPane == .diff, !store.selectedChangePath.isEmpty {
                        Text(WorkspaceChangePresentation.filename(store.selectedChangePath))
                            .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 10).frame(height: 38).background(DieterTheme.sidebar)
                Divider().overlay(DieterTheme.border)
                if compactPane == .files { reviewNavigator(workspace: workspace, compact: true) }
                else { diffView(compact: true) }
            }
        } else {
            HSplitView {
                reviewNavigator(workspace: workspace, compact: false).frame(minWidth: 250, idealWidth: 300, maxWidth: 340)
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
                    commitsSection(compact: compact)
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
                Image(systemName: "arrow.triangle.pull").font(.system(size: 11, weight: .semibold)).foregroundStyle(DieterTheme.shell)
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
                            if await store.sendAgentMessage(prompt) {
                                store.showWorkspaceToast("Asked the agent to address the review on PR #\(pr.number)")
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
                .opacity(presentation.mergeBlockedReason != nil || !availability.allows(.mergePullRequest) ? 0.55 : 1)
            }
            HStack(spacing: 4) {
                Text("Pushed from \(workspace?.branch.isEmpty == false ? workspace!.branch : "the workspace branch")")
                Spacer()
                Button { operationKind = .refreshPullRequest } label: { Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold)) }
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
            WorkspaceSectionHeader(title: "Files · vs \(baseBranch)", count: changes?.files.count ?? 0, additions: changes?.additions, deletions: changes?.deletions)
            if changes?.files.isEmpty != false {
                WorkspaceEmptyRow(symbol: "checkmark.circle", title: "No changes against \(baseBranch)")
            }
            ForEach(changes?.files ?? [], id: \.path) { file in
                WorkspaceFileRow(
                    file: file,
                    selected: store.selectedChangePath == file.path && store.selectedCommitSHA.isEmpty,
                    viewed: viewedPaths.contains(file.path)
                ) {
                    compactPane = .diff
                    Task { await store.loadConversationDiff(path: file.path) }
                }
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
                    .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 11).padding(.top, 11).padding(.bottom, 7)
            if commits.isEmpty {
                WorkspaceEmptyRow(symbol: "arrow.triangle.branch", title: "No commits ahead of \(baseBranch)")
                    .padding(.horizontal, 3).padding(.bottom, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(commits, id: \.sha) { commit in
                        WorkspaceCommitRow(commit: commit, selected: store.selectedCommitSHA == commit.sha) {
                            compactPane = .diff
                            Task { await store.loadConversationDiff(path: "", commitSHA: commit.sha) }
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
                        NSPasteboard.general.setString(commits.map(\.sha).joined(separator: "\n"), forType: .string)
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
        if let capabilities = store.conversationSCMCapabilities,
           !capabilities.authenticated,
           !capabilities.unavailableReason.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle.fill").foregroundStyle(DieterTheme.amber)
                Text(capabilities.unavailableReason).font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10).background(DieterTheme.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func workspaceFooter(_ workspace: Dieter_V1_Workspace) -> some View {
        HStack(spacing: 7) {
            StatusPill(text: workspace.state, color: workspace.state == "conflicted" ? DieterTheme.coral : DieterTheme.eyes)
            Text(ConversationWorkspaceMode.projectMode(workspace.mode).shortTitle)
            if workspace.sizeBytes > 0 {
                Text("· \(ByteCountFormatter.string(fromByteCount: workspace.sizeBytes, countStyle: .file))")
            }
            Spacer()
            Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.path) } label: { Image(systemName: "finder") }
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
                if let diff = store.conversationDiff {
                    if diff.binary {
                        ContentUnavailableView("Binary diff", systemImage: "doc.badge.ellipsis", description: Text("This file cannot be rendered as text."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        WorkspaceDiffContent(
                            diff: diff,
                            split: diffMode == .split,
                            comments: store.conversationChangeComments.filter { $0.path == store.selectedChangePath },
                            canComment: store.selectedCommitSHA.isEmpty,
                            addComment: { line in selectedCommentLine = line },
                            loadMore: {
                                Task { await store.loadConversationDiff(path: diff.path, commitSHA: diff.commitSha, append: true) }
                            }
                        )
                    }
                } else {
                    ContentUnavailableView("Select a change", systemImage: "doc.text.magnifyingglass", description: Text("Choose a changed file or commit to inspect its diff."))
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
            Image(systemName: store.selectedCommitSHA.isEmpty ? "doc.text" : "arrow.triangle.branch")
                .foregroundStyle(DieterTheme.shell).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(diffTitle).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                if !compact, let file = selectedFile {
                    Text(WorkspaceChangePresentation.title(status: file.status, conflicted: file.conflicted, untracked: file.untracked))
                        .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
                }
            }
            Spacer(minLength: 8)
            if let file = selectedFile { WorkspaceDeltaLabel(additions: file.additions, deletions: file.deletions) }
            if !store.selectedChangePath.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.selectedChangePath, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(DieterIconButtonStyle()).help("Copy file path")
                if let card {
                    Button { Task { await store.openWorkspaceFiles(card: card, opening: store.selectedChangePath) } } label: { Image(systemName: "pencil") }
                        .buttonStyle(DieterIconButtonStyle()).help("Open file in workspace editor")
                }
                viewedToggle
            }
        }
        .padding(.horizontal, 12).frame(height: 46).background(DieterTheme.sidebar)
    }

    private var viewedToggle: some View {
        let path = store.selectedChangePath
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
                    .foregroundStyle(viewed ? DieterTheme.eyes : DieterTheme.tertiary)
                Text("Viewed").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(viewed ? DieterTheme.text : DieterTheme.subtle)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(viewed ? DieterTheme.selection : DieterTheme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(DieterTheme.border))
        }
        .buttonStyle(.plain)
        .help(viewed ? "Mark as not viewed" : "Mark as viewed and jump to the next file")
        .accessibilityIdentifier("changes.viewed-toggle")
    }

    private func advanceToNextUnviewedFile(after path: String) {
        guard let files = changes?.files,
              let start = files.firstIndex(where: { $0.path == path }) else { return }
        let wrapped = files[(start + 1)...] + files[..<start]
        guard let next = wrapped.first(where: { !viewedPaths.contains($0.path) }) else { return }
        Task { await store.loadConversationDiff(path: next.path) }
    }

    private var diffFooter: some View {
        HStack(spacing: 14) {
            if (workspace?.state ?? "") == "conflicted" {
                Label("Conflicts with \(baseBranch)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DieterTheme.coral)
            } else {
                Label("No conflicts with \(baseBranch)", systemImage: "checkmark")
                    .foregroundStyle(DieterTheme.eyes)
            }
            if let validation = lastValidationSummary {
                Label(validation.text, systemImage: validation.passed ? "checkmark" : "xmark")
                    .foregroundStyle(validation.passed ? DieterTheme.eyes : DieterTheme.coral)
            }
            Spacer()
            if let files = changes?.files, !files.isEmpty {
                Text("\(files.filter { viewedPaths.contains($0.path) }.count) of \(files.count) files viewed")
                    .foregroundStyle(DieterTheme.tertiary)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 12).frame(height: 32)
        .background(DieterTheme.sidebar)
    }

    private var lastValidationSummary: (text: String, passed: Bool)? {
        guard let operation = store.gitOperation,
              operation.cardID == card?.id,
              GitOperationStatus.terminal(operation.status),
              !operation.validationResults.isEmpty else { return nil }
        let passed = operation.validationResults.allSatisfy { $0.exitCode == 0 }
        let name = operation.validationResults.count == 1
            ? operation.validationResults[0].name
            : "\(operation.validationResults.count) validations"
        let ago = WorkspaceRelativeTime.compact(operation.finishedAt)
        let suffix = ago.isEmpty ? "" : " · \(ago)"
        return ("\(name) \(passed ? "passed" : "failed")\(suffix)", passed)
    }

    private var diffTitle: String {
        if !store.selectedCommitSHA.isEmpty { return "Commit \(store.selectedCommitSHA.prefix(10))" }
        return store.selectedChangePath.isEmpty ? "Diff" : store.selectedChangePath
    }

    // MARK: Comments

    private func commentPopover(_ line: UnifiedDiffLine) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add review comment").font(DieterFont.title)
                    Text("\(WorkspaceChangePresentation.filename(store.selectedChangePath)) · line \(line.newLine ?? line.oldLine ?? 0)")
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
                Button("Cancel") { selectedCommentLine = nil; commentBody = "" }.buttonStyle(DieterSecondaryButtonStyle())
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
            if await store.addChangeComment(path: store.selectedChangePath, side: side, line: number, body: body) {
                selectedCommentLine = nil
                commentBody = ""
            }
        }
    }
}

// MARK: - Diff content

private struct WorkspaceDiffContent: View {
    let diff: Dieter_V1_FileDiff
    let split: Bool
    let comments: [Dieter_V1_ChangeComment]
    let canComment: Bool
    let addComment: (UnifiedDiffLine) -> Void
    let loadMore: () -> Void

    @State private var rows: [WorkspaceDiffRow] = []
    @State private var builtKey = ""
    @State private var expandedFolds: Set<Int> = []

    private var buildKey: String { "\(diff.path)|\(diff.commitSha)|\(split)|\(diff.patch.count)" }

    var body: some View {
        GeometryReader { viewport in
            ScrollView(split ? .vertical : [.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        diffRow(row, viewportWidth: max(0, viewport.size.width))
                    }
                    if diff.truncated {
                        Button("Load the rest of this diff") { loadMore() }
                            .buttonStyle(DieterSecondaryButtonStyle()).padding(12)
                    }
                }
                .frame(
                    minWidth: max(0, viewport.size.width),
                    minHeight: max(0, viewport.size.height),
                    alignment: .topLeading
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task(id: buildKey) {
            guard builtKey != buildKey else { return }
            let lines = UnifiedDiffParser.parse(diff.patch)
            // Whole-commit patches span files; keep their boundaries visible.
            let fileRows = diff.path.isEmpty && !diff.commitSha.isEmpty
            rows = split
                ? WorkspaceDiffDisplay.splitRows(lines, fileRows: fileRows)
                : WorkspaceDiffDisplay.inlineRows(lines, fileRows: fileRows)
            builtKey = buildKey
            expandedFolds = []
        }
    }

    @ViewBuilder private func diffRow(_ row: WorkspaceDiffRow, viewportWidth: CGFloat) -> some View {
        switch row {
        case .line(let line):
            WorkspaceDiffLineRow(
                line: line,
                comments: commentsFor(line),
                canComment: canComment && (line.newLine ?? line.oldLine) != nil,
                minimumWidth: viewportWidth,
                addComment: { addComment(line) }
            )
        case .pair(let pair):
            WorkspaceSplitPairRow(pair: pair, width: viewportWidth)
        case .file(let id, let path):
            HStack(spacing: 7) {
                Image(systemName: "doc.text").font(.system(size: 9, weight: .semibold)).foregroundStyle(DieterTheme.subtle)
                Text(path).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(DieterTheme.text)
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minWidth: viewportWidth, minHeight: 30, alignment: .leading)
            .background(DieterTheme.sidebar)
            .id(id)
        case .hunk(let id, let text, let skipped):
            VStack(spacing: 0) {
                if skipped > 0 {
                    WorkspaceUnchangedSeparator(count: skipped, width: viewportWidth)
                }
                HStack(spacing: 0) {
                    Text(text)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(DieterTheme.shell)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                    Spacer(minLength: 0)
                }
                .frame(minWidth: viewportWidth, minHeight: 26, alignment: .leading)
                .background(DieterTheme.shell.opacity(0.07))
            }
            .id(id)
        case .fold(let id, let count, let lines, let pairs):
            if expandedFolds.contains(id) {
                VStack(spacing: 0) {
                    foldButton(id: id, count: count, expanded: true, width: viewportWidth)
                    if split {
                        ForEach(pairs) { pair in WorkspaceSplitPairRow(pair: pair, width: viewportWidth) }
                    } else {
                        ForEach(lines) { line in
                            WorkspaceDiffLineRow(
                                line: line,
                                comments: commentsFor(line),
                                canComment: canComment && (line.newLine ?? line.oldLine) != nil,
                                minimumWidth: viewportWidth,
                                addComment: { addComment(line) }
                            )
                        }
                    }
                }
            } else {
                foldButton(id: id, count: count, expanded: false, width: viewportWidth)
            }
        }
    }

    private func foldButton(id: Int, count: Int, expanded: Bool, width: CGFloat) -> some View {
        Button {
            if expanded { expandedFolds.remove(id) } else { expandedFolds.insert(id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                Text(expanded ? "Hide \(count) unchanged lines" : "\(count) unchanged lines")
                    .font(.system(size: 10, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(DieterTheme.subtle)
            .padding(.horizontal, 12)
            .frame(minWidth: width, minHeight: 24, alignment: .leading)
            .background(DieterTheme.raised.opacity(0.55))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Collapse this unchanged region" : "Expand this unchanged region")
    }

    private func commentsFor(_ line: UnifiedDiffLine) -> [Dieter_V1_ChangeComment] {
        let side = line.kind == .deletion ? "old" : "new"
        let number = line.kind == .deletion ? line.oldLine : line.newLine
        return comments.filter { $0.side == side && $0.line == Int32(number ?? -1) }
    }
}

private struct WorkspaceUnchangedSeparator: View {
    let count: Int
    let width: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis").font(.system(size: 8, weight: .bold))
            Text("\(count) unchanged lines").font(.system(size: 10, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(DieterTheme.tertiary)
        .padding(.horizontal, 12)
        .frame(minWidth: width, minHeight: 22, alignment: .leading)
    }
}

private struct WorkspaceSplitPairRow: View {
    let pair: WorkspaceSplitPair
    let width: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            side(line: pair.old, number: pair.old.flatMap(\.oldLine), addition: false)
            Rectangle().fill(DieterTheme.border).frame(width: 1)
            side(line: pair.new, number: pair.new.flatMap(\.newLine), addition: true)
        }
        .frame(minWidth: width, minHeight: 21, alignment: .topLeading)
    }

    @ViewBuilder private func side(line: UnifiedDiffLine?, number: Int?, addition: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? "")
                .foregroundStyle(DieterTheme.tertiary)
                .padding(.trailing, 7)
                .frame(width: 42, alignment: .trailing)
                .frame(maxHeight: .infinity)
                .background(DieterTheme.sidebar.opacity(0.72))
            Text(displayText(line))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(foreground(line))
                .padding(.leading, 6).padding(.trailing, 8)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .font(.system(size: 11, design: .monospaced))
        .frame(maxWidth: .infinity, minHeight: 21, alignment: .topLeading)
        .background(background(line, addition: addition))
    }

    private func displayText(_ line: UnifiedDiffLine?) -> String {
        guard let line else { return " " }
        return line.text.isEmpty ? " " : line.text
    }

    private func foreground(_ line: UnifiedDiffLine?) -> Color {
        switch line?.kind {
        case .addition: DieterTheme.eyes
        case .deletion: DieterTheme.coral
        default: DieterTheme.text
        }
    }

    private func background(_ line: UnifiedDiffLine?, addition: Bool) -> Color {
        switch line?.kind {
        case .addition: DieterTheme.eyes.opacity(0.09)
        case .deletion: DieterTheme.coral.opacity(0.09)
        case .context: .clear
        default: DieterTheme.raised.opacity(0.35)
        }
    }
}

// MARK: - Navigator rows

private struct WorkspaceSectionHeader: View {
    let title: String
    let count: Int
    var additions: Int32? = nil
    var deletions: Int32? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(DieterFont.sectionLabel).tracking(0.45).foregroundStyle(DieterTheme.tertiary)
            Text("\(count)").font(.system(size: 9, weight: .bold)).foregroundStyle(DieterTheme.tertiary)
            Spacer()
            if let additions, let deletions { WorkspaceDeltaLabel(additions: additions, deletions: deletions) }
        }
        .frame(height: 22)
    }
}

private struct WorkspaceDeltaLabel: View {
    let additions: Int32
    let deletions: Int32

    var body: some View {
        HStack(spacing: 6) {
            Text("+\(additions)").foregroundStyle(DieterTheme.eyes)
            Text("−\(deletions)").foregroundStyle(DieterTheme.coral)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced)).fixedSize()
    }
}

private struct WorkspaceEmptyRow: View {
    let symbol: String
    let title: String
    var body: some View {
        Label(title, systemImage: symbol).font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
            .padding(.horizontal, 8).frame(height: 34)
    }
}

private struct WorkspaceFileRow: View {
    let file: Dieter_V1_ChangedFile
    let selected: Bool
    var viewed = false
    let action: () -> Void

    private var deleted: Bool {
        WorkspaceChangePresentation.badge(status: file.status, conflicted: file.conflicted, untracked: file.untracked) == "D"
    }

    private var tint: Color {
        if file.conflicted { return DieterTheme.coral }
        if file.untracked { return DieterTheme.amber }
        return DieterTheme.shell
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text(WorkspaceChangePresentation.badge(status: file.status, conflicted: file.conflicted, untracked: file.untracked))
                    .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(tint)
                    .frame(width: 20, height: 20).background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(WorkspaceChangePresentation.filename(file.path))
                        .font(.system(size: 11, weight: .medium))
                        .strikethrough(deleted)
                        .opacity(viewed && !selected ? 0.55 : 1)
                        .lineLimit(1)
                    let directory = WorkspaceChangePresentation.directory(file.path)
                    if !directory.isEmpty { Text(directory).font(.system(size: 9, design: .monospaced)).foregroundStyle(DieterTheme.tertiary).lineLimit(1).truncationMode(.middle) }
                }
                Spacer(minLength: 5)
                if viewed {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(DieterTheme.eyes)
                }
                WorkspaceDeltaLabel(additions: file.additions, deletions: file.deletions)
            }
            .padding(.horizontal, 8).frame(minHeight: 42)
            .background(selected ? DieterTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("\(WorkspaceChangePresentation.title(status: file.status, conflicted: file.conflicted, untracked: file.untracked)): \(file.path)")
    }
}

private struct WorkspaceCommitRow: View {
    let commit: Dieter_V1_WorkspaceCommit
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(String(commit.shortSha.prefix(7)))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(DieterTheme.shell)
                VStack(alignment: .leading, spacing: 2) {
                    Text(commit.subject).font(.system(size: 11, weight: .medium)).lineLimit(2)
                    HStack(spacing: 6) {
                        WorkspaceDeltaLabel(additions: commit.additions, deletions: commit.deletions)
                        if !commit.authoredAt.isEmpty {
                            Text(WorkspaceRelativeTime.compact(commit.authoredAt))
                                .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
                        }
                    }
                }
                Spacer(minLength: 5)
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(selected ? DieterTheme.selection : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PullRequestStateBadge: View {
    let label: String
    let tone: PullRequestPresentation.Tone

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).frame(height: 17)
            .background(color.opacity(0.13), in: Capsule())
    }

    private var color: Color {
        switch tone {
        case .positive: DieterTheme.eyes
        case .active: DieterTheme.shell
        case .warning: DieterTheme.amber
        case .critical: DieterTheme.coral
        case .neutral: DieterTheme.subtle
        }
    }
}

private struct PullRequestSignalLabel: View {
    let signal: PullRequestPresentation.Signal

    var body: some View {
        HStack(spacing: 4) {
            if signal.tone == .active {
                DieterActivityIndicator(color: DieterTheme.shell, size: 9)
            } else {
                Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            }
            Text(signal.text)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
    }

    private var symbol: String {
        switch signal.tone {
        case .positive: "checkmark"
        case .warning: "clock"
        case .critical: "xmark"
        default: "circle"
        }
    }

    private var color: Color {
        switch signal.tone {
        case .positive: DieterTheme.eyes
        case .active: DieterTheme.shell
        case .warning: DieterTheme.amber
        case .critical: DieterTheme.coral
        case .neutral: DieterTheme.subtle
        }
    }
}

private struct WorkspaceDiffLineRow: View {
    let line: UnifiedDiffLine
    let comments: [Dieter_V1_ChangeComment]
    let canComment: Bool
    let minimumWidth: CGFloat
    let addComment: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                lineNumber(line.oldLine).frame(width: 42, alignment: .trailing)
                lineNumber(line.newLine).frame(width: 42, alignment: .trailing)
                Group {
                    if canComment {
                        Button(action: addComment) { Image(systemName: "plus").font(.system(size: 8, weight: .bold)).frame(width: 22, height: 20) }
                            .buttonStyle(.plain).foregroundStyle(DieterTheme.shell).opacity(hovering || !comments.isEmpty ? 1 : 0)
                    } else { Color.clear.frame(width: 22, height: 20) }
                }
                Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, 5).padding(.trailing, 12)
            }
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(foreground)
            .frame(minWidth: minimumWidth, minHeight: 21, alignment: .topLeading)
            .background(background)
            ForEach(comments, id: \.id) { comment in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.bubble.fill").foregroundStyle(DieterTheme.shell)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(comment.body).font(.system(size: 11)).textSelection(.enabled)
                        Text(comment.author.isEmpty ? comment.createdAt : "\(comment.author) · \(comment.createdAt)")
                            .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
                    }
                }
                .padding(9).padding(.leading, 88).frame(minWidth: minimumWidth, alignment: .leading).background(DieterTheme.raised)
            }
        }
        .onHover { hovering = $0 }
    }

    private func lineNumber(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "").foregroundStyle(DieterTheme.tertiary)
            .padding(.trailing, 7).frame(maxHeight: .infinity).background(DieterTheme.sidebar.opacity(0.72))
    }

    private var background: Color {
        switch line.kind {
        case .addition: DieterTheme.eyes.opacity(0.09)
        case .deletion: DieterTheme.coral.opacity(0.09)
        case .hunk: DieterTheme.selection
        case .header: DieterTheme.sidebar
        case .context: .clear
        }
    }

    private var foreground: Color {
        switch line.kind {
        case .addition: DieterTheme.eyes
        case .deletion: DieterTheme.coral
        case .header, .hunk: DieterTheme.shell
        case .context: DieterTheme.text
        }
    }
}

// MARK: - Merge sheet

private struct MergeIntoBaseSheet: View {
    @Environment(DieterStore.self) private var store
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

    private var workspace: Dieter_V1_Workspace? { store.conversationWorkspace }
    private var changes: Dieter_V1_Changeset? { store.conversationChangeset }
    private var branch: String {
        let value = workspace?.branch ?? card?.workspace.branch ?? ""
        return value.isEmpty ? "workspace" : value
    }
    private var baseBranch: String {
        let value = workspace?.baseBranch ?? card?.workspace.baseBranch ?? ""
        return value.isEmpty ? "base" : value
    }
    private var conflicted: Bool {
        workspace?.state == "conflicted" || store.gitOperation?.status == "waiting_for_resolution"
    }
    private var mergeFailedConflict: Bool {
        guard let operation = store.gitOperation else { return false }
        return operation.kind == "merge_local" && operation.status == "failed"
    }
    private var running: Bool { store.mergeFlowStep != nil }
    private var isChat: Bool { (card?.scope ?? "") == "chat" }
    private var readiness: WorkspaceMergeReadiness {
        WorkspaceMergeReadiness.evaluate(
            workspaceState: workspace?.state ?? "",
            baseBranch: baseBranch,
            behind: Int(workspace?.behind ?? 0),
            dirty: workspace?.dirty ?? false,
            conflictedFiles: store.gitOperation?.conflicts.count ?? 0,
            lastValidation: lastValidation
        )
    }
    private var lastValidation: (name: String, passed: Bool, ago: String)? {
        guard let operation = store.gitOperation,
              operation.cardID == card?.id,
              GitOperationStatus.terminal(operation.status),
              !operation.validationResults.isEmpty else { return nil }
        let passed = operation.validationResults.allSatisfy { $0.exitCode == 0 }
        let name = operation.validationResults.count == 1 ? operation.validationResults[0].name : "validation"
        return (name, passed, WorkspaceRelativeTime.compact(operation.finishedAt))
    }
    private var mergeButtonTitle: String {
        let count = changes?.files.count ?? 0
        return count > 0 ? "Merge \(count) file\(count == 1 ? "" : "s")" : "Merge into \(baseBranch)"
    }

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
                        if mergeFailedConflict { mergeFailedNotice }
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
        }
        .interactiveDismissDisabled(running)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Merge into \(baseBranch)").font(.custom("Sora", size: 19).weight(.semibold))
            HStack(spacing: 8) {
                branchChip(branch, tinted: true)
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(DieterTheme.tertiary)
                branchChip(baseBranch, tinted: false)
                Spacer()
                if let changes {
                    HStack(spacing: 6) {
                        WorkspaceDeltaLabel(additions: changes.additions, deletions: changes.deletions)
                        Text("· \(changes.files.count) files · \(changes.commits.count) commit\(changes.commits.count == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(DieterTheme.tertiary)
                    }
                }
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(DieterTheme.sidebar)
    }

    private func branchChip(_ name: String, tinted: Bool) -> some View {
        HStack(spacing: 5) {
            if tinted { Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold)) }
            Text(name).font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(tinted ? DieterTheme.shell : DieterTheme.text)
        .lineLimit(1).truncationMode(.middle)
        .padding(.horizontal, 9).frame(height: 26)
        .background(tinted ? DieterTheme.shell.opacity(0.1) : DieterTheme.surface, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(tinted ? DieterTheme.shell.opacity(0.3) : DieterTheme.border))
    }

    // MARK: Ready mode

    private var readinessCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(readiness.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: symbol(for: item.tone))
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(color(for: item.tone))
                        .frame(width: 14)
                    Text(item.text).font(.system(size: 11, weight: .medium)).foregroundStyle(DieterTheme.text)
                    if !item.detail.isEmpty {
                        Text("· \(item.detail)").font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
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

    private func symbol(for tone: WorkspaceMergeReadiness.Tone) -> String {
        switch tone {
        case .ready: "checkmark"
        case .note: "exclamationmark.circle"
        case .blocked: "exclamationmark.triangle.fill"
        }
    }

    private func color(for tone: WorkspaceMergeReadiness.Tone) -> Color {
        switch tone {
        case .ready: DieterTheme.eyes
        case .note: DieterTheme.amber
        case .blocked: DieterTheme.coral
        }
    }

    private var mergeFailedNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DieterTheme.coral).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text("The last merge attempt failed").font(.system(size: 11, weight: .semibold)).foregroundStyle(DieterTheme.text)
                Text(store.gitOperation?.error.isEmpty == false
                    ? store.gitOperation!.error
                    : "Update from \(baseBranch) first — conflicts surface there with the files that need attention.")
                    .font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(DieterTheme.coral.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.coral.opacity(0.18)))
    }

    private var messageFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text("COMMIT MESSAGE").font(DieterFont.sectionLabel).tracking(0.45).foregroundStyle(DieterTheme.tertiary)
                TextField("Summarize the change", text: $subject)
                    .textFieldStyle(.plain).font(DieterFont.body)
                    .padding(.horizontal, 11)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.strongBorder))
                    .disabled(running)
                    .accessibilityIdentifier("merge.subject")
            }
            TextField("Optional description — drafted from the card, edit freely.", text: $bodyText, axis: .vertical)
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
                Text("STRATEGY").font(DieterFont.sectionLabel).tracking(0.45).foregroundStyle(DieterTheme.tertiary)
                Picker("Merge strategy", selection: $strategy) {
                    Text("Squash").tag("squash")
                    Text("Merge commit").tag("merge_commit")
                    Text("Fast-forward").tag("fast_forward")
                }
                .labelsHidden().pickerStyle(.segmented).disabled(running)
                Text(strategyCaption)
                    .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                Toggle("Validate the merge result", isOn: $validate)
                    .font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini).disabled(running)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 7) {
                Text("AFTER MERGE").font(DieterFont.sectionLabel).tracking(0.45).foregroundStyle(DieterTheme.tertiary)
                Toggle("Remove worktree & branch", isOn: $removeWorkspace)
                    .font(.system(size: 11, weight: .medium)).toggleStyle(.switch).controlSize(.small).disabled(running)
                Text(removeWorkspace
                    ? (isChat ? "The chat keeps its full history." : "Card moves to Done.")
                    : "The worktree stays for follow-up work.")
                    .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
            }
            .frame(width: 210, alignment: .leading)
        }
    }

    private var strategyCaption: String {
        let count = changes?.commits.count ?? 0
        switch strategy {
        case "merge_commit": return "Keeps every commit and adds a merge commit."
        case "fast_forward": return "Moves \(baseBranch) forward without a new commit."
        default:
            return count > 1 ? "\(count) commits become one on \(baseBranch)." : "The work lands as a single commit on \(baseBranch)."
        }
    }

    // MARK: Conflict mode

    private var conflictContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(DieterTheme.coral).font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(conflictTitle).font(.system(size: 12, weight: .semibold)).foregroundStyle(DieterTheme.coral)
                    Text("Merge is blocked until conflicts are resolved.")
                        .font(DieterFont.meta).foregroundStyle(DieterTheme.coral.opacity(0.8))
                }
            }
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(DieterTheme.coral.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.coral.opacity(0.22)))

            ForEach(store.gitOperation?.conflicts ?? [], id: \.path) { conflict in
                HStack(spacing: 9) {
                    Text("!")
                        .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(DieterTheme.coral)
                        .frame(width: 20, height: 20).background(DieterTheme.coral.opacity(0.11), in: RoundedRectangle(cornerRadius: 5))
                    Text(conflict.path).font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if conflict.hunkCount > 0 {
                        Text("\(conflict.hunkCount) conflicting hunk\(conflict.hunkCount == 1 ? "" : "s")")
                            .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                    }
                    if let card {
                        Button("Open in editor") { Task { await store.openWorkspaceFiles(card: card, opening: conflict.path) } }
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
                    let prompt = WorkspaceAgentPrompt.resolveConflicts(
                        baseBranch: baseBranch,
                        conflicts: store.gitOperation?.conflicts ?? []
                    )
                    Task {
                        if await store.sendAgentMessage(prompt) {
                            store.showWorkspaceToast("Asked the agent to resolve the conflicts")
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

    private var conflictTitle: String {
        let count = store.gitOperation?.conflicts.count ?? 0
        if count > 0 { return "\(count) file\(count == 1 ? "" : "s") conflict with \(baseBranch)" }
        return "This workspace conflicts with \(baseBranch)"
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack(spacing: 10) {
            if running {
                ProgressView().controlSize(.small)
                Text(store.mergeFlowStep?.progressLabel ?? "Working…")
                    .font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary)
                Spacer()
            } else if conflicted {
                Text("Resolve the markers, then continue — or hand it to the agent.")
                    .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                Spacer()
                Button("Abort") { startOperationAndDismiss(.abortConflict) }
                    .buttonStyle(DieterSecondaryButtonStyle(destructive: true))
                Button("Continue after resolving") { startOperationAndDismiss(.continueConflict) }
                    .buttonStyle(DieterSecondaryButtonStyle())
                Button("Merge blocked") {}
                    .buttonStyle(DieterPrimaryButtonStyle())
                    .disabled(true).opacity(0.45)
            } else {
                Text("Runs locally · nothing is pushed")
                    .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                Spacer()
                if mergeFailedConflict {
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
                    Label(mergeButtonTitle, systemImage: "arrow.triangle.merge")
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
            let merged = await store.performMergeFlow(
                strategy: strategy,
                subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
                body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines),
                validate: validate,
                removeWorkspace: removeWorkspace,
                moveCardToDone: removeWorkspace && !isChat
            )
            if merged { dismiss() }
        }
    }

    private func startOperationAndDismiss(_ kind: GitOperationKind) {
        Task {
            let parameters: [String: String]
            switch kind {
            case .update: parameters = ["fetch": "true", "validate": "false"]
            case .continueConflict: parameters = ["conflicted_operation_id": store.gitOperation?.id ?? "", "validate": String(validate)]
            case .abortConflict: parameters = ["conflicted_operation_id": store.gitOperation?.id ?? ""]
            default: parameters = [:]
            }
            if await store.startGitOperation(kind, parameters: parameters) { dismiss() }
        }
    }
}

// MARK: - Operation sheet (secondary flows)

private struct GitOperationSheet: View {
    @Environment(DieterStore.self) private var store
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
                            detail: "Dieter saves recovery artifacts before removing this workspace. Its uncommitted changes and managed branch will no longer remain in active use.",
                            symbol: "archivebox.fill",
                            tint: DieterTheme.coral
                        )
                    } else if kind == .cleanup {
                        WorkspaceSheetNotice(
                            title: "Clean, integrated work only",
                            detail: "Cleanup stops if the branch still has changes or has not been integrated.",
                            symbol: "checkmark.shield.fill",
                            tint: DieterTheme.eyes
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
                    .buttonStyle(kind.destructive ? DieterPrimaryButtonStyle(tint: DieterTheme.coral) : DieterPrimaryButtonStyle())
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
            WorkspaceSheetField(label: "DESCRIPTION", placeholder: "Optional commit body", text: $bodyText, multiline: true)
            WorkspaceSheetOptions {
                Toggle("Include untracked files", isOn: $includeUntracked)
            }
        case .update:
            WorkspaceSheetNotice(title: "Rebase onto the latest base", detail: operationDescription, symbol: "arrow.triangle.2.circlepath", tint: DieterTheme.shell)
            WorkspaceSheetOptions {
                Toggle("Fetch the configured base remote", isOn: $fetch)
                Divider().overlay(DieterTheme.border)
                Toggle("Run project validation after rebasing", isOn: $validate)
            }
        case .validate:
            WorkspaceSheetNotice(title: "Validate this workspace", detail: operationDescription, symbol: "checkmark.seal.fill", tint: DieterTheme.eyes)
        case .mergeLocal:
            WorkspaceSheetPickerLabel("MERGE STRATEGY")
            Picker("Merge strategy", selection: $strategy) { Text("Squash").tag("squash"); Text("Merge commit").tag("merge_commit"); Text("Fast-forward").tag("fast_forward") }
                .labelsHidden().pickerStyle(.segmented)
            if strategy == "squash" { WorkspaceSheetField(label: "SQUASH COMMIT SUBJECT", placeholder: "Summarize the integrated work", text: $subject) }
            WorkspaceSheetOptions { Toggle("Validate the isolated integration result", isOn: $validate) }
        case .createPullRequest:
            WorkspaceSheetField(label: "PULL REQUEST TITLE", placeholder: "Summarize the proposed change", text: $subject)
            WorkspaceSheetField(label: "DESCRIPTION", placeholder: "Explain what changed and how it was verified", text: $bodyText, multiline: true)
            WorkspaceSheetOptions {
                Toggle("Push branch before creating", isOn: $push)
                Divider().overlay(DieterTheme.border)
                Toggle("Create as draft", isOn: $draft)
            }
        case .mergePullRequest:
            WorkspaceSheetPickerLabel("MERGE STRATEGY")
            Picker("Merge strategy", selection: $strategy) { Text("Squash").tag("squash"); Text("Merge commit").tag("merge"); Text("Rebase").tag("rebase") }
                .labelsHidden().pickerStyle(.segmented)
            WorkspaceSheetNotice(title: "Head revision is protected", detail: "The provider verifies that the pull request head still matches this workspace before merging.", symbol: "lock.shield.fill", tint: DieterTheme.eyes)
        case .continueConflict:
            WorkspaceSheetNotice(title: "Confirm conflicts are resolved", detail: "Continue only after every conflict marker has been resolved and the files have been saved.", symbol: "exclamationmark.triangle.fill", tint: DieterTheme.amber)
            WorkspaceSheetOptions { Toggle("Run validation after continuing", isOn: $validate) }
        case .abortConflict:
            WorkspaceSheetNotice(title: "Restore the previous state", detail: operationDescription, symbol: "arrow.uturn.backward.circle.fill", tint: DieterTheme.amber)
        case .adopt:
            WorkspaceSheetField(label: "DESTINATION CARD ID", placeholder: "c_…", text: $adoptCardID)
            WorkspaceSheetNotice(title: "Transfer the complete workspace", detail: operationDescription, symbol: "arrow.right.arrow.left.circle.fill", tint: DieterTheme.shell)
        case .migrate:
            WorkspaceSheetNotice(title: "Isolate this conversation", detail: operationDescription, symbol: "rectangle.on.rectangle.angled", tint: DieterTheme.shell)
        case .push:
            WorkspaceSheetNotice(title: "Publish the workspace branch", detail: operationDescription, symbol: "arrow.up.circle.fill", tint: DieterTheme.shell)
            WorkspaceSheetOptions { Toggle("Force with lease", isOn: $forceWithLease) }
            if forceWithLease {
                WorkspaceSheetField(label: "EXPECTED REMOTE HEAD", placeholder: "Commit SHA", text: $expectedRemoteSHA)
                Text("The push is rejected if the remote branch no longer matches this exact revision.")
                    .font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        case .refreshPullRequest, .cleanup, .discard:
            WorkspaceSheetNotice(title: kind.title, detail: operationDescription, symbol: operationSymbol, tint: kind.destructive ? DieterTheme.coral : DieterTheme.shell)
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
        case .migrate: "rectangle.on.rectangle.angled"
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
        case .adopt: "Move this workspace, branch, recovery history, and terminal ownership to another unstarted conversation."
        case .migrate: "Convert this clean branch workspace into an isolated Git worktree."
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
        case .push: ["force_with_lease": String(forceWithLease), "expected_remote_sha": expectedRemoteSHA.trimmingCharacters(in: .whitespacesAndNewlines)]
        case .mergeLocal: ["strategy": strategy, "subject": subject, "validate": String(validate)]
        case .createPullRequest: ["title": subject, "body": bodyText, "draft": String(draft), "push": String(push)]
        case .mergePullRequest: ["strategy": strategy, "expected_head_sha": card?.pullRequest.headSha ?? ""]
        case .continueConflict: ["conflicted_operation_id": operation?.id ?? "", "validate": String(validate)]
        case .abortConflict: ["conflicted_operation_id": operation?.id ?? ""]
        case .adopt: ["target_card_id": adoptCardID.trimmingCharacters(in: .whitespacesAndNewlines)]
        case .migrate: ["mode": "worktree"]
        default: [:]
        }
    }

    private func start() {
        starting = true
        Task {
            let success = await store.startGitOperation(kind, parameters: parameters)
            starting = false
            if success { dismiss() }
        }
    }
}

struct ConversationWorkspaceSettingsSheet: View {
    @Environment(DieterStore.self) private var store
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
                            Button { mode = value } label: {
                                HStack(alignment: .top, spacing: 11) {
                                    Image(systemName: mode == value ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(mode == value ? DieterTheme.shell : DieterTheme.tertiary)
                                        .padding(.top, 1)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(value.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DieterTheme.text)
                                        Text(value.detail).font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary).fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(mode == value ? DieterTheme.selection : DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(mode == value ? DieterTheme.shell.opacity(0.35) : DieterTheme.border))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    WorkspaceSheetField(label: "BRANCH NAME", placeholder: "Optional — Dieter can generate one", text: $branch)
                    WorkspaceSheetField(label: "BASE BRANCH", placeholder: "Optional — uses the project default", text: $baseBranch)
                    WorkspaceSheetNotice(
                        title: "Locked when work begins",
                        detail: "Workspace mode, branch, and base branch cannot be changed after the first prompt starts.",
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
                    .disabled(saving || !card.workspace.revision.isEmpty).opacity(saving || !card.workspace.revision.isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 20).frame(height: 58).background(DieterTheme.sidebar)
        }
        .frame(width: 540).background(DieterTheme.background)
        .onAppear {
            mode = ConversationWorkspaceMode(rawValue: card.workspaceMode) ?? .main
            branch = card.workspaceBranch
            baseBranch = card.workspaceBaseBranch
        }
    }

    private func save() {
        saving = true
        Task {
            if await store.updateConversationWorkspace(.init(mode: mode, branch: branch, baseBranch: baseBranch)) {
                await store.loadWorkspaceSurface()
                dismiss()
            }
            saving = false
        }
    }
}

// MARK: - Toast

struct WorkspaceToastView: View {
    let toast: WorkspaceToast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(DieterTheme.eyes)
            Text(toast.message).font(.system(size: 12, weight: .medium)).foregroundStyle(DieterTheme.text)
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: 540)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16).frame(height: 40)
        .background(DieterTheme.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(DieterTheme.strongBorder))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        .accessibilityIdentifier("workspace-toast")
    }
}

// MARK: - Sheet primitives

private struct WorkspaceSheetHeader: View {
    let eyebrow: String
    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 36, height: 36).background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text(eyebrow).font(DieterFont.sectionLabel).tracking(0.5).foregroundStyle(tint)
                Text(title).font(.custom("Sora", size: 19).weight(.semibold)).foregroundStyle(DieterTheme.text)
                if !detail.isEmpty { Text(detail).font(DieterFont.subtitle).foregroundStyle(DieterTheme.tertiary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(DieterTheme.sidebar)
    }
}

private struct WorkspaceSheetField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var multiline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            WorkspaceSheetPickerLabel(label)
            if multiline {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(4...8).workspaceSheetInput(minHeight: 92, alignment: .topLeading)
            } else {
                TextField(placeholder, text: $text).workspaceSheetInput(minHeight: 36, alignment: .leading)
            }
        }
    }
}

private struct WorkspaceSheetPickerLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(DieterFont.sectionLabel).tracking(0.45).foregroundStyle(DieterTheme.tertiary)
    }
}

private struct WorkspaceSheetOptions<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 11) { content() }
            .font(DieterFont.body).toggleStyle(.switch).controlSize(.small)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.border))
    }
}

private struct WorkspaceSheetNotice: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(DieterTheme.text)
                Text(detail).font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(0.18)))
    }
}

private extension View {
    func workspaceSheetInput(minHeight: CGFloat, alignment: Alignment) -> some View {
        textFieldStyle(.plain).font(DieterFont.body).padding(.horizontal, 11).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: alignment)
            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.strongBorder))
    }
}
