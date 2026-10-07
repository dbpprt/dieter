import AppKit
import DieterAPI
import DieterShared
import SwiftUI

/// A path the user asked to discard: one file, or every change under a folder.
private struct ProjectDiscardRequest: Identifiable {
    let path: String
    let folder: Bool
    let fileCount: Int
    var id: String { path }
}

private enum ProjectChangesMetrics {
    static let rowHeight: CGFloat = 22
    static let indent: CGFloat = 12
    static let toolbarHeight: CGFloat = 38
}

struct ProjectChangesView: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("DieterDiffViewMode") private var diffMode = "Inline"
    @AppStorage("DieterChangesTreeView") private var treeView = true
    @State private var filter = ""
    @State private var showCompactDiff = false
    @State private var discard: ProjectDiscardRequest?
    /// Collapsed folders and sections, keyed "section|path" and "section".
    @State private var collapsed: Set<String> = []
    @State private var hovered: String?
    @FocusState private var fileListFocused: Bool
    private var injectedModel: ProjectChangesModel?
    private var injectedProjectName: String?
    private var active = true
    private var isLive = true
    private var bindingRevision = 0
    private var model: ProjectChangesModel { injectedModel ?? store.projectChanges }
    private var projectName: String { injectedProjectName ?? store.selectedProject?.name ?? "Project" }
    private var connected: Bool { injectedModel == nil ? store.phase.isConnected : isLive }
    /// The Changes section owns the window's header; a conversation tab sits below its own.
    private var standalone: Bool { injectedModel == nil }

    init() {}
    init(model: ProjectChangesModel, projectName: String, active: Bool, isLive: Bool, bindingRevision: Int) {
        injectedModel = model
        injectedProjectName = projectName
        self.active = active
        self.isLive = isLive
        self.bindingRevision = bindingRevision
    }
    private var targetKey: String {
        if injectedModel != nil {
            return "\(ObjectIdentifier(model))|\(bindingRevision)|\(active)|\(isLive)|\(scenePhase)"
        }
        return
            "\(store.selectedProjectID)|\(store.checkout(forProjectID: store.selectedProjectID)?.id ?? "")|\(store.phase.isConnected)|\(scenePhase)"
    }
    private var ready: Bool {
        injectedModel != nil ? !model.projectID.isEmpty : model.projectID == store.selectedProjectID
    }
    private var canMutate: Bool { ready && connected && active && !model.mutationsDisabled }
    /// The checkout operation `kind` can run now, as the core decides it.
    private func can(_ kind: String) -> Bool { canMutate && model.allows(kind) }
    private var selectedFile: Dieter_V1_ChangedFile? { model.changes?.files.first { $0.path == model.selection?.path } }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 900
            VStack(spacing: 0) {
                if standalone {
                    paneHeader
                    Divider().overlay(DieterTheme.border)
                }
                if compact {
                    if showCompactDiff, ready, model.selection != nil { diffPane(compact: true) } else { fileNavigator }
                } else {
                    HSplitView {
                        fileNavigator.frame(minWidth: 260, idealWidth: 340, maxWidth: 520)
                        diffPane(compact: false).frame(minWidth: 440)
                    }
                }
                feedback
            }
            .onChange(of: compact) { _, compact in
                if compact, model.selection != nil { showCompactDiff = true }
            }
        }
        .ignoresSafeArea(.container, edges: standalone ? .top : [])
        .foregroundStyle(DieterTheme.text)
        .background(DieterTheme.background)
        .task(id: targetKey) {
            guard active, scenePhase == .active else { model.suspend(); return }
            if injectedModel == nil {
                // The core reaches the checkout's machine.
                guard let checkout = store.checkout(forProjectID: store.selectedProjectID) else {
                    model.suspend(); return
                }
                model.bind(
                    projectID: store.selectedProjectID, checkoutID: checkout.id, daemonID: checkout.daemonID,
                    core: store.core)
            } else if !isLive {
                model.suspend(); return
            }
            // An active surface refreshes itself.
            model.active = true
            model.setLayout(split: diffMode == "Split")
            await model.refresh()
        }
        .onChange(of: diffMode) { _, mode in model.setLayout(split: mode == "Split") }
        .onDisappear { model.suspend() }
        .confirmationDialog(
            discard.map { discardTitle($0) } ?? "Discard changes?",
            isPresented: Binding(get: { discard != nil }, set: { if !$0 { discard = nil } }),
            presenting: discard
        ) { request in
            Button("Discard changes", role: .destructive) {
                model.startOperation(kind: "discard_changes", path: request.path)
                discard = nil
            }
            .accessibilityIdentifier("project-changes.confirm-discard")
            .smokeTarget("project-changes.confirm-discard")
            Button("Cancel", role: .cancel) { discard = nil }
        } message: { request in
            Text(
                request.folder
                    ? "Discard staged and unstaged changes under \(request.path). Dieter saves a recovery copy first, then restores tracked files to HEAD. Untracked files in the folder are removed; ignored files stay."
                    : "Discard staged and unstaged changes to \(request.path). Dieter saves a recovery copy first, then restores the file to HEAD. Untracked files are removed."
            )
        }
    }

    private func discardTitle(_ request: ProjectDiscardRequest) -> String {
        request.folder
            ? "Discard changes to \(SharedRules.shared.count(count: Int32(clamping: request.fileCount), noun: "file", plural: "")) in \(request.path)?"
            : "Discard changes to \(request.path)?"
    }

    // MARK: Header

    private var headerSummary: String {
        guard ready, let changes = model.changes else { return projectName }
        var parts = [projectName]
        parts.append(
            changes.files.isEmpty
                ? "Working tree clean"
                : SharedRules.shared.count(
                    count: Int32(clamping: changes.files.count), noun: "changed file", plural: ""))
        if changes.additions != 0 || changes.deletions != 0 {
            parts.append("+\(changes.additions) −\(changes.deletions)")
        }
        return parts.joined(separator: " · ")
    }

    private var paneHeader: some View {
        FluidPaneChrome(background: .clear, spacing: 7) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Changes").font(DieterFont.paneTitle).lineLimit(1)
                    Text(headerSummary).font(DieterFont.subtitle)
                        .foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                GlobalQuickTaskButton()
            }
        } secondary: {
            HStack(spacing: 8) {
                ProjectCheckoutMenu(projectID: store.selectedProjectID)
                    .menuStyle(.button).fixedSize()
                branchSummary
                Spacer(minLength: 8)
                ViewThatFits(in: .horizontal) {
                    shipActions(iconOnly: false).fixedSize()
                    shipActions(iconOnly: true).fixedSize()
                }
                refreshButton
            }
            .font(.callout)
            .controlSize(.regular)
            .buttonStyle(.bordered)
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
        }
        .disabled(model.refreshing).help("Refresh changes")
        .accessibilityLabel("Refresh changes").accessibilityIdentifier("project-changes.refresh")
        .smokeTarget("project-changes.refresh")
    }

    /// The branch, its base, and how far it has drifted from its upstream.
    private var branchSummary: some View {
        let changes = model.changes
        let branch = changes?.branch.isEmpty == false ? changes!.branch : "Detached HEAD"
        let base = changes?.baseBranch ?? ""
        return HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
            Text(branch).lineLimit(1).truncationMode(.middle)
            if let changes, changes.ahead != 0 || changes.behind != 0 {
                Text("↑\(changes.ahead) ↓\(changes.behind)").monospacedDigit()
                    .foregroundStyle(DieterTheme.tertiary)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(DieterTheme.subtle)
        .help(base.isEmpty || base == branch ? branch : "\(branch) → \(base)")
        .opacity(ready && changes != nil ? 1 : 0)
    }

    private func shipActions(iconOnly: Bool) -> some View {
        HStack(spacing: 6) {
            shipButton("Update", symbol: "arrow.down.circle", kind: "update", iconOnly: iconOnly)
                .help("Fetch and rebase onto the base branch")
            shipButton("Validate", symbol: "checkmark.seal", kind: "validate", iconOnly: iconOnly)
                .help("Run the project's validation")
            shipButton("Push", symbol: "arrow.up.circle", kind: "push", iconOnly: iconOnly)
                .help("Push the current branch")
        }
    }

    private func shipButton(_ title: String, symbol: String, kind: String, iconOnly: Bool) -> some View {
        Button {
            model.startOperation(kind: kind)
        } label: {
            if iconOnly {
                Label(title, systemImage: symbol).labelStyle(.iconOnly)
            } else {
                Label(title, systemImage: symbol)
            }
        }
        .disabled(!can(kind))
        .accessibilityLabel(title)
        .accessibilityIdentifier("project-changes.\(kind)").smokeTarget("project-changes.\(kind)")
    }

    // MARK: Navigator

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
            if !standalone { embeddedToolbar }
            if ready, model.changes != nil {
                commitComposer.padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 8)
                listToolbar.padding(.horizontal, 10).padding(.bottom, 4)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            fileSection("Staged Changes", section: "staged", files: model.stagedFiles)
                            fileSection("Changes", section: "unstaged", files: model.unstagedFiles)
                        }.padding(.horizontal, 4).padding(.bottom, 10)
                    }
                    .focusable().focused($fileListFocused).focusEffectDisabled()
                    .onKeyPress(.downArrow) {
                        moveSelection(by: 1); return .handled
                    }
                    .onKeyPress(.upArrow) {
                        moveSelection(by: -1); return .handled
                    }
                    .onKeyPress(.space) {
                        toggleSelectedStage(); return .handled
                    }
                    .onChange(of: model.selection) { _, selection in
                        if let selection { proxy.scrollTo(rowID(selection.section, selection.path)) }
                    }
                    .accessibilityElement(children: .contain).accessibilityLabel("Changed files")
                    .accessibilityIdentifier("project-changes.files").smokeTarget("project-changes.files")
                }
            } else {
                initialState
            }
        }.background(DieterTheme.sidebar)
    }

    /// A conversation's review tab has no pane header, so its Git actions sit atop the list.
    private var embeddedToolbar: some View {
        HStack(spacing: 6) {
            branchSummary
            Spacer(minLength: 4)
            shipActions(iconOnly: true)
            refreshButton
        }
        .buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 12).frame(height: 34)
        .overlay(alignment: .bottom) { Divider().overlay(DieterTheme.border) }
    }

    private var commitComposer: some View {
        @Bindable var model = model
        let count = model.stagedFiles.count
        let branch = model.changes?.branch ?? ""
        return VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    TextField(
                        "Commit subject", text: $model.commitSubject,
                        prompt: Text(branch.isEmpty ? "Message (⌘↩ to commit)" : "Message (⌘↩ to commit on \(branch))")
                            .foregroundStyle(DieterTheme.tertiary)
                    )
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityIdentifier("project-changes.commit-subject")
                    .smokeTarget("project-changes.commit-subject")
                    if model.commitSubject.count > 50 {
                        Text("\(model.commitSubject.count)/72").monospacedDigit()
                            .font(.system(size: 10))
                            .foregroundStyle(model.commitSubject.count > 72 ? DieterTheme.amber : DieterTheme.tertiary)
                    }
                }
                .padding(.horizontal, 8).frame(height: 26)
                TextField(
                    "Description (optional)", text: $model.commitBody,
                    prompt: Text("Description").foregroundStyle(DieterTheme.tertiary), axis: .vertical
                )
                .font(.system(size: 11)).lineLimit(1...6).padding(.horizontal, 8).padding(.bottom, 6)
                .accessibilityIdentifier("project-changes.commit-body").smokeTarget("project-changes.commit-body")
            }
            .textFieldStyle(.plain).disabled(model.pendingKind == "commit")
            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(DieterTheme.border) }
            Button {
                model.startOperation(kind: "commit", subject: model.commitSubject, body: model.commitBody)
            } label: {
                HStack(spacing: 6) {
                    if model.pendingKind == "commit" {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "checkmark")
                    }
                    Text(
                        model.pendingKind == "commit"
                            ? "Committing…"
                            : count == 0
                                ? "Commit"
                                : "Commit \(SharedRules.shared.count(count: Int32(clamping: count), noun: "file", plural: ""))"
                    )
                }.frame(maxWidth: .infinity)
            }
            .buttonStyle(ChangesActionButtonStyle(prominent: true))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!can("commit") || !commitReady)
            .help(count == 0 ? "Stage files to commit" : "Commit staged changes (⌘↩)")
            .accessibilityIdentifier("project-changes.commit").smokeTarget("project-changes.commit")
        }
    }

    /// The commit form has what it needs, as the core checks it.
    private var commitReady: Bool {
        SharedRules.shared.gitOperationReady(
            form: ClientGitOperationForm.with {
                $0.kind = "commit"
                $0.subject = model.commitSubject
                $0.body = model.commitBody
            }.rulesData)
    }

    private var listToolbar: some View {
        HStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10))
                    .foregroundStyle(DieterTheme.tertiary)
                TextField(
                    "Filter files", text: $filter,
                    prompt: Text("Filter files").foregroundStyle(DieterTheme.tertiary)
                )
                .textFieldStyle(.plain).font(.system(size: 11))
                .accessibilityIdentifier("project-changes.filter").smokeTarget("project-changes.filter")
                if !filter.isEmpty {
                    Button {
                        filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).foregroundStyle(DieterTheme.tertiary)
                    .accessibilityLabel("Clear file filter")
                }
            }
            .padding(.horizontal, 7).frame(height: 24)
            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).stroke(DieterTheme.border) }
            if treeView {
                listIconButton(
                    allCollapsed ? "Expand all folders" : "Collapse all folders",
                    symbol: allCollapsed ? "plus.square.on.square" : "minus.square",
                    identifier: "project-changes.collapse-all"
                ) { toggleAllFolders() }
            }
            listIconButton(
                treeView ? "View as list" : "View as tree",
                symbol: treeView ? "list.bullet" : "list.bullet.indent",
                identifier: "project-changes.view-mode"
            ) { treeView.toggle() }
        }
    }

    private func listIconButton(
        _ title: String, symbol: String, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(DieterTheme.subtle)
        .help(title).accessibilityLabel(title).accessibilityIdentifier(identifier)
    }

    // MARK: Rows

    private func visible(_ files: [Dieter_V1_ChangedFile]) -> [Dieter_V1_ChangedFile] {
        filter.isEmpty ? files : files.filter { $0.path.localizedCaseInsensitiveContains(filter) }
    }

    private func treeRows(section: String, files: [Dieter_V1_ChangedFile]) -> [ChangeTreeRow] {
        let paths = visible(files).map(\.path)
        guard treeView else {
            return paths.map {
                ChangeTreeRow(
                    kind: .file, path: $0, name: ClientChangedFileLabel.of($0).filename, depth: 0, fileCount: 1)
            }
        }
        let folded = Set(
            collapsed.compactMap { key in key.hasPrefix("\(section)|") ? String(key.dropFirst(section.count + 1)) : nil
            })
        return ChangeTree.rows(paths: paths, collapsed: folded)
    }

    private var allFolderKeys: Set<String> {
        let staged = ChangeTree.folders(paths: visible(model.stagedFiles).map(\.path)).map { "staged|\($0)" }
        let unstaged = ChangeTree.folders(paths: visible(model.unstagedFiles).map(\.path)).map { "unstaged|\($0)" }
        return Set(staged).union(unstaged)
    }

    private var allCollapsed: Bool {
        let keys = allFolderKeys
        return !keys.isEmpty && keys.isSubset(of: collapsed)
    }

    private func toggleAllFolders() {
        let keys = allFolderKeys
        if allCollapsed { collapsed.subtract(keys) } else { collapsed.formUnion(keys) }
    }

    private func rowID(_ section: String, _ path: String) -> String { "\(section)|\(path)" }

    private func fileSection(_ title: String, section: String, files: [Dieter_V1_ChangedFile]) -> some View {
        let staged = section == "staged"
        let folded = collapsed.contains(section)
        let rows = folded ? [] : treeRows(section: section, files: files)
        let byPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return Section {
            if !folded {
                if rows.isEmpty {
                    Text(files.isEmpty ? (staged ? "No staged files" : "No local changes") : "No matching files")
                        .font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary)
                        .padding(.leading, 22).frame(height: ProjectChangesMetrics.rowHeight)
                }
                ForEach(rows, id: \.self) { row in
                    switch row.kind {
                    case .folder: folderRow(row, section: section).id(rowID(section, "/" + row.path))
                    case .file:
                        if let file = byPath[row.path] {
                            fileRow(file, row: row, section: section).id(rowID(section, row.path))
                        }
                    }
                }
            }
        } header: {
            sectionHeader(title, section: section, files: files, folded: folded)
        }
    }

    private func sectionHeader(_ title: String, section: String, files: [Dieter_V1_ChangedFile], folded: Bool)
        -> some View
    {
        let staged = section == "staged"
        let kind = staged ? "unstage" : "stage"
        let id = "header|\(section)"
        return HStack(spacing: 4) {
            Button {
                if folded { collapsed.remove(section) } else { collapsed.insert(section) }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(folded ? 0 : 90)).frame(width: 12)
                    Text(title.uppercased()).tracking(0.6)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(files.count)")
            if !files.isEmpty {
                rowAction(
                    staged ? "Unstage all" : "Stage all", symbol: staged ? "minus" : "plus", kind: kind, path: "",
                    identifier: "project-changes.\(kind)-all", emphasized: hovered == id)
            }
            Text("\(files.count)").monospacedDigit()
                .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 15)
                .background(DieterTheme.elevated, in: Capsule())
        }
        .font(.system(size: 10, weight: .semibold)).foregroundStyle(DieterTheme.subtle)
        .padding(.leading, 2).padding(.trailing, 8).frame(height: 24)
        .padding(.top, staged ? 2 : 8)
        .background(DieterTheme.sidebar)
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
    }

    private func indent(_ depth: Int) -> some View {
        Color.clear.frame(width: CGFloat(depth) * ProjectChangesMetrics.indent, height: 1)
    }

    private func folderRow(_ row: ChangeTreeRow, section: String) -> some View {
        let staged = section == "staged"
        let key = rowID(section, row.path)
        let folded = collapsed.contains(key)
        let id = "folder|\(key)"
        let emphasized = hovered == id
        return HStack(spacing: 2) {
            Button {
                if folded { collapsed.remove(key) } else { collapsed.insert(key) }
            } label: {
                HStack(spacing: 4) {
                    indent(row.depth)
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DieterTheme.tertiary)
                        .rotationEffect(.degrees(folded ? 0 : 90)).frame(width: 12)
                    Image(systemName: folded ? "folder.fill" : "folder").font(.system(size: 11))
                        .foregroundStyle(DieterTheme.shell).frame(width: 15)
                    Text(row.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: ProjectChangesMetrics.rowHeight).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(row.path)
            .accessibilityLabel("Folder \(row.path), \(row.fileCount) files")
            .accessibilityValue(folded ? "Collapsed" : "Expanded")
            .accessibilityIdentifier("project-changes.folder.\(section).\(row.path)")
            if emphasized {
                if standalone {
                    rowIconButton("Open folder in Files", symbol: "arrow.up.forward.square") {
                        openInFiles(row.path, directory: true)
                    }
                }
                if !staged {
                    rowIconButton("Discard changes in folder", symbol: "arrow.uturn.backward") {
                        discard = .init(path: row.path, folder: true, fileCount: row.fileCount)
                    }
                    .disabled(!can("discard_changes"))
                }
            }
            rowAction(
                staged ? "Unstage folder" : "Stage folder", symbol: staged ? "minus" : "plus",
                kind: staged ? "unstage" : "stage", path: row.path,
                identifier: "project-changes.\(staged ? "unstage" : "stage")-folder.\(row.path)", emphasized: emphasized
            )
            Text("\(row.fileCount)").font(.system(size: 10)).monospacedDigit()
                .foregroundStyle(DieterTheme.tertiary).frame(minWidth: 16, alignment: .trailing)
        }
        .padding(.leading, 4).padding(.trailing, 8)
        .background(emphasized ? DieterTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 4))
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .contextMenu { folderMenu(row, section: section, folded: folded) }
    }

    @ViewBuilder private func folderMenu(_ row: ChangeTreeRow, section: String, folded: Bool) -> some View {
        let staged = section == "staged"
        Button(staged ? "Unstage Folder" : "Stage Folder") {
            model.startOperation(kind: staged ? "unstage" : "stage", path: row.path)
        }.disabled(!can(staged ? "unstage" : "stage"))
        Button("Discard Changes in Folder…", role: .destructive) {
            discard = .init(path: row.path, folder: true, fileCount: row.fileCount)
        }.disabled(!can("discard_changes"))
        Divider()
        if standalone {
            Button("Open in Files") { openInFiles(row.path, directory: true) }
        }
        Button("Copy Path") { copy(row.path) }
        Divider()
        Button(folded ? "Expand" : "Collapse") {
            let key = rowID(section, row.path)
            if folded { collapsed.remove(key) } else { collapsed.insert(key) }
        }
        Button("Collapse All") { collapsed.formUnion(allFolderKeys) }
    }

    private func fileRow(_ file: Dieter_V1_ChangedFile, row: ChangeTreeRow, section: String) -> some View {
        let status = section == "staged" ? file.indexStatus : file.worktreeStatus
        let stage = section != "staged"
        let selection = ProjectChangeSelection(path: file.path, section: section)
        let selected = model.selection == selection
        let id = "file|\(rowID(section, file.path))"
        let emphasized = hovered == id || selected
        let label = ClientChangedFileLabel.of(
            file.path, status: status, conflicted: file.conflicted, untracked: status == "untracked")
        return HStack(spacing: 2) {
            Button {
                fileListFocused = true
                model.select(selection)
                showCompactDiff = true
            } label: {
                HStack(spacing: 4) {
                    indent(row.depth)
                    Color.clear.frame(width: treeView ? 12 : 0, height: 1)
                    Image(systemName: FilePresentation.symbol(name: label.filename)).font(.system(size: 10))
                        .foregroundStyle(DieterTheme.tertiary).frame(width: 15)
                    Text(label.filename).font(.system(size: 12))
                        .foregroundStyle(nameColor(status, conflicted: file.conflicted))
                        .strikethrough(status == "deleted", color: DieterTheme.coral.opacity(0.7))
                        .lineLimit(1).layoutPriority(1)
                    if !treeView, !label.directory.isEmpty {
                        Text(label.directory).font(.system(size: 10.5)).foregroundStyle(DieterTheme.tertiary)
                            .lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: ProjectChangesMetrics.rowHeight).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(file.path)
            .accessibilityLabel("\(section.capitalized) \(file.path)")
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("project-changes.\(section).\(file.path)")
            .smokeTarget("project-changes.\(section).\(file.path)")
            if emphasized {
                if standalone, status != "deleted" {
                    rowIconButton("Open file in Files", symbol: "arrow.up.forward.square") {
                        openInFiles(file.path, directory: false)
                    }
                }
                if stage {
                    rowIconButton("Discard changes", symbol: "arrow.uturn.backward") {
                        discard = .init(path: file.path, folder: false, fileCount: 1)
                    }
                    .disabled(!can("discard_changes"))
                }
            }
            rowAction(
                stage ? "Stage \(file.path)" : "Unstage \(file.path)", symbol: stage ? "plus" : "minus",
                kind: stage ? "stage" : "unstage", path: file.path,
                identifier: "project-changes.\(stage ? "stage" : "unstage").\(file.path)", emphasized: emphasized)
            if file.staged && file.unstaged {
                Image(systemName: "circle.lefthalf.filled").font(.system(size: 8))
                    .foregroundStyle(DieterTheme.tertiary)
                    .help("This file has both staged and unstaged edits")
            }
            Text(label.badge)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(statusColor(status)).frame(width: 14)
                .help(label.title)
        }
        .padding(.leading, 4).padding(.trailing, 8)
        .background(
            selected ? DieterTheme.selection : (emphasized ? DieterTheme.raised : .clear),
            in: RoundedRectangle(cornerRadius: 4)
        )
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 1).fill(DieterTheme.reviewAccent).frame(width: 2).padding(.vertical, 4)
            }
        }
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .contextMenu { fileMenu(file, status: status, stage: stage) }
    }

    @ViewBuilder private func fileMenu(_ file: Dieter_V1_ChangedFile, status: String, stage: Bool) -> some View {
        if standalone, status != "deleted" {
            Button("Open in Files") { openInFiles(file.path, directory: false) }
            Divider()
        }
        Button(stage ? "Stage Changes" : "Unstage Changes") {
            model.startOperation(kind: stage ? "stage" : "unstage", path: file.path)
        }.disabled(!can(stage ? "stage" : "unstage"))
        Button("Discard Changes…", role: .destructive) {
            discard = .init(path: file.path, folder: false, fileCount: 1)
        }.disabled(!can("discard_changes"))
        Divider()
        Button("Copy Path") { copy(file.path) }
        Button("Copy File Name") { copy(ClientChangedFileLabel.of(file.path).filename) }
        if let root = store.selectedProject?.path, standalone, !root.isEmpty {
            Button("Copy Absolute Path") { copy((root as NSString).appendingPathComponent(file.path)) }
        }
    }

    /// Stages or unstages a path; the row's primary action stays visible so it can be pressed directly.
    private func rowAction(
        _ title: String, symbol: String, kind: String, path: String, identifier: String, emphasized: Bool
    ) -> some View {
        Button {
            model.startOperation(kind: kind, path: path)
        } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(emphasized ? DieterTheme.text : DieterTheme.tertiary.opacity(0.7))
        .disabled(!can(kind)).opacity(can(kind) ? 1 : 0.4)
        .help(title).accessibilityLabel(title)
        .accessibilityIdentifier(identifier).smokeTarget(identifier)
    }

    private func rowIconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(DieterTheme.subtle)
        .help(title).accessibilityLabel(title)
    }

    private func openInFiles(_ path: String, directory: Bool) {
        let projectID = store.selectedProjectID
        Task { await store.openProjectPath(projectID, path: path, directory: directory) }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// Selectable files in on-screen order, skipping collapsed folders and sections.
    private var orderedSelections: [ProjectChangeSelection] {
        ["staged", "unstaged"].flatMap { section -> [ProjectChangeSelection] in
            guard !collapsed.contains(section) else { return [] }
            let files = section == "staged" ? model.stagedFiles : model.unstagedFiles
            return treeRows(section: section, files: files).filter { $0.kind == .file }
                .map { ProjectChangeSelection(path: $0.path, section: section) }
        }
    }

    private func moveSelection(by offset: Int) {
        let visible = orderedSelections
        guard !visible.isEmpty else { return }
        let index = model.selection.flatMap { visible.firstIndex(of: $0) } ?? (offset > 0 ? -1 : 0)
        model.select(visible[min(max(index + offset, 0), visible.count - 1)])
    }

    private func toggleSelectedStage() {
        guard let selection = model.selection else { return }
        let kind = selection.section == "staged" ? "unstage" : "stage"
        guard can(kind) else { return }
        model.startOperation(kind: kind, path: selection.path)
    }

    private func nameColor(_ status: String, conflicted: Bool) -> Color {
        if conflicted { return DieterTheme.coral }
        switch status {
        case "added", "untracked": return DieterTheme.diffAddition
        case "deleted": return DieterTheme.coral
        default: return DieterTheme.text
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "added", "untracked": DieterTheme.diffAddition
        case "deleted", "conflicted": DieterTheme.coral
        default: DieterTheme.amber
        }
    }

    // MARK: Diff

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
                            layout: model.diffLayout, addComment: { _ in }, loadMore: { model.loadMore() },
                            loadingMore: model.diffLoading, reviewSection: selection.section
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
                    description: Text("No local changes in \(projectName).")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("project-changes.clean").smokeTarget("project-changes.clean")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func diffToolbar(selection: ProjectChangeSelection, compact: Bool) -> some View {
        let staged = selection.section == "staged"
        let status = (staged ? selectedFile?.indexStatus : selectedFile?.worktreeStatus) ?? "modified"
        let label = ClientChangedFileLabel.of(selection.path, status: status, untracked: status == "untracked")
        let position = orderedSelections.firstIndex(of: selection)
        let total = orderedSelections.count
        return ViewThatFits(in: .horizontal) {
            diffToolbarContent(
                selection: selection, label: label, status: status, position: position, total: total,
                compact: compact, wide: true)
            diffToolbarContent(
                selection: selection, label: label, status: status, position: position, total: total,
                compact: compact, wide: false)
        }
        .padding(.horizontal, 10).frame(height: ProjectChangesMetrics.toolbarHeight)
        .background(DieterTheme.sidebar)
    }

    private func diffToolbarContent(
        selection: ProjectChangeSelection, label: ClientChangedFileLabel, status: String, position: Int?, total: Int,
        compact: Bool, wide: Bool
    ) -> some View {
        let staged = selection.section == "staged"
        return HStack(spacing: 8) {
            if compact {
                Button {
                    showCompactDiff = false
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(DieterIconButtonStyle()).help("Back to files").accessibilityLabel("Back to files")
                .accessibilityIdentifier("project-changes.back").smokeTarget("project-changes.back")
            }
            Image(systemName: FilePresentation.symbol(name: label.filename)).font(.system(size: 11))
                .foregroundStyle(DieterTheme.tertiary)
            HStack(spacing: 0) {
                if wide, !label.directory.isEmpty {
                    Text(label.directory + "/").foregroundStyle(DieterTheme.tertiary)
                        .lineLimit(1).truncationMode(.head)
                }
                Text(label.filename).fontWeight(.semibold).lineLimit(1).layoutPriority(1)
            }
            .font(.system(size: 12, design: .monospaced))
            .help(selection.path).textSelection(.enabled)
            Text(wide ? "\(label.title) · \(staged ? "Staged" : "Unstaged")" : label.badge)
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(statusColor(status))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(statusColor(status).opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()
            if let file = selectedFile {
                let additions = staged ? file.stagedAdditions : file.unstagedAdditions
                let deletions = staged ? file.stagedDeletions : file.unstagedDeletions
                if additions != 0 || deletions != 0 {
                    HStack(spacing: 5) {
                        Text("+\(additions)").foregroundStyle(DieterTheme.diffAddition)
                        Text("−\(deletions)").foregroundStyle(DieterTheme.coral)
                    }.font(.system(size: 10, design: .monospaced)).fixedSize()
                }
            }
            Spacer(minLength: 8)
            fileStepper(position: position, total: total, wide: wide)
            diffModePicker
            Button("Discard") { discard = .init(path: selection.path, folder: false, fileCount: 1) }
                .buttonStyle(ChangesActionButtonStyle()).foregroundStyle(DieterTheme.coral)
                .disabled(!can("discard_changes"))
                .help("Discard all changes to this file")
                .accessibilityIdentifier("project-changes.discard").smokeTarget("project-changes.discard")
            Button(staged ? "Unstage" : "Stage") {
                model.startOperation(kind: staged ? "unstage" : "stage", path: selection.path)
            }
            .buttonStyle(ChangesActionButtonStyle(prominent: true)).disabled(!can(staged ? "unstage" : "stage"))
            .help(staged ? "Unstage this file (Space)" : "Stage this file (Space)")
            .accessibilityIdentifier("project-changes.stage-file").smokeTarget("project-changes.stage-file")
            Menu {
                if standalone, status != "deleted" {
                    Button("Open in Files") { openInFiles(selection.path, directory: false) }
                    Divider()
                }
                Button("Copy Path") { copy(selection.path) }
                Button("Copy File Name") { copy(label.filename) }
                Divider()
                Button("Discard Changes…", role: .destructive) {
                    discard = .init(path: selection.path, folder: false, fileCount: 1)
                }
                .disabled(!can("discard_changes"))
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("File actions").accessibilityIdentifier("project-changes.file-actions")
        }
    }

    /// Steps through changed files in list order without leaving the diff.
    private func fileStepper(position: Int?, total: Int, wide: Bool) -> some View {
        HStack(spacing: 2) {
            Button {
                moveSelection(by: -1)
            } label: {
                Image(systemName: "chevron.up").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .disabled((position ?? 0) <= 0).help("Previous file (↑)").accessibilityLabel("Previous file")
            .accessibilityIdentifier("project-changes.previous-file")
            if wide, let position {
                Text("\(position + 1)/\(total)").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DieterTheme.tertiary).fixedSize()
            }
            Button {
                moveSelection(by: 1)
            } label: {
                Image(systemName: "chevron.down").frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .disabled(position.map { $0 >= total - 1 } ?? true).help("Next file (↓)").accessibilityLabel("Next file")
            .accessibilityIdentifier("project-changes.next-file")
        }
        .buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(DieterTheme.subtle)
    }

    private var diffModePicker: some View {
        HStack(spacing: 2) {
            ForEach(["Inline", "Split"], id: \.self) { mode in
                Button {
                    diffMode = mode
                } label: {
                    Text(mode).font(.system(size: 11, weight: .medium)).frame(width: 42, height: 22)
                        .foregroundStyle(diffMode == mode ? DieterTheme.text : DieterTheme.tertiary)
                        .background(
                            diffMode == mode ? DieterTheme.elevated : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
                }.buttonStyle(.plain).accessibilityLabel("\(mode) diff").accessibilityAddTraits(
                    diffMode == mode ? .isSelected : []
                )
                .accessibilityIdentifier("project-changes.diff-mode.\(mode.lowercased())")
                .smokeTarget("project-changes.diff-mode.\(mode.lowercased())")
            }
        }.padding(2).background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).stroke(DieterTheme.border) }
            .fixedSize()
            .accessibilityIdentifier("project-changes.diff-mode").smokeTarget("project-changes.diff-mode")
    }

    // MARK: Status

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
        .font(.system(size: 10, design: .monospaced)).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
        .padding(.horizontal, 12).frame(minHeight: 22).background(DieterTheme.sidebar)
        .overlay(alignment: .top) { Divider().overlay(DieterTheme.border) }
        .accessibilityIdentifier("project-changes.status").smokeTarget("project-changes.status")
    }
}

private struct ChangesActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).frame(height: 26)
            .foregroundStyle(prominent ? Color.black.opacity(0.82) : DieterTheme.text)
            .background(prominent ? DieterTheme.reviewAccent : DieterTheme.input, in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).stroke(prominent ? .clear : DieterTheme.border) }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 5))
    }
}
