import AppKit
import DieterAPI
import SwiftUI

struct WorkspaceSummaryBadge: View {
    let card: Dieter_V1_Card
    var compact = false

    private var summary: Dieter_V1_WorkspaceSummary { card.workspace }
    private var mode: String { summary.mode.isEmpty ? card.workspaceMode : summary.mode }
    private var title: String {
        let modeTitle = ConversationWorkspaceMode.projectMode(mode).shortTitle
        if summary.state == "conflicted" { return "Conflicts" }
        if card.pullRequest.number > 0 { return "PR #\(card.pullRequest.number)" }
        if summary.changedFiles > 0 { return "\(summary.changedFiles) changed" }
        return modeTitle
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: summary.state == "conflicted" ? "exclamationmark.triangle.fill" : (card.pullRequest.number > 0 ? "arrow.triangle.pull" : "point.3.connected.trianglepath.dotted"))
            Text(title)
        }
        .font(.system(size: compact ? 9 : 10, weight: .semibold))
        .foregroundStyle(summary.state == "conflicted" ? DieterTheme.coral : DieterTheme.shell)
        .lineLimit(1)
        .help(workspaceHelp)
    }

    private var workspaceHelp: String {
        var pieces = [ConversationWorkspaceMode.projectMode(mode).title]
        let branch = summary.branch.isEmpty ? card.workspaceBranch : summary.branch
        if !branch.isEmpty { pieces.append(branch) }
        if summary.ahead > 0 || summary.behind > 0 { pieces.append("↑\(summary.ahead) ↓\(summary.behind)") }
        return pieces.joined(separator: " · ")
    }
}

private enum WorkspaceCompactPane: String, CaseIterable, Identifiable {
    case files = "Changes"
    case diff = "Diff"
    var id: String { rawValue }
}

struct WorkspaceChangesView: View {
    @Environment(DieterStore.self) private var store
    @State private var operationKind: GitOperationKind?
    @State private var selectedCommentLine: UnifiedDiffLine?
    @State private var commentBody = ""
    @State private var compactPane: WorkspaceCompactPane = .files

    private var card: Dieter_V1_Card? { store.selectedCard ?? store.selectedDetail?.card }
    private var workspace: Dieter_V1_Workspace? { store.conversationWorkspace }
    private var changes: Dieter_V1_Changeset? { store.conversationChangeset }
    private var pullRequest: Dieter_V1_PullRequestSummary? {
        guard let card, card.pullRequest.number > 0 else { return nil }
        return card.pullRequest
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
            hasPullRequest: pullRequest != nil
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = WorkspaceReviewLayout.isCompact(width: geometry.size.width)
            VStack(spacing: 0) {
                workspaceToolbar(compact: compact)
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
        .sheet(item: $operationKind) { kind in
            GitOperationSheet(kind: kind, card: card, operation: store.gitOperation).environment(store)
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
            ContentUnavailableView("No workspace", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Choose workspace settings before starting this conversation."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func workspaceToolbar(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DieterTheme.selection)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(DieterTheme.shell)
            }
            .frame(width: 30, height: 30)
            if let workspace {
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.branch.isEmpty ? ConversationWorkspaceMode.projectMode(workspace.mode).title : workspace.branch)
                        .font(DieterFont.title).lineLimit(1).truncationMode(.middle)
                    if !compact {
                        HStack(spacing: 5) {
                            Text(ConversationWorkspaceMode.projectMode(workspace.mode).title)
                            Text("·")
                            Text("base \(workspace.baseBranch.isEmpty ? "unconfigured" : workspace.baseBranch)")
                            Text("·")
                            Text(workspace.state.replacingOccurrences(of: "_", with: " ").capitalized)
                        }
                        .font(DieterFont.subtitle).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                    }
                }
                .frame(minWidth: 0, maxWidth: compact ? 150 : 280, alignment: .leading)
            } else {
                Text("Workspace changes").font(DieterFont.title)
            }
            Spacer(minLength: 6)
            if !compact, let workspace {
                WorkspaceDeltaLabel(additions: changes?.additions ?? workspace.additions, deletions: changes?.deletions ?? workspace.deletions)
                if workspace.ahead > 0 || workspace.behind > 0 {
                    Text("↑\(workspace.ahead) ↓\(workspace.behind)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(DieterTheme.tertiary)
                }
            }
            primaryAction(compact: compact)
            Menu { operationMenu } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().buttonStyle(DieterIconButtonStyle())
                .help("Workspace actions")
            Button { Task { await store.loadWorkspaceSurface() } } label: {
                if store.workspaceLoading { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(DieterIconButtonStyle()).disabled(store.workspaceLoading).help("Refresh changes")
        }
        .padding(.horizontal, 14).frame(height: compact ? 52 : 56).background(DieterTheme.sidebar)
    }

    @ViewBuilder private func primaryAction(compact: Bool) -> some View {
        if availability.allows(.commit) {
            Button { operationKind = .commit } label: {
                Label(compact ? "Commit" : "Commit changes", systemImage: "checkmark.circle")
            }
            .buttonStyle(DieterPrimaryButtonStyle())
        } else if let pullRequest, let url = URL(string: pullRequest.url) {
            Button { NSWorkspace.shared.open(url) } label: {
                Label(compact ? "PR" : "Open PR #\(pullRequest.number)", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(DieterPrimaryButtonStyle())
        } else if availability.allows(.createPullRequest) {
            Button { operationKind = .createPullRequest } label: {
                Label(compact ? "PR" : "Create pull request", systemImage: "arrow.triangle.pull")
            }
            .buttonStyle(DieterPrimaryButtonStyle())
        } else if availability.allows(.push) {
            Button { operationKind = .push } label: { Label("Push", systemImage: "arrow.up") }
                .buttonStyle(DieterPrimaryButtonStyle())
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
            Button(GitOperationKind.mergeLocal.title, systemImage: "arrow.triangle.merge") { operationKind = .mergeLocal }
                .disabled(!availability.allows(.mergeLocal))
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

    private var conflictBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DieterTheme.coral)
            VStack(alignment: .leading, spacing: 2) {
                Text("Resolve conflicts before continuing").font(.system(size: 12, weight: .semibold))
                Text(store.gitOperation?.conflicts.map(\.path).joined(separator: ", ") ?? "Open the workspace files, resolve every marker, then continue.")
                    .font(DieterFont.subtitle).foregroundStyle(DieterTheme.tertiary).lineLimit(2)
            }
            Spacer()
            if let card {
                Button("Open Files") { Task { await store.openWorkspaceFiles(card: card) } }.buttonStyle(DieterSecondaryButtonStyle())
            }
            Button("Abort") { operationKind = .abortConflict }.buttonStyle(DieterSecondaryButtonStyle(destructive: true))
                .disabled(operationActive && store.gitOperation?.status != "waiting_for_resolution")
            Button("Continue") { operationKind = .continueConflict }.buttonStyle(DieterPrimaryButtonStyle())
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(DieterTheme.coral.opacity(0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(DieterTheme.coral.opacity(0.22)).frame(height: 1) }
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
                reviewNavigator(workspace: workspace, compact: false).frame(minWidth: 248, idealWidth: 292, maxWidth: 330)
                diffView(compact: false).frame(minWidth: 360)
            }
        }
    }

    private func reviewNavigator(workspace: Dieter_V1_Workspace, compact: Bool) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let pullRequest { pullRequestRow(pullRequest) }
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

    private func pullRequestRow(_ pr: Dieter_V1_PullRequestSummary) -> some View {
        Button {
            if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.pull").foregroundStyle(DieterTheme.shell).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pull request #\(pr.number)").font(.system(size: 11, weight: .semibold))
                    Text(pr.draft ? "Draft" : (pr.checksState.isEmpty ? pr.state.capitalized : "Checks \(pr.checksState)"))
                        .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(DieterTheme.tertiary)
            }
            .padding(.horizontal, 10).frame(height: 44).background(DieterTheme.selection, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func filesSection(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkspaceSectionHeader(title: "Working changes", count: changes?.files.count ?? 0, additions: changes?.additions, deletions: changes?.deletions)
            if changes?.files.isEmpty != false {
                WorkspaceEmptyRow(symbol: "checkmark.circle", title: "Working tree is clean")
            }
            ForEach(changes?.files ?? [], id: \.path) { file in
                WorkspaceFileRow(file: file, selected: store.selectedChangePath == file.path && store.selectedCommitSHA.isEmpty) {
                    compactPane = .diff
                    Task { await store.loadConversationDiff(path: file.path) }
                }
            }
        }
    }

    private func commitsSection(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkspaceSectionHeader(title: "Commits ahead", count: changes?.commits.count ?? 0)
            if changes?.commits.isEmpty != false {
                WorkspaceEmptyRow(symbol: "arrow.triangle.branch", title: "No commits ahead of base")
            }
            ForEach(changes?.commits ?? [], id: \.sha) { commit in
                WorkspaceCommitRow(commit: commit, selected: store.selectedCommitSHA == commit.sha) {
                    compactPane = .diff
                    Task { await store.loadConversationDiff(path: "", commitSHA: commit.sha) }
                }
            }
        }
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
            if let remote = store.conversationSCMCapabilities?.remote, !remote.isEmpty { Text("· \(remote)") }
            Spacer()
            Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.path) } label: { Image(systemName: "finder") }
                .buttonStyle(DieterIconButtonStyle()).help("Reveal workspace in Finder")
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(DieterTheme.tertiary)
        .padding(.horizontal, 10).frame(height: 42)
    }

    private func diffView(compact: Bool) -> some View {
        VStack(spacing: 0) {
            diffHeader(compact: compact)
            Divider().overlay(DieterTheme.border)
            if let diff = store.conversationDiff {
                if diff.binary {
                    ContentUnavailableView("Binary diff", systemImage: "doc.badge.ellipsis", description: Text("This file cannot be rendered as text."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GeometryReader { viewport in
                        ScrollView([.horizontal, .vertical]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(UnifiedDiffParser.parse(diff.patch)) { line in
                                    diffLine(line, minimumWidth: max(0, viewport.size.width))
                                }
                                if diff.truncated {
                                    Button("Load the rest of this diff") {
                                        Task { await store.loadConversationDiff(path: diff.path, commitSHA: diff.commitSha, append: true) }
                                    }
                                    .buttonStyle(DieterSecondaryButtonStyle()).padding(12)
                                }
                            }
                            .frame(minWidth: max(0, viewport.size.width), alignment: .topLeading)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            } else {
                ContentUnavailableView("Select a change", systemImage: "doc.text.magnifyingglass", description: Text("Choose a changed file or commit to inspect its diff."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DieterTheme.background)
    }

    private func diffHeader(compact: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: store.selectedCommitSHA.isEmpty ? "doc.text" : "point.3.connected.trianglepath.dotted")
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
            if !compact, let diff = store.conversationDiff {
                Text(ByteCountFormatter.string(fromByteCount: diff.totalBytes, countStyle: .file)).font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
            if let card, !store.selectedChangePath.isEmpty {
                Button { Task { await store.openWorkspaceFiles(card: card, opening: store.selectedChangePath) } } label: { Image(systemName: "pencil") }
                    .buttonStyle(DieterIconButtonStyle()).help("Open file in workspace editor")
            }
        }
        .padding(.horizontal, 12).frame(height: 46).background(DieterTheme.sidebar)
    }

    private var diffTitle: String {
        if !store.selectedCommitSHA.isEmpty { return "Commit \(store.selectedCommitSHA.prefix(10))" }
        return store.selectedChangePath.isEmpty ? "Diff" : store.selectedChangePath
    }

    private func diffLine(_ line: UnifiedDiffLine, minimumWidth: CGFloat) -> some View {
        let side = line.kind == .deletion ? "old" : "new"
        let number = line.kind == .deletion ? line.oldLine : line.newLine
        let comments = store.conversationChangeComments.filter {
            $0.path == store.selectedChangePath && $0.side == side && $0.line == Int32(number ?? -1)
        }
        return WorkspaceDiffLineRow(
            line: line,
            comments: comments,
            canComment: number != nil && store.selectedCommitSHA.isEmpty,
            minimumWidth: minimumWidth,
            addComment: { selectedCommentLine = line }
        )
    }

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
    let action: () -> Void

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
                    Text(WorkspaceChangePresentation.filename(file.path)).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    let directory = WorkspaceChangePresentation.directory(file.path)
                    if !directory.isEmpty { Text(directory).font(.system(size: 9, design: .monospaced)).foregroundStyle(DieterTheme.tertiary).lineLimit(1).truncationMode(.middle) }
                }
                Spacer(minLength: 5)
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
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 10)).foregroundStyle(DieterTheme.shell).frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(commit.subject).font(.system(size: 11, weight: .medium)).lineLimit(2)
                    HStack(spacing: 5) {
                        Text(commit.shortSha).font(.system(size: 9, design: .monospaced)).foregroundStyle(DieterTheme.shell)
                        Text("· \(commit.changedFiles) files").font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
                    }
                }
                Spacer(minLength: 5)
                WorkspaceDeltaLabel(additions: commit.additions, deletions: commit.deletions)
            }
            .padding(8).frame(minHeight: 46)
            .background(selected ? DieterTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    @State private var mode: ConversationWorkspaceMode = .projectDefault
    @State private var branch = ""
    @State private var baseBranch = ""
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceSheetHeader(
                eyebrow: "CONVERSATION SETUP",
                title: "Workspace",
                detail: "Choose where this conversation will work before its first prompt starts.",
                symbol: "point.3.connected.trianglepath.dotted",
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
