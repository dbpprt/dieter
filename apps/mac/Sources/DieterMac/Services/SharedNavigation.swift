import DieterAPI
import Foundation
import SharedCore

/// The account-wide navigation layout lives in the shared core: it keeps
/// edits on this Mac until a machine accepts them and folds in edits from
/// other devices. The sidebar's preference values mirror the core's slice;
/// changing one sends only that edit.
extension AppSession {
    func foldNavigation(_ slice: ClientNavigationSlice) {
        applyingSharedNavigation = true
        defer { applyingSharedNavigation = false }
        func folders(_ values: [ClientNavigationFolder]) -> NavigationFolderPreferences {
            NavigationFolderPreferences(
                folders: values.map {
                    NavigationFolder(id: $0.id, name: $0.name, itemIDs: $0.itemIds, isExpanded: $0.expanded)
                })
        }
        let projectFolders = folders(slice.projectFolders)
        if sidebarProjectFolders != projectFolders { sidebarProjectFolders = projectFolders }
        let chatFolders = folders(slice.chatFolders)
        if allChatsFolders != chatFolders { allChatsFolders = chatFolders }
        let sidebar = SidebarProjectNavigationPreferences(
            projectOrder: slice.projectOrder, expandedProjectIDs: Set(slice.expandedProjects))
        if sidebarProjectNavigation != sidebar { sidebarProjectNavigation = sidebar }
        let pinnedProjects = PinnedProjectNavigationPreferences(projectOrder: slice.pinnedProjects)
        if pinnedProjectNavigation != pinnedProjects { pinnedProjectNavigation = pinnedProjects }
        let pinnedChats = PinnedChatNavigationPreferences(chatOrder: slice.pinnedChatOrder)
        if pinnedChatNavigation != pinnedChats { pinnedChatNavigation = pinnedChats }
        let disclosure = ChatProjectDisclosurePreferences(
            collapsedProjectIDs: Set(slice.collapsedChatSections), expandedProjectIDs: Set(slice.chatsShowAll))
        if chatProjectDisclosure != disclosure { chatProjectDisclosure = disclosure }
        if sharedLaneSortDirections != slice.laneSorts { sharedLaneSortDirections = slice.laneSorts }
        if navigationPendingCount != Int(slice.pending) { navigationPendingCount = Int(slice.pending) }
        let error = slice.error.isEmpty ? nil : slice.error
        if navigationSyncError != error { navigationSyncError = error }
        navigationCaughtUp = slice.caughtUp
    }

    /// Sends a layout edit the user made; edits that mirror the core are not sent back.
    private func editNavigation(_ build: @escaping (inout ClientCommand) -> Void) {
        guard !applyingSharedNavigation else { return }
        // Edits apply in the order the user made them.
        let previous = navigationEditTail
        navigationEditTail = Task { [weak self] in
            await previous?.value
            await self?.perform(build)
        }
    }

    func syncSidebarProjects(_ old: SidebarProjectNavigationPreferences, _ next: SidebarProjectNavigationPreferences) {
        if old.projectOrder != next.projectOrder {
            editNavigation { $0.setProjectOrder = .with { $0.projectIds = next.projectOrder } }
        }
        for id in old.expandedProjectIDs.symmetricDifference(next.expandedProjectIDs).sorted() {
            let expanded = next.expandedProjectIDs.contains(id)
            editNavigation {
                $0.setProjectExpanded = .with {
                    $0.projectID = id
                    $0.expanded = expanded
                }
            }
        }
    }

    func syncNavigationFolders(_ next: NavigationFolderPreferences, scope: ClientFolderScope) {
        let folders = next.folders.map { folder in
            ClientNavigationFolder.with {
                $0.id = folder.id
                $0.name = folder.name
                $0.itemIds = folder.itemIDs
                $0.expanded = folder.isExpanded
            }
        }
        editNavigation {
            $0.setFolders = .with {
                $0.scope = scope
                $0.folders = folders
            }
        }
    }

    func syncPinnedProjects(_ next: PinnedProjectNavigationPreferences) {
        editNavigation { $0.setPinnedProjects = .with { $0.projectIds = next.projectOrder } }
    }

    func syncPinnedChats(_ next: PinnedChatNavigationPreferences) {
        editNavigation { $0.setPinnedChatOrder = .with { $0.cardIds = next.chatOrder } }
    }

    func syncChatDisclosure(_ old: ChatProjectDisclosurePreferences, _ next: ChatProjectDisclosurePreferences) {
        for id in old.collapsedProjectIDs.symmetricDifference(next.collapsedProjectIDs).sorted() {
            let collapsed = next.collapsedProjectIDs.contains(id)
            editNavigation {
                $0.setChatSectionCollapsed = .with {
                    $0.projectID = id
                    $0.collapsed = collapsed
                }
            }
        }
        for id in old.expandedProjectIDs.symmetricDifference(next.expandedProjectIDs).sorted() {
            let showAll = next.expandedProjectIDs.contains(id)
            editNavigation {
                $0.setChatsShowAll = .with {
                    $0.projectID = id
                    $0.showAll = showAll
                }
            }
        }
    }

    func laneSortDirection(board: String, lane: String) -> BoardCardSortDirection {
        sharedLaneSortDirections["\(board).\(lane)"] == "ascending" ? .ascending : .descending
    }

    func toggleLaneSort(board: String, lane: String) {
        let descending = laneSortDirection(board: board, lane: lane) == .ascending
        // Show the new direction at once; the core's slice confirms it.
        sharedLaneSortDirections["\(board).\(lane)"] = descending ? "descending" : "ascending"
        editNavigation {
            $0.setLaneDescending = .with {
                $0.boardID = board
                $0.laneID = lane
                $0.descending = descending
            }
        }
    }
}
