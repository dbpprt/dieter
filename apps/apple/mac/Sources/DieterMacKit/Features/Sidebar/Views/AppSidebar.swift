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
/// projects, then machines and quotas. Each part observes what it shows, so
/// chat, activity, and selection updates redraw only their own part.
struct AppSidebar: View {
    @Environment(DieterStore.self) private var store
    @State private var folderEditor: NavigationFolderEditor?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            topBand
            SidebarPrimaryDestinations()

            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        SidebarProjectsSection(folderEditor: $folderEditor)
                        Spacer(minLength: 0)
                        SidebarNavigationSyncStatus()
                        SidebarStatusPanel()
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)
                    }
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
                .scrollIndicators(.automatic)
            }
            .clipped()
            .e2eTarget("sidebar.scroll-region")
            SidebarActions()
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

    private func saveProjectFolder(editor: NavigationFolderEditor, name: String) {
        if let folderID = editor.folderID {
            store.renameFolder(.projects, folderID: folderID, name: name)
        } else {
            store.createFolder(.projects, name: name)
        }
    }
}

/// Inbox, Chats, Terminals, and Screens. Each count observes its own source.
private struct SidebarPrimaryDestinations: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        let section = store.section
        VStack(spacing: 1) {
            DieterNavRow(title: "Inbox", symbol: "tray", selected: section == .inbox) {
                SidebarInboxCount()
            } action: {
                Task { await store.openInbox() }
            }
            .accessibilityIdentifier("sidebar.inbox").e2eTarget("sidebar.inbox")

            DieterNavRow(title: "Channels", symbol: "number", selected: section == .channels) {
                SidebarChannelsCount()
            } action: {
                store.openChannels()
            }
            .accessibilityIdentifier("sidebar.channels").e2eTarget("sidebar.channels")

            DieterNavRow(title: "Chats", symbol: "bubble.left.and.bubble.right", selected: section == .chats) {
                SidebarChatsCount()
            } action: {
                Task { await store.openChats() }
            }
            .accessibilityIdentifier("sidebar.all-chats").e2eTarget("sidebar.all-chats")

            DieterNavRow(title: "Terminals", symbol: "terminal", selected: section == .terminals) {
                SidebarTerminalsCount()
            } action: {
                Task { await store.openTerminals() }
            }
            .accessibilityIdentifier("sidebar.terminals").e2eTarget("sidebar.terminals")

            DieterNavRow(
                title: "Screens", symbol: "rectangle.inset.filled.and.person.filled",
                selected: section == .screens
            ) {
                SidebarScreensCount()
            } action: {
                store.openScreens()
            }
            .accessibilityIdentifier("sidebar.screens").e2eTarget("sidebar.screens")
        }
        .padding(.horizontal, 8)
    }
}

private struct SidebarInboxCount: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        let attention = Int(store.activity.summary.attention)
        if attention > 0 { DieterRowCount(count: attention, attention: true) }
    }
}

/// Unread agent channel messages, as the core counts them.
private struct SidebarChannelsCount: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        let unread = store.channelsModel.unread
        if unread > 0 {
            DieterCountBadge(count: unread, tint: DieterTheme.coral)
                .accessibilityLabel("\(store.channelsModel.slice.unreadLabel) unread")
        }
    }
}

private struct SidebarChatsCount: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        let active = store.chats.count(where: { !$0.archived })
        if active > 0 { DieterRowCount(count: active) }
    }
}

private struct SidebarTerminalsCount: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        let running = store.terminalsModel.terminals.count(where: { $0.status == "running" })
        if running > 0 { DieterRowCount(count: running) }
    }
}

private struct SidebarScreensCount: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        let screens = store.screensModel.connectedCount
        if screens > 0 { DieterRowCount(count: screens) }
    }
}

/// The projects in the core's layout, in folders when there are any, with
/// each project's active conversations. Rows take values, so an activity or
/// selection change redraws only the rows it touches.
private struct SidebarProjectsSection: View {
    @Environment(DieterStore.self) private var store
    @Binding var folderEditor: NavigationFolderEditor?
    @State private var unfiledDropTargeted = false
    @State private var projectsHeaderHovering = false

    var body: some View {
        let layout = store.navigation.projects
        let projectsByID = Dictionary(
            store.projects.filter { !$0.archived }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let projects = layout.order.compactMap { projectsByID[$0] }
        let folders = layout.folders
        let unfiledProjects = layout.unfiled.compactMap { projectsByID[$0] }
        let expanded = Set(layout.expanded), pinned = Set(layout.pinned)
        let activity = SidebarProjectActivity.group(store.inboxEntries)
        let showsProject = [AppSection.board, .files, .changes, .schedules].contains(store.section)
        let selectedProjectID: String? = showsProject ? store.selectedProjectID : nil
        func row(_ project: Dieter_V1_Project, groupIDs: [String]) -> SidebarProjectNavigationRow {
            SidebarProjectNavigationRow(
                project: project, groupIDs: groupIDs, expanded: expanded.contains(project.id),
                pinned: pinned.contains(project.id), selected: selectedProjectID == project.id,
                activity: activity[project.id] ?? [])
        }
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
                    row(project, groupIDs: layout.order)
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
                            row(project, groupIDs: folder.itemIds)
                        }
                    }
                }

                ForEach(unfiledProjects, id: \.id) { project in
                    row(project, groupIDs: layout.unfiled)
                }
            }
            SidebarProjectInsertionTarget(beforeProjectID: nil)
        }
        .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 10)
    }
}

/// A project row and the insertion target above it. A drop moves the project
/// within `groupIDs`, the projects shown with it.
private struct SidebarProjectNavigationRow: View {
    let project: Dieter_V1_Project
    let groupIDs: [String]
    let expanded: Bool
    let pinned: Bool
    let selected: Bool
    let activity: [InboxActivityEntry]

    var body: some View {
        SidebarProjectInsertionTarget(beforeProjectID: project.id)
        SidebarProjectRow(
            project: project, projectIDs: groupIDs, expanded: expanded, pinned: pinned, selected: selected,
            activity: activity
        )
        .equatable()
    }
}

/// Navigation edits waiting to sync, or why they cannot.
private struct SidebarNavigationSyncStatus: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
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
    }
}

/// Add a Git project, and Settings, highlighted while Settings shows.
private struct SidebarActions: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
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
