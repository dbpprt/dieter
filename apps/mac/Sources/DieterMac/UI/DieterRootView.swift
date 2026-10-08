import AppKit
import DieterAPI
import DieterShared
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

struct DieterRootView: View {
    @Environment(DieterStore.self) private var store
    @AppStorage private var navigationWidth: Double
    @State private var hasOpenedBoard = false
    @State private var hasOpenedChats = false
    @State private var hasOpenedInbox = false

    init(navigationDefaults: UserDefaults = SidebarPreferences.applicationDefaults()) {
        _navigationWidth = AppStorage(
            wrappedValue: Double(SidebarSizing.defaultWidth), SidebarSizing.storageKey, store: navigationDefaults)
    }

    private var showsSynchronizedWorkspace: Bool {
        switch store.section {
        case .inbox, .board, .chats, .files, .changes, .schedules, .archive: true
        case .terminals, .screens, .settings: false
        }
    }

    /// The core's notice while synchronized views show cached data; this
    /// window decides which sections show it.
    private var workspaceNotice: ClientWorkspaceNotice? {
        guard showsSynchronizedWorkspace, store.hasLoadedWorkspace else { return nil }
        return store.workspaceNotice
    }

    /// How far top bars move right to clear the floating window controls.
    private var titleBandLeadingInset: CGFloat {
        store.sidebarCollapsed ? DieterWindowControlsCapsule.width + DieterMetrics.panelGap : 0
    }

    var body: some View {
        @Bindable var store = store
        let collapsed = store.sidebarCollapsed
        let sidebarWidth = collapsed ? 0 : CGFloat(navigationWidth)
        let sidebarDividerWidth: CGFloat = collapsed ? 0 : 1

        WorkspaceSplit(
            visibility: Binding(
                get: { store.sidebarCollapsed ? .detailOnly : .all },
                set: { store.sidebarCollapsed = $0 == .detailOnly }),
            sidebarWidth: $navigationWidth
        ) {
            AppSidebar()
                .frame(minWidth: SidebarSizing.minimumWidth)
        } detail: {
            ZStack {
                // Keep one board attached to this window after its first
                // visit. Detaching NSHostingView discards its row graph even
                // when its controller survives. The native host is hidden
                // while away, excluding its content from drawing and input.
                if hasOpenedBoard || store.section == .board {
                    BoardView(active: store.section == .board)
                        .opacity(store.section == .board ? 1 : 0)
                        .allowsHitTesting(store.section == .board)
                        .accessibilityHidden(store.section != .board)
                }
                if hasOpenedChats || store.section == .chats {
                    RetainedWorkspacePane(active: store.section == .chats) {
                        ChatsView(active: store.section == .chats)
                            .environment(store)
                            .environment(\.dieterTitleBandLeadingInset, titleBandLeadingInset)
                            .dieterThemeRoot(
                                palette: store.themeSelection.palette, appearance: store.themeSelection.appearance)
                    }
                    // Give the native host the full pane so its glass panels
                    // reach the title band; the top bars place their controls.
                    .ignoresSafeArea(.container, edges: .top)
                    .allowsHitTesting(store.section == .chats)
                    .accessibilityHidden(store.section != .chats)
                }
                if hasOpenedInbox || store.section == .inbox {
                    RetainedWorkspacePane(active: store.section == .inbox) {
                        InboxView(active: store.section == .inbox)
                            .environment(store)
                            .environment(\.dieterTitleBandLeadingInset, titleBandLeadingInset)
                            .dieterThemeRoot(
                                palette: store.themeSelection.palette, appearance: store.themeSelection.appearance)
                    }
                    .ignoresSafeArea(.container, edges: .top)
                    .allowsHitTesting(store.section == .inbox)
                    .accessibilityHidden(store.section != .inbox)
                }
                switch store.section {
                case .inbox: Color.clear.allowsHitTesting(false)
                case .board:
                    Color.clear.allowsHitTesting(false)
                case .chats: Color.clear.allowsHitTesting(false)
                case .terminals:
                    TerminalsView(model: store.terminalsModel, showAll: { await store.showAllTerminals() })
                case .screens:
                    ScreensView(
                        model: store.screensModel,
                        machines: store.machines, initialMachineID: store.localMachine?.id ?? "",
                        entries: store.machineEntries,
                        showInDieter: { [store] in
                            store.section = .screens
                            store.reopenWorkspaceWindow()
                        })
                case .files: FilesView(model: store.filesModel)
                case .changes: ProjectChangesView()
                case .schedules:
                    SchedulesView(
                        model: store.schedulesModel, context: store.scheduleEditorContext,
                        prepare: {
                            let projectID = store.selectedProjectID
                            let connected = await store.ensureConnected(reportOffline: false)
                            guard connected, store.selectedProjectID == projectID, store.section == .schedules
                            else {
                                if !Task.isCancelled {
                                    store.schedulesError = "This machine is unavailable. Reconnect and retry."
                                }
                                return false
                            }
                            store.bindSchedules()
                            return true
                        },
                        openCard: { id in
                            store.section = .board
                            Task { await store.openConversation(cardID: id) }
                        })
                case .archive: ArchiveView()
                case .settings: DieterSettingsView()
                }
            }
            .onChange(of: store.section, initial: true) { _, section in
                if section == .board { hasOpenedBoard = true }
                if section == .chats { hasOpenedChats = true }
                if section == .inbox { hasOpenedInbox = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if let notice = workspaceNotice {
                    WorkspaceFreshnessBanner(notice: notice, lastSyncedAt: store.lastSyncedAt)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .environment(\.dieterTitleBandLeadingInset, titleBandLeadingInset)
            .navigationSmokeDestination(store.section)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(DieterTheme.canvas)
        .background {
            DieterWindowBackdrop(
                transparencyEnabled: DieterTheme.usesTransparency,
                solidColor: DieterTheme.canvasSolid,
                paneTitlebarEnabled: true
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        // Every section draws its own glass top bar in the title band, beside
        // the window controls that live in the sidebar card.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .overlay(alignment: .topLeading) {
            if collapsed {
                DieterWindowControlsCapsule {
                    navigationWidth = Double(SidebarSizing.clamped(CGFloat(navigationWidth)))
                    store.sidebarCollapsed = false
                }
                .padding(.leading, DieterMetrics.windowInset)
                .padding(.top, DieterMetrics.windowInset)
                .ignoresSafeArea(.container, edges: .top)
            }
        }
        .animation(.easeOut(duration: 0.18), value: workspaceNotice)
        .foregroundStyle(DieterTheme.text)
        .overlay {
            if store.fleet.selectedMachineID != nil {
                GeometryReader { geometry in
                    let workspaceLeadingEdge = sidebarWidth + sidebarDividerWidth
                    let popupWidth = min(820, max(560, geometry.size.width - workspaceLeadingEdge - 32))
                    let processCount =
                        store.fleet.selectedMachineID
                        .flatMap { store.fleet.machineInformation[$0]?.processes.count } ?? 1
                    let desiredPopupHeight = 420 + CGFloat(min(max(processCount, 1), 4) * 54)
                    let popupHeight = min(max(460, desiredPopupHeight), geometry.size.height - 32)
                    let popupTop = max(16, geometry.size.height - popupHeight - 28)

                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(DieterTheme.usesTransparency ? 0.12 : 0.08)
                            .contentShape(Rectangle())
                            .onTapGesture { store.fleet.dismissMachinePopover() }
                            .accessibilityHidden(true)
                        MachinePopover()
                            .frame(width: popupWidth, height: popupHeight)
                            .offset(x: workspaceLeadingEdge + DieterMetrics.panelGap, y: popupTop)
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            MachineDeliveryToastStack()
                .padding(.top, DieterMetrics.titleBandHeight)
                .padding(.trailing, DieterMetrics.windowInset + 4)
        }
        .overlay {
            if !store.phase.isConnected && (!store.hasLoadedWorkspace || store.phase.needsConnectionOverlay) {
                ConnectionOverlay()
            }
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
        .alert(
            "Dieter",
            isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

/// The window controls and the show-sidebar button while the sidebar card is
/// hidden. Top bars move right by this capsule's width.
struct DieterWindowControlsCapsule: View {
    static let width: CGFloat = 132
    let showSidebar: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            DieterWindowTrafficLights()
                .frame(width: 76, height: 36)
            Button(action: showSidebar) {
                Image(systemName: "sidebar.left").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 28))
            .help("Show sidebar (⌃⌘S)")
            .accessibilityLabel("Show sidebar")
            .accessibilityIdentifier("workspace.sidebar.show")
            Spacer(minLength: 0)
        }
        .padding(.trailing, 6)
        .frame(width: Self.width, height: 36)
        .dieterCapsuleChrome(interactive: false)
    }
}

/// How far top bars move right so they clear the floating window controls.
private struct DieterTitleBandLeadingInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var dieterTitleBandLeadingInset: CGFloat {
        get { self[DieterTitleBandLeadingInsetKey.self] }
        set { self[DieterTitleBandLeadingInsetKey.self] = newValue }
    }
}

/// A floating glass notice while synchronized views show cached data.
struct WorkspaceFreshnessBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let notice: ClientWorkspaceNotice
    let lastSyncedAt: Date?

    private var isWorking: Bool { notice.working }
    private var accent: Color { notice.offline ? DieterTheme.coral : DieterTheme.amber }
    private var title: String { notice.title }
    private var detail: String { notice.detail }

    private func updated(now: Date) -> String {
        SharedRules.shared.workspaceUpdated(atMillis: lastSyncedAt?.epochMillis ?? 0, nowMillis: now.epochMillis)
    }

    var body: some View {
        let now = Date()
        HStack(spacing: 9) {
            Group {
                if isWorking {
                    if reduceMotion {
                        Image(systemName: "hourglass").font(.system(size: 10))
                    } else {
                        ProgressView().controlSize(.mini).accessibilityLabel(title)
                    }
                } else {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(accent)
            .frame(width: 16)
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(DieterTheme.subtle)
                .lineLimit(1)
            Text(updated(now: now))
                .font(DieterFont.monoSmall)
                .foregroundStyle(DieterTheme.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .dieterCapsuleChrome(interactive: false)
        .overlay { Capsule().strokeBorder(accent.opacity(0.35), lineWidth: 1).allowsHitTesting(false) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(title). \(detail) \(updated(now: now))."
        )
        .accessibilityIdentifier("workspace.cached")
    }
}

/// Compact workspace connection state, docked beside the machines so it never
/// floats over a pane header. The full freshness lives in the tooltip and
/// accessibility label.
private struct SidebarConnectionStatus: View {
    @Environment(DieterStore.self) private var store

    /// Live, still working toward live, or offline until something changes.
    private var dotColor: Color {
        if store.workspaceIsLive { return DieterTheme.running }
        return store.workspaceNotice?.offline == true ? DieterTheme.coral : DieterTheme.amber
    }

    private var working: Bool { !store.workspaceIsLive && store.workspaceNotice?.offline != true }

    private var label: String { store.session.phaseLabel }

    var body: some View {
        let now = Date()
        HStack(spacing: 5) {
            if working {
                DieterActivityIndicator(color: dotColor, size: 8).accessibilityHidden(true)
            } else {
                Circle().fill(dotColor).frame(width: 6, height: 6).accessibilityHidden(true)
            }
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(store.workspaceIsLive ? DieterTheme.tertiary : dotColor)
                .lineLimit(1)
        }
        .fixedSize()
        .help(accessibilityLabel(now: now))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(now: now))
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func accessibilityLabel(now: Date) -> String {
        let freshness = SharedRules.shared.lastConnected(
            atMillis: store.lastSyncedAt?.epochMillis ?? 0, nowMillis: now.epochMillis)
        return "Dieter is \(label.lowercased()), \(freshness)"
    }

    private var accessibilityIdentifier: String {
        "connection.\(label.lowercased().replacingOccurrences(of: " ", with: "-"))"
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
            .smokeTarget("sidebar.scroll-region")
            sidebarActions
                .fixedSize(horizontal: false, vertical: true)
        }
        .dieterPanel(radius: DieterMetrics.sidebarCardRadius)
        .padding(.leading, DieterMetrics.windowInset)
        .padding(.vertical, DieterMetrics.windowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.main-pane")
        .smokeTarget("sidebar.main-pane")
        .ignoresSafeArea(.container, edges: .top)
        .task(id: store.phase.isConnected) {
            // The quota subscription starts with the workspace, not with the
            // first popover; the panel below the machines shows it.
            guard store.phase.isConnected else { return }
            await store.loadProviderQuotas()
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
                Image(systemName: "sidebar.left").font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(DieterTheme.subtle)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide sidebar (⌃⌘S)")
            .accessibilityLabel("Hide sidebar")
            .accessibilityIdentifier("sidebar.hide")
        }
        .padding(.trailing, 8)
        .frame(height: 36)
        .background(DieterTitleBandRegion().smokeTarget("workspace.title-band"))
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
            .accessibilityIdentifier("sidebar.inbox").smokeTarget("sidebar.inbox")

            DieterNavRow(title: "Chats", symbol: "bubble.left.and.bubble.right", selected: store.section == .chats) {
                if !activeChats.isEmpty { DieterRowCount(count: activeChats.count) }
            } action: {
                Task { await store.openChats() }
            }
            .accessibilityIdentifier("sidebar.all-chats").smokeTarget("sidebar.all-chats")

            let runningTerminals = store.terminalsModel.terminals.filter { $0.status == "running" }.count
            DieterNavRow(title: "Terminals", symbol: "terminal", selected: store.section == .terminals) {
                if runningTerminals > 0 { DieterRowCount(count: runningTerminals) }
            } action: {
                Task { await store.openTerminals() }
            }
            .accessibilityIdentifier("sidebar.terminals").smokeTarget("sidebar.terminals")

            let screens = store.screensModel.connectedCount
            DieterNavRow(
                title: "Screens", symbol: "rectangle.inset.filled.and.person.filled",
                selected: store.section == .screens
            ) {
                if screens > 0 { DieterRowCount(count: screens) }
            } action: {
                store.openScreens()
            }
            .accessibilityIdentifier("sidebar.screens").smokeTarget("sidebar.screens")
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
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(store.section == .settings ? DieterTheme.text : DieterTheme.subtle)
                    .frame(width: 30, height: 30)
                    .background(
                        store.section == .settings ? DieterTheme.tileSelected : .clear,
                        in: RoundedRectangle(cornerRadius: DieterMetrics.rowRadius, style: .continuous)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("sidebar.settings").smokeTarget("sidebar.settings")
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

/// The machines and provider quotas, in one recessed panel at the foot of the
/// sidebar card.
private struct SidebarStatusPanel: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Machines").font(.system(size: 11, weight: .semibold)).foregroundStyle(DieterTheme.tertiary)
                Spacer(minLength: 4)
                SidebarConnectionStatus()
            }
            .padding(.horizontal, 8).frame(height: 24)
            ForEach(store.machines) { machine in
                SidebarMachineRow(machine: machine)
            }
            Rectangle().fill(DieterTheme.hairline).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 5)
            ProviderQuotaSidebarBlock()
        }
        .padding(.vertical, 6)
        .dieterInset(radius: 12)
    }
}

private struct SidebarMachineRow: View {
    @Environment(DieterStore.self) private var store
    let machine: MachineEndpoint

    var body: some View {
        let online = store.machineIsAvailable(machine)
        let detail = store.machineStatusLine(machine)
        let entry = store.machineEntry(machine)
        Button {
            Task { await store.fleet.openMachine(machine.id) }
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    DieterStatusDot(color: online ? DieterTheme.running : DieterTheme.tertiary.opacity(0.6), size: 6)
                    name(online: online).fixedSize()
                    privacy(entry)
                    Spacer(minLength: 6)
                    detailText(detail).fixedSize()
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 7) {
                        DieterStatusDot(
                            color: online ? DieterTheme.running : DieterTheme.tertiary.opacity(0.6), size: 6)
                        name(online: online)
                        privacy(entry)
                        Spacer(minLength: 0)
                    }
                    detailText(detail).padding(.leading, 13)
                }
                .padding(.vertical, 4)
            }
            .padding(.horizontal, 8).frame(minHeight: 26)
            .background(
                store.fleet.selectedMachineID == machine.id ? DieterTheme.tileSelected : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(detail: detail, entry: entry))
        .accessibilityIdentifier("machine.\(machine.daemonID ?? machine.id)")
    }

    private func name(online: Bool) -> some View {
        Text(machine.name)
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(online ? DieterTheme.text : DieterTheme.subtle)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder private func privacy(_ entry: ClientMachineEntry?) -> some View {
        if let entry, entry.privacyActive || entry.privacyWarning {
            Image(systemName: entry.privacyWarning ? "exclamationmark.shield" : "lock.shield")
                .font(.system(size: 10.5))
                .foregroundStyle(entry.privacyWarning ? DieterTheme.amber : DieterTheme.subtle)
                .opacity(entry.privacyStale ? 0.45 : 1)
                .help(entry.privacyLabel)
                .accessibilityLabel(entry.privacyLabel)
                .accessibilityIdentifier("machine.privacy.\(machine.id)")
        }
    }

    private func detailText(_ detail: String) -> some View {
        Text(detail)
            .font(DieterFont.monoSmall)
            .foregroundStyle(DieterTheme.tertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(detail)
    }

    private func accessibilityLabel(detail: String, entry: ClientMachineEntry?) -> String {
        let privacy = entry.flatMap { $0.privacyActive || $0.privacyWarning ? $0.privacyLabel : nil }
        return [machine.name, detail, privacy].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
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

/// The Inbox's active rows, grouped by project for the sidebar.
enum SidebarProjectActivity {
    /// Each project's running, waiting, and reviewable conversations.
    static func group(_ entries: [InboxActivityEntry]) -> [String: [InboxActivityEntry]] {
        Dictionary(grouping: entries.filter(isActive)) { $0.card.projectID }
    }

    static func isActive(_ entry: InboxActivityEntry) -> Bool {
        entry.running || entry.needsYou || entry.kind == .review || entry.kind == .failed
    }

    @MainActor static func color(_ entry: InboxActivityEntry) -> Color {
        if entry.needsYou { return DieterTheme.attention }
        if entry.running { return DieterTheme.running }
        if entry.kind == .failed { return DieterTheme.failed }
        return DieterTheme.tertiary
    }
}

private struct SidebarProjectFolderGroup<Content: View>: View {
    let folder: ClientNavigationFolder
    let visibleCount: Int
    let toggleExpanded: () -> Void
    let moveProjectHere: (String) -> Void
    let rename: () -> Void
    let delete: () -> Void
    @ViewBuilder let content: Content
    @State private var dropTargeted = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(DieterTheme.tertiary)
                            .rotationEffect(.degrees(folder.expanded ? 90 : 0))
                            .frame(width: 10)
                        Image(systemName: dropTargeted ? "folder.fill.badge.plus" : "folder")
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(dropTargeted ? DieterTheme.shell : DieterTheme.subtle)
                        Text(folder.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DieterTheme.text.opacity(0.88))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if !hovering {
                            Text("\(visibleCount)")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(DieterTheme.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if hovering {
                    Menu {
                        Button("Rename folder…", systemImage: "pencil", action: rename)
                        Divider()
                        Button("Delete folder", systemImage: "trash", role: .destructive, action: delete)
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 18, height: 20)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Folder options")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: DieterMetrics.rowHeight)
            .background(
                dropTargeted ? DieterTheme.tileSelected : (hovering ? DieterTheme.tileHover : .clear),
                in: RoundedRectangle(cornerRadius: DieterMetrics.rowRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DieterMetrics.rowRadius, style: .continuous)
                    .strokeBorder(dropTargeted ? DieterTheme.shell.opacity(0.55) : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .dropDestination(for: String.self) { values, _ in
                guard let value = values.first, let payload = SidebarProjectDragPayload(value) else { return false }
                moveProjectHere(payload.projectID)
                return true
            } isTargeted: {
                dropTargeted = $0
            }
            .contextMenu {
                Button("Rename folder…", systemImage: "pencil", action: rename)
                Button("Delete folder", systemImage: "trash", role: .destructive, action: delete)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(folder.name), \(visibleCount) projects")
            .accessibilityIdentifier("sidebar.project-folder.\(folder.id)")
            .smokeTarget("sidebar.project-folder.\(folder.id)")

            if folder.expanded {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.leading, 10)
            }
        }
        .padding(.vertical, 1)
        .animation(.snappy(duration: 0.18), value: folder.expanded)
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
    }
}

/// A project: its name, a strip of its active conversations, and, while
/// expanded, its destinations and the conversations that are running or wait.
private struct SidebarProjectRow: View {
    @Environment(DieterStore.self) private var store
    let project: Dieter_V1_Project
    let projectIDs: [String]
    let expanded: Bool
    let pinned: Bool
    let activity: [InboxActivityEntry]
    let toggleExpanded: () -> Void
    let moveProject: (String, String?) -> Void
    @State private var dropTargeted = false
    @State private var hovering = false

    private var selected: Bool {
        store.selectedProjectID == project.id && [.board, .files, .changes, .schedules].contains(store.section)
    }

    private var accessibilityLabel: String {
        "\(project.name), \(SharedRules.shared.count(count: Int32(project.checkoutChoices.count), noun: "checkout", plural: ""))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 6) {
                        Text(project.name)
                            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? DieterTheme.text : DieterTheme.text.opacity(0.88))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                            .smokeTarget("sidebar.project.\(project.id).name")
                        if pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(DieterTheme.tertiary)
                                .accessibilityLabel("Pinned project")
                        }
                        Spacer(minLength: 4)
                        if !hovering && !activity.isEmpty {
                            SidebarActivityStrip(entries: activity)
                            Text("\(activity.count)")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(DieterTheme.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(project.name)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityIdentifier("sidebar.project.\(project.id)")
                .accessibilityAction(named: "Edit project") {
                    guard store.projectIsAvailable(project.id) else { return }
                    store.presentProjectEditor(projectID: project.id)
                }
                .accessibilityAction(named: "New board") {
                    guard store.projectIsAvailable(project.id) else { return }
                    store.presentNewBoard(projectID: project.id)
                }

                if hovering {
                    Button {
                        store.presentProjectEditor(projectID: project.id)
                    } label: {
                        Image(systemName: "gearshape").font(.system(size: 11)).frame(width: 18, height: 20)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DieterTheme.tertiary)
                    .help("Project context for \(project.name)")
                    .accessibilityLabel("Project context for \(project.name)")
                    .accessibilityIdentifier("sidebar.project.\(project.id).settings")
                    .smokeTarget("sidebar.project.\(project.id).settings")
                    .disabled(!store.projectIsAvailable(project.id))
                    .transition(.opacity)

                    Button {
                        store.presentNewBoard(projectID: project.id)
                    } label: {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                            .frame(width: 16, height: 20)
                    }
                    .buttonStyle(.plain).foregroundStyle(DieterTheme.tertiary)
                    .disabled(!store.projectIsAvailable(project.id))
                    .help("New board in \(project.name)")
                    .accessibilityLabel("New board in \(project.name)")
                    .accessibilityIdentifier("sidebar.project.\(project.id).new-board")
                    .smokeTarget("sidebar.project.\(project.id).new-board")
                    .transition(.opacity)
                }

                Button(action: toggleExpanded) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(DieterTheme.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 14, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering || expanded ? 1 : 0.55)
                .help(expanded ? "Collapse \(project.name)" : "Expand \(project.name)")
                .accessibilityLabel(expanded ? "Collapse \(project.name)" : "Expand \(project.name)")
                .accessibilityIdentifier("sidebar.project.\(project.id).toggle")
                .smokeTarget("sidebar.project.\(project.id).toggle")
            }
            .padding(.leading, 10).padding(.trailing, 6).frame(height: DieterMetrics.rowHeight + 2)
            .background {
                RoundedRectangle(cornerRadius: DieterMetrics.rowRadius + 1, style: .continuous)
                    .fill(
                        dropTargeted
                            ? DieterTheme.tileSelected
                            : (selected ? DieterTheme.tileSelected : (hovering ? DieterTheme.tileHover : .clear)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: DieterMetrics.rowRadius + 1, style: .continuous)
                    .strokeBorder(
                        dropTargeted ? DieterTheme.shell.opacity(0.55) : (selected ? DieterTheme.tileRim : .clear))
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .draggable(SidebarProjectDragPayload(projectID: project.id).encoded) {
                SidebarProjectDragPreview(project: project)
            }
            .dropDestination(for: String.self) { values, location in
                guard let value = values.first, let payload = SidebarProjectDragPayload(value),
                    payload.projectID != project.id
                else { return false }
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
            } isTargeted: {
                dropTargeted = $0
            }
            .animation(.easeOut(duration: 0.12), value: dropTargeted)
            .animation(.easeOut(duration: 0.12), value: hovering)

            if expanded {
                SidebarProjectTabs(project: project)
                if !activity.isEmpty {
                    SidebarProjectActivityList(entries: activity)
                }
            }
        }
        .padding(.bottom, expanded ? 8 : 1)
        .animation(.snappy(duration: 0.18), value: expanded)
        .projectContextMenu(for: project)
    }
}

/// One short dash per active conversation, coloured by what it is doing.
private struct SidebarActivityStrip: View {
    let entries: [InboxActivityEntry]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(entries.prefix(5).enumerated()), id: \.offset) { _, entry in
                Capsule().fill(SidebarProjectActivity.color(entry)).frame(width: 7, height: 2.5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Board · Files · Changes · Schedules for an expanded project.
private struct SidebarProjectTabs: View {
    @Environment(DieterStore.self) private var store
    let project: Dieter_V1_Project

    private var projectIsUnavailable: Bool { !store.projectIsAvailable(project.id) }

    /// The board the Board tab opens: the selected one in this project, else its first.
    private var board: Dieter_V1_Board? {
        let boards = store.boards(for: project.id)
        if store.selectedProjectID == project.id, let selected = boards.first(where: { $0.id == store.selectedBoardID })
        {
            return selected
        }
        return boards.first
    }

    private var current: Bool { store.selectedProjectID == project.id }

    var body: some View {
        HStack(spacing: 1) {
            if let board {
                tab(
                    "Board", symbol: "rectangle.split.3x1", selected: current && store.section == .board,
                    id: "sidebar.board.\(board.id)"
                ) { store.openBoard(board.id, projectID: project.id) }
                .attentionDot(Int(store.boardAttention[board.id] ?? 0))
            } else {
                tab(
                    "Board", symbol: "rectangle.split.3x1", selected: false,
                    id: "sidebar.boardless-create.\(project.id)"
                ) {
                    store.presentNewBoard(projectID: project.id)
                }
                .disabled(projectIsUnavailable)
                .opacity(projectIsUnavailable ? 0.42 : 1)
            }
            tab(
                "Files", symbol: "folder", selected: current && store.section == .files,
                id: "sidebar.files.\(project.id)"
            ) {
                Task { await store.openProject(project.id, section: .files) }
            }
            .disabled(projectIsUnavailable)
            .opacity(projectIsUnavailable ? 0.42 : 1)
            tab(
                "Changes", symbol: "arrow.triangle.branch", selected: current && store.section == .changes,
                id: "sidebar.changes.\(project.id)"
            ) {
                Task { await store.openProjectChanges(project.id) }
            }
            .disabled(projectIsUnavailable)
            .opacity(projectIsUnavailable ? 0.42 : 1)
            tab(
                "Schedules", symbol: "clock", selected: current && store.section == .schedules,
                id: "sidebar.schedules.\(project.id)"
            ) {
                Task { await store.openProject(project.id, section: .schedules) }
            }
            .disabled(projectIsUnavailable)
            .opacity(projectIsUnavailable ? 0.42 : 1)
        }
        .padding(2)
        .background(DieterTheme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func tab(
        _ title: String, symbol: String, selected: Bool, id: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 12, weight: .regular))
                Text(title).font(.system(size: 9.5, weight: selected ? .semibold : .medium)).lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(selected ? DieterTheme.text : DieterTheme.subtle)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? DieterTheme.segmentThumb : .clear)
                    .shadow(color: .black.opacity(selected && !DieterTheme.isDark ? 0.08 : 0), radius: 1.5, y: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
        .smokeTarget(id)
    }
}

private extension View {
    /// A small attention marker on a project tab.
    func attentionDot(_ count: Int) -> some View {
        overlay(alignment: .topTrailing) {
            if count > 0 {
                DieterStatusDot(color: DieterTheme.attention, size: 6).padding(5).accessibilityHidden(true)
            }
        }
    }
}

/// The project's running, waiting, and reviewable conversations.
private struct SidebarProjectActivityList: View {
    @Environment(DieterStore.self) private var store
    let entries: [InboxActivityEntry]

    var body: some View {
        let now = Date()
        VStack(spacing: 0) {
            ForEach(entries.prefix(8)) { entry in
                let selected = (store.selectedCardID ?? store.selectedChatID) == entry.id
                DieterNavRow(
                    title: entry.row.title, selected: selected,
                    leadingDot: SidebarProjectActivity.color(entry)
                ) {
                    Text(
                        SharedRules.shared.activityAge(
                            atMillis: entry.row.shownAtMillis, nowMillis: now.epochMillis, suffix: false)
                    )
                    .font(DieterFont.monoSmall)
                    .foregroundStyle(DieterTheme.tertiary)
                } action: {
                    guard !selected else { return }
                    Task { await store.openConversation(cardID: entry.id, chat: entry.row.chat) }
                }
                .accessibilityIdentifier("sidebar.activity.\(entry.id)")
            }
        }
        .padding(.top, 2)
    }
}

/// Compact host marker shown beside each chat.
struct ProjectMachineBadge: View {
    let machine: MachineEndpoint
    let online: Bool
    var compact = false

    var body: some View {
        Group {
            if compact {
                ViewThatFits(in: .horizontal) {
                    badge(showName: true).frame(maxWidth: 72)
                    badge(showName: true).frame(width: 40)
                    badge(showName: false)
                }
            } else {
                badge(showName: true)
            }
        }
        .help("Hosted on \(machine.name) · \(SharedRules.shared.machinePresence(online: online))")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hosted on \(machine.name), \(online ? "online" : "offline")")
    }

    private func badge(showName: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(online ? DieterTheme.machineOnline : DieterTheme.machineOffline).frame(width: 5, height: 5)
            if showName {
                Text(machine.name)
                    .font(.system(size: 8.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .foregroundStyle(online ? DieterTheme.subtle : DieterTheme.tertiary)
        .padding(.horizontal, 6)
        .frame(height: 16)
        .background(DieterTheme.tileHover, in: Capsule())
    }
}

private struct ProjectContextMenuModifier: ViewModifier {
    @Environment(DieterStore.self) private var store
    let project: Dieter_V1_Project
    @State private var deleteConfirmationPresented = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                let pinned = store.navigation.projects.pinned.contains(project.id)
                Button(pinned ? "Unpin project" : "Pin project", systemImage: pinned ? "pin.slash" : "pin") {
                    store.setProjectPinned(project.id, pinned: !pinned)
                }
                Divider()
                Button("Rename project…", systemImage: "pencil") {
                    store.presentRenameProject(projectID: project.id)
                }
                Button("Edit project…", systemImage: "slider.horizontal.3") {
                    store.presentProjectEditor(projectID: project.id)
                }
                .disabled(!store.projectIsAvailable(project.id))
                Button("New board…", systemImage: "plus") {
                    store.presentNewBoard(projectID: project.id)
                }
                .disabled(!store.projectIsAvailable(project.id))
                let folders = store.navigation.projects.folders
                if !folders.isEmpty {
                    Divider()
                    Menu("Move to folder", systemImage: "folder") {
                        ForEach(folders, id: \.id) { folder in
                            Button {
                                moveProject(to: folder.id)
                            } label: {
                                if folder.itemIds.contains(project.id) {
                                    Label(folder.name, systemImage: "checkmark")
                                } else {
                                    Text(folder.name)
                                }
                            }
                        }
                        if folders.folder(containing: project.id) != nil {
                            Divider()
                            Button("No folder", systemImage: "arrow.up.backward") {
                                moveProject(to: nil)
                            }
                        }
                    }
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
                Text(
                    "This removes the project from the sidebar without deleting its Git working tree. You can restore it from Archive."
                )
            }
    }

    private func moveProject(to folderID: String?) {
        store.moveToFolder(.projects, itemID: project.id, folderID: folderID)
    }
}

private extension View {
    func projectContextMenu(for project: Dieter_V1_Project) -> some View {
        modifier(ProjectContextMenuModifier(project: project))
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
            guard let value = values.first, let payload = SidebarProjectDragPayload(value),
                payload.projectID != beforeProjectID
            else { return false }
            moveProject(payload.projectID)
            return true
        } isTargeted: {
            targeted = $0
        }
        .animation(.easeOut(duration: 0.12), value: targeted)
    }
}

struct SidebarProjectDragPreview: View {
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

/// The global "New Task" action at the trailing end of each top bar.
struct GlobalQuickTaskButton: View {
    @Environment(DieterStore.self) private var store
    var compact = false
    @State private var presented = false

    var body: some View {
        Button {
            presented = true
        } label: {
            if compact {
                Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text("New Task")
                }
            }
        }
        .buttonStyle(DieterBarButtonStyle(shape: compact ? .circle : .capsule, prominent: true))
        .help("New task")
        .accessibilityLabel("Quick task")
        .accessibilityIdentifier("sidebar.quick-task")
        .smokeTarget("sidebar.quick-task")
        .popover(isPresented: $presented, arrowEdge: .top) {
            QuickTaskPopover(isPresented: $presented, draft: store.quickTaskForm, chooseDestination: true)
                .environment(store)
        }
    }
}

struct ConnectionOverlay: View {
    @Environment(DieterStore.self) private var store
    @State private var address = ""

    var body: some View {
        ZStack {
            Color.black.opacity(DieterTheme.usesTransparency ? 0.38 : 0.55).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 17) {
                    DieterBrandIcon(size: 62)
                    VStack(spacing: 6) {
                        Text("Connect Dieter").font(.title2.weight(.bold))
                        Text(
                            "Choose the gateway that knows your account. Dieter automatically combines projects and conversations from every enrolled machine."
                        )
                        .font(.system(size: 13)).foregroundStyle(DieterTheme.subtle)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        OnboardingConnectionConcept(
                            symbol: "point.3.connected.trianglepath.dotted", title: "Gateway",
                            detail: "Sign-in, machine discovery, encrypted relay")
                        Image(systemName: "arrow.right").foregroundStyle(DieterTheme.tertiary)
                        OnboardingConnectionConcept(
                            symbol: "desktopcomputer", title: "All machines",
                            detail: "One combined workspace with automatic routing")
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        Text("1  CHOOSE A GATEWAY").font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(
                            DieterTheme.tertiary)
                        ForEach(store.gateways) { gateway in
                            Button {
                                Task { await store.chooseGateway(gateway) }
                            } label: {
                                OnboardingGatewayRow(
                                    gateway: gateway,
                                    active: gateway.credentialID == store.activeGateway.credentialID
                                )
                            }.buttonStyle(.plain)
                        }
                        Text(
                            "The primary gateway is the normal choice. Add another only for a separate self-hosted or organizational deployment; its session and machines are separate."
                        )
                        .font(.caption2).foregroundStyle(DieterTheme.tertiary).fixedSize(
                            horizontal: false, vertical: true)
                    }

                    if store.phase == .authenticationRequired {
                        VStack(spacing: 8) {
                            Text("Sign in to \(store.activeGateway.name) to discover its enrolled machines.")
                                .font(.caption).foregroundStyle(DieterTheme.subtle)
                            Button("Sign in with GitHub") { Task { await store.signIn() } }.buttonStyle(
                                .borderedProminent)
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
                                if let gateway = MachineEndpoint(address: address, name: "Custom gateway") {
                                    Task { await store.saveEndpoint(gateway) }
                                    address = ""
                                }
                            }.disabled(MachineEndpoint(address: address, name: "") == nil)
                        }.padding(.top, 8)
                    }
                    .font(.caption)

                    if case .connecting = store.phase {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small); Text("Contacting \(store.activeGateway.name)…")
                        }
                        .font(.caption).foregroundStyle(DieterTheme.subtle)
                    }
                    if case let .failed(message) = store.phase {
                        Text(message).font(.caption).foregroundStyle(DieterTheme.coral).fixedSize(
                            horizontal: false, vertical: true)
                    }
                }
                .padding(24)
            }
            .frame(width: 570)
            .frame(maxHeight: 720)
            .dieterOverlayChrome(cornerRadius: 22)
        }
    }
}

private struct OnboardingConnectionConcept: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(DieterTheme.shell)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(detail).font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary).lineLimit(2)
            }
        }
        .padding(10).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .dieterInset(radius: 10)
    }
}

private struct OnboardingGatewayRow: View {
    let gateway: MachineEndpoint
    let active: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "network").foregroundStyle(DieterTheme.shell).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(gateway.name).font(.system(size: 12, weight: .semibold))
                    if gateway.isPrimaryGateway {
                        Text("PRIMARY").font(.system(size: 8, weight: .bold)).foregroundStyle(DieterTheme.eyes)
                    }
                }
                Text(gateway.address).font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
            Spacer()
            Image(systemName: active ? "checkmark.circle.fill" : "arrow.right")
                .foregroundStyle(active ? DieterTheme.running : DieterTheme.tertiary)
        }
        .padding(11).dieterTile(active ? .selected : .rest, radius: 10)
    }
}

private struct OnboardingMachineRow: View {
    @Environment(DieterStore.self) private var store
    let machine: MachineEndpoint

    private var detail: String { store.machineStatusLine(machine) }
    private var compatible: Bool { store.machineEntry(machine)?.compatible ?? true }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(machine.online ? DieterTheme.running : DieterTheme.tertiary).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(machine.name).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
            Spacer()
            Text(!compatible ? "Update daemon" : (machine.online ? "Included automatically" : "Offline"))
                .font(.caption2).foregroundStyle(storeColor)
        }
        .padding(11).dieterTile(radius: 10)
    }

    private var storeColor: Color {
        !compatible ? DieterTheme.coral : (machine.online ? DieterTheme.shell : DieterTheme.tertiary)
    }
}

#Preview("Dieter") {
    DieterRootView()
        .environment(DieterStore())
        .dieterThemeRoot(
            palette: DieterPalette.defaultValue,
            appearance: DieterAppearance.defaultValue
        )
        .frame(width: 1380, height: 870)
}
