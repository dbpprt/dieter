import DieterAPI
import DieterCore
import SwiftUI

struct CommandPalette: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var index = TaskSearchIndex()
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    private var commands: [(String, String, () -> Void)] {
        [
            ("New card", "rectangle.badge.plus", { store.createConversationPresented = true }),
            ("New standalone chat", "bubble.left.and.bubble.right.fill", { store.beginStandaloneChat() }),
            ("Open all chats", "bubble.left.and.bubble.right", { Task { await store.openChats() } }),
            ("Open terminals", "terminal", { Task { await store.openTerminals() } }),
            (
                "Browse project files", "doc.on.doc",
                { Task { await store.openProject(store.selectedProjectID, section: .files) } }
            ),
            (
                "Open project schedules", "calendar.badge.clock",
                { Task { await store.openProject(store.selectedProjectID, section: .schedules) } }
            ),
            ("Add Git project", "folder.badge.plus", { store.createProjectPresented = true }),
            ("Edit project context", "text.book.closed", { store.projectContextPresented = true }),
            ("Refresh", "arrow.clockwise", { Task { await store.refreshState() } }),
        ]
    }

    private var documents: [TaskSearchIndex.Document] {
        let projects = store.projectDirectory.merging(
            Dictionary(store.state.projects.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }),
            uniquingKeysWith: { _, new in new })
        let boards = Dictionary(
            (store.navigationBoards.values.flatMap { $0 } + store.state.boards).map { ($0.id, $0.name) },
            uniquingKeysWith: { _, new in new })
        return (store.navigationCards.values.flatMap { $0 } + store.state.cards + store.chats + store.state.chats)
            .map { card in
                TaskSearchIndex.Document(
                    id: card.id, title: card.title,
                    text: card.initialPrompt + " " + card.summary,
                    location: [projects[card.projectID]?.name, boards[card.boardID]].compactMap { $0 }.joined(
                        separator: " · "),
                    updatedAt: card.updatedAt, archived: card.archived, isChat: card.scope == "chat")
            }.sorted { $0.id == $1.id ? $0.updatedAt < $1.updatedAt : $0.id < $1.id }
    }

    private struct Result: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let action: () -> Void
    }

    private var results: [Result] {
        let matchingCommands = commands.enumerated().filter {
            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || $0.element.0.localizedCaseInsensitiveContains(query)
        }.map { position, command in
            Result(id: "command-\(position)", title: command.0, subtitle: "Command", icon: command.1, action: command.2)
        }
        let tasks = index.search(query).map { document in
            Result(
                id: document.id, title: document.title.isEmpty ? "Untitled task" : document.title,
                subtitle: document.location.isEmpty ? "Chat" : document.location,
                icon: document.isChat ? "bubble.left" : "rectangle.on.rectangle"
            ) {
                Task { await store.openConversation(cardID: document.id, chat: document.isChat) }
            }
        }
        return tasks + matchingCommands
    }

    private func activate(_ result: Result) {
        dismiss()
        // Let the palette sheet close before an action presents another sheet.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            result.action()
        }
    }

    var body: some View {
        let rows = results
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tasks or commands", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 18))
                    .focused($searchFocused)
                    .accessibilityIdentifier("command-palette.search")
                    .onSubmit { if rows.indices.contains(selection) { activate(rows[selection]) } }
                Text("esc").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }.padding(20)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        if rows.isEmpty {
                            ContentUnavailableView.search(text: query).frame(height: 220)
                        }
                        ForEach(Array(rows.enumerated()), id: \.element.id) { offset, result in
                            Button {
                                activate(result)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: result.icon).frame(width: 24).foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(result.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                        Text(result.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if offset == selection {
                                        Image(systemName: "return").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(12).contentShape(Rectangle())
                                .background(
                                    offset == selection ? Color.primary.opacity(0.09) : .clear,
                                    in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain).id(result.id)
                        }
                    }.padding(8)
                }
                .onChange(of: selection) { _, value in
                    if rows.indices.contains(value) { proxy.scrollTo(rows[value].id) }
                }
            }
            Divider()
            HStack {
                Text("Searches synced task titles, prompts and summaries")
                Spacer()
                Text("↑↓ Navigate  ↵ Open")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(12)
        }
        .frame(width: 600, height: 430)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22))
        .presentationBackground(.clear)
        .background(SheetOutsideClickDismissal(enabled: true) { dismiss() })
        .onChange(of: documents, initial: true) { _, value in index = TaskSearchIndex(documents: value) }
        .onChange(of: query) { _, _ in selection = 0 }
        .onChange(of: rows.map(\.id)) { _, _ in selection = 0 }
        .onAppear { searchFocused = true }
        .onExitCommand { dismiss() }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, max(rows.count - 1, 0)); return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0); return .handled
        }
    }
}
