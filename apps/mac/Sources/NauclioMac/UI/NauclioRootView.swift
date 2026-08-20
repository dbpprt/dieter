import AppKit
import NauclioAPI
import SwiftUI

struct NauclioRootView: View {
    @Environment(NauclioStore.self) private var store
    @State private var navigationCollapsed = false

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            AppSidebar(collapsed: $navigationCollapsed)
                .frame(width: navigationCollapsed ? NauclioMetrics.sidebarCollapsedWidth : NauclioMetrics.sidebarExpandedWidth)
            Divider().overlay(NauclioTheme.border)
            Group {
                switch store.section {
                case .board: BoardView()
                case .chats: ChatsView()
                case .files: FilesView()
                case .schedules: SchedulesView()
                case .archive: ArchiveView()
                case .settings: NauclioSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.snappy(duration: 0.24), value: navigationCollapsed)
        .background(NauclioTheme.background)
        .foregroundStyle(NauclioTheme.text)
        .overlay {
            if !store.phase.isConnected && !store.hasLoadedWorkspace { ConnectionOverlay() }
        }
        .overlay(alignment: .topTrailing) {
            if !store.phase.isConnected && store.hasLoadedWorkspace {
                HStack(spacing: 7) { ProgressView().controlSize(.mini); Text("Reconnecting…") }
                    .font(.caption.weight(.medium)).padding(.horizontal, 11).frame(height: 30)
                    .background(NauclioTheme.elevated, in: Capsule()).padding(10)
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
        .alert("Nauclio", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

struct AppSidebar: View {
    @Environment(NauclioStore.self) private var store
    @Binding var collapsed: Bool
    @State private var renameMachine: NauclioEndpoint?

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
        .background(NauclioTheme.sidebar)
        .clipped()
        .sheet(item: $renameMachine) { machine in RenameMachineSheet(machine: machine).environment(store) }
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
                NauclioBrandIcon(size: 24)
                Text("Nauclio").font(.system(size: 16, weight: .bold))
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
                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(NauclioTheme.subtle)
                    .frame(width: 34, height: 32)
                    .background(NauclioTheme.surface, in: RoundedRectangle(cornerRadius: NauclioMetrics.controlRadius))
                    .overlay(RoundedRectangle(cornerRadius: NauclioMetrics.controlRadius).stroke(NauclioTheme.border))
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                    Text("Search").foregroundStyle(NauclioTheme.subtle)
                    Spacer()
                    Text("⌘K").font(.system(size: 9, weight: .semibold)).foregroundStyle(NauclioTheme.tertiary)
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(NauclioTheme.surface, in: RoundedRectangle(cornerRadius: NauclioMetrics.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: NauclioMetrics.controlRadius).stroke(NauclioTheme.border))
            }
        }
        .buttonStyle(.plain).help("Search and commands")
        .frame(maxWidth: .infinity)
        .padding(.horizontal, collapsed ? 12 : 10).padding(.bottom, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(NauclioTheme.border).frame(height: 1) }
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
    }

    private var expandedProjects: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(store.projects.filter { !$0.archived }, id: \.id) { project in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(project.name.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.6).foregroundStyle(NauclioTheme.tertiary).lineLimit(1)
                        if let machine = store.machine(forProjectID: project.id) {
                            ProjectMachineBadge(machine: machine)
                        }
                        Spacer()
                        Button { store.presentNewBoard(projectID: project.id) } label: { Image(systemName: "plus").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(.plain).foregroundStyle(NauclioTheme.subtle).help("New board in \(project.name)")
                    }
                    .padding(.horizontal, 9).frame(height: 24)

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
        }
        .padding(.horizontal, 8).padding(.vertical, 14)
    }

    private var collapsedProjects: some View {
        LazyVStack(spacing: 8) {
            ForEach(store.projects.filter { !$0.archived }, id: \.id) { project in
                VStack(spacing: 5) {
                    if let machine = store.machine(forProjectID: project.id) {
                        Text(machine.name.prefix(2).uppercased())
                            .font(.system(size: 7, weight: .bold, design: .rounded))
                            .foregroundStyle(machine.online ? NauclioTheme.seafoam : NauclioTheme.tertiary)
                            .frame(width: 24, height: 13)
                            .background((machine.online ? NauclioTheme.seafoam : NauclioTheme.tertiary).opacity(0.1), in: Capsule())
                            .help("\(project.name) · \(machine.name) · \(machine.online ? "Online" : "Offline")")
                    } else {
                        Rectangle().fill(NauclioTheme.border).frame(width: 24, height: 1).padding(.vertical, 3)
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
                    Button { if machine.online { Task { await store.setEndpoint(machine) } } } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Text(machine.name.prefix(1).uppercased())
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .frame(width: 28, height: 28)
                                .background(machine.id == store.endpoint.id ? NauclioTheme.raised : NauclioTheme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                            Circle().fill(machine.online ? NauclioTheme.seafoam : NauclioTheme.tertiary)
                                .frame(width: 7, height: 7).overlay(Circle().stroke(NauclioTheme.sidebar, lineWidth: 2))
                                .offset(x: 2, y: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!machine.online)
                    .help("\(machine.name) · \(machineDetail(machine))")
                    .contextMenu { Button("Rename machine…") { renameMachine = machine } }
                    .accessibilityIdentifier("machine.\(machine.daemonID ?? machine.id)")
                }
                SidebarRailDestination(title: "Settings", symbol: "gearshape", selected: store.section == .settings) { store.openSettings() }
                    .accessibilityIdentifier("sidebar.settings")
                SidebarRailDestination(title: "Add a Git project", symbol: "plus", selected: false) { store.createProjectPresented = true }
            }.frame(maxWidth: .infinity).padding(.vertical, 9)
                .overlay(alignment: .top) { Rectangle().fill(NauclioTheme.border).frame(height: 1) }
        } else {
            VStack(spacing: 5) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("MACHINES").font(.system(size: 9, weight: .bold)).tracking(0.7).foregroundStyle(NauclioTheme.tertiary)
                        Spacer()
                        Text("\(store.machines.filter(\.online).count) online").font(.system(size: 9, weight: .medium)).foregroundStyle(NauclioTheme.tertiary)
                    }
                    ForEach(store.machines) { machine in
                        Button { if machine.online { Task { await store.setEndpoint(machine) } } } label: {
                            HStack(spacing: 8) {
                                Circle().fill(machine.online ? NauclioTheme.seafoam : NauclioTheme.tertiary).frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(machine.name).font(.system(size: 10, weight: machine.id == store.endpoint.id ? .semibold : .medium)).lineLimit(1)
                                    Text(machineDetail(machine))
                                        .font(.system(size: 8)).foregroundStyle(NauclioTheme.tertiary)
                                }
                                Spacer()
                                if machine.id == store.endpoint.id { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(NauclioTheme.seafoam) }
                            }
                            .padding(.horizontal, 8).frame(height: 32)
                            .background(machine.id == store.endpoint.id ? NauclioTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .disabled(!machine.online)
                        .contextMenu { Button("Rename machine…") { renameMachine = machine } }
                        .accessibilityIdentifier("machine.\(machine.daemonID ?? machine.id)")
                    }
                }
                .padding(8)
                .background(NauclioTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke((store.phase.isConnected ? NauclioTheme.seafoam : NauclioTheme.coral).opacity(0.15)))

                SidebarDestination(title: "Settings", symbol: "gearshape", selected: store.section == .settings) { store.openSettings() }
                    .accessibilityIdentifier("sidebar.settings")
                SidebarFooterButton(title: "Add a Git project", symbol: "plus") { store.createProjectPresented = true }
            }.padding(8).overlay(alignment: .top) { Rectangle().fill(NauclioTheme.border).frame(height: 1) }
        }
    }

    private func activeCount(_ boardID: String) -> Int {
        store.navigationCards.values.flatMap { $0 }.filter { $0.boardID == boardID && ["running", "waiting_for_user", "review"].contains($0.runtime) }.count
    }

    private func machineDetail(_ machine: NauclioEndpoint) -> String {
        guard machine.online else { return MachinePresenceText.lastSeen(machine.lastSeenAt) }
        guard let status = store.connectionStatus(for: machine) else { return "Measuring…" }
        return "\(status.route.rawValue) · \(status.latencyMilliseconds) ms"
    }
}

private struct ProjectMachineBadge: View {
    let machine: NauclioEndpoint

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(machine.online ? NauclioTheme.seafoam : NauclioTheme.tertiary).frame(width: 5, height: 5)
            Text(machine.name).lineLimit(1)
        }
        .font(.system(size: 8, weight: .semibold))
        .foregroundStyle(machine.online ? NauclioTheme.subtle : NauclioTheme.tertiary)
        .padding(.horizontal, 5).frame(height: 15)
        .background((machine.online ? NauclioTheme.seafoam : NauclioTheme.tertiary).opacity(0.08), in: Capsule())
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
                    .fill(hovering ? NauclioTheme.surface : .clear)

                NauclioBrandIcon(size: 24)
                    .opacity(hovering ? 0 : 1)

                Image(systemName: "sidebar.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(NauclioTheme.aegean)
                    .opacity(hovering ? 1 : 0)
            }
            .frame(width: 36, height: 32)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(hovering ? NauclioTheme.strongBorder : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct NauclioBrandIcon: View {
    let size: CGFloat

    private static let appImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "NauclioAppIcon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    private static let faviconImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "NauclioFavicon", withExtension: "png") else { return nil }
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
                    .foregroundStyle(NauclioTheme.aegean)
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
                RoundedRectangle(cornerRadius: 1).fill(selected ? NauclioTheme.primary : .clear).frame(width: 2, height: 16)
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 16).foregroundStyle(selected ? NauclioTheme.aegean : NauclioTheme.subtle)
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1)
                Spacer()
                if badge > 0 {
                    if prominentBadge {
                        Text("\(badge)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).frame(height: 17).background(NauclioTheme.cobalt, in: Capsule())
                    } else {
                        Circle().fill(NauclioTheme.amber).frame(width: 5, height: 5)
                        Text("\(badge)").font(.system(size: 9, weight: .medium)).foregroundStyle(NauclioTheme.tertiary)
                    }
                }
            }
            .padding(.horizontal, 7).frame(height: NauclioMetrics.navigationRowHeight)
            .background(selected ? NauclioTheme.raised : (hovering ? NauclioTheme.surface.opacity(0.7) : .clear), in: RoundedRectangle(cornerRadius: 7))
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
                    .foregroundStyle(selected ? NauclioTheme.aegean : NauclioTheme.subtle)
                    .frame(width: 36, height: 32)
                    .background(selected ? NauclioTheme.raised : (hovering ? NauclioTheme.surface : .clear), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(selected ? NauclioTheme.primary : .clear).frame(width: 2, height: 17) }
                if badge > 0 {
                    Text(badge > 9 ? "9+" : "\(badge)").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 3).frame(height: 12).background(NauclioTheme.cobalt, in: Capsule()).offset(x: 3, y: -2)
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
            .buttonStyle(.plain).foregroundStyle(hovering ? Color.white : NauclioTheme.subtle)
            .background(hovering ? NauclioTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 6))
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
                .background(hovering ? NauclioTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).onHover { hovering = $0 }
    }
}

struct ConnectionOverlay: View {
    @Environment(NauclioStore.self) private var store
    @State private var address = ""

    var body: some View {
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()
            VStack(spacing: 16) {
                NauclioBrandIcon(size: 68)
                Text("Connect to Nauclio").font(.title2.weight(.bold))
                Text("Sign in to your Nauclio gateway and choose an enrolled daemon.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                if store.phase == .authenticationRequired {
                    Text("This Nauclio server requires GitHub authentication.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Sign in with GitHub") { Task { await store.signIn() } }
                        .buttonStyle(.borderedProminent)
                }
                ForEach(store.endpoints) { endpoint in
                    Button { Task { await store.setEndpoint(endpoint) } } label: {
                        HStack {
                            VStack(alignment: .leading) { Text(endpoint.name).fontWeight(.semibold); Text(endpoint.address).font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Image(systemName: "arrow.right")
                        }.padding(10).background(NauclioTheme.raised, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
                HStack {
                    TextField("https://nauclio.example.com", text: $address).textFieldStyle(.roundedBorder)
                    Button("Connect") {
                        if let endpoint = NauclioEndpoint.parse(address), endpoint.secure { Task { await store.setEndpoint(endpoint) } }
                    }.disabled(NauclioEndpoint.parse(address)?.secure != true)
                }
                if case .connecting = store.phase { ProgressView().controlSize(.small) }
                if case let .failed(message) = store.phase { Text(message).font(.caption).foregroundStyle(NauclioTheme.coral).lineLimit(3) }
            }
            .padding(24).frame(width: 430).nauclioSurface(radius: 16)
        }
    }
}

struct CommandPalette: View {
    @Environment(NauclioStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var commands: [(String, String, () -> Void)] {
        [
            ("New card", "rectangle.badge.plus", { store.createConversationPresented = true }),
            ("New standalone chat", "bubble.left.and.bubble.right.fill", { store.beginStandaloneChat() }),
            ("Open all chats", "bubble.left.and.bubble.right", { Task { await store.openChats() } }),
            ("Browse project files", "doc.on.doc", { Task { await store.openProject(store.selectedProjectID, section: .files) } }),
            ("Open project schedules", "calendar.badge.clock", { Task { await store.openProject(store.selectedProjectID, section: .schedules) } }),
            ("Add Git project", "folder.badge.plus", { store.createProjectPresented = true }),
            ("Edit project context", "text.book.closed", { store.projectContextPresented = true }),
            ("Refresh", "arrow.clockwise", { Task { await store.refreshState() } }),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: "magnifyingglass"); TextField("Type a command…", text: $query).textFieldStyle(.plain).font(.title3) }
                .padding(16)
            Divider()
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(commands.enumerated()).filter { query.isEmpty || $0.element.0.localizedCaseInsensitiveContains(query) }, id: \.offset) { _, command in
                        Button {
                            command.2(); dismiss()
                        } label: {
                            HStack { Image(systemName: command.1).frame(width: 22); Text(command.0); Spacer(); Image(systemName: "return").foregroundStyle(.secondary) }
                                .padding(10).background(NauclioTheme.raised.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }.padding(10)
            }
        }.frame(width: 560, height: 410).background(NauclioTheme.surface)
    }
}
