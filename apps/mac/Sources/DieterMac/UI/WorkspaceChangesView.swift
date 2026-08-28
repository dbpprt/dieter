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

struct WorkspaceChangesView: View {
    @Environment(DieterStore.self) private var store
    @State private var operationKind: GitOperationKind?
    @State private var selectedCommentLine: UnifiedDiffLine?
    @State private var commentBody = ""

    private var card: Dieter_V1_Card? { store.selectedCard ?? store.selectedDetail?.card }
    private var workspace: Dieter_V1_Workspace? { store.conversationWorkspace }
    private var changes: Dieter_V1_Changeset? { store.conversationChangeset }
    private var pullRequest: Dieter_V1_PullRequestSummary? {
        guard let card, card.pullRequest.number > 0 else { return nil }
        return card.pullRequest
    }
    private var operationActive: Bool { store.gitOperation.map { GitOperationStatus.active($0.status) } ?? false }
    private var availability: WorkspaceActionAvailability {
        WorkspaceActionAvailability(
            agentActive: ["starting", "running", "working", "streaming", "waiting", "waiting_for_user", "cancelling"].contains((card?.runtime ?? "").lowercased()),
            operationActive: operationActive,
            workspaceState: workspace?.state ?? card?.workspace.state ?? "",
            workspaceMode: workspace?.mode ?? card?.workspace.mode ?? "main",
            changedFiles: Int(changes?.files.count ?? Int(card?.workspace.changedFiles ?? 0)),
            hasCommits: !(changes?.commits.isEmpty ?? true) || (workspace?.ahead ?? card?.workspace.ahead ?? 0) > 0,
            hasRemote: store.conversationSCMCapabilities?.pushAvailable ?? false,
            scmAuthenticated: store.conversationSCMCapabilities?.authenticated ?? false,
            hasPullRequest: pullRequest != nil
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            workspaceToolbar
            Divider().overlay(DieterTheme.border)
            if store.workspaceLoading && workspace == nil {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Preparing workspace and changes…").font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.workspaceError, workspace == nil {
                ContentUnavailableView("Workspace unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let workspace {
                VStack(spacing: 0) {
                    if workspace.state == "conflicted" || store.gitOperation?.status == "waiting_for_resolution" { conflictBanner }
                    if let operation = store.gitOperation { operationProgress(operation) }
                    changesSplit(workspace)
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
        .background(DieterTheme.background)
        .task(id: card?.id) {
            guard let id = card?.id, DieterConversationID.isServerBacked(id) else { return }
            await store.loadWorkspaceSurface()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled,
                      (store.selectedCardID ?? store.selectedChatID) == id else { return }
                let runtime = (store.selectedCard ?? store.selectedDetail?.card)?.runtime.lowercased() ?? ""
                if ["starting", "running", "working", "streaming", "waiting", "waiting_for_user", "cancelling"].contains(runtime) {
                    await store.loadWorkspaceSurface()
                }
            }
        }
        .sheet(item: $operationKind) { kind in
            GitOperationSheet(kind: kind, card: card, operation: store.gitOperation)
                .environment(store)
        }
        .popover(item: $selectedCommentLine) { line in
            VStack(alignment: .leading, spacing: 12) {
                Text("Comment on line \(line.newLine ?? line.oldLine ?? 0)").font(.headline)
                TextField("Review comment", text: $commentBody, axis: .vertical).lineLimit(3...8)
                HStack {
                    Spacer()
                    Button("Cancel") { selectedCommentLine = nil; commentBody = "" }
                    Button("Add comment") { addComment(line) }
                        .buttonStyle(.borderedProminent)
                        .disabled(commentBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16).frame(width: 390)
        }
    }

    private var workspaceToolbar: some View {
        HStack(spacing: 9) {
            if let workspace {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(DieterTheme.shell)
                VStack(alignment: .leading, spacing: 2) {
                    Text(workspace.branch.isEmpty ? ConversationWorkspaceMode.projectMode(workspace.mode).title : workspace.branch)
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text("\(ConversationWorkspaceMode.projectMode(workspace.mode).title) · base \(workspace.baseBranch.isEmpty ? "unconfigured" : workspace.baseBranch)")
                        .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                }
            } else {
                Text("Workspace changes").font(.system(size: 12, weight: .semibold))
            }
            Spacer()
            if availability.allows(.commit) { actionButton(.commit, icon: "checkmark.circle") }
            if availability.allows(.update) { actionButton(.update, icon: "arrow.triangle.2.circlepath") }
            Menu {
                operationMenu
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().buttonStyle(DieterIconButtonStyle())
            Button { Task { await store.loadWorkspaceSurface() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(DieterIconButtonStyle()).disabled(store.workspaceLoading)
        }
        .padding(.horizontal, 14).frame(height: 48).background(DieterTheme.sidebar)
    }

    @ViewBuilder private var operationMenu: some View {
        Button(GitOperationKind.validate.title, systemImage: "checkmark.seal") { operationKind = .validate }
            .disabled(!availability.allows(.validate))
        Button(GitOperationKind.mergeLocal.title, systemImage: "arrow.triangle.merge") { operationKind = .mergeLocal }
            .disabled(!availability.allows(.mergeLocal))
        Button(GitOperationKind.push.title, systemImage: "arrow.up.circle") { operationKind = .push }
            .disabled(!availability.allows(.push))
        Divider()
        if pullRequest == nil {
            Button(GitOperationKind.createPullRequest.title, systemImage: "arrow.triangle.pull") { operationKind = .createPullRequest }
                .disabled(!availability.allows(.createPullRequest))
        } else {
            Button(GitOperationKind.refreshPullRequest.title, systemImage: "arrow.clockwise") { operationKind = .refreshPullRequest }
                .disabled(!availability.allows(.refreshPullRequest))
            Button(GitOperationKind.mergePullRequest.title, systemImage: "arrow.triangle.merge") { operationKind = .mergePullRequest }
                .disabled(!availability.allows(.mergePullRequest))
            if let url = URL(string: pullRequest?.url ?? "") {
                Button("Open pull request", systemImage: "safari") { NSWorkspace.shared.open(url) }
            }
        }
        Divider()
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

    private func actionButton(_ kind: GitOperationKind, icon: String) -> some View {
        Button { operationKind = kind } label: { Label(kind == .commit ? "Commit" : "Update", systemImage: icon) }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private var conflictBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DieterTheme.coral)
            VStack(alignment: .leading, spacing: 2) {
                Text("Resolve Git conflicts in the workspace").font(.system(size: 12, weight: .semibold))
                Text(store.gitOperation?.conflicts.map(\.path).joined(separator: ", ") ?? "Review the conflicted files below, save the resolution, then continue.")
                    .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary).lineLimit(2)
            }
            Spacer()
            if let card {
                Button("Open Files") { Task { await store.openWorkspaceFiles(card: card) } }
            }
            Button("Abort", role: .destructive) { operationKind = .abortConflict }.disabled(operationActive && store.gitOperation?.status != "waiting_for_resolution")
            Button("Continue") { operationKind = .continueConflict }.buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14).padding(.vertical, 10).background(DieterTheme.coral.opacity(0.08))
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
            HStack {
                if GitOperationStatus.active(operation.status) { ProgressView().controlSize(.mini) }
                Text("\(GitOperationKind(rawValue: operation.kind)?.title ?? operation.kind) · \(operation.status.replacingOccurrences(of: "_", with: " ").capitalized)")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if GitOperationStatus.active(operation.status) && operation.status != "waiting_for_resolution" {
                    Button("Cancel") { Task { await store.cancelCurrentGitOperation() } }.controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9).background(DieterTheme.raised)
    }

    private func changesSplit(_ workspace: Dieter_V1_Workspace) -> some View {
        GeometryReader { geometry in
            if geometry.size.width < 720 {
                VStack(spacing: 0) {
                    changesSidebar(workspace).frame(height: min(300, geometry.size.height * 0.42))
                    Divider().overlay(DieterTheme.border)
                    diffView
                }
            } else {
                HSplitView {
                    changesSidebar(workspace).frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
                    diffView
                }
            }
        }
    }

    private func changesSidebar(_ workspace: Dieter_V1_Workspace) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                workspaceSummary(workspace)
                if let pullRequest { pullRequestSummary(pullRequest) }
                filesSection
                commitsSection
            }
            .padding(12)
        }
        .background(DieterTheme.sidebar)
    }

    private func workspaceSummary(_ workspace: Dieter_V1_Workspace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WORKSPACE").font(DieterFont.sectionLabel).foregroundStyle(DieterTheme.tertiary)
            LabeledContent("Mode", value: ConversationWorkspaceMode.projectMode(workspace.mode).title)
            LabeledContent("Branch", value: workspace.branch.isEmpty ? "—" : workspace.branch)
            LabeledContent("Ahead / behind", value: "\(workspace.ahead) / \(workspace.behind)")
            if let capabilities = store.conversationSCMCapabilities {
                LabeledContent("Remote", value: capabilities.remote.isEmpty ? "None" : capabilities.remote)
                LabeledContent("Provider", value: capabilities.provider.isEmpty ? "Local Git" : capabilities.provider.capitalized)
                if !capabilities.authenticated && !capabilities.unavailableReason.isEmpty {
                    Text(capabilities.unavailableReason).foregroundStyle(DieterTheme.amber).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                Text("+\(changes?.additions ?? workspace.additions)").foregroundStyle(DieterTheme.eyes)
                Text("−\(changes?.deletions ?? workspace.deletions)").foregroundStyle(DieterTheme.coral)
                Spacer()
                Text(workspace.state.replacingOccurrences(of: "_", with: " ").capitalized)
            }
            .font(.system(size: 10, weight: .semibold))
            Button("Reveal workspace in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.path) }
                .font(.system(size: 10))
        }
        .font(.system(size: 10)).padding(12).dieterSurface(radius: 8)
    }

    private func pullRequestSummary(_ pr: Dieter_V1_PullRequestSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "arrow.triangle.pull").foregroundStyle(DieterTheme.shell)
                Text("Pull request #\(pr.number)").font(.system(size: 11, weight: .semibold))
                Spacer()
                StatusPill(text: pr.state, color: pr.state == "open" ? DieterTheme.eyes : DieterTheme.tertiary)
            }
            HStack(spacing: 8) {
                Text(pr.draft ? "Draft" : "Ready")
                if !pr.checksState.isEmpty { Text("Checks: \(pr.checksState)") }
                if !pr.reviewDecision.isEmpty { Text("Review: \(pr.reviewDecision)") }
            }
            .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
        }
        .padding(12).dieterSurface(radius: 8)
    }

    @ViewBuilder private var filesSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("CHANGED FILES · \(changes?.files.count ?? 0)").font(DieterFont.sectionLabel).foregroundStyle(DieterTheme.tertiary)
            if changes?.files.isEmpty != false {
                Text("No uncommitted changes").font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary).padding(.vertical, 5)
            }
            ForEach(changes?.files ?? [], id: \.path) { file in
                Button { Task { await store.loadConversationDiff(path: file.path) } } label: {
                    HStack(spacing: 7) {
                        Text(file.status.uppercased()).font(.system(size: 8, weight: .bold, design: .monospaced)).frame(width: 15)
                            .foregroundStyle(file.conflicted ? DieterTheme.coral : DieterTheme.shell)
                        Text(file.path).font(.system(size: 10, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("+\(file.additions)").foregroundStyle(DieterTheme.eyes)
                        Text("−\(file.deletions)").foregroundStyle(DieterTheme.coral)
                    }
                    .padding(.horizontal, 8).frame(height: 29)
                    .background(store.selectedChangePath == file.path && store.selectedCommitSHA.isEmpty ? DieterTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var commitsSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("COMMITS · \(changes?.commits.count ?? 0)").font(DieterFont.sectionLabel).foregroundStyle(DieterTheme.tertiary)
            if changes?.commits.isEmpty != false {
                Text("No commits ahead of base").font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary).padding(.vertical, 5)
            }
            ForEach(changes?.commits ?? [], id: \.sha) { commit in
                Button { Task { await store.loadConversationDiff(path: "", commitSHA: commit.sha) } } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(commit.shortSha).font(.system(size: 9, design: .monospaced)).foregroundStyle(DieterTheme.shell); Text(commit.subject).lineLimit(1); Spacer() }
                        Text("\(commit.authorName) · \(commit.changedFiles) files · +\(commit.additions) −\(commit.deletions)")
                            .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
                    }
                    .padding(8).background(store.selectedCommitSHA == commit.sha ? DieterTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var diffView: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.selectedCommitSHA.isEmpty ? (store.selectedChangePath.isEmpty ? "Diff" : store.selectedChangePath) : "Commit \(store.selectedCommitSHA.prefix(10))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let diff = store.conversationDiff { Text(ByteCountFormatter.string(fromByteCount: diff.totalBytes, countStyle: .file)).font(.caption2).foregroundStyle(DieterTheme.tertiary) }
            }
            .padding(.horizontal, 12).frame(height: 37).background(DieterTheme.sidebar)
            Divider().overlay(DieterTheme.border)
            if let diff = store.conversationDiff {
                if diff.binary {
                    ContentUnavailableView("Binary diff", systemImage: "doc.badge.ellipsis", description: Text("This file cannot be rendered as text."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(UnifiedDiffParser.parse(diff.patch)) { line in diffLine(line) }
                            if diff.truncated {
                                Button("Load more") { Task { await store.loadConversationDiff(path: diff.path, commitSHA: diff.commitSha, append: true) } }
                                    .padding(12)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Select a change", systemImage: "doc.text.magnifyingglass", description: Text("Choose a changed file or commit to inspect its diff."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func diffLine(_ line: UnifiedDiffLine) -> some View {
        let side = line.kind == .deletion ? "old" : "new"
        let number = line.kind == .deletion ? line.oldLine : line.newLine
        let comments = store.conversationChangeComments.filter { $0.path == store.selectedChangePath && $0.side == side && $0.line == Int32(number ?? -1) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Text(line.oldLine.map(String.init) ?? "").frame(width: 42, alignment: .trailing)
                Text(line.newLine.map(String.init) ?? "").frame(width: 42, alignment: .trailing)
                if number != nil && store.selectedCommitSHA.isEmpty {
                    Button { selectedCommentLine = line } label: { Image(systemName: "plus").font(.system(size: 8, weight: .bold)).frame(width: 22, height: 17) }
                        .buttonStyle(.plain).foregroundStyle(DieterTheme.shell).help("Add comment")
                } else { Color.clear.frame(width: 22, height: 17) }
                Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(diffForeground(line.kind))
            .padding(.vertical, 1).padding(.trailing, 10)
            .background(diffBackground(line.kind))
            ForEach(comments, id: \.id) { comment in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "text.bubble.fill").foregroundStyle(DieterTheme.shell)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(comment.body).textSelection(.enabled)
                        Text(comment.author.isEmpty ? comment.createdAt : "\(comment.author) · \(comment.createdAt)").font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    }
                }
                .font(.system(size: 10)).padding(8).padding(.leading, 84).background(DieterTheme.raised)
            }
        }
    }

    private func diffBackground(_ kind: UnifiedDiffLine.Kind) -> Color {
        switch kind { case .addition: DieterTheme.eyes.opacity(0.10); case .deletion: DieterTheme.coral.opacity(0.10); case .hunk: DieterTheme.shell.opacity(0.10); default: .clear }
    }

    private func diffForeground(_ kind: UnifiedDiffLine.Kind) -> Color {
        switch kind { case .addition: DieterTheme.eyes; case .deletion: DieterTheme.coral; case .header, .hunk: DieterTheme.shell; default: DieterTheme.text }
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
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Image(systemName: kind.destructive ? "exclamationmark.triangle.fill" : "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(kind.destructive ? DieterTheme.coral : DieterTheme.shell)
                Text(kind.title).font(.title2.weight(.bold))
            }
            operationFields
            if kind == .discard {
                Text("Dieter creates recovery artifacts before removing this workspace, but uncommitted changes and its managed branch will be removed from active use.")
                    .font(.caption).foregroundStyle(DieterTheme.coral)
            } else if kind == .cleanup {
                Text("Cleanup succeeds only after the branch is integrated and the workspace is clean.").font(.caption).foregroundStyle(DieterTheme.tertiary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(kind.title, role: kind.destructive ? .destructive : nil) { start() }
                    .buttonStyle(.borderedProminent).disabled(starting || !valid)
            }
        }
        .padding(22).frame(width: 520)
        .onAppear {
            subject = card?.title ?? ""
            bodyText = card?.initialPrompt ?? ""
            expectedRemoteSHA = card?.pullRequest.headSha ?? ""
        }
    }

    @ViewBuilder private var operationFields: some View {
        switch kind {
        case .commit:
            TextField("Commit subject", text: $subject)
            TextField("Optional commit body", text: $bodyText, axis: .vertical).lineLimit(3...7)
            Toggle("Include untracked files", isOn: $includeUntracked)
        case .update:
            Toggle("Fetch the configured base remote", isOn: $fetch)
            Toggle("Run project validation after rebasing", isOn: $validate)
        case .validate:
            Text("Run all validation commands configured for this project inside the conversation workspace.").font(.callout).foregroundStyle(DieterTheme.tertiary)
        case .mergeLocal:
            Picker("Strategy", selection: $strategy) { Text("Squash").tag("squash"); Text("Merge commit").tag("merge_commit"); Text("Fast-forward").tag("fast_forward") }
            if strategy == "squash" { TextField("Squash commit subject", text: $subject) }
            Toggle("Validate the isolated integration result", isOn: $validate)
        case .createPullRequest:
            TextField("Pull request title", text: $subject)
            TextField("Description", text: $bodyText, axis: .vertical).lineLimit(4...9)
            Toggle("Push branch first", isOn: $push)
            Toggle("Create as draft", isOn: $draft)
        case .mergePullRequest:
            Picker("Strategy", selection: $strategy) { Text("Squash").tag("squash"); Text("Merge commit").tag("merge"); Text("Rebase").tag("rebase") }
            Text("The provider will verify that the pull request head still matches the workspace.").font(.caption).foregroundStyle(DieterTheme.tertiary)
        case .continueConflict:
            Toggle("Run validation after continuing", isOn: $validate)
            Text("Continue only after every conflict marker has been resolved and the files have been saved.").font(.callout).foregroundStyle(DieterTheme.tertiary)
        case .abortConflict:
            Text("Abort the active rebase or merge and restore the workspace to its previous ready state.").font(.callout).foregroundStyle(DieterTheme.tertiary)
        case .adopt:
            TextField("Destination card ID", text: $adoptCardID)
            Text("Move this workspace, branch, recovery history, and terminal ownership to another unstarted conversation.").font(.caption).foregroundStyle(DieterTheme.tertiary)
        case .migrate:
            Text("Convert this clean branch workspace into an isolated Git worktree.").font(.callout).foregroundStyle(DieterTheme.tertiary)
        case .push:
            Toggle("Force with lease", isOn: $forceWithLease)
            if forceWithLease {
                TextField("Expected remote head SHA", text: $expectedRemoteSHA)
                Text("The push is rejected if the remote branch no longer matches this exact revision.").font(.caption).foregroundStyle(DieterTheme.tertiary)
            } else {
                Text(operationDescription).font(.callout).foregroundStyle(DieterTheme.tertiary)
            }
        case .refreshPullRequest, .cleanup, .discard:
            Text(operationDescription).font(.callout).foregroundStyle(DieterTheme.tertiary)
        }
    }

    private var operationDescription: String {
        switch kind {
        case .push: "Push this workspace branch to its configured remote and establish upstream tracking."
        case .refreshPullRequest: "Refresh state, checks, review decision, and head/base revisions from the provider."
        case .cleanup: "Remove this clean, integrated workspace and its managed branch."
        case .discard: "Remove the workspace even when it contains unintegrated work."
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
        VStack(alignment: .leading, spacing: 15) {
            Text("Conversation workspace").font(.title2.weight(.bold))
            Text("Workspace settings are locked after the first prompt starts.").font(.caption).foregroundStyle(DieterTheme.tertiary)
            Picker("Mode", selection: $mode) {
                ForEach(ConversationWorkspaceMode.allCases.filter { $0 != .projectDefault }) { value in Text(value.title).tag(value) }
            }
            Text(mode.detail).font(.caption).foregroundStyle(DieterTheme.tertiary)
            TextField("Optional branch name", text: $branch)
            TextField("Optional base branch override", text: $baseBranch)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(saving || !card.workspace.revision.isEmpty)
            }
        }
        .padding(22).frame(width: 500)
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
