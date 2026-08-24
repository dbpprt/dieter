import AppKit
import DieterAPI
import SwiftUI

struct DieterRootView: View {
    @Environment(DieterStore.self) private var store
    @State private var navigationCollapsed = false

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            AppSidebar(collapsed: $navigationCollapsed)
                .frame(width: navigationCollapsed ? DieterMetrics.sidebarCollapsedWidth : DieterMetrics.sidebarExpandedWidth)
            Divider().overlay(DieterTheme.border)
                .ignoresSafeArea(.container, edges: .top)
            Group {
                switch store.section {
                case .board: BoardView()
                case .chats: ChatsView()
                case .terminals: TerminalsView()
                case .files: FilesView()
                case .schedules: SchedulesView()
                case .archive: ArchiveView()
                case .settings: DieterSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.snappy(duration: 0.24), value: navigationCollapsed)
        .background(DieterTheme.background)
        .background(WindowTitleBarDoubleClickHandler())
        .foregroundStyle(DieterTheme.text)
        .overlay {
            if !store.phase.isConnected && (!store.hasLoadedWorkspace || store.phase.needsConnectionOverlay) { ConnectionOverlay() }
        }
        .overlay(alignment: .topTrailing) {
            if !store.phase.isConnected && store.hasLoadedWorkspace {
                HStack(spacing: 7) { ProgressView().controlSize(.mini); Text("Reconnecting…") }
                    .font(.caption.weight(.medium)).padding(.horizontal, 11).frame(height: 30)
                    .background(DieterTheme.elevated, in: Capsule()).padding(10)
                    .accessibilityIdentifier("connection.reconnecting")
            }
        }
        .sheet(isPresented: $store.createConversationPresented) { NewConversationSheet().environment(store) }
        .sheet(isPresented: $store.createProjectPresented) { NewProjectSheet().environment(store) }
        .sheet(isPresented: $store.createBoardPresented) { NewBoardSheet().environment(store) }
        .sheet(isPresented: $store.renameBoardPresented) { RenameBoardSheet().environment(store) }
        .sheet(isPresented: $store.projectContextPresented) { ProjectContextSheet().environment(store) }
        .sheet(isPresented: $store.labelsPresented) { LabelsSheet().environment(store) }
        .sheet(isPresented: $store.archivePolicyPresented) { ArchivePolicySheet().environment(store) }
        .sheet(isPresented: $store.commandPalettePresented) { CommandPalette().environment(store) }
        .alert("Dieter", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

struct AppSidebar: View {
    @Environment(DieterStore.self) private var store
    @Binding var collapsed: Bool
    @State private var projectNavigation = SidebarProjectNavigationPreferences.load(from: SidebarProjectNavigationPreferences.applicationDefaults())

    private var visibleProjects: [Dieter_V1_Project] {
        let projects = store.projects.filter { !$0.archived }
        let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        return projectNavigation.orderedIDs(from: projects.map(\.id)).compactMap { byID[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
            searchControl
            allChatsControl

            ScrollView {
                if collapsed { collapsedProjects } else { expandedProjects }
            }
            sidebarFooter
        }
        .background(DieterTheme.sidebar)
        .clipped()
    }

    @ViewBuilder private var sidebarHeader: some View {
        if collapsed {
            SidebarRailToggle { collapsed = false }
            .help("Expand navigation (⌃⌘S)")
            .keyboardShortcut("s", modifiers: [.command, .control])
            .accessibilityLabel("Expand navigation")
            .accessibilityIdentifier("sidebar.toggle")
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        } else {
            HStack(spacing: 9) {
                DieterBrandIcon(size: 24)
                Text("Dieter").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 4)
                SidebarUtilityButton(symbol: "sidebar.left", help: "Collapse navigation (⌃⌘S)") { collapsed = true }
                    .keyboardShortcut("s", modifiers: [.command, .control])
                    .accessibilityIdentifier("sidebar.toggle")
                SidebarUtilityButton(symbol: "plus", help: "Add Git project") { store.createProjectPresented = true }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
    }

    @ViewBuilder private var searchControl: some View {
        Button { store.commandPalettePresented = true } label: {
            if collapsed {
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(DieterTheme.subtle)
                    .frame(width: 34, height: 30)
                    .background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: DieterMetrics.controlRadius, style: .continuous))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(DieterTheme.tertiary)
                    Text("Search").font(.system(size: 12)).foregroundStyle(DieterTheme.tertiary)
                    Spacer()
                    Text("⌘K").font(.system(size: 10, weight: .medium)).foregroundStyle(DieterTheme.tertiary)
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: DieterMetrics.controlRadius, style: .continuous))
            }
        }
        .buttonStyle(.plain).help("Search and commands")
        .frame(maxWidth: .infinity)
        .padding(.horizontal, collapsed ? 12 : 10).padding(.bottom, 6)
    }

    @ViewBuilder private var allChatsControl: some View {
        let activeChats = store.chats.filter { !$0.archived }
        if collapsed {
            SidebarRailDestination(
                title: "All chats",
                symbol: "bubble.left.and.bubble.right",
                selected: store.section == .chats,
                badge: activeChats.count
            ) { Task { await store.openChats() } }
            .padding(.top, 9)
            .accessibilityIdentifier("sidebar.all-chats")
        } else {
            SidebarDestination(
                title: "All chats",
                symbol: "bubble.left.and.bubble.right",
                selected: store.section == .chats,
                badge: activeChats.count,
                prominentBadge: true
            ) { Task { await store.openChats() } }
            .padding(.horizontal, 8).padding(.top, 9)
            .accessibilityIdentifier("sidebar.all-chats")
        }

        if collapsed {
            SidebarRailDestination(
                title: "Terminals",
                symbol: "terminal",
                selected: store.section == .terminals,
                badge: store.terminals.filter { $0.status == "running" }.count
            ) { Task { await store.openTerminals() } }
            .accessibilityIdentifier("sidebar.terminals")
        } else {
            SidebarDestination(
                title: "Terminals",
                symbol: "terminal",
                selected: store.section == .terminals,
                badge: store.terminals.filter { $0.status == "running" }.count
            ) { Task { await store.openTerminals() } }
            .padding(.horizontal, 8)
            .accessibilityIdentifier("sidebar.terminals")
        }
    }

    private var expandedProjects: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(visibleProjects, id: \.id) { project in
                SidebarProjectInsertionTarget(beforeProjectID: project.id) { moveProject($0, before: project.id) }
                SidebarExpandedProject(
                    project: project,
                    projectIDs: visibleProjects.map(\.id),
                    collapsed: projectNavigation.isCollapsed(project.id),
                    toggleCollapsed: { toggleProject(project.id) },
                    moveProject: moveProject
                )
            }
            SidebarProjectInsertionTarget(beforeProjectID: nil) { moveProject($0, before: nil) }
        }
        .padding(.horizontal, 8).padding(.vertical, 10)
    }

    private var collapsedProjects: some View {
        LazyVStack(spacing: 8) {
            ForEach(visibleProjects, id: \.id) { project in
                VStack(spacing: 5) {
                    if let machine = store.machine(forProjectID: project.id) {
                        Text(machine.name.prefix(2).uppercased())
                            .font(.system(size: 7, weight: .bold, design: .rounded))
                            .foregroundStyle(machine.online ? DieterTheme.eyes : DieterTheme.tertiary)
                            .frame(width: 24, height: 13)
                            .background((machine.online ? DieterTheme.eyes : DieterTheme.tertiary).opacity(0.1), in: Capsule())
                            .help("\(project.name) · \(machine.name) · \(machine.online ? "Online" : "Offline")")
                    } else {
                        Rectangle().fill(DieterTheme.border).frame(width: 24, height: 1).padding(.vertical, 3)
                    }
                    ForEach(store.boards(for: project.id), id: \.id) { board in
                        SidebarRailDestination(
                            title: "\(project.name) / \(board.name)",
                            symbol: "rectangle.split.3x1",
                            selected: store.section == .board && store.selectedBoardID == board.id,
                            badge: board.projectID == store.selectedProjectID ? activeCount(board.id) : 0
                        ) { Task { await store.openBoard(board.id, projectID: project.id) } }
                        .accessibilityIdentifier("sidebar.board.\(board.id)")
                        .contextMenu {
                            Button("Rename board…", systemImage: "pencil") { store.presentRenameBoard(boardID: board.id) }
                            Button("New board…", systemImage: "plus") { store.presentNewBoard(projectID: project.id) }
                        }
                    }
                    SidebarRailDestination(title: "\(project.name) files", symbol: "folder", selected: store.section == .files && store.selectedProjectID == project.id) {
                        Task { await store.openProject(project.id, section: .files) }
                    }.accessibilityIdentifier("sidebar.files.\(project.id)")
                    SidebarRailDestination(title: "\(project.name) schedules", symbol: "calendar", selected: store.section == .schedules && store.selectedProjectID == project.id) {
                        Task { await store.openProject(project.id, section: .schedules) }
                    }.accessibilityIdentifier("sidebar.schedules.\(project.id)")
                }
            }
        }.padding(.vertical, 10)
    }

    @ViewBuilder private var sidebarFooter: some View {
        if collapsed {
            VStack(spacing: 6) {
                ForEach(store.machines) { machine in
                    ZStack(alignment: .bottomTrailing) {
                        Text(machine.name.prefix(1).uppercased())
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .frame(width: 28, height: 28)
                            .background(DieterTheme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                        Circle().fill(machine.online ? DieterTheme.eyes : DieterTheme.tertiary)
                            .frame(width: 7, height: 7).overlay(Circle().stroke(DieterTheme.sidebar, lineWidth: 2))
                            .offset(x: 2, y: 2)
                    }
                    .help("\(machine.name) · \(machineDetail(machine))")
                    .accessibilityLabel("\(machine.name), \(machineDetail(machine))")
                    .accessibilityIdentifier("machine.\(machine.daemonID ?? machine.id)")
                }
                SidebarRailDestination(title: "Settings", symbol: "gearshape", selected: store.section == .settings) { store.openSettings() }
                    .accessibilityIdentifier("sidebar.settings")
                SidebarRailDestination(title: "Add a Git project", symbol: "plus", selected: false) { store.createProjectPresented = true }
            }.frame(maxWidth: .infinity).padding(.vertical, 9)
        } else {
            VStack(spacing: 5) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("MACHINES").font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary)
                        Spacer()
                        Text("\(store.machines.filter(\.online).count) online").font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                    }
                    ForEach(store.machines) { machine in
                        HStack(spacing: 8) {
                            Circle().fill(machine.online ? DieterTheme.eyes : DieterTheme.tertiary).frame(width: 6, height: 6)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(machine.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                Text(machineDetail(machine))
                                    .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8).frame(height: 32)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("machine.\(machine.daemonID ?? machine.id)")
                    }
                }
                .padding(8)
                .background(DieterTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DieterTheme.border))

                SidebarDestination(title: "Settings", symbol: "gearshape", selected: store.section == .settings) { store.openSettings() }
                    .accessibilityIdentifier("sidebar.settings")
                SidebarFooterButton(title: "Add a Git project", symbol: "plus") { store.createProjectPresented = true }
            }.padding(8)
        }
    }

    private func activeCount(_ boardID: String) -> Int {
        store.navigationCards.values.flatMap { $0 }.filter { $0.boardID == boardID && ["running", "waiting_for_user", "review"].contains($0.runtime) }.count
    }

    private func toggleProject(_ projectID: String) {
        projectNavigation.toggleCollapsed(projectID)
        projectNavigation.save(to: SidebarProjectNavigationPreferences.applicationDefaults())
    }

    private func moveProject(_ projectID: String, before targetProjectID: String?) {
        guard projectNavigation.move(projectID, before: targetProjectID, availableIDs: visibleProjects.map(\.id)) else { return }
        projectNavigation.save(to: SidebarProjectNavigationPreferences.applicationDefaults())
    }

    private func machineDetail(_ machine: DieterEndpoint) -> String {
        guard machine.online else { return MachinePresenceText.lastSeen(machine.lastSeenAt) }
        guard let status = store.connectionStatus(for: machine) else { return "Measuring…" }
        return "\(status.route.rawValue) · \(status.latencyMilliseconds) ms"
    }
}

private struct SidebarExpandedProject: View {
    @Environment(DieterStore.self) private var store
    let project: Dieter_V1_Project
    let projectIDs: [String]
    let collapsed: Bool
    let toggleCollapsed: () -> Void
    let moveProject: (String, String?) -> Void
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button(action: toggleCollapsed) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DieterTheme.tertiary)
                        .frame(width: 10, height: 18)
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Expand \(project.name)" : "Collapse \(project.name)")
                .accessibilityLabel(collapsed ? "Expand \(project.name)" : "Collapse \(project.name)")
                .accessibilityIdentifier("sidebar.project.\(project.id).toggle")

                Text(project.name.uppercased())
                    .font(DieterFont.sectionLabel).tracking(0.8)
                    .foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                if let machine = store.machine(forProjectID: project.id) {
                    ProjectMachineBadge(machine: machine)
                }
                Spacer()
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(dropTargeted ? DieterTheme.shell : DieterTheme.tertiary.opacity(0.65))
                    .accessibilityHidden(true)
                Button { store.presentNewBoard(projectID: project.id) } label: {
                    Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(DieterTheme.subtle).help("New board in \(project.name)")
            }
            .padding(.horizontal, 9).frame(height: 24)
            .contentShape(Rectangle())
            .background(dropTargeted ? DieterTheme.shellDeep.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .draggable(SidebarProjectDragPayload(projectID: project.id).encoded) {
                SidebarProjectDragPreview(project: project)
            }
            .dropDestination(for: String.self) { values, location in
                guard let value = values.first, let payload = SidebarProjectDragPayload(value), payload.projectID != project.id else { return false }
                let targetIndex = projectIDs.firstIndex(of: project.id) ?? 0
                let beforeProjectID: String?
                if location.y < 12 {
                    beforeProjectID = project.id
                } else if projectIDs.indices.contains(targetIndex + 1) {
                    beforeProjectID = projectIDs[targetIndex + 1]
                } else {
                    beforeProjectID = nil
                }
                moveProject(payload.projectID, beforeProjectID)
                return true
            } isTargeted: { dropTargeted = $0 }
            .animation(.easeOut(duration: 0.12), value: dropTargeted)
            .help("Drag to reorder \(project.name)")
            .accessibilityIdentifier("sidebar.project.\(project.id)")

            if !collapsed {
                ForEach(store.boards(for: project.id), id: \.id) { board in
                    SidebarDestination(
                        title: board.name,
                        symbol: "rectangle.split.3x1",
                        selected: store.section == .board && store.selectedBoardID == board.id,
                        badge: board.projectID == store.selectedProjectID ? activeCount(board.id) : 0
                    ) { Task { await store.openBoard(board.id, projectID: project.id) } }
                    .accessibilityIdentifier("sidebar.board.\(board.id)")
                    .contextMenu {
                        Button("Rename board…", systemImage: "pencil") { store.presentRenameBoard(boardID: board.id) }
                        Button("New board…", systemImage: "plus") { store.presentNewBoard(projectID: project.id) }
                    }
                }

                SidebarDestination(title: "Files", symbol: "folder", selected: store.section == .files && store.selectedProjectID == project.id) {
                    Task { await store.openProject(project.id, section: .files) }
                }.accessibilityIdentifier("sidebar.files.\(project.id)")

                SidebarDestination(title: "Schedules", symbol: "calendar", selected: store.section == .schedules && store.selectedProjectID == project.id) {
                    Task { await store.openProject(project.id, section: .schedules) }
                }.accessibilityIdentifier("sidebar.schedules.\(project.id)")
            }
        }
        .padding(.bottom, 4)
        .animation(.snappy(duration: 0.18), value: collapsed)
    }

    private func activeCount(_ boardID: String) -> Int {
        store.navigationCards.values.flatMap { $0 }.filter { $0.boardID == boardID && ["running", "waiting_for_user", "review"].contains($0.runtime) }.count
    }
}

private struct SidebarProjectInsertionTarget: View {
    let beforeProjectID: String?
    let moveProject: (String) -> Void
    @State private var targeted = false

    var body: some View {
        ZStack {
            Color.clear
            if targeted {
                HStack(spacing: 5) {
                    Circle().fill(DieterTheme.shell).frame(width: 5, height: 5)
                    Capsule().fill(DieterTheme.shell).frame(height: 2)
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(height: 8)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first, let payload = SidebarProjectDragPayload(value), payload.projectID != beforeProjectID else { return false }
            moveProject(payload.projectID)
            return true
        } isTargeted: { targeted = $0 }
        .animation(.easeOut(duration: 0.12), value: targeted)
    }
}

private struct SidebarProjectDragPreview: View {
    let project: Dieter_V1_Project

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill").foregroundStyle(DieterTheme.shell)
            Text(project.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 12).frame(width: 190, height: 38, alignment: .leading)
        .background(DieterTheme.elevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(DieterTheme.shell.opacity(0.4)))
        .shadow(color: Color.black.opacity(0.4), radius: 14, y: 7)
    }
}

struct SidebarProjectDragPayload: Equatable {
    private static let prefix = "dieter:sidebar-project:"
    let projectID: String

    init(projectID: String) {
        self.projectID = projectID
    }

    init?(_ encoded: String) {
        guard encoded.hasPrefix(Self.prefix) else { return nil }
        let projectID = String(encoded.dropFirst(Self.prefix.count))
        guard !projectID.isEmpty else { return nil }
        self.projectID = projectID
    }

    var encoded: String { Self.prefix + projectID }
}

private struct ProjectMachineBadge: View {
    let machine: DieterEndpoint

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(machine.online ? DieterTheme.eyes : DieterTheme.tertiary).frame(width: 5, height: 5)
            Text(machine.name).lineLimit(1)
        }
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(machine.online ? DieterTheme.subtle : DieterTheme.tertiary)
        .padding(.horizontal, 5).frame(height: 15)
        .background((machine.online ? DieterTheme.eyes : DieterTheme.tertiary).opacity(0.08), in: Capsule())
        .help("Runs on \(machine.name) · \(machine.online ? "Online" : "Offline")")
    }
}

private struct SidebarRailToggle: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? DieterTheme.surface : .clear)

                DieterBrandIcon(size: 24)
                    .opacity(hovering ? 0 : 1)

                Image(systemName: "sidebar.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DieterTheme.subtle)
                    .opacity(hovering ? 1 : 0)
            }
            .frame(width: 36, height: 32)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(hovering ? DieterTheme.strongBorder : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct DieterBrandIcon: View {
    let size: CGFloat

    private static let appImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "DieterAppIcon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    private static let faviconImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "DieterFavicon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        Group {
            if let image = size < 32 ? Self.faviconImage : Self.appImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "terminal.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(DieterTheme.shell)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct SidebarDestination: View {
    let title: String
    let symbol: String
    let selected: Bool
    var badge = 0
    var prominentBadge = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 16)
                    .foregroundStyle(selected ? DieterTheme.text : DieterTheme.subtle)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? DieterTheme.text : DieterTheme.subtle)
                    .lineLimit(1)
                Spacer()
                if badge > 0 {
                    if prominentBadge {
                        Text("\(badge)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).frame(height: 17).background(DieterTheme.shellDeep, in: Capsule())
                    } else {
                        Circle().fill(DieterTheme.amber).frame(width: 5, height: 5)
                        Text("\(badge)").font(.system(size: 10, weight: .medium)).foregroundStyle(DieterTheme.tertiary)
                    }
                }
            }
            .padding(.horizontal, 9).frame(height: DieterMetrics.navigationRowHeight)
            .background(selected ? DieterTheme.selection : (hovering ? DieterTheme.surface.opacity(0.7) : .clear), in: RoundedRectangle(cornerRadius: DieterMetrics.controlRadius, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SidebarRailDestination: View {
    let title: String
    let symbol: String
    let selected: Bool
    var badge = 0
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? DieterTheme.text : DieterTheme.subtle)
                    .frame(width: 36, height: 32)
                    .background(selected ? DieterTheme.selection : (hovering ? DieterTheme.surface : .clear), in: RoundedRectangle(cornerRadius: DieterMetrics.controlRadius, style: .continuous))
                if badge > 0 {
                    Text(badge > 9 ? "9+" : "\(badge)").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 3).frame(height: 12).background(DieterTheme.shellDeep, in: Capsule()).offset(x: 3, y: -2)
                }
            }
        }
        .buttonStyle(.plain).help(title).onHover { hovering = $0 }
        .accessibilityLabel(title)
        .frame(maxWidth: .infinity)
    }
}

private struct SidebarUtilityButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26) }
            .buttonStyle(.plain).foregroundStyle(hovering ? DieterTheme.text : DieterTheme.subtle)
            .background(hovering ? DieterTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }.help(help)
    }
}

private struct SidebarFooterButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) { Image(systemName: symbol).frame(width: 15); Text(title); Spacer() }
                .font(.system(size: 11, weight: .medium)).padding(.horizontal, 9).frame(height: 30)
                .background(hovering ? DieterTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}

struct ConnectionOverlay: View {
    @Environment(DieterStore.self) private var store
    @State private var address = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 17) {
                    DieterBrandIcon(size: 62)
                    VStack(spacing: 6) {
                        Text("Connect Dieter").font(.title2.weight(.bold))
                        Text("Choose the gateway that knows your account. Dieter automatically combines projects and conversations from every enrolled machine.")
                            .font(.system(size: 13)).foregroundStyle(DieterTheme.subtle)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        OnboardingConnectionConcept(symbol: "point.3.connected.trianglepath.dotted", title: "Gateway", detail: "Sign-in, machine discovery, encrypted relay")
                        Image(systemName: "arrow.right").foregroundStyle(DieterTheme.tertiary)
                        OnboardingConnectionConcept(symbol: "desktopcomputer", title: "All machines", detail: "One combined workspace with automatic routing")
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        Text("1  CHOOSE A GATEWAY").font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary)
                        ForEach(store.gateways) { gateway in
                            Button { Task { await store.chooseGateway(gateway) } } label: {
                                OnboardingGatewayRow(
                                    gateway: gateway,
                                    active: gateway.credentialID == store.activeGateway.credentialID
                                )
                            }.buttonStyle(.plain)
                        }
                        Text("The primary gateway is the normal choice. Add another only for a separate self-hosted or organizational deployment; its session and machines are separate.")
                            .font(.caption2).foregroundStyle(DieterTheme.tertiary).fixedSize(horizontal: false, vertical: true)
                    }

                    if store.phase == .authenticationRequired {
                        VStack(spacing: 8) {
                            Text("Sign in to \(store.activeGateway.name) to discover its enrolled machines.")
                                .font(.caption).foregroundStyle(DieterTheme.subtle)
                            Button("Sign in with GitHub") { Task { await store.signIn() } }.buttonStyle(.borderedProminent)
                        }
                    }

                    if !store.machines.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("MACHINES INCLUDED THROUGH \(store.activeGateway.name.uppercased())")
                                .font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary)
                            ForEach(store.machines) { machine in
                                OnboardingMachineRow(machine: machine)
                            }
                        }
                    }

                    DisclosureGroup("Use another gateway address") {
                        HStack {
                            TextField("https://dieter.example.com", text: $address).textFieldStyle(.roundedBorder)
                            Button("Save and discover") {
                                if let gateway = DieterEndpoint.parse(address, name: "Custom gateway"), gateway.secure {
                                    Task { await store.saveEndpoint(gateway) }
                                    address = ""
                                }
                            }.disabled(DieterEndpoint.parse(address)?.secure != true)
                        }.padding(.top, 8)
                    }
                    .font(.caption)

                    if case .connecting = store.phase {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Contacting \(store.activeGateway.name)…") }
                            .font(.caption).foregroundStyle(DieterTheme.subtle)
                    }
                    if case let .failed(message) = store.phase {
                        Text(message).font(.caption).foregroundStyle(DieterTheme.coral).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
            }
            .frame(width: 570)
            .frame(maxHeight: 720)
            .background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DieterTheme.strongBorder))
            .shadow(color: .black.opacity(0.4), radius: 28, y: 12)
        }
    }
}

private struct OnboardingConnectionConcept: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(DieterTheme.shell).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(detail).font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary).lineLimit(2)
            }
        }
        .padding(10).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.border))
    }
}

private struct OnboardingGatewayRow: View {
    let gateway: DieterEndpoint
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "network").foregroundStyle(DieterTheme.shell).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(gateway.name).font(.system(size: 12, weight: .semibold))
                    if gateway.credentialID == DieterEndpoint.defaults.first?.credentialID {
                        Text("PRIMARY").font(.system(size: 8, weight: .bold)).foregroundStyle(DieterTheme.eyes)
                    }
                }
                Text(gateway.address).font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
            Spacer()
            Image(systemName: active ? "checkmark.circle.fill" : "arrow.right")
                .foregroundStyle(active ? DieterTheme.eyes : DieterTheme.tertiary)
        }
        .padding(11).background(DieterTheme.raised, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(active ? DieterTheme.shell.opacity(0.4) : DieterTheme.border))
    }
}

private struct OnboardingMachineRow: View {
    let machine: DieterEndpoint

    private var detail: String {
        if !machine.online { return MachinePresenceText.lastSeen(machine.lastSeenAt) }
        return machine.version.isEmpty ? "Online" : "Online · Dieter \(machine.version)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(machine.online ? DieterTheme.eyes : DieterTheme.tertiary).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(machine.name).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
            Spacer()
            Text(machine.online ? "Included automatically" : "Offline")
                .font(.caption2).foregroundStyle(machine.online ? DieterTheme.shell : DieterTheme.tertiary)
        }
        .padding(11).background(DieterTheme.raised, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.border))
    }
}

struct CommandPalette: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var commands: [(String, String, () -> Void)] {
        [
            ("New card", "rectangle.badge.plus", { store.createConversationPresented = true }),
            ("New standalone chat", "bubble.left.and.bubble.right.fill", { store.beginStandaloneChat() }),
            ("Open all chats", "bubble.left.and.bubble.right", { Task { await store.openChats() } }),
            ("Open terminals", "terminal", { Task { await store.openTerminals() } }),
            ("Browse project files", "doc.on.doc", { Task { await store.openProject(store.selectedProjectID, section: .files) } }),
            ("Open project schedules", "calendar.badge.clock", { Task { await store.openProject(store.selectedProjectID, section: .schedules) } }),
            ("Add Git project", "folder.badge.plus", { store.createProjectPresented = true }),
            ("Edit project context", "text.book.closed", { store.projectContextPresented = true }),
            ("Refresh", "arrow.clockwise", { Task { await store.refreshState() } }),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(DieterTheme.tertiary)
                TextField("Type a command…", text: $query).textFieldStyle(.plain).font(.system(size: 16))
            }
            .padding(16)
            Divider().overlay(DieterTheme.border)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(commands.enumerated()).filter { query.isEmpty || $0.element.0.localizedCaseInsensitiveContains(query) }, id: \.offset) { _, command in
                        Button {
                            command.2(); dismiss()
                        } label: {
                            HStack { Image(systemName: command.1).font(.system(size: 12)).foregroundStyle(DieterTheme.subtle).frame(width: 22); Text(command.0).font(DieterFont.body); Spacer(); Image(systemName: "return").font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary) }
                                .padding(10).background(DieterTheme.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: DieterMetrics.controlRadius, style: .continuous))
                        }.buttonStyle(.plain)
                    }
                }.padding(10)
            }
        }.frame(width: 560, height: 410).background(DieterTheme.surface)
    }
}
