import AppKit
import DieterAPI
import DieterClientAPI
import DieterCore
import Observation
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

/// What the panes may do now, decided once from the session, so they observe
/// the checkout's model and nothing else of the app.
private struct ProjectChangesAccess: Equatable {
    /// The model shows the checkout this view is bound to.
    var ready: Bool
    var canMutate: Bool
    /// The Changes section owns the window's header; a conversation tab sits below its own.
    var standalone: Bool
    /// The project's directory, for copying absolute paths; empty in a conversation tab.
    var projectRoot: String

    /// The checkout operation `kind` can run now, as the core decides it.
    @MainActor func allows(_ kind: String, in model: ProjectChangesModel) -> Bool {
        canMutate && model.allows(kind)
    }
}

/// The navigator's own state: the filter, the collapsed folders and sections,
/// the pane shown while compact, and a discard awaiting confirmation. It lays
/// the files out once per change of these or of the files, not on every render.
@MainActor @Observable
private final class ProjectChangesNavigation {
    var filter = ""
    /// Collapsed folders and sections, keyed "section|path" and "section".
    var collapsed: Set<String> = []
    var showCompactDiff = false
    var discard: ProjectDiscardRequest?
    @ObservationIgnored private var laidOut: (key: ListingKey, listing: ProjectChangeListing)?

    private struct ListingKey: Equatable {
        let model: ObjectIdentifier
        let files: Int
        let filter: String
        let collapsed: Set<String>
        let tree: Bool
    }

    /// A discard awaits confirmation.
    var confirmingDiscard: Bool {
        get { discard != nil }
        set { if !newValue { discard = nil } }
    }

    /// `model`'s files as the navigator lists them. A view that reads the
    /// listing observes the files, the filter, and the collapsed folders.
    func listing(_ model: ProjectChangesModel, tree: Bool) -> ProjectChangeListing {
        let key = ListingKey(
            model: ObjectIdentifier(model), files: model.filesRevision, filter: filter, collapsed: collapsed,
            tree: tree)
        if let laidOut, laidOut.key == key { return laidOut.listing }
        let listing = ProjectChangeListing(
            stagedFiles: model.stagedFiles, unstagedFiles: model.unstagedFiles, filter: filter, collapsed: collapsed,
            tree: tree)
        laidOut = (key, listing)
        return listing
    }

    /// Collapses or expands a folder (keyed "section|path") or a section.
    func toggle(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
    }

    func toggleAllFolders(_ model: ProjectChangesModel) {
        let listing = listing(model, tree: true)
        if listing.allCollapsed {
            collapsed.subtract(listing.folderKeys)
        } else {
            collapsed.formUnion(listing.folderKeys)
        }
    }

    func collapseAllFolders(_ model: ProjectChangesModel) {
        collapsed.formUnion(listing(model, tree: true).folderKeys)
    }

    /// Selects the file `offset` places away in on-screen order.
    func move(by offset: Int, in model: ProjectChangesModel, tree: Bool) {
        let listing = listing(model, tree: tree)
        let order = listing.order
        guard !order.isEmpty else { return }
        let index = model.selection.flatMap { listing.position(of: $0) } ?? (offset > 0 ? -1 : 0)
        model.select(order[min(max(index + offset, 0), order.count - 1)])
    }
}

/// The changed files as the navigator lists them: each section's rows after
/// the filter, the tree layout, and collapsed folders and sections, and the
/// selectable files in on-screen order.
private struct ProjectChangeListing {
    struct Section {
        /// "staged" or "unstaged".
        let name: String
        /// The section is collapsed and shows no rows.
        let folded: Bool
        let rows: [ChangeTreeRow]
        /// The section's files by path, whatever the filter.
        let files: [String: Dieter_V1_ChangedFile]
        /// How many files the section has, whatever the filter.
        let count: Int

        var staged: Bool { name == "staged" }
    }

    let staged: Section
    let unstaged: Section
    /// Selectable files in on-screen order, skipping collapsed folders and sections.
    let order: [ProjectChangeSelection]
    /// Every folder the filter leaves, keyed "section|path"; empty as a flat list.
    let folderKeys: Set<String>
    /// Every folder is collapsed.
    let allCollapsed: Bool
    private let positions: [ProjectChangeSelection: Int]

    init(
        stagedFiles: [Dieter_V1_ChangedFile], unstagedFiles: [Dieter_V1_ChangedFile], filter: String,
        collapsed: Set<String>, tree: Bool
    ) {
        var folders = Set<String>()
        let staged = Self.section(
            "staged", stagedFiles, filter: filter, collapsed: collapsed, tree: tree, folders: &folders)
        let unstaged = Self.section(
            "unstaged", unstagedFiles, filter: filter, collapsed: collapsed, tree: tree, folders: &folders)
        var order: [ProjectChangeSelection] = []
        for section in [staged, unstaged] {
            for row in section.rows where row.kind == .file {
                order.append(ProjectChangeSelection(path: row.path, section: section.name))
            }
        }
        self.staged = staged
        self.unstaged = unstaged
        self.order = order
        folderKeys = folders
        allCollapsed = !folders.isEmpty && folders.isSubset(of: collapsed)
        positions = Dictionary(
            order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }

    func position(of selection: ProjectChangeSelection) -> Int? { positions[selection] }

    private static func section(
        _ name: String, _ files: [Dieter_V1_ChangedFile], filter: String, collapsed: Set<String>, tree: Bool,
        folders: inout Set<String>
    ) -> Section {
        let folded = collapsed.contains(name)
        let visible = filter.isEmpty ? files : files.filter { $0.path.localizedCaseInsensitiveContains(filter) }
        let paths = visible.map(\.path)
        var rows: [ChangeTreeRow] = []
        if tree {
            let all = ChangeTree.rows(paths: paths)
            for row in all where row.kind == .folder { folders.insert("\(name)|\(row.path)") }
            if !folded {
                let prefix = "\(name)|"
                let closed = Set(
                    collapsed.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil })
                rows = closed.isEmpty ? all : ChangeTree.rows(paths: paths, collapsed: closed)
            }
        } else if !folded {
            rows = ChangeTree.list(paths: paths)
        }
        return Section(
            name: name, folded: folded, rows: rows,
            files: Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }),
            count: files.count)
    }
}

private func projectRowID(_ section: String, _ path: String) -> String { "\(section)|\(path)" }

@MainActor private func openInFiles(_ store: DieterStore, _ path: String, directory: Bool) {
    let projectID = store.selectedProjectID
    Task { await store.openProjectPath(projectID, path: path, directory: directory) }
}

@MainActor private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

/// A checkout's changes: the file list beside the diff. The view is split so
/// that typing, hovering, a slice update, or a scroll re-renders only the part
/// that shows it.
struct ProjectChangesView: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("DieterDiffViewMode") private var diffMode = "Inline"
    @State private var navigation = ProjectChangesNavigation()
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
    private var access: ProjectChangesAccess {
        let ready = ready
        return ProjectChangesAccess(
            ready: ready, canMutate: ready && connected && active && !model.mutationsDisabled,
            standalone: standalone, projectRoot: standalone ? store.selectedProject?.path ?? "" : "")
    }

    var body: some View {
        @Bindable var navigation = navigation
        let access = access
        let projectName = projectName
        Group {
            if standalone {
                DieterSectionScaffold {
                    ProjectChangesTitle(model: model, projectName: projectName, ready: access.ready)
                } trailing: {
                    EmptyView()
                } content: {
                    VStack(spacing: 0) {
                        ProjectChangesToolbar(model: model, projectID: store.selectedProjectID, access: access)
                        Rectangle().fill(DieterTheme.hairline).frame(height: 1)
                        changesContent(access: access, projectName: projectName)
                    }
                }
            } else {
                changesContent(access: access, projectName: projectName)
            }
        }
        .foregroundStyle(DieterTheme.text)
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
            navigation.discard.map { discardTitle($0) } ?? "Discard changes?",
            isPresented: $navigation.confirmingDiscard,
            presenting: navigation.discard
        ) { request in
            Button("Discard changes", role: .destructive) {
                model.startOperation(kind: "discard_changes", path: request.path)
                navigation.discard = nil
            }
            .accessibilityIdentifier("project-changes.confirm-discard")
            .e2eTarget("project-changes.confirm-discard")
            Button("Cancel", role: .cancel) { navigation.discard = nil }
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

    /// The file list beside the diff, or one of them while compact.
    private func changesContent(access: ProjectChangesAccess, projectName: String) -> some View {
        GeometryReader { geometry in
            ProjectChangesPanes(
                model: model, navigation: navigation, access: access, projectName: projectName,
                compact: geometry.size.width < 900)
        }
    }
}

// MARK: Header

private struct ProjectChangesTitle: View {
    let model: ProjectChangesModel
    let projectName: String
    let ready: Bool

    var body: some View {
        DieterTitleCapsule(title: "Changes", detail: summary)
    }

    private var summary: String {
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
}

private struct ProjectChangesToolbar: View {
    let model: ProjectChangesModel
    let projectID: String
    let access: ProjectChangesAccess

    var body: some View {
        HStack(spacing: 8) {
            ProjectCheckoutMenu(projectID: projectID, size: 28)
            ProjectBranchSummary(model: model, ready: access.ready)
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                ProjectShipActions(model: model, access: access, iconOnly: false).fixedSize()
                ProjectShipActions(model: model, access: access, iconOnly: true).fixedSize()
            }
            ProjectRefreshButton(model: model)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

private struct ProjectRefreshButton: View {
    let model: ProjectChangesModel
    var size: CGFloat = 28

    var body: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
        }
        .buttonStyle(DieterBarButtonStyle(shape: .circle, size: size))
        .disabled(model.refreshing).help("Refresh changes")
        .accessibilityLabel("Refresh changes").accessibilityIdentifier("project-changes.refresh")
        .e2eTarget("project-changes.refresh")
    }
}

/// The branch, its base, and how far it has drifted from its upstream.
private struct ProjectBranchSummary: View {
    let model: ProjectChangesModel
    let ready: Bool

    var body: some View {
        let changes = model.changes
        let branch = changes?.branch.isEmpty == false ? changes!.branch : "Detached HEAD"
        let base = changes?.baseBranch ?? ""
        HStack(spacing: 5) {
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
}

private struct ProjectShipActions: View {
    let model: ProjectChangesModel
    let access: ProjectChangesAccess
    let iconOnly: Bool
    var size: CGFloat = 28

    var body: some View {
        HStack(spacing: 6) {
            shipButton("Update", symbol: "arrow.down.circle", kind: "update")
                .help("Fetch and rebase onto the base branch")
            shipButton("Validate", symbol: "checkmark.seal", kind: "validate")
                .help("Run the project's validation")
            shipButton("Push", symbol: "arrow.up.circle", kind: "push")
                .help("Push the current branch")
        }
    }

    private func shipButton(_ title: String, symbol: String, kind: String) -> some View {
        Button {
            model.startOperation(kind: kind)
        } label: {
            if iconOnly {
                Label(title, systemImage: symbol).labelStyle(.iconOnly)
            } else {
                Label(title, systemImage: symbol)
            }
        }
        .buttonStyle(DieterBarButtonStyle(shape: iconOnly ? .circle : .capsule, size: size))
        .disabled(!access.allows(kind, in: model))
        .accessibilityLabel(title)
        .accessibilityIdentifier("project-changes.\(kind)").e2eTarget("project-changes.\(kind)")
    }
}

// MARK: Panes

/// The file list beside the diff, or one of them while compact.
private struct ProjectChangesPanes: View {
    let model: ProjectChangesModel
    let navigation: ProjectChangesNavigation
    let access: ProjectChangesAccess
    let projectName: String
    let compact: Bool

    var body: some View {
        VStack(spacing: 0) {
            if compact {
                if navigation.showCompactDiff, access.ready, model.selection != nil {
                    ProjectChangesDiffPane(
                        model: model, navigation: navigation, access: access, projectName: projectName, compact: true)
                } else {
                    ProjectChangesNavigator(model: model, navigation: navigation, access: access)
                }
            } else {
                HSplitView {
                    ProjectChangesNavigator(model: model, navigation: navigation, access: access)
                        .frame(minWidth: 260, idealWidth: 340, maxWidth: 520)
                    ProjectChangesDiffPane(
                        model: model, navigation: navigation, access: access, projectName: projectName,
                        compact: false
                    )
                    .frame(minWidth: 440)
                }
            }
            ProjectChangesFeedback(model: model)
        }
        .onChange(of: compact) { _, compact in
            if compact, model.selection != nil { navigation.showCompactDiff = true }
        }
    }
}

private struct ProjectChangesInitialState: View {
    let model: ProjectChangesModel
    let ready: Bool

    var body: some View {
        Group {
            if ready, let error = model.refreshError {
                ContentUnavailableView {
                    Label("Changes unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await model.refresh() } }.buttonStyle(DieterBarButtonStyle(size: 28))
                }
            } else {
                ProgressView("Reading changes…")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Navigator

private struct ProjectChangesNavigator: View {
    let model: ProjectChangesModel
    let navigation: ProjectChangesNavigation
    let access: ProjectChangesAccess
    @AppStorage("DieterChangesTreeView") private var treeView = true
    @FocusState private var fileListFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if !access.standalone { embeddedToolbar }
            if access.ready, model.changes != nil {
                ProjectCommitComposer(model: model, access: access)
                    .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 8)
                ProjectFileListToolbar(model: model, navigation: navigation)
                    .padding(.horizontal, 10).padding(.bottom, 4)
                fileList
            } else {
                ProjectChangesInitialState(model: model, ready: access.ready)
            }
        }.background(DieterTheme.sidebar)
    }

    /// A conversation's review tab has no pane header, so its Git actions sit atop the list.
    private var embeddedToolbar: some View {
        HStack(spacing: 6) {
            ProjectBranchSummary(model: model, ready: access.ready)
            Spacer(minLength: 4)
            ProjectShipActions(model: model, access: access, iconOnly: true, size: 26)
            ProjectRefreshButton(model: model, size: 26)
        }
        .padding(.horizontal, 12).frame(height: 34)
        .overlay(alignment: .bottom) { Divider().overlay(DieterTheme.border) }
    }

    private var fileList: some View {
        let listing = navigation.listing(model, tree: treeView)
        let selection = model.selection
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    fileSection("Staged Changes", listing.staged, selection: selection)
                    fileSection("Changes", listing.unstaged, selection: selection)
                }.padding(.horizontal, 4).padding(.bottom, 10)
            }
            .focusable().focused($fileListFocused).focusEffectDisabled()
            .onKeyPress(.downArrow) {
                navigation.move(by: 1, in: model, tree: treeView); return .handled
            }
            .onKeyPress(.upArrow) {
                navigation.move(by: -1, in: model, tree: treeView); return .handled
            }
            .onKeyPress(.space) {
                toggleSelectedStage(); return .handled
            }
            .onChange(of: model.selection) { _, selection in
                if let selection { proxy.scrollTo(projectRowID(selection.section, selection.path)) }
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Changed files")
            .accessibilityIdentifier("project-changes.files").e2eTarget("project-changes.files")
        }
    }

    private func fileSection(
        _ title: String, _ section: ProjectChangeListing.Section, selection: ProjectChangeSelection?
    ) -> some View {
        Section {
            if !section.folded {
                if section.rows.isEmpty {
                    Text(
                        section.count == 0
                            ? (section.staged ? "No staged files" : "No local changes") : "No matching files"
                    )
                    .font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary)
                    .padding(.leading, 22).frame(height: ProjectChangesMetrics.rowHeight)
                }
                ForEach(section.rows, id: \.self) { row in
                    switch row.kind {
                    case .folder:
                        ProjectFolderRow(
                            model: model, navigation: navigation, row: row, section: section.name,
                            folded: navigation.collapsed.contains(projectRowID(section.name, row.path)),
                            access: access
                        )
                        .equatable()
                        .id(projectRowID(section.name, "/" + row.path))
                    case .file:
                        if let file = section.files[row.path] {
                            let target = ProjectChangeSelection(path: file.path, section: section.name)
                            ProjectFileRow(
                                model: model, navigation: navigation, file: file, depth: row.depth,
                                section: section.name, selected: selection == target, tree: treeView, access: access
                            ) {
                                fileListFocused = true
                                model.select(target)
                                navigation.showCompactDiff = true
                            }
                            .equatable()
                            .id(projectRowID(section.name, row.path))
                        }
                    }
                }
            }
        } header: {
            ProjectSectionHeader(
                model: model, navigation: navigation, title: title, section: section.name, count: section.count,
                folded: section.folded, access: access
            )
            .equatable()
        }
    }

    private func toggleSelectedStage() {
        guard let selection = model.selection else { return }
        let kind = selection.section == "staged" ? "unstage" : "stage"
        guard access.allows(kind, in: model) else { return }
        model.startOperation(kind: kind, path: selection.path)
    }
}

private struct ProjectCommitComposer: View {
    @Bindable var model: ProjectChangesModel
    let access: ProjectChangesAccess

    var body: some View {
        let count = model.stagedFiles.count
        let branch = model.changes?.branch ?? ""
        VStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    TextField(
                        "Commit subject", text: $model.commitSubject,
                        prompt: Text(branch.isEmpty ? "Message (⌘↩ to commit)" : "Message (⌘↩ to commit on \(branch))")
                            .foregroundStyle(DieterTheme.tertiary)
                    )
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityIdentifier("project-changes.commit-subject")
                    .e2eTarget("project-changes.commit-subject")
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
                .accessibilityIdentifier("project-changes.commit-body").e2eTarget("project-changes.commit-body")
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
            .buttonStyle(DieterBarButtonStyle(prominent: true, size: 28))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!access.allows("commit", in: model) || !commitReady)
            .help(count == 0 ? "Stage files to commit" : "Commit staged changes (⌘↩)")
            .accessibilityIdentifier("project-changes.commit").e2eTarget("project-changes.commit")
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
}

private struct ProjectFileListToolbar: View {
    let model: ProjectChangesModel
    @Bindable var navigation: ProjectChangesNavigation
    @AppStorage("DieterChangesTreeView") private var treeView = true

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10))
                    .foregroundStyle(DieterTheme.tertiary)
                TextField(
                    "Filter files", text: $navigation.filter,
                    prompt: Text("Filter files").foregroundStyle(DieterTheme.tertiary)
                )
                .textFieldStyle(.plain).font(.system(size: 11))
                .accessibilityIdentifier("project-changes.filter").e2eTarget("project-changes.filter")
                if !navigation.filter.isEmpty {
                    Button {
                        navigation.filter = ""
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
                let allCollapsed = navigation.listing(model, tree: true).allCollapsed
                iconButton(
                    allCollapsed ? "Expand all folders" : "Collapse all folders",
                    symbol: allCollapsed ? "plus.square.on.square" : "minus.square",
                    identifier: "project-changes.collapse-all"
                ) { navigation.toggleAllFolders(model) }
            }
            iconButton(
                treeView ? "View as list" : "View as tree",
                symbol: treeView ? "list.bullet" : "list.bullet.indent",
                identifier: "project-changes.view-mode"
            ) { treeView.toggle() }
        }
    }

    private func iconButton(
        _ title: String, symbol: String, identifier: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 24))
        .help(title).accessibilityLabel(title).accessibilityIdentifier(identifier)
    }
}

// MARK: Rows

/// A section's header; only its own hover re-renders it.
private struct ProjectSectionHeader: View, Equatable {
    let model: ProjectChangesModel
    let navigation: ProjectChangesNavigation
    let title: String
    let section: String
    let count: Int
    let folded: Bool
    let access: ProjectChangesAccess
    @State private var hovered = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.navigation === rhs.navigation && lhs.title == rhs.title
            && lhs.section == rhs.section && lhs.count == rhs.count && lhs.folded == rhs.folded
            && lhs.access == rhs.access
    }

    var body: some View {
        let staged = section == "staged"
        let kind = staged ? "unstage" : "stage"
        HStack(spacing: 4) {
            Button {
                navigation.toggle(section)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(folded ? 0 : 90)).frame(width: 12)
                    Text(title.uppercased()).tracking(0.6)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(count)")
            if count > 0 {
                ProjectStageButton(
                    model: model, title: staged ? "Unstage all" : "Stage all", symbol: staged ? "minus" : "plus",
                    kind: kind, path: "", identifier: "project-changes.\(kind)-all", emphasized: hovered,
                    access: access)
            }
            Text("\(count)").monospacedDigit()
                .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 15)
                .background(DieterTheme.elevated, in: Capsule())
        }
        .font(.system(size: 10, weight: .semibold)).foregroundStyle(DieterTheme.subtle)
        .padding(.leading, 2).padding(.trailing, 8).frame(height: 24)
        .padding(.top, staged ? 2 : 8)
        .background(DieterTheme.sidebar)
        .onHover { hovered = $0 }
    }
}

/// A folder in one section; only its own hover re-renders it.
private struct ProjectFolderRow: View, Equatable {
    @Environment(DieterStore.self) private var store
    let model: ProjectChangesModel
    let navigation: ProjectChangesNavigation
    let row: ChangeTreeRow
    let section: String
    let folded: Bool
    let access: ProjectChangesAccess
    @State private var hovered = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.navigation === rhs.navigation && lhs.row == rhs.row
            && lhs.section == rhs.section && lhs.folded == rhs.folded && lhs.access == rhs.access
    }

    var body: some View {
        let staged = section == "staged"
        HStack(spacing: 2) {
            Button {
                navigation.toggle(projectRowID(section, row.path))
            } label: {
                HStack(spacing: 4) {
                    Color.clear.frame(width: CGFloat(row.depth) * ProjectChangesMetrics.indent, height: 1)
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
            if hovered {
                if access.standalone {
                    ProjectRowIconButton(title: "Open folder in Files", symbol: "arrow.up.forward.square") {
                        openInFiles(store, row.path, directory: true)
                    }
                }
                if !staged {
                    ProjectRowIconButton(title: "Discard changes in folder", symbol: "arrow.uturn.backward") {
                        navigation.discard = .init(path: row.path, folder: true, fileCount: row.fileCount)
                    }
                    .disabled(!access.allows("discard_changes", in: model))
                }
            }
            ProjectStageButton(
                model: model, title: staged ? "Unstage folder" : "Stage folder", symbol: staged ? "minus" : "plus",
                kind: staged ? "unstage" : "stage", path: row.path,
                identifier: "project-changes.\(staged ? "unstage" : "stage")-folder.\(row.path)", emphasized: hovered,
                access: access)
            Text("\(row.fileCount)").font(.system(size: 10)).monospacedDigit()
                .foregroundStyle(DieterTheme.tertiary).frame(minWidth: 16, alignment: .trailing)
        }
        .padding(.leading, 4).padding(.trailing, 8)
        .background(hovered ? DieterTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 4))
        .onHover { hovered = $0 }
        .contextMenu { menu(staged: staged) }
    }

    @ViewBuilder private func menu(staged: Bool) -> some View {
        Button(staged ? "Unstage Folder" : "Stage Folder") {
            model.startOperation(kind: staged ? "unstage" : "stage", path: row.path)
        }.disabled(!access.allows(staged ? "unstage" : "stage", in: model))
        Button("Discard Changes in Folder…", role: .destructive) {
            navigation.discard = .init(path: row.path, folder: true, fileCount: row.fileCount)
        }.disabled(!access.allows("discard_changes", in: model))
        Divider()
        if access.standalone {
            Button("Open in Files") { openInFiles(store, row.path, directory: true) }
        }
        Button("Copy Path") { copyToPasteboard(row.path) }
        Divider()
        Button(folded ? "Expand" : "Collapse") { navigation.toggle(projectRowID(section, row.path)) }
        Button("Collapse All") { navigation.collapseAllFolders(model) }
    }
}

/// A changed file in one section; only its own hover re-renders it.
private struct ProjectFileRow: View, Equatable {
    @Environment(DieterStore.self) private var store
    let model: ProjectChangesModel
    let navigation: ProjectChangesNavigation
    let file: Dieter_V1_ChangedFile
    let depth: Int
    let section: String
    let selected: Bool
    /// The list is a tree, so files leave room for a folder's chevron.
    let tree: Bool
    let access: ProjectChangesAccess
    let select: () -> Void
    @State private var hovered = false

    /// Its action selects this file, so equal rows act alike.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.navigation === rhs.navigation && lhs.file == rhs.file
            && lhs.depth == rhs.depth && lhs.section == rhs.section && lhs.selected == rhs.selected
            && lhs.tree == rhs.tree && lhs.access == rhs.access
    }

    var body: some View {
        let status = section == "staged" ? file.indexStatus : file.worktreeStatus
        let stage = section != "staged"
        let emphasized = hovered || selected
        let label = ClientChangedFileLabel.of(
            file.path, status: status, conflicted: file.conflicted, untracked: status == "untracked")
        HStack(spacing: 2) {
            Button(action: select) {
                HStack(spacing: 4) {
                    Color.clear.frame(width: CGFloat(depth) * ProjectChangesMetrics.indent, height: 1)
                    Color.clear.frame(width: tree ? 12 : 0, height: 1)
                    Image(systemName: FilePresentation.symbol(name: label.filename)).font(.system(size: 10))
                        .foregroundStyle(DieterTheme.tertiary).frame(width: 15)
                    Text(label.filename).font(.system(size: 12))
                        .foregroundStyle(nameColor(status))
                        .strikethrough(status == "deleted", color: DieterTheme.coral.opacity(0.7))
                        .lineLimit(1).layoutPriority(1)
                    if !tree, !label.directory.isEmpty {
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
            .e2eTarget("project-changes.\(section).\(file.path)")
            if emphasized {
                if access.standalone, status != "deleted" {
                    ProjectRowIconButton(title: "Open file in Files", symbol: "arrow.up.forward.square") {
                        openInFiles(store, file.path, directory: false)
                    }
                }
                if stage {
                    ProjectRowIconButton(title: "Discard changes", symbol: "arrow.uturn.backward") {
                        navigation.discard = .init(path: file.path, folder: false, fileCount: 1)
                    }
                    .disabled(!access.allows("discard_changes", in: model))
                }
            }
            ProjectStageButton(
                model: model, title: stage ? "Stage \(file.path)" : "Unstage \(file.path)",
                symbol: stage ? "plus" : "minus", kind: stage ? "stage" : "unstage", path: file.path,
                identifier: "project-changes.\(stage ? "stage" : "unstage").\(file.path)", emphasized: emphasized,
                access: access)
            if file.staged && file.unstaged {
                Image(systemName: "circle.lefthalf.filled").font(.system(size: 8))
                    .foregroundStyle(DieterTheme.tertiary)
                    .help("This file has both staged and unstaged edits")
            }
            Text(label.badge)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(projectStatusColor(status)).frame(width: 14)
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
        .onHover { hovered = $0 }
        .contextMenu { menu(status: status, stage: stage) }
    }

    @ViewBuilder private func menu(status: String, stage: Bool) -> some View {
        if access.standalone, status != "deleted" {
            Button("Open in Files") { openInFiles(store, file.path, directory: false) }
            Divider()
        }
        Button(stage ? "Stage Changes" : "Unstage Changes") {
            model.startOperation(kind: stage ? "stage" : "unstage", path: file.path)
        }.disabled(!access.allows(stage ? "stage" : "unstage", in: model))
        Button("Discard Changes…", role: .destructive) {
            navigation.discard = .init(path: file.path, folder: false, fileCount: 1)
        }.disabled(!access.allows("discard_changes", in: model))
        Divider()
        Button("Copy Path") { copyToPasteboard(file.path) }
        Button("Copy File Name") { copyToPasteboard(ClientChangedFileLabel.of(file.path).filename) }
        if access.standalone, !access.projectRoot.isEmpty {
            Button("Copy Absolute Path") {
                copyToPasteboard((access.projectRoot as NSString).appendingPathComponent(file.path))
            }
        }
    }

    private func nameColor(_ status: String) -> Color {
        if file.conflicted { return DieterTheme.coral }
        switch status {
        case "added", "untracked": return DieterTheme.diffAddition
        case "deleted": return DieterTheme.coral
        default: return DieterTheme.text
        }
    }
}

/// Stages or unstages a path; the row's primary action stays visible so it can be pressed directly.
private struct ProjectStageButton: View {
    let model: ProjectChangesModel
    let title: String
    let symbol: String
    let kind: String
    let path: String
    let identifier: String
    let emphasized: Bool
    let access: ProjectChangesAccess

    var body: some View {
        let allowed = access.allows(kind, in: model)
        Button {
            model.startOperation(kind: kind, path: path)
        } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(emphasized ? DieterTheme.text : DieterTheme.tertiary.opacity(0.7))
        .disabled(!allowed).opacity(allowed ? 1 : 0.4)
        .help(title).accessibilityLabel(title)
        .accessibilityIdentifier(identifier).e2eTarget(identifier)
    }
}

private struct ProjectRowIconButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(DieterTheme.subtle)
        .help(title).accessibilityLabel(title)
    }
}

@MainActor private func projectStatusColor(_ status: String) -> Color {
    switch status {
    case "added", "untracked": DieterTheme.diffAddition
    case "deleted", "conflicted": DieterTheme.coral
    default: DieterTheme.amber
    }
}

// MARK: Diff

private struct ProjectChangesDiffPane: View {
    let model: ProjectChangesModel
    let navigation: ProjectChangesNavigation
    let access: ProjectChangesAccess
    let projectName: String
    let compact: Bool

    var body: some View {
        VStack(spacing: 0) {
            if access.ready, let selection = model.selection {
                ProjectDiffToolbar(
                    model: model, navigation: navigation, access: access, selection: selection, compact: compact)
                Divider().overlay(DieterTheme.border)
                if let error = model.diffError {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle").lineLimit(2); Spacer()
                        Button("Retry") { model.retryDiff() }.buttonStyle(DieterBarButtonStyle(size: 26))
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
                        .equatable()
                        .id("\(model.projectID)|\(selection.section)|\(selection.path)")
                        .accessibilityIdentifier("project-changes.diff").e2eTarget("project-changes.diff")
                    }
                } else if model.diffLoading {
                    ProgressView("Loading diff…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer()
                }
            } else if !access.ready || model.changes == nil {
                ProjectChangesInitialState(model: model, ready: access.ready)
            } else {
                ContentUnavailableView(
                    "Working tree is clean", systemImage: "checkmark.circle",
                    description: Text("No local changes in \(projectName).")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("project-changes.clean").e2eTarget("project-changes.clean")
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ProjectDiffToolbar: View {
    @Environment(DieterStore.self) private var store
    @AppStorage("DieterDiffViewMode") private var diffMode = "Inline"
    @AppStorage("DieterChangesTreeView") private var treeView = true
    let model: ProjectChangesModel
    let navigation: ProjectChangesNavigation
    let access: ProjectChangesAccess
    let selection: ProjectChangeSelection
    let compact: Bool

    var body: some View {
        let staged = selection.section == "staged"
        let file = model.changes?.files.first(where: { $0.path == selection.path })
        let status = (staged ? file?.indexStatus : file?.worktreeStatus) ?? "modified"
        let label = ClientChangedFileLabel.of(selection.path, status: status, untracked: status == "untracked")
        let listing = navigation.listing(model, tree: treeView)
        let position = listing.position(of: selection)
        let total = listing.order.count
        ViewThatFits(in: .horizontal) {
            content(file: file, label: label, status: status, position: position, total: total, wide: true)
            content(file: file, label: label, status: status, position: position, total: total, wide: false)
        }
        .padding(.horizontal, 10).frame(height: ProjectChangesMetrics.toolbarHeight)
        .background(DieterTheme.sidebar)
    }

    private func content(
        file: Dieter_V1_ChangedFile?, label: ClientChangedFileLabel, status: String, position: Int?, total: Int,
        wide: Bool
    ) -> some View {
        let staged = selection.section == "staged"
        return HStack(spacing: 8) {
            if compact {
                Button {
                    navigation.showCompactDiff = false
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 28)).help("Back to files").accessibilityLabel(
                    "Back to files"
                )
                .accessibilityIdentifier("project-changes.back").e2eTarget("project-changes.back")
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
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(projectStatusColor(status))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(projectStatusColor(status).opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()
            if let file {
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
            Button("Discard") { navigation.discard = .init(path: selection.path, folder: false, fileCount: 1) }
                .buttonStyle(DieterBarButtonStyle(destructive: true, size: 28))
                .disabled(!access.allows("discard_changes", in: model))
                .help("Discard all changes to this file")
                .accessibilityIdentifier("project-changes.discard").e2eTarget("project-changes.discard")
            Button(staged ? "Unstage" : "Stage") {
                model.startOperation(kind: staged ? "unstage" : "stage", path: selection.path)
            }
            .buttonStyle(DieterBarButtonStyle(prominent: true, size: 28))
            .disabled(!access.allows(staged ? "unstage" : "stage", in: model))
            .help(staged ? "Unstage this file (Space)" : "Stage this file (Space)")
            .accessibilityIdentifier("project-changes.stage-file").e2eTarget("project-changes.stage-file")
            Menu {
                if access.standalone, status != "deleted" {
                    Button("Open in Files") { openInFiles(store, selection.path, directory: false) }
                    Divider()
                }
                Button("Copy Path") { copyToPasteboard(selection.path) }
                Button("Copy File Name") { copyToPasteboard(label.filename) }
                Divider()
                Button("Discard Changes…", role: .destructive) {
                    navigation.discard = .init(path: selection.path, folder: false, fileCount: 1)
                }
                .disabled(!access.allows("discard_changes", in: model))
            } label: {
                DieterMenuLabel(symbol: "ellipsis", size: 28)
            }
            .dieterMenuChrome(.circle)
            .accessibilityLabel("File actions").accessibilityIdentifier("project-changes.file-actions")
        }
    }

    /// Steps through changed files in list order without leaving the diff.
    private func fileStepper(position: Int?, total: Int, wide: Bool) -> some View {
        HStack(spacing: 4) {
            Button {
                navigation.move(by: -1, in: model, tree: treeView)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled((position ?? 0) <= 0).help("Previous file (↑)").accessibilityLabel("Previous file")
            .accessibilityIdentifier("project-changes.previous-file")
            if wide, let position {
                Text("\(position + 1)/\(total)").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DieterTheme.tertiary).fixedSize()
            }
            Button {
                navigation.move(by: 1, in: model, tree: treeView)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(position.map { $0 >= total - 1 } ?? true).help("Next file (↓)").accessibilityLabel("Next file")
            .accessibilityIdentifier("project-changes.next-file")
        }
        .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 26))
    }

    private var diffModePicker: some View {
        DieterSegmentTrack(height: 28) {
            ForEach(["Inline", "Split"], id: \.self) { mode in
                Button(mode) { diffMode = mode }
                    .buttonStyle(DieterSegmentStyle(selected: diffMode == mode, height: 22))
                    .accessibilityLabel("\(mode) diff").accessibilityAddTraits(diffMode == mode ? .isSelected : [])
                    .accessibilityIdentifier("project-changes.diff-mode.\(mode.lowercased())")
                    .e2eTarget("project-changes.diff-mode.\(mode.lowercased())")
            }
        }
        .fixedSize()
        .accessibilityIdentifier("project-changes.diff-mode").e2eTarget("project-changes.diff-mode")
    }
}

// MARK: Status

private struct ProjectChangesFeedback: View {
    let model: ProjectChangesModel

    var body: some View {
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
        .accessibilityIdentifier("project-changes.status").e2eTarget("project-changes.status")
    }
}
