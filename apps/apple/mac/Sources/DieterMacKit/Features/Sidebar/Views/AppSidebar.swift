import DieterAPI
import SwiftUI

enum SidebarSizing {
    static let storageKey = "DieterSidebarWidth"
    static let minimumWidth: CGFloat = 220
    static let defaultWidth = DieterMetrics.sidebarExpandedWidth
    static let maximumWidth: CGFloat = 310

    static func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }
}

/// The navigation as a floating glass card: window controls, destinations,
/// projects, then machines and quotas.
struct AppSidebar: View {
    @Environment(DieterStore.self) private var store
    @State private var folderEditor: NavigationFolderEditor?
    @State private var unfiledDropTargeted = false
    @State private var projectsHeaderHovering = false

    /// The listed projects by ID; the core's layout names them in order.
    private var projectsByID: [String: Dieter_V1_Project] {
        Dictionary(
            store.projects.filter { !$0.archived }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBand
            primaryDestinations

            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        expandedProjects
                        Spacer(minLength: 0)
                        sidebarStatus
                    }
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
                .scrollIndicators(.automatic)
            }
            .clipped()
            .e2eTarget("sidebar.scroll-region")
            sidebarActions
                .fixedSize(horizontal: false, vertical: true)
        }
        .dieterPanel(radius: DieterMetrics.sidebarCardRadius)
        .padding(.leading, DieterMetrics.windowInset)
        .padding(.vertical, DieterMetrics.windowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.main-pane")
        .e2eTarget("sidebar.main-pane")
        .ignoresSafeArea(.container, edges: .top)
        .task(id: store.phase.isConnected) {
            // The quota subscription starts with the workspace, not with the
            // first popover; the panel below the machines shows it.
            guard store.phase.isConnected else { return }
            await store.quotas.load()
        }
        .sheet(item: $folderEditor) { editor in
            NavigationFolderNameSheet(
                editor: editor,
                existingNames: store.navigation.projects.folders.filter { $0.id != editor.folderID }.map(\.name),
                save: { saveProjectFolder(editor: editor, name: $0) }
            )
        }
    }

    private var topBand: some View {
        HStack(spacing: 0) {
            DieterWindowTrafficLights()
                .frame(width: 76, height: 36)
            Spacer(minLength: 4)
            Button {
                store.sidebarCollapsed = true
            } label: {
                Image(systemName: "sidebar.left").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 28))
            .help("Hide sidebar (⌃⌘S)")
            .accessibilityLabel("Hide sidebar")
            .accessibilityIdentifier("sidebar.hide")
        }
        .padding(.trailing, 8)
        .frame(height: 36)
        .background(DieterTitleBandRegion().e2eTarget("workspace.title-band"))
        .padding(.bottom, 6)
    }

    @ViewBuilder private var primaryDestinations: some View {
        let activeChats = store.chats.filter { !$0.archived }
        let attention = Int(store.activity.summary.attention)
        VStack(spacing: 1) {
            DieterNavRow(title: "Inbox", symbol: "tray", selected: store.section == .inbox) {
                if attention > 0 { DieterRowCount(count: attention, attention: true) }
            } action: {
                Task { await store.openInbox() }
            }
            .accessibilityIdentifier("sidebar.inbox").e2eTarget("sidebar.inbox")

            DieterNavRow(title: "Chats", symbol: "bubble.left.and.bubble.right", selected: store.section == .chats) {
                if !activeChats.isEmpty { DieterRowCount(count: activeChats.count) }
            } action: {
                Task { await store.openChats() }
            }
            .accessibilityIdentifier("sidebar.all-chats").e2eTarget("sidebar.all-chats")

            let runningTerminals = store.terminalsModel.terminals.filter { $0.status == "running" }.count
            DieterNavRow(title: "Terminals", symbol: "terminal", selected: store.section == .terminals) {
                if runningTerminals > 0 { DieterRowCount(count: runningTerminals) }
            } action: {
                Task { await store.openTerminals() }
            }
            .accessibilityIdentifier("sidebar.terminals").e2eTarget("sidebar.terminals")

            let screens = store.screensModel.connectedCount
            DieterNavRow(
                title: "Screens", symbol: "rectangle.inset.filled.and.person.filled",
                selected: store.section == .screens
            ) {
                if screens > 0 { DieterRowCount(count: screens) }
            } action: {
                store.openScreens()
            }
            .accessibilityIdentifier("sidebar.screens").e2eTarget("sidebar.screens")
        }
        .padding(.horizontal, 8)
    }

    private var expandedProjects: some View {
        let layout = store.navigation.projects
        let projectsByID = projectsByID
        let projects = layout.order.compactMap { projectsByID[$0] }
        let folders = layout.folders
        let unfiledProjects = layout.unfiled.compactMap { projectsByID[$0] }
        let expanded = Set(layout.expanded), pinned = Set(layout.pinned)
        let activity = SidebarProjectActivity.group(store.inboxEntries)
        return VStack(alignment: .leading, spacing: 0) {
            DieterSectionHeader(title: "Projects") {
                if projectsHeaderHovering {
                    Button {
                        folderEditor = .create(title: "New project folder")
                    } label: {
                        Image(systemName: "folder.badge.plus").font(.system(size: 10.5, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DieterTheme.tertiary)
                    .help("New project folder")
                    .accessibilityIdentifier("sidebar.project-folder.new")
                    Button {
                        store.createProjectPresented = true
                    } label: {
                        Image(systemName: "plus").font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(DieterTheme.tertiary).help("Add Git project")
                    .accessibilityIdentifier("sidebar.project.new")
                } else if !activity.isEmpty {
                    SidebarActivityLegend()
                }
            }
            .padding(.horizontal, 10).frame(height: 24)
            .contentShape(Rectangle())
            .onHover { projectsHeaderHovering = $0 }
            .background(
                unfiledDropTargeted ? DieterTheme.tileSelected : .clear,
                in: RoundedRectangle(cornerRadius: DieterMetrics.rowRadius, style: .continuous)
            )
            .dropDestination(for: String.self) { values, _ in
                guard !folders.isEmpty,
                    let value = values.first,
                    let payload = SidebarProjectDragPayload(value)
                else { return false }
                store.moveToFolder(.projects, itemID: payload.projectID, folderID: nil)
                return true
            } isTargeted: {
                unfiledDropTargeted = !folders.isEmpty && $0
            }

            if folders.isEmpty {
                ForEach(projects, id: \.id) { project in
                    projectNavigationRow(
                        project, groupIDs: layout.order, expanded: expanded.contains(project.id),
                        pinned: pinned.contains(project.id), activity: activity[project.id] ?? [])
                }
            } else {
                ForEach(folders, id: \.id) { folder in
                    let folderProjects = folder.itemIds.compactMap { projectsByID[$0] }
                    SidebarProjectFolderGroup(
                        folder: folder,
                        visibleCount: folderProjects.count,
                        toggleExpanded: {
                            store.setFolderExpanded(.projects, folderID: folder.id, expanded: !folder.expanded)
                        },
                        moveProjectHere: { store.moveToFolder(.projects, itemID: $0, folderID: folder.id) },
                        rename: { folderEditor = .rename(id: folder.id, name: folder.name) },
                        delete: { store.deleteFolder(.projects, folderID: folder.id) }
                    ) {
                        ForEach(folderProjects, id: \.id) { project in
                            projectNavigationRow(
                                project, groupIDs: folder.itemIds, expanded: expanded.contains(project.id),
                                pinned: pinned.contains(project.id), activity: activity[project.id] ?? [])
                        }
                    }
                }

                ForEach(unfiledProjects, id: \.id) { project in
                    projectNavigationRow(
                        project, groupIDs: layout.unfiled, expanded: expanded.contains(project.id),
                        pinned: pinned.contains(project.id), activity: activity[project.id] ?? [])
                }
            }
            SidebarProjectInsertionTarget(beforeProjectID: nil) {
                store.moveProject($0, before: nil, ungrouped: false)
            }
        }
        .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 10)
    }

    @ViewBuilder private var sidebarStatus: some View {
        if store.navigationPendingCount > 0 || store.navigationSyncError != nil {
            Text(
                store.navigationPendingCount > 0
                    ? "\(store.navigationPendingCount) navigation edits pending sync" : "Navigation sync unavailable"
            )
            .font(.caption2).foregroundStyle(DieterTheme.tertiary).padding(.horizontal, 14)
            .help(
                store.navigationSyncError ?? "Edits are saved on this device and will sync when a machine is reachable."
            )
            .accessibilityIdentifier("navigation.sync-status")
        }

        SidebarStatusPanel()
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)
    }

    private var sidebarActions: some View {
        HStack(spacing: 4) {
            Button {
                store.createProjectPresented = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).frame(width: 16)
                    Text("Add a Git project").font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DieterTheme.subtle)
                .padding(.horizontal, 9).frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sidebar.add-project")
            Button {
                store.openSettings()
            } label: {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(DieterBarButtonStyle(shape: .circle, prominent: store.section == .settings, size: 28))
            .accessibilityAddTraits(store.section == .settings ? .isSelected : [])
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("sidebar.settings").e2eTarget("sidebar.settings")
        }
        .padding(.horizontal, 8).padding(.bottom, 8).padding(.top, 2)
    }

    /// A project row and the insertion target above it. A drop moves the
    /// project within `groupIDs`, the projects shown with it.
    @ViewBuilder
    private func projectNavigationRow(
        _ project: Dieter_V1_Project, groupIDs: [String], expanded: Bool, pinned: Bool,
        activity: [InboxActivityEntry]
    ) -> some View {
        SidebarProjectInsertionTarget(beforeProjectID: project.id) {
            store.moveProject($0, before: project.id, ungrouped: false)
        }
        SidebarProjectRow(
            project: project,
            projectIDs: groupIDs,
            expanded: expanded,
            pinned: pinned,
            activity: activity,
            toggleExpanded: { store.setProjectExpanded(project.id, expanded: !expanded) },
            moveProject: { store.moveProject($0, before: $1, ungrouped: false) }
        )
    }

    private func saveProjectFolder(editor: NavigationFolderEditor, name: String) {
        if let folderID = editor.folderID {
            store.renameFolder(.projects, folderID: folderID, name: name)
        } else {
            store.createFolder(.projects, name: name)
        }
    }
}

/// "● running ● waiting", shown beside the Projects heading.
private struct SidebarActivityLegend: View {
    var body: some View {
        HStack(spacing: 8) {
            legend("running", DieterTheme.running)
            legend("waiting", DieterTheme.attention)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(DieterTheme.tertiary)
        .accessibilityHidden(true)
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            DieterStatusDot(color: color, size: 5)
            Text(title)
        }
    }
}
