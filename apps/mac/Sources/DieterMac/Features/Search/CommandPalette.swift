import DieterAPI
import DieterCore
import SwiftUI

struct CommandPalette: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [ClientSearchHit] = []
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    private var commands: [(String, String, () -> Void)] {
        [
            ("New card", "rectangle.badge.plus", { store.createConversationPresented = true }),
            ("New standalone chat", "bubble.left.and.bubble.right.fill", { store.beginStandaloneChat() }),
            ("Open inbox", "tray", { Task { await store.openInbox() } }),
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

    private var catalogRevision: UInt64 { store.replica.commandSearchRevision }

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
        let tasks = hits.map { hit in
            Result(
                id: hit.cardID, title: hit.title.isEmpty ? "Untitled task" : hit.title,
                subtitle: hit.location.isEmpty ? "Chat" : hit.location,
                icon: hit.chat ? "bubble.left" : "rectangle.on.rectangle"
            ) {
                Task { await store.openConversation(cardID: hit.cardID, chat: hit.chat) }
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
        .dieterGlass(.regular, in: RoundedRectangle(cornerRadius: 22))
        .presentationBackground(.clear)
        .background(SheetOutsideClickDismissal(enabled: true) { dismiss() })
        .task(id: "\(catalogRevision)|\(query)") { await search() }
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

    /// Tasks and chats matching the query, ranked by the core.
    private func search() async {
        let query = query
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hits = []
            return
        }
        guard let result = try? await store.core.dispatch({ $0.search = .with { $0.query = query } }),
            !Task.isCancelled, query == self.query
        else { return }
        hits = result.searchResults.hits
    }
}
