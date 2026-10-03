#if os(iOS)
    import DieterAPI
    import SwiftUI

    /// The signed-in workspace: a sidebar of destinations and projects, the
    /// destination's list, and the open conversation. iPad shows the three
    /// columns; iPhone collapses them into one navigation stack.
    struct IOSWorkspaceView: View {
        @Environment(IOSAppModel.self) private var app
        @Environment(IOSWorkspaceNavigation.self) private var navigation
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        var body: some View {
            @Bindable var navigation = navigation
            NavigationSplitView(preferredCompactColumn: $navigation.preferredColumn) {
                // The sidebar column reports a compact size class even beside
                // the other columns, so the window's class decides.
                IOSSidebarView(collapsed: horizontalSizeClass == .compact)
                    .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 340)
            } content: {
                content
                    .navigationSplitViewColumnWidth(min: 280, ideal: 350, max: 480)
            } detail: {
                detail
            }
            .accessibilityIdentifier("ios.workspace")
            // The conversation toolbar shows its account's quota.
            .task { await app.quotas.load() }
            .sheet(item: $navigation.sheet) { sheet in
                switch sheet {
                case .settings:
                    NavigationStack { IOSSettingsView() }
                case .machines:
                    NavigationStack { IOSMachinesView() }
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                case .machineState:
                    NavigationStack {
                        IOSMachineStateView()
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { navigation.sheet = nil }
                                        .accessibilityIdentifier("ios.machine-state.done")
                                }
                            }
                    }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                case .providerQuotas:
                    IOSProviderQuotaDetailsView(quotas: app.quotas)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                case .create(let request):
                    IOSCreateTaskView(request: request)
                case .files(let scope):
                    IOSFilesView(scope: scope)
                case .shareTarget(let request):
                    IOSShareTargetPicker(request: request)
                }
            }
        }

        @ViewBuilder
        private var content: some View {
            switch navigation.destination {
            case .inbox, nil:
                IOSInboxView()
            case .chats:
                IOSChatsView()
            case .project(let id):
                IOSProjectBoardsView(projectID: id)
            case .board(let id):
                IOSBoardView(boardID: id).id(id)
            case .terminals:
                IOSTerminalsMachinePickerView()
            case .screens:
                IOSScreensMachinePickerView()
            }
        }

        @ViewBuilder
        private var detail: some View {
            if navigation.destination == .terminals {
                if let machineID = navigation.terminalMachineID {
                    IOSTerminalsView(machineID: machineID).id(machineID)
                } else {
                    IOSTerminalsPlaceholderView()
                }
            } else if navigation.destination == .screens {
                if let machineID = navigation.screenMachineID {
                    IOSScreensView(machineID: machineID).id(machineID)
                } else {
                    IOSScreensPlaceholderView()
                }
            } else if let id = navigation.selectedCardID {
                IOSConversationScreen(cardID: id).id(id)
            } else {
                ContentUnavailableView(
                    "Choose a conversation", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Open a task or chat to read its conversation and continue working."))
            }
        }
    }

    // MARK: - Sidebar

    private struct IOSSidebarView: View {
        @Environment(IOSAppModel.self) private var app
        @Environment(IOSWorkspaceNavigation.self) private var navigation
        /// The columns collapse into one stack, which hides the list's own New task.
        let collapsed: Bool

        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if app.session.hasNotice {
                        let notice = app.session.notice
                        IOSConnectionBanner(
                            title: notice.title, detail: notice.detail, isConnecting: notice.working,
                            retry: notice.working ? nil : { Task { await app.reconnect() } })
                    }

                    VStack(spacing: 0) {
                        row(
                            .inbox, title: "Inbox", systemImage: "tray", identifier: "ios.inbox",
                            count: Int(app.activity.summary.attention))
                        divider()
                        row(
                            .chats, title: "Chats", systemImage: "bubble.left.and.bubble.right", identifier: "ios.chats"
                        )
                        divider()
                        row(.terminals, title: "Terminals", systemImage: "terminal", identifier: "ios.terminals.open")
                        divider()
                        row(.screens, title: "Screens", systemImage: "display", identifier: "ios.screens.open")
                    }
                    .modifier(IOSGlassCardModifier(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))

                    projects
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background { IOSWorkspaceBackdrop() }
            .navigationTitle("Dieter")
            .accessibilityIdentifier("ios.sidebar")
            .refreshable { await app.reconnect() }
            .toolbar {
                // Machines sit beside Settings: the iPad sidebar's narrow bar
                // would otherwise fold a third trailing item into its overflow.
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { navigation.sheet = .settings }
                        .accessibilityIdentifier("ios.settings")
                    Menu("Machines", systemImage: "desktopcomputer") {
                        Button("Machines", systemImage: "desktopcomputer") { navigation.sheet = .machines }
                            .accessibilityIdentifier("ios.machines.open")
                        Button("Machine state", systemImage: "gauge.with.dots.needle.67percent") {
                            navigation.sheet = .machineState
                        }
                        .accessibilityIdentifier("ios.machine-state.open")
                    }
                    .accessibilityIdentifier("ios.machines.menu")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Provider quotas", systemImage: "gauge.with.needle") {
                        navigation.sheet = .providerQuotas
                    }
                    .accessibilityIdentifier("ios.provider-quotas")
                    if collapsed {
                        Button("New task", systemImage: "square.and.pencil") { createTask() }
                            .accessibilityIdentifier("ios.new-task")
                    }
                }
            }
        }

        /// The projects as the shared navigation lays them out: folders in
        /// order, then projects in no folder.
        @ViewBuilder
        private var projects: some View {
            let layout = app.navigation.projects
            Text("Projects")
                .font(.title3.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            if layout.order.isEmpty {
                Group {
                    if app.workspace.loaded {
                        Text("No projects")
                    } else {
                        ProgressView("Loading projects…")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 92)
                .modifier(IOSGlassCardModifier(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
            } else if layout.folders.isEmpty {
                ForEach(layout.order, id: \.self, content: projectCard)
            } else {
                ForEach(layout.folders, id: \.id) { folder in
                    Label(folder.name, systemImage: "folder")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .accessibilityIdentifier("ios.project-folder.\(folder.id)")
                    ForEach(folder.itemIds, id: \.self, content: projectCard)
                }
                ForEach(layout.unfiled, id: \.self, content: projectCard)
            }
        }

        @ViewBuilder
        private func projectCard(_ projectID: String) -> some View {
            if let project = app.project(projectID) {
                VStack(spacing: 0) {
                    row(
                        .project(project.id), title: project.name, systemImage: "folder",
                        identifier: "ios.project.\(project.id)", emphasized: true)
                    ForEach(app.boards(in: project.id), id: \.id) { board in
                        divider()
                        row(
                            .board(board.id), title: board.name, systemImage: "rectangle.split.3x1",
                            identifier: "ios.board.\(board.id)", indent: 16,
                            count: Int(app.workspace.boardAttention[board.id] ?? 0))
                    }
                }
                .modifier(IOSGlassCardModifier(shape: RoundedRectangle(cornerRadius: 24, style: .continuous)))
            }
        }

        private func row(
            _ value: IOSWorkspaceDestination, title: String, systemImage: String, identifier: String,
            indent: CGFloat = 0, emphasized: Bool = false, count: Int = 0
        ) -> some View {
            let selected = navigation.destination == value
            return Button {
                navigation.show(value)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
                        .frame(width: 28)
                    Text(title)
                        .font(emphasized ? .headline : .body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if count > 0 {
                        Text(count, format: .number)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.18), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 18 + indent)
                .padding(.trailing, 16)
                .frame(minHeight: 56)
                .background(selected ? Color.accentColor.opacity(0.12) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }

        private func divider() -> some View {
            Divider().padding(.leading, 58)
        }

        private func createTask() {
            switch navigation.destination {
            case .chats: navigation.create(chat: true)
            case .board(let id): navigation.create(chat: false, projectID: app.board(id)?.projectID ?? "", boardID: id)
            case .project(let id): navigation.create(chat: false, projectID: id)
            default: navigation.create(chat: false)
            }
        }
    }

    // MARK: - Project

    /// A project's boards; each opens its board view.
    private struct IOSProjectBoardsView: View {
        @Environment(IOSAppModel.self) private var app
        @Environment(IOSWorkspaceNavigation.self) private var navigation
        let projectID: String

        var body: some View {
            let boards = app.boards(in: projectID)
            List {
                ForEach(boards, id: \.id) { board in
                    Button {
                        navigation.show(.board(board.id))
                    } label: {
                        HStack {
                            Label(board.name, systemImage: "rectangle.split.3x1")
                                .foregroundStyle(.primary)
                            Spacer()
                            let attention = Int(app.workspace.boardAttention[board.id] ?? 0)
                            if attention > 0 {
                                Text(attention, format: .number)
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .accessibilityIdentifier("ios.project-board.\(board.id)")
                }
            }
            .overlay {
                if boards.isEmpty {
                    ContentUnavailableView("No boards", systemImage: "rectangle.split.3x1")
                }
            }
            .navigationTitle(app.project(projectID)?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New task", systemImage: "plus") {
                        navigation.create(chat: false, projectID: projectID)
                    }
                    .accessibilityIdentifier("ios.list.new-task")
                }
            }
        }
    }
#endif
