import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct ChatsView: View {
    var active = true
    @Environment(DieterStore.self) private var store
    @State private var search = ""
    @State private var showArchived = false
    @State private var pinnedPageIndex = 0
    @State private var folderEditor: NavigationFolderEditor?
    @State private var unfiledDropTargeted = false

    private var activePinnedChats: [Dieter_V1_Card] {
        store.chats
            .filter { $0.scope == "chat" && $0.boardID.isEmpty && !$0.archived && $0.pinned }
            .sorted {
                ($0.lastActivityAt.isEmpty ? $0.updatedAt : $0.lastActivityAt)
                    > ($1.lastActivityAt.isEmpty ? $1.updatedAt : $1.lastActivityAt)
            }
    }

    private var pinnedChatMembership: [String] {
        activePinnedChats.map(\.id).sorted()
    }

    private var orderedProjects: [Dieter_V1_Project] {
        let projects = store.projects.filter { !$0.archived }
        let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        return store.sidebarProjectNavigation.orderedIDs(from: projects.map(\.id)).compactMap { byID[$0] }
    }

    var body: some View {
        let _ = BoardRenderingDiagnostics.record(.chatListBody)
        let chatFolders = store.allChatsFolders
        let projection = store.replica.chatProjection(
            showArchived: showArchived,
            search: search,
            pinnedOrder: store.pinnedChatNavigation.chatOrder
        )
        let pinnedPage = LaneCardPage.resolve(
            total: projection.pinned.count, requestedPage: pinnedPageIndex)
        let displayedPinned = Array(projection.pinned[pinnedPage.lowerBound..<pinnedPage.upperBound])
        let visibleChatsByID = Dictionary(uniqueKeysWithValues: projection.visible.map { ($0.id, $0) })
        let filedChatIDs = Set(chatFolders.folders.flatMap(\.itemIDs))
        let displayedProjects = orderedProjects.filter { project in
            let chats = projection.byProject[project.id] ?? []
            let unfiledChats = chats.filter { !filedChatIDs.contains($0.id) }
            if chatFolders.folders.isEmpty { return search.isEmpty || !chats.isEmpty }
            return !unfiledChats.isEmpty
        }
        let displayedProjectIDs = displayedProjects.map(\.id)
        ChatPaneSplit {
            VStack(spacing: 0) {
                FluidPaneChrome(background: .clear, spacing: 9) {
                    HStack(spacing: 8) {
                        PaneTitleBlock(
                            title: showArchived ? "Archived chats" : "Chats",
                            subtitle:
                                "\(projection.visible.count) conversation\(projection.visible.count == 1 ? "" : "s")",
                            prominent: true
                        )
                        Button {
                            showArchived.toggle()
                            store.closeConversation()
                        } label: {
                            Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
                        }
                        .buttonStyle(DieterGlassButtonStyle())
                        .buttonBorderShape(.circle)
                        .controlSize(.small)
                        .tint(showArchived ? DieterTheme.shell : nil)
                        .help(
                            showArchived ? "Show active chats" : "Show archived chats")
                        Button {
                            folderEditor = .create(title: "New chat folder")
                        } label: {
                            Image(systemName: "folder.badge.plus")
                        }
                        .buttonStyle(DieterGlassButtonStyle())
                        .buttonBorderShape(.circle)
                        .controlSize(.small)
                        .help("New chat folder")
                        .accessibilityIdentifier("chats.folder.new")
                        Button {
                            store.beginStandaloneChat()
                        } label: {
                            Label("New chat", systemImage: "plus")
                        }
                        .buttonStyle(DieterGlassButtonStyle(prominent: true)).disabled(showArchived).help(
                            "New standalone chat"
                        )
                        .accessibilityIdentifier("chats.new")
                        .smokeTarget("chats.new")
                    }
                } secondary: {
                    DieterSearchField(text: $search, placeholder: "Search chats")
                }

                if store.chatsLoading || store.chatsError != nil {
                    LoadFeedback(
                        title: "Refreshing chats…", error: store.chatsError,
                        retry: { Task { await store.refreshChats() } }, compact: true
                    )
                    .accessibilityIdentifier("chats.load-feedback")
                }
                ScrollView {
                    // The daemon returns bounded pages, so eager layout is
                    // affordable and avoids the macOS LazyVStack placement
                    // cycle that can trap AttributeGraph in one transaction.
                    VStack(alignment: .leading, spacing: 12) {
                        let pinned = projection.pinned
                        if !pinned.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("PINNED", systemImage: "pin.fill").font(DieterFont.sectionLabel)
                                    .foregroundStyle(
                                        DieterTheme.tertiary
                                    ).padding(.horizontal, 8)
                                ChatGroupCard(chats: displayedPinned, movePinnedChat: movePinnedChat).padding(
                                    .leading, 14)
                                if pinnedPage.pageCount > 1 {
                                    ChatPageControls(
                                        page: pinnedPage,
                                        previous: { pinnedPageIndex = max(0, pinnedPage.page - 1) },
                                        next: { pinnedPageIndex = min(pinnedPage.pageCount - 1, pinnedPage.page + 1) }
                                    )
                                    .padding(.leading, 14)
                                }
                            }
                        }

                        if !chatFolders.folders.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("FOLDERS")
                                    .font(DieterFont.sectionLabel).tracking(0.8)
                                    .foregroundStyle(DieterTheme.tertiary)
                                    .padding(.horizontal, 8)

                                ForEach(chatFolders.folders) { folder in
                                    let folderChats = folder.itemIDs.compactMap { visibleChatsByID[$0] }
                                    if search.isEmpty || !folderChats.isEmpty {
                                        ChatNavigationFolderGroup(
                                            folder: folder,
                                            chats: folderChats,
                                            toggleExpanded: { toggleChatFolder(folder.id) },
                                            moveChatHere: { moveChatToFolder($0, folderID: folder.id) },
                                            rename: { folderEditor = .rename(folder) },
                                            delete: { deleteChatFolder(folder.id) }
                                        )
                                    }
                                }
                            }
                        }

                        Text(showArchived ? "ARCHIVED PROJECTS" : "PROJECTS")
                            .font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary)
                            .padding(.horizontal, 8).padding(.top, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                unfiledDropTargeted ? DieterTheme.shellDeep.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .dropDestination(for: String.self) { values, _ in
                                guard !chatFolders.folders.isEmpty,
                                    let value = values.first,
                                    let payload = PinnedChatDragPayload(value)
                                else { return false }
                                moveChatToFolder(payload.chatID, folderID: nil)
                                return true
                            } isTargeted: {
                                unfiledDropTargeted = !chatFolders.folders.isEmpty && $0
                            }

                        ForEach(displayedProjects, id: \.id) { project in
                            let projectChats = (projection.byProject[project.id] ?? []).filter {
                                chatFolders.folders.isEmpty || !filedChatIDs.contains($0.id)
                            }
                            ChatProjectGroup(
                                project: project,
                                projectIDs: displayedProjectIDs,
                                chats: projectChats,
                                showArchived: showArchived,
                                expanded: store.chatProjectDisclosure.isExpanded(project.id),
                                collapsed: store.chatProjectDisclosure.isCollapsed(project.id),
                                toggleExpanded: { toggleExpanded(project.id) },
                                toggleCollapsed: { toggleCollapsed(project.id) },
                                moveProject: moveProject
                            )
                        }

                        if projection.visible.isEmpty && !store.chatsLoading && store.chatsError == nil {
                            ContentUnavailableView(
                                search.isEmpty
                                    ? (showArchived ? "No archived chats" : "No chats yet") : "No matching chats",
                                systemImage: showArchived ? "archivebox" : "bubble.left.and.bubble.right",
                                description: Text(
                                    showArchived
                                        ? "Archived standalone conversations appear here."
                                        : "Start a standalone conversation in any project folder.")
                            )
                            .padding(.vertical, 32)
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 11)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chats.browser-pane")
            .smokeTarget("chats.browser-pane")
        } detail: {
            if active { ChatDetailPane(showArchived: showArchived) }
        }
        .defaultAppStorage(store.environment.defaults)
        .task(id: showArchived) { await store.ensureChatDirectory(includeArchived: showArchived) }
        .task(id: pinnedChatMembership) { initializePinnedChatOrderIfNeeded() }
        .onChange(of: projection.pinned.count) { _, _ in pinnedPageIndex = pinnedPage.page }
        .sheet(item: $folderEditor) { editor in
            NavigationFolderNameSheet(
                editor: editor,
                existingNames: store.allChatsFolders.folders.filter { $0.id != editor.folderID }.map(\.name),
                save: { saveChatFolder(editor: editor, name: $0) }
            )
        }
    }

    private func toggleExpanded(_ projectID: String) {
        store.chatProjectDisclosure.toggleExpanded(projectID)
    }

    private func toggleCollapsed(_ projectID: String) {
        store.chatProjectDisclosure.toggleCollapsed(projectID)
    }

    private func initializePinnedChatOrderIfNeeded() {
        guard store.pinnedChatNavigation.initializeIfNeeded(with: activePinnedChats.map(\.id)) else { return }
    }

    private func movePinnedChat(_ chatID: String, to targetChatID: String) {
        guard store.pinnedChatNavigation.move(chatID, to: targetChatID, among: activePinnedChats) else {
            return
        }
    }

    private func moveProject(_ projectID: String, before targetProjectID: String?) {
        var navigation = store.sidebarProjectNavigation
        guard navigation.move(projectID, before: targetProjectID, availableIDs: orderedProjects.map(\.id)) else {
            return
        }
        store.sidebarProjectNavigation = navigation
    }

    private func saveChatFolder(editor: NavigationFolderEditor, name: String) {
        var chatFolders = store.allChatsFolders
        if let folderID = editor.folderID {
            guard chatFolders.renameFolder(folderID, to: name) else { return }
        } else {
            guard chatFolders.createFolder(named: name) != nil else { return }
        }
        store.allChatsFolders = chatFolders
    }

    private func toggleChatFolder(_ folderID: String) {
        var chatFolders = store.allChatsFolders
        guard chatFolders.toggleExpanded(folderID) else { return }
        store.allChatsFolders = chatFolders
    }

    private func moveChatToFolder(_ chatID: String, folderID: String?) {
        var chatFolders = store.allChatsFolders
        guard chatFolders.moveItem(chatID, to: folderID) else { return }
        store.allChatsFolders = chatFolders
    }

    private func deleteChatFolder(_ folderID: String) {
        var chatFolders = store.allChatsFolders
        guard chatFolders.deleteFolder(folderID) else { return }
        store.allChatsFolders = chatFolders
    }
}

/// Selection and transcript-panel changes belong to the detail observation
/// boundary. They must not rebuild the directory projection on every click.
