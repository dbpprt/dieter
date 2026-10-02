import DieterAPI
import Foundation
import SharedCore

/// The account-wide navigation layout lives in the shared core: it keeps
/// edits on this Mac until a machine accepts them, folds in edits from other
/// devices, and lays the sidebar out. The Mac sends each edit as the user
/// makes it and shows the core's slice.
extension AppSession {
    func foldNavigation(_ slice: ClientNavigationSlice) {
        var slice = slice
        #if DIETER_UI_SMOKE
            // A fixture's projects exist only on this Mac; lay them out from the saved layout.
            if coreFoldsHeld { slice.projects = NavigationFixture.projects(slice, available: projects) }
        #endif
        if navigation != slice { navigation = slice }
        if navigationPendingCount != Int(slice.pending) { navigationPendingCount = Int(slice.pending) }
        let error = slice.error.isEmpty ? nil : slice.error
        if navigationSyncError != error { navigationSyncError = error }
        navigationCaughtUp = slice.caughtUp
        #if DIETER_UI_SMOKE
            if coreFoldsHeld { chatsList.showFixture(of: self) }
        #endif
    }

    /// Sends a layout edit the user made, after the ones made before it.
    private func editNavigation(_ build: @escaping (inout ClientCommand) -> Void) {
        let previous = navigationEditTail
        navigationEditTail = Task { [weak self] in
            await previous?.value
            await self?.perform(build)
        }
    }

    private func navigate(_ build: @escaping (inout ClientNavigationCommand) -> Void) {
        editNavigation { command in
            var navigation = ClientNavigationCommand()
            build(&navigation)
            command.navigation = navigation
        }
    }

    /// Moves a project above `before`, or to the end of its group when nil.
    /// The sidebar moves it within its folder (or among unfiled projects);
    /// the chats pane, which lists every project, moves it `ungrouped`.
    func moveProject(_ projectID: String, before: String?, ungrouped: Bool) {
        navigate {
            $0.moveProject = .with {
                $0.projectID = projectID
                $0.beforeProjectID = before ?? ""
                $0.ungrouped = ungrouped
            }
        }
    }

    func setProjectPinned(_ projectID: String, pinned: Bool) {
        navigate {
            $0.pinProject = .with {
                $0.projectID = projectID
                $0.pinned = pinned
            }
        }
    }

    /// Shows or hides a project's boards in the sidebar.
    func setProjectExpanded(_ projectID: String, expanded: Bool) {
        editNavigation {
            $0.setProjectExpanded = .with {
                $0.projectID = projectID
                $0.expanded = expanded
            }
        }
    }

    /// Collapses or opens a project's section in the chats pane.
    func setChatSectionCollapsed(_ projectID: String, collapsed: Bool) {
        editNavigation {
            $0.setChatSectionCollapsed = .with {
                $0.projectID = projectID
                $0.collapsed = collapsed
            }
        }
    }

    /// Shows every chat of a project's section in the chats pane, or its preview.
    func setChatsShowAll(_ projectID: String, showAll: Bool) {
        editNavigation {
            $0.setChatsShowAll = .with {
                $0.projectID = projectID
                $0.showAll = showAll
            }
        }
    }

    /// Moves a pinned chat to the place of the pinned chat it was dropped on.
    func movePinnedChat(_ chatID: String, onto targetChatID: String) {
        navigate {
            $0.movePinnedChat = .with {
                $0.chatID = chatID
                $0.targetChatID = targetChatID
            }
        }
    }

    func createFolder(_ scope: ClientFolderScope, name: String) {
        navigate {
            $0.createFolder = .with {
                $0.scope = scope
                $0.name = name
            }
        }
    }

    func renameFolder(_ scope: ClientFolderScope, folderID: String, name: String) {
        navigate {
            $0.renameFolder = .with {
                $0.scope = scope
                $0.folderID = folderID
                $0.name = name
            }
        }
    }

    /// Deletes a folder; its items stay, in no folder.
    func deleteFolder(_ scope: ClientFolderScope, folderID: String) {
        navigate {
            $0.deleteFolder = .with {
                $0.scope = scope
                $0.folderID = folderID
            }
        }
    }

    func setFolderExpanded(_ scope: ClientFolderScope, folderID: String, expanded: Bool) {
        navigate {
            $0.setFolderExpanded = .with {
                $0.scope = scope
                $0.folderID = folderID
                $0.expanded = expanded
            }
        }
    }

    /// Files an item in a folder, or in none when `folderID` is nil.
    func moveToFolder(_ scope: ClientFolderScope, itemID: String, folderID: String?) {
        navigate {
            $0.moveToFolder = .with {
                $0.scope = scope
                $0.itemID = itemID
                $0.folderID = folderID ?? ""
            }
        }
    }

    /// Reverses a lane's shared sort; the core's board view shows it at once.
    func toggleLaneSort(board: String, lane: ClientBoardLaneView) {
        editNavigation {
            $0.setLaneDescending = .with {
                $0.boardID = board
                $0.laneID = lane.laneID
                $0.descending = !lane.descending
            }
        }
    }
}

extension Array where Element == ClientNavigationFolder {
    /// The folder holding `itemID`, if any.
    func folder(containing itemID: String) -> ClientNavigationFolder? {
        first { $0.itemIds.contains(itemID) }
    }
}
