#if os(iOS)
    import DieterAPI
    import DieterShared
    import SharedCore
    import SwiftUI

    /// Picks the task or chat that shared attachments go to. The attachments
    /// wait in the navigation for that conversation's composer.
    struct IOSShareTargetPicker: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(IOSAppModel.self) private var app
        @Environment(IOSWorkspaceNavigation.self) private var navigation
        let request: IOSShareTargetRequest
        @State private var search = ""

        private var chat: Bool { request.kind == .chat }

        /// The workspace's tasks or chats, in its order, matching the search.
        private var matches: [Dieter_V1_Card] {
            app.workspace.cards.filter { card in
                SharedRules.shared.isChat(scope: card.scope, boardId: card.boardID) == chat
                    && SharedRules.shared.activityMatches(
                        query: search, title: card.title, projectName: app.project(card.projectID)?.name ?? "",
                        boardName: app.board(card.boardID)?.name ?? "")
            }
        }

        var body: some View {
            NavigationStack {
                List(matches, id: \.id) { card in
                    Button {
                        route(to: card)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                SharedRules.shared.conversationTitle(
                                    title: card.title, scope: card.scope, boardId: card.boardID)
                            )
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            if let project = app.project(card.projectID) {
                                Text(project.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .accessibilityIdentifier("ios.share.destination.\(card.id)")
                }
                .searchable(text: $search, prompt: chat ? "Search chats" : "Search tasks")
                .navigationTitle(chat ? "Choose Chat" : "Choose Task")
                .navigationBarTitleDisplayMode(.inline)
                .overlay {
                    if matches.isEmpty {
                        if search.isEmpty {
                            ContentUnavailableView(
                                chat ? "No chats" : "No tasks",
                                systemImage: chat ? "bubble.left.and.bubble.right" : "checklist",
                                description: Text("Create one in Dieter, then share this item again."))
                        } else {
                            ContentUnavailableView.search(text: search)
                        }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .accessibilityIdentifier("ios.share.cancel")
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }

        private func route(to card: Dieter_V1_Card) {
            let existing = navigation.sharedAttachments[card.id] ?? []
            do {
                // The core's limits apply to what the composer already holds.
                navigation.sharedAttachments[card.id] = try IOSAttachmentLoader.appending(
                    request.attachments, to: existing)
            } catch {
                app.show(error)
                return
            }
            navigation.show(chat ? .chats : .board(card.boardID))
            navigation.openConversation(card.id)
            dismiss()
        }
    }
#endif
