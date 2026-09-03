import AppKit
import DieterAPI
import SwiftUI

enum WorkspaceSurfaceTreatment: Equatable {
    case current
    case refreshing
    case unavailable

    static func resolve(
        showsSynchronizedWorkspace: Bool,
        hasCachedWorkspace: Bool,
        freshness: WorkspaceFreshnessState
    ) -> Self {
        guard showsSynchronizedWorkspace, hasCachedWorkspace else { return .current }
        switch freshness {
        case .live: return .current
        case .syncing: return .refreshing
        case .reconnecting, .offline: return .unavailable
        }
    }

    var showsNotice: Bool { self != .current }
    var blocksInteraction: Bool { self == .unavailable }
}

enum SidebarSizing {
    static let storageKey = "DieterSidebarWidth"
    static let minimumWidth: CGFloat = 210
    static let defaultWidth = DieterMetrics.sidebarExpandedWidth
    static let maximumWidth: CGFloat = 420
    static let dividerWidth: CGFloat = 7

    static func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }
}

private struct SidebarResizeDivider: View {
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(DieterTheme.sidebar)
            Rectangle()
                .fill(hovering ? DieterTheme.shell.opacity(0.62) : DieterTheme.paneSeparator)
                .frame(width: hovering ? 2 : 1)
        }
        .frame(width: SidebarSizing.dividerWidth)
        .ignoresSafeArea(.container, edges: .top)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { onChanged($0.translation.width) }
                .onEnded { _ in onEnded() }
        )
        .onHover { isHovering in
            if isHovering, !hovering { NSCursor.resizeLeftRight.push() }
            if !isHovering, hovering { NSCursor.pop() }
            hovering = isHovering
        }
        .onDisappear {
            if hovering { NSCursor.pop() }
        }
        .accessibilityLabel("Resize sidebar")
        .accessibilityIdentifier("sidebar.resize-divider")
    }
}

struct DieterRootView: View {
    @Environment(DieterStore.self) private var store
    @AppStorage(SidebarSizing.storageKey, store: SidebarProjectNavigationPreferences.applicationDefaults())
    private var navigationWidth = Double(SidebarSizing.defaultWidth)
    @State private var navigationCollapsed = false
    @State private var navigationDragStartWidth: CGFloat?

    private var showsSynchronizedWorkspace: Bool {
        switch store.section {
        case .board, .chats, .files, .schedules, .archive: true
        case .terminals, .screens, .settings: false
        }
    }

    private var workspaceSurfaceTreatment: WorkspaceSurfaceTreatment {
        WorkspaceSurfaceTreatment.resolve(
            showsSynchronizedWorkspace: showsSynchronizedWorkspace,
            hasCachedWorkspace: store.hasLoadedWorkspace,
            freshness: store.workspaceFreshness
        )
    }

    var body: some View {
        @Bindable var store = store
        let sidebarWidth = navigationCollapsed
            ? DieterMetrics.sidebarCollapsedWidth
            : SidebarSizing.clamped(CGFloat(navigationWidth))
        let sidebarDividerWidth = navigationCollapsed ? 1 : SidebarSizing.dividerWidth

        HStack(spacing: 0) {
            AppSidebar(collapsed: $navigationCollapsed)
                .frame(width: sidebarWidth)
            if navigationCollapsed {
                Rectangle()
                    .fill(DieterTheme.paneSeparator)
                    .frame(width: sidebarDividerWidth)
                    .ignoresSafeArea(.container, edges: .top)
                    .accessibilityHidden(true)
            } else {
                SidebarResizeDivider(
                    onChanged: { translation in
                        let startWidth = navigationDragStartWidth ?? sidebarWidth
                        if navigationDragStartWidth == nil { navigationDragStartWidth = startWidth }
                        let next = SidebarSizing.clamped(startWidth + translation)
                        if abs(Double(next) - navigationWidth) > 0.5 {
                            navigationWidth = Double(next)
                        }
                    },
                    onEnded: { navigationDragStartWidth = nil }
                )
            }
            VStack(spacing: 0) {
                if workspaceSurfaceTreatment.showsNotice {
                    WorkspaceFreshnessBanner(
                        freshness: store.workspaceFreshness,
                        lastSyncedAt: store.lastSyncedAt
                    )
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Group {
                    switch store.section {
                    case .board: BoardView()
                    case .chats: ChatsView()
                    case .terminals: TerminalsView()
					case .screens: ScreensView()
                    case .files: FilesView()
                    case .schedules: SchedulesView()
                    case .archive: ArchiveView()
                    case .settings: DieterSettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .saturation(workspaceSurfaceTreatment == .unavailable ? 0.72 : 1)
                .opacity(workspaceSurfaceTreatment == .unavailable ? 0.82 : 1)
                .disabled(workspaceSurfaceTreatment.blocksInteraction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.snappy(duration: 0.24), value: navigationCollapsed)
        .animation(.easeOut(duration: 0.18), value: workspaceSurfaceTreatment)
        .background(DieterTheme.background)
        .background(WindowTitleBarDoubleClickHandler())
        .foregroundStyle(DieterTheme.text)
        .overlay {
            if store.selectedMachineID != nil {
                GeometryReader { geometry in
                    let workspaceLeadingEdge = sidebarWidth + sidebarDividerWidth
                    let popupWidth = min(820, max(560, geometry.size.width - workspaceLeadingEdge - 32))
                    let processCount = store.selectedMachineID
                        .flatMap { store.machineInformation[$0]?.processes.count } ?? 1
                    let desiredPopupHeight = 420 + CGFloat(min(max(processCount, 1), 4) * 54)
                    let popupHeight = min(max(460, desiredPopupHeight), geometry.size.height - 32)
                    let popupTop = max(16, geometry.size.height - popupHeight - 28)

                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { store.dismissMachinePopover() }
                            .accessibilityHidden(true)
                        MachinePopover()
                            .frame(width: popupWidth, height: popupHeight)
                            .offset(x: workspaceLeadingEdge + 14, y: popupTop)
                    }
                }
            }
        }
        .overlay {
            if !store.phase.isConnected && (!store.hasLoadedWorkspace || store.phase.needsConnectionOverlay) { ConnectionOverlay() }
        }
        .sheet(isPresented: $store.createConversationPresented) { NewConversationSheet().environment(store) }
        .sheet(isPresented: $store.createProjectPresented) { NewProjectSheet().environment(store) }
        .sheet(isPresented: $store.createBoardPresented) { NewBoardSheet().environment(store) }
        .sheet(isPresented: $store.renameProjectPresented) { RenameProjectSheet().environment(store) }
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

struct WorkspaceFreshnessBanner: View {
    let freshness: WorkspaceFreshnessState
    let lastSyncedAt: Date?

    private var isWorking: Bool {
        freshness == .syncing || freshness == .reconnecting
    }

    private var accent: Color {
        freshness == .offline ? DieterTheme.coral : DieterTheme.amber
    }

    private var title: String {
        switch freshness {
        case .live: "Workspace is up to date"
        case .syncing: "Refreshing workspace"
        case .reconnecting: "Reconnecting to Dieter"
        case .offline: "Working from cached data"
        }
    }

    private var detail: String {
        switch freshness {
        case .live: ""
        case .syncing: "Your current workspace stays available while changes load."
        case .reconnecting: "Cached data stays visible while the connection recovers."
        case .offline: "Cached data is read-only until Dieter reconnects."
        }
    }

    var body: some View {
        let now = Date()
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.12))
                    .frame(width: 24, height: 24)
                if isWorking {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                }
            }
            Text(title)
                .font(.system(size: 11, weight: .semibold))
            Text(detail)
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(DieterTheme.tertiary)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(SyncFreshnessPresentation.lastUpdateLabel(lastUpdatedAt: lastSyncedAt, now: now))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DieterTheme.tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DieterTheme.background.opacity(0.54), in: Capsule())
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(accent.opacity(0.055))
        .overlay(alignment: .bottom) { Rectangle().fill(accent.opacity(0.16)).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail) \(SyncFreshnessPresentation.lastUpdateLabel(lastUpdatedAt: lastSyncedAt, now: now)).")
        .accessibilityIdentifier("workspace.cached")
    }
}

/// Compact workspace connection state, docked in the sidebar footer so it never
/// floats over a pane header. Shows a dot + label when expanded, a dot when
/// collapsed; the full freshness lives in the tooltip and accessibility label.
private struct SidebarConnectionStatus: View {
    @Environment(DieterStore.self) private var store
    var compact = false

    private var dotColor: Color {
        switch store.workspaceFreshness {
        case .live: DieterTheme.eyes
        case .syncing, .reconnecting: DieterTheme.amber
        case .offline: DieterTheme.coral
        }
    }

    private var label: String {
        store.workspaceFreshness.label
    }

    var body: some View {
        let now = Date()
        Group {
            if compact {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                    .padding(4)
            } else {
                HStack(spacing: 5) {
                    if store.workspaceFreshness == .syncing || store.workspaceFreshness == .reconnecting {
                        DieterActivityIndicator(color: dotColor, size: 9).accessibilityHidden(true)
                    } else {
                        Circle().fill(dotColor).frame(width: 6, height: 6).accessibilityHidden(true)
                    }
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(store.workspaceIsLive ? DieterTheme.subtle : dotColor)
                }
            }
        }
        .help(accessibilityLabel(now: now))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(now: now))
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func accessibilityLabel(now: Date) -> String {
        let freshness = SyncFreshnessPresentation.lastConnectedLabel(
            lastConnectedAt: store.lastSyncedAt,
            now: now
        )
        return "Dieter is \(store.workspaceFreshness.label.lowercased()), \(freshness)"
    }

    private var accessibilityIdentifier: String {
        "connection.\(store.workspaceFreshness.label.lowercased())"
    }
}

enum SidebarMachineOrdering {
    static func sorted(_ machines: [DieterEndpoint]) -> [DieterEndpoint] {
        machines.sorted { left, right in
            let comparison = left.name.localizedCaseInsensitiveCompare(right.name)
            if comparison == .orderedSame { return left.id < right.id }
            return comparison == .orderedAscending
        }
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

    private var visibleMachines: [DieterEndpoint] {
        SidebarMachineOrdering.sorted(store.machines)
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
        // Extend the sidebar tone up behind the traffic lights so the title-bar
        // strip matches the nav instead of showing the darker window background.
        .background(DieterTheme.sidebar.ignoresSafeArea(.container, edges: .top))
    }

    @ViewBuilder private var sidebarHeader: some View {
        if collapsed {
            SidebarRailToggle { collapsed = false }
            .help("Expand navigation (⌃⌘S)")
            .keyboardShortcut("s", modifiers: [.command, .control])
            .accessibilityLabel("Expand navigation")
            .accessibilityIdentifier("sidebar.toggle")
            .frame(maxWidth: .infinity)
            .padding(.top, DieterMetrics.headerTopPadding).padding(.bottom, 10)
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
            .padding(.horizontal, 12).padding(.top, DieterMetrics.headerTopPadding).padding(.bottom, 10)
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

		if collapsed {
			SidebarRailDestination(
				title: "Screens",
				symbol: "rectangle.inset.filled.and.person.filled",
				selected: store.section == .screens,
				annotation: "Experimental"
			) { store.openScreens() }
			.accessibilityIdentifier("sidebar.screens")
		} else {
			SidebarDestination(
				title: "Screens",
				symbol: "rectangle.inset.filled.and.person.filled",
				selected: store.section == .screens,
				annotation: "Experimental"
			) { store.openScreens() }
			.padding(.horizontal, 8)
			.accessibilityIdentifier("sidebar.screens")
		}
    }

    private var expandedProjects: some View {
        let projects = visibleProjects
        let projectIDs = projects.map(\.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("PROJECTS").font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary)
                if !projects.isEmpty {
                    Text("· \(projects.count)")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(DieterTheme.tertiary.opacity(0.7))
                }
                Spacer()
                Button { store.createProjectPresented = true } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(DieterTheme.tertiary).help("Add Git project")
            }
            .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 4)

            ForEach(projects, id: \.id) { project in
                SidebarProjectInsertionTarget(beforeProjectID: project.id) { moveProject($0, before: project.id) }
                SidebarProjectRow(
                    project: project,
                    projectIDs: projectIDs,
                    expanded: projectNavigation.isExpanded(project.id),
                    toggleExpanded: { toggleProject(project.id) },
                    moveProject: moveProject
                )
            }
            SidebarProjectInsertionTarget(beforeProjectID: nil) { moveProject($0, before: nil) }
        }
        .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 10)
    }

    private var collapsedProjects: some View {
        let projects = visibleProjects
        return VStack(spacing: 7) {
            ForEach(projects, id: \.id) { project in
                SidebarProjectRail(project: project)
            }
        }.padding(.vertical, 10)
    }

    @ViewBuilder private var sidebarFooter: some View {
        if collapsed {
            VStack(spacing: 6) {
                SidebarConnectionStatus(compact: true)
                ForEach(visibleMachines) { machine in
                    Button { Task { await store.openMachine(machine) } } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Text(machine.name.prefix(1).uppercased())
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .frame(width: 28, height: 28)
                                .background(
                                    store.selectedMachineID == machine.id
                                        ? DieterTheme.selection : DieterTheme.surface.opacity(0.7),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                            Circle().fill(machineIsPresentedOnline(machine) ? DieterTheme.eyes : DieterTheme.tertiary)
                                .frame(width: 7, height: 7).overlay(Circle().stroke(DieterTheme.sidebar, lineWidth: 2))
                                .offset(x: 2, y: 2)
                        }
                    }
                    .buttonStyle(.plain)
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
                        if let age = MachinePresenceText.freshestAge(store.machines.map(\.lastSeenAt), relativeTo: .now) {
                            Text(age)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(DieterTheme.tertiary.opacity(0.65))
                        }
                        Spacer()
                        SidebarConnectionStatus()
                    }
                    ForEach(visibleMachines) { machine in
                        VStack(alignment: .leading, spacing: 5) {
                            Button { Task { await store.openMachine(machine) } } label: {
                                HStack(spacing: 8) {
                                    Circle().fill(machineIsPresentedOnline(machine) ? DieterTheme.eyes : DieterTheme.tertiary).frame(width: 6, height: 6)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(machine.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                        Text(machineDetail(machine))
                                            .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 8).frame(height: 32)
                                .background(
                                    store.selectedMachineID == machine.id
                                        ? DieterTheme.selection : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("machine.\(machine.daemonID ?? machine.id)")

                            if let summary = store.outboxSummary(for: machine) {
                                MachineQueueBanner(machine: machine, summary: summary)
                            }
                        }
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

    private func toggleProject(_ projectID: String) {
        projectNavigation.toggleExpanded(projectID)
        projectNavigation.save(to: SidebarProjectNavigationPreferences.applicationDefaults())
    }

    private func moveProject(_ projectID: String, before targetProjectID: String?) {
        guard projectNavigation.move(projectID, before: targetProjectID, availableIDs: visibleProjects.map(\.id)) else { return }
        projectNavigation.save(to: SidebarProjectNavigationPreferences.applicationDefaults())
    }

    private func machineDetail(_ machine: DieterEndpoint) -> String {
        if machine.id == store.endpoint.id && !store.workspaceIsLive {
            if store.workspaceFreshness == .syncing { return "Waiting for live sync…" }
            return "Unavailable · \(MachinePresenceText.lastSeen(machine.lastSeenAt))"
        }
        guard machine.online else {
            let suffix = store.outboxSummary(for: machine).map { summary in
                summary.failed ? " · attention needed" : (summary.retrying ? " · retrying" : " · queued")
            } ?? ""
            return MachinePresenceText.lastSeen(machine.lastSeenAt) + suffix
        }
        guard let status = store.connectionStatus(for: machine) else { return "Measuring…" }
        return "\(status.route.rawValue) · \(status.latencyMilliseconds) ms"
    }

    private func machineIsPresentedOnline(_ machine: DieterEndpoint) -> Bool {
        machine.online && (machine.id != store.endpoint.id || store.workspaceIsLive)
    }

}

private struct MachineQueueBanner: View {
    @Environment(DieterStore.self) private var store
    let machine: DieterEndpoint
    let summary: MachineOutboxSummary
    @State private var discardConfirmationPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                Text(machine.online ? "Delivering to \(machine.name)" : "\(machine.name) is unreachable")
                    .fontWeight(.semibold).lineLimit(1)
            }
            .font(.system(size: 10))
            Text(summary.deliveryLabel)
                .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel queue…", role: .destructive) {
                    discardConfirmationPresented = true
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .accessibilityIdentifier("machine.\(machine.daemonID ?? machine.id).cancel-queue")
                Spacer()
                Button("Retry now") { Task { await store.retryOutbox(for: machine) } }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .accessibilityIdentifier("machine.\(machine.daemonID ?? machine.id).retry")
            }
        }
        .foregroundStyle(DieterTheme.amber)
        .padding(8)
        .background(DieterTheme.amber.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(DieterTheme.amber.opacity(0.4)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("machine.\(machine.daemonID ?? machine.id).queue")
        .confirmationDialog(
            "Cancel \(summary.itemCount) queued \(summary.itemCount == 1 ? "item" : "items")?",
            isPresented: $discardConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Cancel queued \(summary.itemCount == 1 ? "item" : "items")", role: .destructive) {
                Task { await store.discardOutbox(for: machine) }
            }
            Button("Keep queued", role: .cancel) {}
        } message: {
            Text("This permanently removes the queued work from this Mac. Work already accepted by \(machine.name) is not affected.")
        }
    }
}

/// Compressed project row (default): initials avatar + name. Tapping the row body
/// opens a quick-nav popover (boards · files · schedules); the trailing chevron
/// expands the same destinations inline.
private struct SidebarProjectRow: View {
    @Environment(DieterStore.self) private var store
    let project: Dieter_V1_Project
    let projectIDs: [String]
    let expanded: Bool
    let toggleExpanded: () -> Void
    let moveProject: (String, String?) -> Void
    @State private var dropTargeted = false
    @State private var hovering = false
    @State private var popoverPresented = false

    private var selected: Bool {
        store.selectedProjectID == project.id &&
            [.board, .files, .schedules].contains(store.section)
    }

    private var projectMachineOnline: Bool? {
        guard let machine = store.machine(forProjectID: project.id) else { return nil }
        return store.workspaceIsLive && machine.online
    }

    private var projectMachine: DieterEndpoint? {
        store.machine(forProjectID: project.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Button { popoverPresented = true } label: {
                    HStack(spacing: 8) {
                        ProjectAvatar(name: project.name, online: projectMachineOnline)
                        Text(project.name)
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? DieterTheme.text : DieterTheme.subtle)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let projectMachine {
                            ProjectMachineBadge(machine: projectMachine, online: projectMachineOnline == true)
                                .accessibilityIdentifier("sidebar.project.\(project.id).machine")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(project.name) — boards, files, schedules")
                .accessibilityIdentifier("sidebar.project.\(project.id)")

                if hovering {
                    Button { store.presentNewBoard(projectID: project.id) } label: {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain).foregroundStyle(DieterTheme.tertiary)
                    .disabled(!store.workspaceIsLive)
                    .help("New board in \(project.name)")
                    .transition(.opacity)
                }

                Button(action: toggleExpanded) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DieterTheme.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 16, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse \(project.name)" : "Expand \(project.name)")
                .accessibilityLabel(expanded ? "Collapse \(project.name)" : "Expand \(project.name)")
                .accessibilityIdentifier("sidebar.project.\(project.id).toggle")
            }
            .padding(.horizontal, 8).frame(height: DieterMetrics.navigationRowHeight)
            .background(
                dropTargeted ? DieterTheme.shellDeep.opacity(0.16)
                    : (selected ? DieterTheme.selection : (hovering ? DieterTheme.surface.opacity(0.7) : .clear)),
                in: RoundedRectangle(cornerRadius: DieterMetrics.controlRadius, style: .continuous)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .draggable(SidebarProjectDragPayload(projectID: project.id).encoded) {
                SidebarProjectDragPreview(project: project)
            }
            .dropDestination(for: String.self) { values, location in
                guard let value = values.first, let payload = SidebarProjectDragPayload(value), payload.projectID != project.id else { return false }
                let targetIndex = projectIDs.firstIndex(of: project.id) ?? 0
                let beforeProjectID: String?
                if location.y < 16 {
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
            .animation(.easeOut(duration: 0.12), value: hovering)
            .popover(isPresented: $popoverPresented, arrowEdge: .trailing) {
                ProjectQuickNav(project: project) { popoverPresented = false }
                    .environment(store)
            }

            if expanded {
                SidebarProjectDestinations(project: project)
                    .padding(.leading, 6)
            }
        }
        .padding(.bottom, 2)
        .animation(.snappy(duration: 0.18), value: expanded)
        .projectContextMenu(for: project)
    }
}

/// Compact host marker shown beside each project name.
private struct ProjectMachineBadge: View {
    let machine: DieterEndpoint
    let online: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(online ? DieterTheme.eyes : DieterTheme.tertiary)
                .frame(width: 5, height: 5)
            Text(machine.name)
                .font(.system(size: 8.5, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(online ? DieterTheme.subtle : DieterTheme.tertiary)
        .padding(.horizontal, 6)
        .frame(height: 16)
        .background(DieterTheme.surface.opacity(0.9), in: Capsule())
        .overlay(Capsule().stroke(DieterTheme.border))
        .help("Hosted on \(machine.name) · \(online ? "Online" : "Offline")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hosted on \(machine.name), \(online ? "online" : "offline")")
    }
}

private struct ProjectContextMenuModifier: ViewModifier {
    @Environment(DieterStore.self) private var store
    let project: Dieter_V1_Project
    @State private var deleteConfirmationPresented = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Rename project…", systemImage: "pencil") {
                    store.presentRenameProject(projectID: project.id)
                }
                Button("Edit project…", systemImage: "slider.horizontal.3") {
                    store.presentProjectEditor(projectID: project.id)
                }
                Divider()
                Button("Delete project…", systemImage: "trash", role: .destructive) {
                    deleteConfirmationPresented = true
                }
            }
            .confirmationDialog(
                "Delete \(project.name) from Dieter?",
                isPresented: $deleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Delete project", role: .destructive) {
                    Task { await store.setProjectArchived(id: project.id, archived: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the project from the sidebar without deleting its Git working tree. You can restore it from Archive.")
            }
    }
}

private extension View {
    func projectContextMenu(for project: Dieter_V1_Project) -> some View {
        modifier(ProjectContextMenuModifier(project: project))
    }
}

/// Inline boards · files · schedules rows shown when a project row is expanded,
/// and reused (without indentation) inside the quick-nav popover.
private struct SidebarProjectDestinations: View {
    @Environment(DieterStore.self) private var store
    let project: Dieter_V1_Project
    var onNavigate: (() -> Void)? = nil

    private var projectIsUnavailable: Bool {
        !store.workspaceIsLive || store.machine(forProjectID: project.id)?.online == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.boards(for: project.id), id: \.id) { board in
                SidebarDestination(
                    title: board.name,
                    symbol: "rectangle.split.3x1",
                    selected: store.section == .board && store.selectedBoardID == board.id,
                    badge: activeCount(board.id)
                ) { onNavigate?(); Task { await store.openBoard(board.id, projectID: project.id) } }
                .accessibilityIdentifier("sidebar.board.\(board.id)")
                .contextMenu {
                    Button("Rename board…", systemImage: "pencil") { store.presentRenameBoard(boardID: board.id) }
                    Button("New board…", systemImage: "plus") { store.presentNewBoard(projectID: project.id) }
                }
            }
            SidebarDestination(title: "Files", symbol: "folder", selected: store.section == .files && store.selectedProjectID == project.id) {
                onNavigate?(); Task { await store.openProject(project.id, section: .files) }
            }
            .disabled(projectIsUnavailable)
            .opacity(projectIsUnavailable ? 0.42 : 1)
            .accessibilityIdentifier("sidebar.files.\(project.id)")
            SidebarDestination(title: "Schedules", symbol: "calendar", selected: store.section == .schedules && store.selectedProjectID == project.id) {
                onNavigate?(); Task { await store.openProject(project.id, section: .schedules) }
            }
            .disabled(projectIsUnavailable)
            .opacity(projectIsUnavailable ? 0.42 : 1)
            .accessibilityIdentifier("sidebar.schedules.\(project.id)")
        }
    }

    private func activeCount(_ boardID: String) -> Int {
        store.navigationCards.values.flatMap { $0 }.filter { $0.boardID == boardID && ["running", "waiting_for_user", "review"].contains($0.runtime) }.count
    }
}

/// Collapsed-rail project: the initials avatar alone, opening the quick-nav popover.
private struct SidebarProjectRail: View {
    @Environment(DieterStore.self) private var store
    let project: Dieter_V1_Project
    @State private var popoverPresented = false
    @State private var hovering = false

    private var selected: Bool {
        store.selectedProjectID == project.id &&
            [.board, .files, .schedules].contains(store.section)
    }

    private var projectMachineOnline: Bool? {
        guard let machine = store.machine(forProjectID: project.id) else { return nil }
        return store.workspaceIsLive && machine.online
    }

    var body: some View {
        Button { popoverPresented = true } label: {
            ProjectAvatar(name: project.name, online: projectMachineOnline, size: 30)
                .padding(3)
                .background(
                    selected ? DieterTheme.selection : (hovering ? DieterTheme.surface.opacity(0.7) : .clear),
                    in: RoundedRectangle(cornerRadius: DieterMetrics.controlRadius, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(project.name) — boards, files, schedules")
        .accessibilityIdentifier("sidebar.project.\(project.id)")
        .popover(isPresented: $popoverPresented, arrowEdge: .trailing) {
            ProjectQuickNav(project: project) { popoverPresented = false }
                .environment(store)
        }
        .projectContextMenu(for: project)
    }
}

/// Rounded initials tile with a small machine-presence dot.
private struct ProjectAvatar: View {
    let name: String
    var online: Bool?
    var size: CGFloat = 22

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "/" })
        if words.count >= 2 {
            return (words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return name.replacingOccurrences(of: " ", with: "").prefix(2).uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(DieterTheme.subtle)
            .frame(width: size, height: size)
            .background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).stroke(DieterTheme.border))
            .overlay(alignment: .bottomTrailing) {
                if let online {
                    Circle().fill(online ? DieterTheme.eyes : DieterTheme.tertiary)
                        .frame(width: size * 0.3, height: size * 0.3)
                        .overlay(Circle().stroke(DieterTheme.sidebar, lineWidth: 1.5))
                        .offset(x: size * 0.12, y: size * 0.12)
                }
            }
            .accessibilityHidden(true)
    }
}

/// Quick-navigation flyout for a project, shared by the expanded row and the
/// collapsed rail. Lists the project's boards, files, and schedules.
private struct ProjectQuickNav: View {
    @Environment(DieterStore.self) private var store
    let project: Dieter_V1_Project
    let dismiss: () -> Void

    private var projectMachineOnline: Bool? {
        guard let machine = store.machine(forProjectID: project.id) else { return nil }
        return store.workspaceIsLive && machine.online
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                ProjectAvatar(name: project.name, online: projectMachineOnline, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let machine = store.machine(forProjectID: project.id) {
                        Text("\(machine.name) · \(projectMachineOnline == true ? "Online" : "Offline")")
                            .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 4)

            Divider().overlay(DieterTheme.border)

            SidebarProjectDestinations(project: project, onNavigate: dismiss)

            Divider().overlay(DieterTheme.border)

            SidebarFooterButton(title: "New board…", symbol: "plus") { dismiss(); store.presentNewBoard(projectID: project.id) }
                .disabled(!store.workspaceIsLive)
        }
        .padding(10)
        .frame(width: 244)
        .background(DieterTheme.surface)
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
    var annotation: String?
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
                if let annotation {
                    ExperimentalBadge(text: annotation)
                }
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
    var annotation: String?
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
                } else if annotation != nil {
                    Text("E")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(DieterTheme.amber)
                        .frame(width: 12, height: 12)
                        .background(DieterTheme.amber.opacity(0.14), in: Capsule())
                        .offset(x: 3, y: -2)
                }
            }
        }
        .buttonStyle(.plain).help(annotation.map { "\(title) · \($0)" } ?? title).onHover { hovering = $0 }
        .accessibilityLabel(annotation.map { "\(title), \($0)" } ?? title)
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
