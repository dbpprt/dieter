import AppKit
import DieterAPI
import DieterShared
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
                DieterPaneTopBar {
                    HStack(spacing: 7) {
                        Text(showArchived ? "Archived chats" : "Chats")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("\(list.visibleIds.count)")
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                            .foregroundStyle(DieterTheme.tertiary)
                    }
                    .padding(.horizontal, 14).frame(height: DieterMetrics.capsuleHeight)
                    .dieterCapsuleChrome(interactive: false)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        SharedRules.shared.count(
                            count: Int32(clamping: list.visibleIds.count), noun: "conversation", plural: ""))
                } trailing: {
                    Button {
                        showArchived.toggle()
                        store.closeConversation()
                    } label: {
                        Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .buttonStyle(DieterBarButtonStyle(shape: .circle))
                    .help(showArchived ? "Show active chats" : "Show archived chats")
                    Button {
                        folderEditor = .create(title: "New chat folder")
                    } label: {
                        Image(systemName: "folder.badge.plus").font(.system(size: 12.5, weight: .medium))
                    }
                    .buttonStyle(DieterBarButtonStyle(shape: .circle))
                    .help("New chat folder")
                    .accessibilityIdentifier("chats.folder.new")
                    Button {
                        store.beginStandaloneChat()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                            Text("New chat")
                        }
                    }
                    .buttonStyle(DieterBarButtonStyle(prominent: true))
                    .disabled(showArchived)
                    .help("New standalone chat")
                    .accessibilityIdentifier("chats.new")
                    .smokeTarget("chats.new")
                }
                DieterSearchField(text: $search, placeholder: "Search chats")
                    .padding(.leading, 14).padding(.trailing, 6).padding(.bottom, 8)

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
                                DieterSectionHeader(title: "Pinned").padding(.horizontal, 8)
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
                                DieterSectionHeader(title: "Folders").padding(.horizontal, 8)

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

                        DieterSectionHeader(title: showArchived ? "Archived projects" : "Projects")
                            .padding(.horizontal, 8).padding(.top, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                unfiledDropTargeted ? DieterTheme.tileSelected : .clear,
                                in: RoundedRectangle(cornerRadius: DieterMetrics.rowRadius, style: .continuous)
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
                                DieterSectionHeader(title: "Other").padding(.horizontal, 8)
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
                    }.padding(.leading, 8).padding(.trailing, 2).padding(.vertical, 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .top)
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
