#if os(iOS)
    import DieterAPI
    import DieterShared
    import SharedCore
    import SwiftUI

    /// One board as the core's board view shows it: its lanes in order, each
    /// with the cards it shows, narrowed by a state and the search.
    struct IOSBoardView: View {
        @Environment(IOSAppModel.self) private var app
        @Environment(IOSWorkspaceNavigation.self) private var navigation
        let boardID: String
        @State private var model = BoardViewModel(scope: "ios-board-\(UUID().uuidString.lowercased())")
        @State private var search = ""
        @State private var state: ClientBoardStateFilter = .all

        var body: some View {
            let view = model.slice
            TimelineView(.periodic(from: .now, by: 60)) { clock in
                List {
                    ForEach(view.lanes, id: \.laneID) { lane in
                        Section {
                            ForEach(lane.cardIds, id: \.self) { cardID in
                                if let card = app.card(cardID) {
                                    IOSBoardCardRow(
                                        card: card, flags: view.cards[cardID] ?? ClientBoardCardFlags(),
                                        now: clock.date,
                                        selected: navigation.selectedCardID == cardID
                                    ) {
                                        navigation.openConversation(cardID)
                                    }
                                    .contextMenu { actions(card: card, flags: view.cards[cardID], lanes: view.lanes) }
                                }
                            }
                        } header: {
                            HStack {
                                Circle().fill(lane.kind.tint).frame(width: 8, height: 8)
                                Text(lane.name)
                                Spacer()
                                Text(lane.cardIds.count, format: .number).monospacedDigit()
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("ios.lane.\(lane.laneID)")
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle(app.board(boardID)?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search tasks")
            .accessibilityIdentifier("ios.task-list")
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Picker("State", selection: $state) {
                        ForEach(view.stateOptions, id: \.state) { option in
                            Text(option.title).tag(option.state)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("ios.board.state-filter")
                    Spacer()
                    Text(view.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .overlay {
                if view.lanes.allSatisfy({ $0.cardIds.isEmpty }) {
                    if !search.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else if view.target.boardID == boardID {
                        ContentUnavailableView {
                            Label("No tasks here", systemImage: "tray")
                        } actions: {
                            Button("New task", action: createTask).buttonStyle(.borderedProminent)
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New task", systemImage: "plus", action: createTask)
                        .accessibilityIdentifier("ios.list.new-task")
                }
            }
            .onAppear {
                model.onFailure = { [app] error in app.show(error) }
                model.attach(app.core)
                model.bind(boardID: boardID, state: state, query: search)
            }
            .onChange(of: search) { _, query in model.bind(boardID: boardID, state: state, query: query) }
            .onChange(of: state) { _, state in model.bind(boardID: boardID, state: state, query: search) }
        }

        @ViewBuilder
        private func actions(card: Dieter_V1_Card, flags: ClientBoardCardFlags?, lanes: [ClientBoardLaneView])
            -> some View
        {
            if flags?.canStart == true {
                Button("Start", systemImage: "play") {
                    Task { await app.perform { $0.startCard = .with { $0.cardID = card.id } } }
                }
            }
            if flags?.canCancel == true {
                Button("Stop", systemImage: "stop") {
                    Task { await app.perform { $0.cancelCard = .with { $0.cardID = card.id } } }
                }
            }
            Menu("Move to", systemImage: "arrow.right.square") {
                ForEach(lanes, id: \.laneID) { lane in
                    Button(lane.name) { model.drop(cardID: card.id, laneID: lane.laneID) }
                }
            }
        }

        private func createTask() {
            navigation.create(chat: false, projectID: app.board(boardID)?.projectID ?? "", boardID: boardID)
        }
    }

    /// A board card: its title, the runtime pill the core words, and its age.
    private struct IOSBoardCardRow: View {
        let card: Dieter_V1_Card
        let flags: ClientBoardCardFlags
        let now: Date
        let selected: Bool
        let open: () -> Void

        var body: some View {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        SharedRules.shared.conversationTitle(
                            title: card.title, scope: card.scope, boardId: card.boardID)
                    )
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    if !card.summary.isEmpty {
                        Text(card.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                    HStack(spacing: 8) {
                        if !flags.runtimeLabel.isEmpty {
                            HStack(spacing: 5) {
                                Circle().fill(flags.tone.tint).frame(width: 6, height: 6)
                                Text(flags.runtimeLabel).font(.caption.weight(.medium))
                            }
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(flags.agentLabel.isEmpty ? flags.runtimeLabel : flags.agentLabel)
                        }
                        Spacer(minLength: 0)
                        Text(
                            SharedRules.shared.cardAge(
                                updatedAt: card.updatedAt, lastActivityAt: card.lastActivityAt,
                                nowMillis: now.epochMillis)
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
                .opacity(flags.pending ? 0.6 : 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(selected ? Color.accentColor.opacity(0.12) : nil)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("ios.task.\(card.id)")
        }
    }

    extension ClientRuntimeTone {
        /// The colour family's tint.
        var tint: Color {
            switch self {
            case .active: .green
            case .attention: .orange
            case .done: .blue
            case .failed: .red
            case .idle, .UNRECOGNIZED: .secondary
            }
        }
    }

    extension ClientBoardLaneKind {
        /// A lane's tint by its kind.
        var tint: Color {
            switch self {
            case .running: .green
            case .review: .orange
            case .done: .blue
            case .other, .UNRECOGNIZED: .secondary
            }
        }
    }
#endif
