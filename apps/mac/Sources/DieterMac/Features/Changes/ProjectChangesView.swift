import AppKit
import DieterAPI
import SwiftUI

private struct ProjectChangeRow: Identifiable {
    let file: Dieter_V1_ChangedFile
    let section: String
    var id: ProjectChangeSelection { .init(path: file.path, section: section) }
}

struct ProjectChangesView: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("DieterDiffViewMode") private var diffMode = "Inline"
    @State private var filter = ""
    @State private var showCompactDiff = false
    @State private var discardPath: String?
    @FocusState private var fileListFocused: Bool
    private var model: ProjectChangesModel { store.projectChanges }
    private var targetKey: String {
        "\(store.selectedProjectID)|\(store.endpoint.id)|\(store.connectionGeneration)|\(store.phase.isConnected)|\(scenePhase)"
    }
    private var ready: Bool { model.projectID == store.selectedProjectID }
    private var canMutate: Bool { ready && store.phase.isConnected && !model.mutationsDisabled }
    private var selectedFile: Dieter_V1_ChangedFile? { model.changes?.files.first { $0.path == model.selection?.path } }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 900
            VStack(spacing: 0) {
                if compact {
                    if showCompactDiff, ready, model.selection != nil { diffPane(compact: true) } else { fileNavigator }
                } else {
                    HSplitView {
                        fileNavigator.frame(minWidth: 280, idealWidth: 350, maxWidth: 380)
                        diffPane(compact: false).frame(minWidth: 440)
                    }
                }
                feedback
            }
            .onChange(of: compact) { _, compact in
                if compact, model.selection != nil { showCompactDiff = true }
            }
        }
        .foregroundStyle(DieterTheme.text)
        .background(DieterTheme.background)
        .task(id: targetKey) {
            guard scenePhase == .active else { return }
            guard store.phase.isConnected, let rpc = store.rpc else { model.suspend(); return }
            guard
                store.projectEndpointIDs[store.selectedProjectID] == nil
                    || store.projectEndpointIDs[store.selectedProjectID] == store.endpoint.id
            else { return }
            model.bind(projectID: store.selectedProjectID, client: rpc)
            await model.refresh()
            while !Task.isCancelled {
                try? await DieterTaskSleep.seconds(2)
                guard !Task.isCancelled else { return }
                await model.refresh()
            }
        }
        .onDisappear { model.suspend() }
        .confirmationDialog(
            "Discard changes to \(discardPath ?? "this file")?",
            isPresented: Binding(
                get: { discardPath != nil }, set: { if !$0 { discardPath = nil } }
            ), presenting: discardPath
        ) { path in
            Button("Discard changes", role: .destructive) {
                model.startOperation(kind: "discard_changes", path: path)
                discardPath = nil
            }
            .accessibilityIdentifier("project-changes.confirm-discard")
            .smokeTarget("project-changes.confirm-discard")
            Button("Cancel", role: .cancel) { discardPath = nil }
        } message: { path in
            Text(
                "Discard staged and unstaged changes to \(path). Dieter saves a recovery copy first, then restores the file to HEAD. Untracked files are removed."
            )
        }
    }

    private var navigatorHeader: some View {
        HStack(spacing: 9) {
            Text("Changes").font(.system(size: 17, weight: .semibold))
            Text(store.selectedProject?.name ?? "Project").font(.system(size: 12))
                .foregroundStyle(DieterTheme.tertiary).lineLimit(1)
            Spacer(minLength: 0)
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(DieterIconButtonStyle()).disabled(model.refreshing).help("Refresh changes")
            .accessibilityLabel("Refresh changes").accessibilityIdentifier("project-changes.refresh")
            .smokeTarget("project-changes.refresh")
        }.padding(.horizontal, 16).frame(height: 58)
    }

    private var initialState: some View {
        Group {
            if ready, let error = model.refreshError {
                ContentUnavailableView {
                    Label("Changes unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await model.refresh() } }
                }
            } else {
                ProgressView("Reading changes…")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileNavigator: some View {
        VStack(spacing: 0) {
            navigatorHeader
            if ready, model.changes != nil {
                commitComposer.padding(.horizontal, 14)
                branchStrip.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary)
                    TextField(
                        "Filter files", text: $filter,
                        prompt: Text("Filter files").foregroundStyle(DieterTheme.tertiary)
                    )
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .accessibilityIdentifier("project-changes.filter").smokeTarget("project-changes.filter")
                    if !filter.isEmpty {
                        Button {
                            filter = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain).foregroundStyle(DieterTheme.tertiary).accessibilityLabel(
                            "Clear file filter")
                    }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(DieterTheme.border) }
                .padding(.horizontal, 14).padding(.bottom, 6)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            fileSection("Staged", section: "staged", files: model.stagedFiles)
                            fileSection("Changes", section: "unstaged", files: model.unstagedFiles)
                        }.padding(.horizontal, 10).padding(.bottom, 14)
                    }
                    .focusable().focused($fileListFocused).focusEffectDisabled()
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1); return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1); return .handled
                    }
                    .onChange(of: model.selection) { _, selection in
                        if let selection { proxy.scrollTo(selection) }
                    }
                    .accessibilityElement(children: .contain).accessibilityLabel("Changed files")
                    .accessibilityIdentifier("project-changes.files").smokeTarget("project-changes.files")
                }
            } else {
                initialState
            }
        }.background(DieterTheme.sidebar)
    }

    private var commitComposer: some View {
        @Bindable var model = model
        let count = model.stagedFiles.count
        return VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                TextField(
                    "Commit subject", text: $model.commitSubject,
                    prompt: Text("Commit subject").foregroundStyle(DieterTheme.tertiary)
                )
                .font(.system(size: 13, weight: .medium)).padding(.horizontal, 10).frame(height: 36)
                .accessibilityIdentifier("project-changes.commit-subject").smokeTarget("project-changes.commit-subject")
                Divider().overlay(DieterTheme.border)
                TextField(
                    "Description (optional)", text: $model.commitBody,
                    prompt: Text("Description (optional)").foregroundStyle(DieterTheme.tertiary), axis: .vertical
                )
                .font(.system(size: 12)).lineLimit(3...5).padding(10)
                .accessibilityIdentifier("project-changes.commit-body").smokeTarget("project-changes.commit-body")
                HStack {
                    Text(count == 0 ? "Stage files to commit" : "Only staged changes will be committed")
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(model.commitSubject.count)/72").monospacedDigit()
                        .foregroundStyle(model.commitSubject.count > 72 ? DieterTheme.amber : DieterTheme.tertiary)
                }.font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary).padding(.horizontal, 10).padding(
                    .bottom, 9)
            }
            .textFieldStyle(.plain).disabled(model.pendingKind == "commit")
            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.border) }
            Button {
                model.startOperation(
                    kind: "commit",
                    parameters: [
                        "subject": model.commitSubject.trimmingCharacters(in: .whitespacesAndNewlines),
                        "body": model.commitBody, "validate": "false",
                    ])
            } label: {
                HStack(spacing: 6) {
                    if model.pendingKind == "commit" { ProgressView().controlSize(.mini) }
                    Text(
                        model.pendingKind == "commit"
                            ? "Committing…"
                            : count == 0 ? "Commit staged changes" : "Commit \(count) \(count == 1 ? "file" : "files")")
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(ChangesActionButtonStyle(prominent: true))
            .disabled(
                !canMutate || count == 0 || model.commitSubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .accessibilityIdentifier("project-changes.commit").smokeTarget("project-changes.commit")
        }
    }

    private var branchStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
            Text(model.changes?.branch.isEmpty == false ? model.changes!.branch : "Detached HEAD")
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if let base = model.changes?.baseBranch, !base.isEmpty, base != model.changes?.branch {
                Text("→ \(base)").lineLimit(1)
            }
        }.font(.system(size: 10, design: .monospaced)).foregroundStyle(DieterTheme.tertiary)
    }

    private func fileSection(_ title: String, section: String, files: [Dieter_V1_ChangedFile]) -> some View {
        Section {
            let visible = files.filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) }
            if visible.isEmpty {
                Text(
                    files.isEmpty ? (section == "staged" ? "No staged files" : "No local changes") : "No matching files"
                )
                .font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary)
                .padding(.leading, 24).padding(.vertical, 8)
            }
            ForEach(visible.map { ProjectChangeRow(file: $0, section: section) }) { row in
                fileRow(row.file, section: section).id(row.id)
            }
        } header: {
            HStack(spacing: 6) {
                Text(title.uppercased()).tracking(0.8)
                Text("\(files.count)").monospacedDigit()
                Spacer()
                if !files.isEmpty {
                    Button(section == "staged" ? "Unstage all" : "Stage all") {
                        model.startOperation(kind: section == "staged" ? "unstage" : "stage")
                    }
                    .buttonStyle(.plain).font(.system(size: 10)).disabled(!canMutate)
                    .accessibilityIdentifier("project-changes.\(section == "staged" ? "unstage" : "stage")-all")
                    .smokeTarget("project-changes.\(section == "staged" ? "unstage" : "stage")-all")
                }
            }.font(.system(size: 10, weight: .semibold)).foregroundStyle(DieterTheme.tertiary)
                .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 5)
        }
    }

    private func moveSelection(by offset: Int) {
        let choices =
            model.stagedFiles.map { ProjectChangeSelection(path: $0.path, section: "staged") }
            + model.unstagedFiles.map { ProjectChangeSelection(path: $0.path, section: "unstaged") }
        let visible = choices.filter { filter.isEmpty || $0.path.localizedCaseInsensitiveContains(filter) }
        guard !visible.isEmpty else { return }
        let index = model.selection.flatMap { visible.firstIndex(of: $0) } ?? (offset > 0 ? -1 : 0)
        model.select(visible[min(max(index + offset, 0), visible.count - 1)])
    }

    private func fileRow(_ file: Dieter_V1_ChangedFile, section: String) -> some View {
        let status = section == "staged" ? file.indexStatus : file.worktreeStatus
        let stage = section != "staged"
        let selection = ProjectChangeSelection(path: file.path, section: section)
        let selected = model.selection == selection
        return HStack(spacing: 7) {
            Button {
                model.startOperation(kind: stage ? "stage" : "unstage", path: file.path)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 3).fill(stage ? .clear : DieterTheme.reviewAccent)
                    RoundedRectangle(cornerRadius: 3).stroke(
                        stage ? DieterTheme.strongBorder : DieterTheme.reviewAccent)
                    if !stage {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(
                            Color.black.opacity(0.8))
                    }
                }.frame(width: 14, height: 14).padding(3).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!canMutate).opacity(canMutate ? 1 : 0.45)
            .help("\(stage ? "Stage" : "Unstage") \(file.path)")
            .accessibilityLabel("\(stage ? "Stage" : "Unstage") \(file.path)")
            .accessibilityIdentifier("project-changes.\(stage ? "stage" : "unstage").\(file.path)")
            .smokeTarget("project-changes.\(stage ? "stage" : "unstage").\(file.path)")
            Button {
                fileListFocused = true
                model.select(selection)
                showCompactDiff = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc").font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary)
                    Text(WorkspaceChangePresentation.filename(file.path)).font(.system(size: 12, weight: .medium))
                        .lineLimit(1).layoutPriority(1)
                    let directory = WorkspaceChangePresentation.directory(file.path)
                    if !directory.isEmpty {
                        Text(directory).font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if file.staged && file.unstaged {
                        Image(systemName: "circle.lefthalf.filled").font(.system(size: 10)).foregroundStyle(
                            DieterTheme.tertiary
                        )
                        .help("This file has both staged and unstaged edits")
                    }
                    Text(
                        WorkspaceChangePresentation.badge(
                            status: status, conflicted: file.conflicted, untracked: status == "untracked")
                    )
                    .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(
                        statusColor(status)
                    ).frame(width: 12)
                }.frame(maxWidth: .infinity, minHeight: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(file.path)
            .accessibilityLabel("\(section.capitalized) \(file.path)").accessibilityAddTraits(
                selected ? .isSelected : []
            )
            .accessibilityIdentifier("project-changes.\(section).\(file.path)").smokeTarget(
                "project-changes.\(section).\(file.path)")
        }
        .padding(.horizontal, 6)
        .background(selected ? DieterTheme.elevated : .clear, in: RoundedRectangle(cornerRadius: 5))
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 1).fill(DieterTheme.reviewAccent).frame(width: 2).padding(.vertical, 6)
            }
        }
        .contextMenu {
            Button("Discard changes…", role: .destructive) { discardPath = file.path }.disabled(!canMutate)
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "added", "untracked": DieterTheme.diffAddition
        case "deleted", "conflicted": DieterTheme.coral
        default: DieterTheme.amber
        }
    }

    private func diffPane(compact: Bool) -> some View {
        VStack(spacing: 0) {
            if ready, let selection = model.selection {
                diffToolbar(selection: selection, compact: compact)
                Divider().overlay(DieterTheme.border)
                if let error = model.diffError {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle").lineLimit(2); Spacer()
                        Button("Retry") { model.retryDiff() }
                    }.font(.callout).padding(12).foregroundStyle(DieterTheme.coral)
                }
                if let diff = model.diff {
                    if diff.binary {
                        ContentUnavailableView(
                            "Binary file", systemImage: "doc.badge.ellipsis",
                            description: Text("This file cannot be displayed as a text diff.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        WorkspaceDiffContent(
                            diff: diff, split: diffMode == "Split", comments: [], canComment: false,
                            addComment: { _ in }, loadMore: { model.loadMore() }, loadingMore: model.diffLoading,
                            reviewSection: selection.section
                        )
                        .id("\(model.projectID)|\(selection.section)|\(selection.path)")
                        .accessibilityIdentifier("project-changes.diff").smokeTarget("project-changes.diff")
                    }
                } else if model.diffLoading {
                    ProgressView("Loading diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer()
                }
            } else if !ready || model.changes == nil {
                initialState
            } else {
                ContentUnavailableView(
                    "Working tree is clean", systemImage: "checkmark.circle",
                    description: Text("No local changes in \(store.selectedProject?.name ?? "this project").")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("project-changes.clean").smokeTarget("project-changes.clean")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func diffToolbar(selection: ProjectChangeSelection, compact: Bool) -> some View {
        let staged = selection.section == "staged"
        let status = (staged ? selectedFile?.indexStatus : selectedFile?.worktreeStatus) ?? "modified"
        return GeometryReader { geometry in
            HStack(spacing: 10) {
                if compact {
                    Button {
                        showCompactDiff = false
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(DieterIconButtonStyle()).help("Back to files").accessibilityLabel("Back to files")
                    .accessibilityIdentifier("project-changes.back").smokeTarget("project-changes.back")
                }
                Image(systemName: "doc").font(.system(size: 12)).foregroundStyle(DieterTheme.tertiary)
                Text(WorkspaceChangePresentation.filename(selection.path)).font(
                    .system(size: 12, weight: .semibold, design: .monospaced)
                ).lineLimit(1).truncationMode(.middle)
                    .help(selection.path)
                if geometry.size.width > 900 {
                    Text(WorkspaceChangePresentation.directory(selection.path))
                        .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary).lineLimit(1).truncationMode(
                            .middle)
                }
                if geometry.size.width > 680 {
                    Text(status.capitalized).font(.system(size: 10, weight: .semibold)).foregroundStyle(
                        statusColor(status)
                    )
                    .padding(.horizontal, 6).padding(.vertical, 4).background(
                        statusColor(status).opacity(0.12), in: RoundedRectangle(cornerRadius: 4)
                    )
                    .fixedSize()
                }
                Spacer(minLength: 0)
                if geometry.size.width > 680, let file = selectedFile {
                    HStack(spacing: 5) {
                        Text("+\(staged ? file.stagedAdditions : file.unstagedAdditions)").foregroundStyle(
                            DieterTheme.diffAddition)
                        Text("−\(staged ? file.stagedDeletions : file.unstagedDeletions)").foregroundStyle(
                            DieterTheme.coral)
                    }.font(.system(size: 10, design: .monospaced)).fixedSize()
                }
                HStack(spacing: 2) {
                    ForEach(["Inline", "Split"], id: \.self) { mode in
                        Button {
                            diffMode = mode
                        } label: {
                            Text(mode).font(.system(size: 11, weight: .medium)).frame(width: 44, height: 25)
                                .foregroundStyle(diffMode == mode ? DieterTheme.text : DieterTheme.tertiary)
                                .background(
                                    diffMode == mode ? DieterTheme.elevated : .clear,
                                    in: RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain).accessibilityLabel("\(mode) diff").accessibilityAddTraits(
                            diffMode == mode ? .isSelected : [])
                    }
                }.padding(2).background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).stroke(DieterTheme.border) }
                    .accessibilityIdentifier("project-changes.diff-mode").smokeTarget("project-changes.diff-mode")
                Button("Discard") { discardPath = selection.path }
                    .buttonStyle(ChangesActionButtonStyle()).foregroundStyle(DieterTheme.coral).disabled(!canMutate)
                    .help("Discard all changes to this file")
                    .accessibilityIdentifier("project-changes.discard").smokeTarget("project-changes.discard")
                Button(staged ? "Unstage file" : "Stage file") {
                    model.startOperation(kind: staged ? "unstage" : "stage", path: selection.path)
                }
                .buttonStyle(ChangesActionButtonStyle(prominent: true)).disabled(!canMutate)
                .accessibilityIdentifier("project-changes.stage-file").smokeTarget("project-changes.stage-file")
                Menu {
                    Button("Copy path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(selection.path, forType: .string)
                    }
                    Button("Discard changes…", role: .destructive) { discardPath = selection.path }.disabled(!canMutate)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("File actions").accessibilityIdentifier("project-changes.file-actions")
            }.padding(.horizontal, 14).frame(height: 58).background(DieterTheme.sidebar)
        }.frame(height: 58)
    }

    private var feedback: some View {
        HStack(spacing: 8) {
            if model.pendingKind != nil || model.diffLoading { ProgressView().controlSize(.mini) }
            if let error = model.operationError ?? model.refreshError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(DieterTheme.coral)
            } else if let kind = model.pendingKind {
                Text("\(kind.replacingOccurrences(of: "_", with: " ").capitalized)…")
            } else if model.changes?.volatile == true {
                Label(
                    "An agent is editing this checkout. Git actions resume when it finishes.",
                    systemImage: "person.crop.circle.badge.clock"
                ).foregroundStyle(DieterTheme.amber)
            } else if model.busy {
                Text("Updating checkout state…")
            } else {
                Text(model.notice ?? "\(model.stagedFiles.count) staged · \(model.unstagedFiles.count) unstaged")
            }
            Spacer(minLength: 0)
            Text(model.selection?.path ?? "").lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 10, design: .monospaced)).foregroundStyle(DieterTheme.tertiary).lineLimit(2)
        .padding(.horizontal, 14).frame(minHeight: 30).background(DieterTheme.sidebar)
        .overlay(alignment: .top) { Divider().overlay(DieterTheme.border) }
        .accessibilityIdentifier("project-changes.status").smokeTarget("project-changes.status")
    }
}

private struct ChangesActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 11).frame(height: 31)
            .foregroundStyle(prominent ? Color.black.opacity(0.82) : DieterTheme.text)
            .background(prominent ? DieterTheme.reviewAccent : DieterTheme.input, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(prominent ? .clear : DieterTheme.border) }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
