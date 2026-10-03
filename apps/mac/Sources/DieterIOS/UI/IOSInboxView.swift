#if os(iOS)
    import DieterAPI
    import DieterShared
    import SharedCore
    import SwiftUI

    /// The account's activity as the core classifies it (`SLICE_ACTIVITY`):
    /// one latest activity per conversation, in sections for what needs the
    /// person, what runs, and what happened recently.
    struct IOSInboxView: View {
        @Environment(IOSAppModel.self) private var app
        @Environment(IOSWorkspaceNavigation.self) private var navigation
        @State private var search = ""

        var body: some View {
            let rows = app.activity.rows.filter { row in
                SharedRules.shared.activityMatches(
                    query: search, title: row.title, projectName: row.projectName, boardName: row.boardName)
            }
            TimelineView(.periodic(from: .now, by: 30)) { clock in
                List {
                    section(
                        "Needs attention", id: "needs-you", rows: rows.filter { $0.section == .attention },
                        now: clock.date)
                    section("Running", id: "running", rows: rows.filter { $0.section == .running }, now: clock.date)
                    section("Recent", id: "recent", rows: rows.filter { $0.section == .recent }, now: clock.date)
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search activity")
            .accessibilityIdentifier("ios.inbox.list")
            .overlay {
                if rows.isEmpty {
                    if !search.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else {
                        ContentUnavailableView(
                            "All quiet here", systemImage: "tray",
                            description: Text(
                                "Activity from chats and cards appears here when an agent starts, replies, or needs you."
                            ))
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New task", systemImage: "plus") { navigation.create(chat: false) }
                        .accessibilityIdentifier("ios.list.new-task")
                }
            }
        }

        @ViewBuilder
        private func section(_ title: String, id: String, rows: [ClientActivityRow], now: Date) -> some View {
            if !rows.isEmpty {
                Section {
                    ForEach(rows, id: \.card.id) { row in
                        IOSInboxRow(row: row, now: now, selected: navigation.selectedCardID == row.card.id) {
                            navigation.openConversation(row.card.id)
                        }
                        .swipeActions(edge: .trailing) {
                            if row.canFinish {
                                Button("Finish", systemImage: "checkmark") {
                                    Task { await app.finish(cardID: row.card.id) }
                                }
                                .tint(.green)
                                .accessibilityIdentifier("ios.inbox.finish.\(row.card.id)")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(title)
                        Spacer()
                        Text(rows.count, format: .number).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("ios.inbox.section.\(id)")
                }
            }
        }
    }

    private struct IOSInboxRow: View {
        let row: ClientActivityRow
        let now: Date
        let selected: Bool
        let open: () -> Void

        private var tint: Color {
            if row.needsYou { return .orange }
            switch row.section {
            case .running: return .green
            default: return .secondary
            }
        }

        var body: some View {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Text(
                            SharedRules.shared.activityAge(
                                atMillis: row.shownAtMillis, nowMillis: now.epochMillis, suffix: false)
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Circle().fill(tint).frame(width: 7, height: 7)
                        Text(row.kindLabel).font(.caption.weight(.semibold)).foregroundStyle(tint)
                        let place = [row.projectName, row.boardName].filter { !$0.isEmpty }.joined(separator: " · ")
                        if !place.isEmpty {
                            Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(selected ? Color.accentColor.opacity(0.12) : nil)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("ios.inbox.row.\(row.card.id)")
        }
    }
#endif
