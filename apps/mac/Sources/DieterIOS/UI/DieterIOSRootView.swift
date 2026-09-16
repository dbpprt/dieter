#if os(iOS)
    import DieterAPI
    import DieterCore
    import SwiftUI

    @MainActor
    public struct DieterIOSRootView: View {
        @Environment(\.scenePhase) private var scenePhase
        @State private var store = IOSStore()
        @State private var destination: IOSWorkspaceDestination?
        @State private var selectedTaskID: String?
        @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
        @State private var settingsPresented = false
        @State private var createPresented = false
        @State private var fileScope: IOSFileScope?
        @State private var drafts: [String: String] = [:]

        public init() {}

        public var body: some View {
            Group {
                if store.isAuthenticated {
                    workspace
                } else {
                    NavigationStack { IOSGatewayView(store: store) }
                }
            }
            .tint(.blue)
            .task { await store.bootstrap() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { store.resume() } else if phase == .background { store.suspend() }
            }
            .alert(
                "Couldn’t complete the request",
                isPresented: Binding(
                    get: { store.errorMessage != nil },
                    set: { if !$0 { store.clearError() } }
                )
            ) {
                Button("OK", role: .cancel) { store.clearError() }
            } message: {
                Text(store.errorMessage ?? "Please try again.")
            }
        }

        private var workspace: some View {
            NavigationSplitView(preferredCompactColumn: $preferredColumn) {
                sidebar
                    .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 340)
            } content: {
                IOSTaskListView(
                    store: store, destination: destination ?? .allTasks, selectedTaskID: $selectedTaskID,
                    createTask: { createPresented = true }
                )
                .navigationSplitViewColumnWidth(min: 280, ideal: 350, max: 480)
            } detail: {
                if let id = selectedTaskID {
                    IOSConversationView(
                        store: store, cardID: id, draft: draftBinding(for: id),
                        browseFiles: { openFiles(for: store.selectedCard?.card) }
                    )
                    .id((store.selectedMachine?.id ?? "") + ":" + id)
                } else {
                    ContentUnavailableView(
                        "Choose a task", systemImage: "bubble.left.and.bubble.right",
                        description: Text("Open a task to read its conversation and continue working."))
                }
            }
            .accessibilityIdentifier("ios.workspace")
            .sheet(isPresented: $settingsPresented) {
                NavigationStack { IOSSettingsView(store: store) }
            }
            .sheet(isPresented: $createPresented) {
                IOSCreateTaskView(
                    store: store, initialProjectID: selectedProjectID,
                    initialBoardID: selectedBoardID, chat: destination == .chats
                ) { id in
                    selectedTaskID = id
                    preferredColumn = .detail
                }
            }
            .sheet(item: $fileScope) { scope in
                IOSFilesView(store: store, scope: scope)
            }
            .onChange(of: destination) { _, _ in
                selectedTaskID = nil
                store.closeConversation()
            }
            .onChange(of: selectedTaskID) { _, id in
                if id != nil { preferredColumn = .detail } else { store.closeConversation() }
            }
            .onChange(of: store.selectedMachine?.id) { _, _ in
                selectedTaskID = nil
                destination = nil
                preferredColumn = .sidebar
            }
        }

        private var sidebar: some View {
            List(selection: $destination) {
                Section {
                    machinePicker
                    if !store.phase.isConnected {
                        IOSConnectionBanner(title: store.phase.label, detail: "Reconnect to continue working.") {
                            Task { await store.reconnect() }
                        }
                        .listRowInsets(EdgeInsets())
                    }
                }
                Section {
                    NavigationLink(value: IOSWorkspaceDestination.allTasks) {
                        Label("All tasks", systemImage: "square.grid.2x2")
                    }
                    .accessibilityIdentifier("ios.all-tasks")
                    NavigationLink(value: IOSWorkspaceDestination.chats) {
                        Label("Chats", systemImage: "bubble.left.and.bubble.right")
                    }
                    .accessibilityIdentifier("ios.chats")
                }
                Section("Projects") {
                    if store.projects.isEmpty {
                        Text(store.busy ? "Loading projects…" : "No projects on this machine")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(store.projects, id: \.id) { project in
                        NavigationLink(value: IOSWorkspaceDestination.project(project.id)) {
                            Label(project.name, systemImage: "folder")
                                .fontWeight(.medium)
                        }
                        .accessibilityIdentifier("ios.project.\(project.id)")
                        .contextMenu {
                            Button("Browse files", systemImage: "folder") { openProjectFiles(project) }
                                .disabled(!store.phase.isConnected)
                        }
                        ForEach(store.boards.filter { $0.projectID == project.id }, id: \.id) { board in
                            NavigationLink(value: IOSWorkspaceDestination.board(board.id)) {
                                Label(board.name, systemImage: "rectangle.split.3x1")
                                    .padding(.leading, 16)
                            }
                            .accessibilityIdentifier("ios.board.\(board.id)")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Dieter")
            .accessibilityIdentifier("ios.sidebar")
            .refreshable {
                await store.refreshMachines(); await store.reconnect()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { settingsPresented = true }
                        .accessibilityIdentifier("ios.settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New task", systemImage: "square.and.pencil") { createPresented = true }
                        .disabled(!store.phase.isConnected || store.projects.isEmpty)
                        .accessibilityIdentifier("ios.new-task")
                }
            }
        }

        private var machinePicker: some View {
            Menu {
                ForEach(store.machines) { machine in
                    Button {
                        Task { await store.selectMachine(id: machine.daemonID ?? machine.id) }
                    } label: {
                        Label(
                            machine.name + (machine.online ? "" : " · Offline"),
                            systemImage: (machine.daemonID ?? machine.id) == store.selectedMachineID
                                ? "checkmark" : "desktopcomputer")
                    }
                    .accessibilityIdentifier("ios.machine.\(machine.daemonID ?? machine.id)")
                }
                Divider()
                Button("Refresh machines", systemImage: "arrow.clockwise") {
                    Task { await store.refreshMachines() }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.selectedMachine?.name ?? "Choose a machine")
                            .font(.headline).foregroundStyle(.primary).lineLimit(2)
                        Text(store.routeDescription.isEmpty ? store.phase.label : store.routeDescription)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("ios.machine-picker")
        }

        private var selectedProjectID: String {
            switch destination {
            case let .project(id): return id
            case let .board(id): return store.boards.first { $0.id == id }?.projectID ?? ""
            default: return store.projects.first?.id ?? ""
            }
        }

        private var selectedBoardID: String? {
            if case let .board(id) = destination { return id }
            return store.boards.first { $0.projectID == selectedProjectID }?.id
        }

        private func draftBinding(for id: String) -> Binding<String> {
            let key = (store.selectedMachine?.id ?? "") + ":" + id
            return Binding(get: { drafts[key] ?? "" }, set: { drafts[key] = $0 })
        }

        private func openProjectFiles(_ project: Dieter_V1_Project) {
            fileScope = IOSFileScope(
                machineID: store.selectedMachine?.id ?? "", projectID: project.id, cardID: "", title: project.name)
        }

        private func openFiles(for card: Dieter_V1_Card?) {
            guard let card else { return }
            fileScope = IOSFileScope(
                machineID: store.selectedMachine?.id ?? "", projectID: card.projectID, cardID: card.id,
                title: card.title)
        }
    }

    struct IOSTaskListView: View {
        @Bindable var store: IOSStore
        let destination: IOSWorkspaceDestination
        @Binding var selectedTaskID: String?
        let createTask: () -> Void
        @State private var search = ""
        @State private var lane = ""

        private var title: String {
            switch destination {
            case .allTasks: "All tasks"
            case .chats: "Chats"
            case let .project(id): store.projects.first { $0.id == id }?.name ?? "Project"
            case let .board(id): store.boards.first { $0.id == id }?.name ?? "Board"
            }
        }

        private var tasks: [Dieter_V1_Card] {
            let source = destination == .chats ? store.chats : store.cards
            return source.filter { card in
                guard !card.archived else { return false }
                switch destination {
                case let .project(id): if card.projectID != id { return false }
                case let .board(id): if card.boardID != id { return false }
                default: break
                }
                return (lane.isEmpty || destination == .chats || card.lane == lane)
                    && (search.isEmpty || card.title.localizedCaseInsensitiveContains(search)
                        || card.initialPrompt.localizedCaseInsensitiveContains(search))
            }.sorted { $0.updatedAt > $1.updatedAt }
        }

        var body: some View {
            List(selection: $selectedTaskID) {
                ForEach(tasks, id: \.id) { card in
                    NavigationLink(value: card.id) {
                        IOSTaskRow(card: card, projectName: store.projects.first { $0.id == card.projectID }?.name)
                    }
                    .accessibilityIdentifier("ios.task.\(card.id)")
                }
            }
            .listStyle(.plain)
            .navigationTitle(title)
            .searchable(text: $search, prompt: "Search tasks")
            .accessibilityIdentifier("ios.task-list")
            .overlay {
                if tasks.isEmpty {
                    if store.busy {
                        ProgressView("Loading tasks…")
                    } else if !search.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else {
                        ContentUnavailableView {
                            Label("No tasks here", systemImage: "tray")
                        } description: {
                            Text(
                                lane.isEmpty ? "Create a task to get started." : "Choose another lane or create a task."
                            )
                        } actions: {
                            Button("New task", action: createTask)
                                .buttonStyle(.borderedProminent)
                                .disabled(!store.phase.isConnected || store.projects.isEmpty)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if destination != .chats {
                    HStack {
                        Picker("Lane", selection: $lane) {
                            Text("All lanes").tag("")
                            Text("Todo").tag("todo")
                            Text("Running").tag("running")
                            Text("Review").tag("review")
                            Text("Done").tag("done")
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("ios.lane-filter")
                        Spacer()
                        Text("\(tasks.count) tasks").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal).padding(.vertical, 8).background(.bar)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New task", systemImage: "plus", action: createTask)
                        .disabled(!store.phase.isConnected || store.projects.isEmpty)
                        .accessibilityIdentifier("ios.list.new-task")
                }
            }
            .refreshable { await store.reconnect() }
            .onChange(of: destination) { _, _ in
                search = ""; lane = ""
            }
        }
    }
#endif
