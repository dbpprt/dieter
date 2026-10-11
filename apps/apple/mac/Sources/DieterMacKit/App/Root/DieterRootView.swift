import AppKit
import DieterClientAPI
import DieterCore
import SwiftUI

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
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("destination.\(store.section.rawValue)")
            .e2eTarget("destination.\(store.section.rawValue)")
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

#Preview("Dieter") {
    DieterRootView()
        .environment(DieterStore())
        .dieterThemeRoot(
            palette: DieterPalette.defaultValue,
            appearance: DieterAppearance.defaultValue
        )
        .frame(width: 1380, height: 870)
}
