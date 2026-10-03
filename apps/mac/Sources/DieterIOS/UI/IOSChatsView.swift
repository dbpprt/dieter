#if os(iOS)
    import DieterAPI
    import DieterShared
    import SharedCore
    import SwiftUI

    /// The account's chats as the core lays them out (`SLICE_CHATS`): pinned
    /// chats, folders, and project sections, narrowed by the search, live or
    /// archived.
    struct IOSChatsView: View {
        @Environment(IOSAppModel.self) private var app
        @Environment(IOSWorkspaceNavigation.self) private var navigation
        @State private var model = ChatsListModel(scope: "ios-chats-\(UUID().uuidString.lowercased())")
        @State private var search = ""
        @State private var archived = false

        var body: some View {
            let list = model.slice
            let archivedByID = Dictionary(list.archived.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            TimelineView(.periodic(from: .now, by: 60)) { clock in
                List {
                    if archived {
                        Section {
                            ForEach(list.archived, id: \.id) { chat in
                                row(chat, now: clock.date)
                            }
                        }
                    } else {
                        chatSection(ids: list.pinnedIds, now: clock.date, lookup: archivedByID)
                        ForEach(list.folders, id: \.folderID) { folder in
                            Section {
                                if folder.showChats {
                                    ForEach(folder.chatIds.compactMap { app.card($0) ?? archivedByID[$0] }, id: \.id) {
                                        row($0, now: clock.date)
                                    }
                                }
                            } header: {
                                Button {
                                    toggle(folder)
                                } label: {
                                    Label(folder.name, systemImage: folder.expanded ? "folder" : "folder.fill")
                                }
                                .buttonStyle(.plain)
                                .accessibilityValue(folder.expanded ? "Expanded" : "Collapsed")
                                .accessibilityIdentifier("ios.chats.folder.\(folder.folderID)")
                            }
                        }
                        ForEach(list.projects, id: \.projectID) { section in
                            Section {
                                if section.showChats {
                                    ForEach(section.chatIds, id: \.self) { id in
                                        if let chat = app.card(id) ?? archivedByID[id] { row(chat, now: clock.date) }
                                    }
                                    if section.hidden > 0 {
                                        Button(section.showAll ? "Show fewer" : "Show \(section.hidden) more") {
                                            Task {
                                                await app.perform {
                                                    $0.setChatsShowAll = .with {
                                                        $0.projectID = section.projectID
                                                        $0.showAll = !section.showAll
                                                    }
                                                }
                                            }
                                        }
                                        .font(.subheadline)
                                        .accessibilityIdentifier("ios.chats.show-all.\(section.projectID)")
                                    }
                                }
                            } header: {
                                Text(app.project(section.projectID)?.name ?? "")
                            }
                        }
                        chatSection(ids: list.otherIds, now: clock.date, lookup: archivedByID)
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search chats")
            .accessibilityIdentifier("ios.chats.list")
            .overlay {
                if list.loading {
                    ProgressView()
                } else if !list.error.isEmpty {
                    ContentUnavailableView(
                        "Couldn’t load chats", systemImage: "exclamationmark.triangle", description: Text(list.error))
                } else if list.visibleIds.isEmpty && (!archived || list.archived.isEmpty) {
                    if !search.isEmpty {
                        ContentUnavailableView.search(text: search)
                    } else {
                        ContentUnavailableView(
                            archived ? "No archived chats" : "No chats", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Chat options", systemImage: "ellipsis.circle") {
                        Toggle("Show archived", systemImage: "archivebox", isOn: $archived)
                            .accessibilityIdentifier("ios.chats.archived")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New chat", systemImage: "plus") { navigation.create(chat: true) }
                        .accessibilityIdentifier("ios.list.new-task")
                }
            }
            .onAppear { model.attach(app.core) }
            .onChange(of: search) { _, query in model.search(query) }
            .onChange(of: archived) { _, on in model.showArchived(on) }
        }

        @ViewBuilder
        private func chatSection(ids: [String], now: Date, lookup: [String: Dieter_V1_Card]) -> some View {
            let chats = ids.compactMap { app.card($0) ?? lookup[$0] }
            if !chats.isEmpty {
                Section {
                    ForEach(chats, id: \.id) { row($0, now: now) }
                }
            }
        }

        private func toggle(_ folder: ClientChatFolderSection) {
            Task {
                await app.perform {
                    $0.navigation = .with {
                        $0.setFolderExpanded = .with {
                            $0.scope = .chats
                            $0.folderID = folder.folderID
                            $0.expanded = !folder.expanded
                        }
                    }
                }
            }
        }

        private func row(_ chat: Dieter_V1_Card, now: Date) -> some View {
            let selected = navigation.selectedCardID == chat.id
            return Button {
                navigation.openConversation(chat.id)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(
                            ClientRuntimeTone(rawValue: Int(SharedRules.shared.runtimeTone(runtime: chat.runtime)))?
                                .tint ?? .secondary
                        )
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            SharedRules.shared.conversationTitle(
                                title: chat.title, scope: chat.scope, boardId: chat.boardID)
                        )
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        if !chat.summary.isEmpty {
                            Text(chat.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(
                        SharedRules.shared.cardAge(
                            updatedAt: chat.updatedAt, lastActivityAt: chat.lastActivityAt, nowMillis: now.epochMillis)
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowBackground(selected ? Color.accentColor.opacity(0.12) : nil)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("ios.chat.\(chat.id)")
        }
    }
#endif
