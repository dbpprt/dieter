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

    var body: some View {
        let _ = BoardRenderingDiagnostics.record(.chatListBody)
        let list = store.chatsList.slice
        let chatsByID = Dictionary(
            (store.chats + list.archived).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let cards: ([String]) -> [Dieter_V1_Card] = { $0.compactMap { chatsByID[$0] } }
        let projectsByID = Dictionary(store.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pinned = cards(list.pinnedIds)
        let pinnedPage = LaneCardPage.resolve(total: pinned.count, requestedPage: pinnedPageIndex)
        let displayedPinned = Array(pinned[pinnedPage.lowerBound..<pinnedPage.upperBound])
        let hasFolders = !store.navigation.chatFolders.isEmpty
        let sections = list.projects.filter { projectsByID[$0.projectID] != nil }
        let sectionProjectIDs = sections.map(\.projectID)
        let other = cards(list.otherIds)
        ChatPaneSplit {
            VStack(spacing: 0) {
                FluidPaneChrome(background: .clear, spacing: 9) {
                    HStack(spacing: 8) {
                        PaneTitleBlock(
                            title: showArchived ? "Archived chats" : "Chats",
                            subtitle: "\(list.visibleIds.count) conversation\(list.visibleIds.count == 1 ? "" : "s")",
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

                if list.loading || !list.error.isEmpty {
                    LoadFeedback(
                        title: "Refreshing chats…", error: list.error.isEmpty ? nil : list.error,
                        retry: { store.chatsList.reload() }, compact: true
                    )
                    .accessibilityIdentifier("chats.load-feedback")
                }
                ScrollView {
                    // The daemon returns bounded pages, so eager layout is
                    // affordable and avoids the macOS LazyVStack placement
                    // cycle that can trap AttributeGraph in one transaction.
                    VStack(alignment: .leading, spacing: 12) {
                        if !pinned.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("PINNED", systemImage: "pin.fill").font(DieterFont.sectionLabel)
                                    .foregroundStyle(
                                        DieterTheme.tertiary
                                    ).padding(.horizontal, 8)
                                ChatGroupCard(
                                    chats: displayedPinned,
                                    movePinnedChat: { store.movePinnedChat($0, onto: $1) }
                                )
                                .padding(.leading, 14)
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

                        if !list.folders.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("FOLDERS")
                                    .font(DieterFont.sectionLabel).tracking(0.8)
                                    .foregroundStyle(DieterTheme.tertiary)
                                    .padding(.horizontal, 8)

                                ForEach(list.folders, id: \.folderID) { folder in
                                    ChatNavigationFolderGroup(
                                        folder: folder,
                                        chats: cards(folder.chatIds),
                                        toggleExpanded: {
                                            store.setFolderExpanded(
                                                .chats, folderID: folder.folderID, expanded: !folder.expanded)
                                        },
                                        moveChatHere: {
                                            store.moveToFolder(.chats, itemID: $0, folderID: folder.folderID)
                                        },
                                        rename: {
                                            folderEditor = .rename(id: folder.folderID, name: folder.name)
                                        },
                                        delete: { store.deleteFolder(.chats, folderID: folder.folderID) }
                                    )
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
                                guard hasFolders,
                                    let value = values.first,
                                    let payload = PinnedChatDragPayload(value)
                                else { return false }
                                store.moveToFolder(.chats, itemID: payload.chatID, folderID: nil)
                                return true
                            } isTargeted: {
                                unfiledDropTargeted = hasFolders && $0
                            }

                        ForEach(sections, id: \.projectID) { section in
                            if let project = projectsByID[section.projectID] {
                                ChatProjectGroup(
                                    project: project,
                                    projectIDs: sectionProjectIDs,
                                    section: section,
                                    chats: cards(section.chatIds),
                                    showArchived: showArchived,
                                    toggleExpanded: { store.setChatsShowAll(project.id, showAll: !section.showAll) },
                                    toggleCollapsed: {
                                        store.setChatSectionCollapsed(project.id, collapsed: !section.collapsed)
                                    },
                                    moveProject: { store.moveProject($0, before: $1, ungrouped: true) }
                                )
                            }
                        }

                        if !other.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("OTHER")
                                    .font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary)
                                    .padding(.horizontal, 8)
                                ChatGroupCard(chats: other).padding(.leading, 14)
                            }
                        }

                        if list.visibleIds.isEmpty && !list.loading && list.error.isEmpty {
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
        .onAppear { store.chatsList.attach(store.core) }
        .onChange(of: search) { _, text in store.chatsList.search(text) }
        .onChange(of: showArchived) { _, on in store.chatsList.showArchived(on) }
        .onChange(of: pinned.count) { _, _ in pinnedPageIndex = pinnedPage.page }
        .sheet(item: $folderEditor) { editor in
            NavigationFolderNameSheet(
                editor: editor,
                existingNames: store.navigation.chatFolders.filter { $0.id != editor.folderID }.map(\.name),
                save: { name in
                    if let folderID = editor.folderID {
                        store.renameFolder(.chats, folderID: folderID, name: name)
                    } else {
                        store.createFolder(.chats, name: name)
                    }
                }
            )
        }
    }
}

/// Selection and transcript-panel changes belong to the detail observation
/// boundary. They must not rebuild the directory projection on every click.
