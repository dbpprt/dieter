package com.dbpprt.dieter.core.client

import com.dbpprt.dieter.client.v1.ChatFolderSection
import com.dbpprt.dieter.client.v1.ChatProjectSection
import com.dbpprt.dieter.client.v1.ChatsCommand
import com.dbpprt.dieter.client.v1.ChatsSlice
import com.dbpprt.dieter.client.v1.Done
import com.dbpprt.dieter.client.v1.FolderScope as ClientFolderScope
import com.dbpprt.dieter.client.v1.NavigationCommand
import com.dbpprt.dieter.client.v1.Result
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.navigation.ChatLists
import com.dbpprt.dieter.core.navigation.ChatsSurface
import com.dbpprt.dieter.core.navigation.ChatsView
import com.dbpprt.dieter.core.navigation.FolderScope
import com.dbpprt.dieter.core.navigation.NavigationLayout

// The chats surface (SLICE_CHATS), its commands, and navigation edits made on
// the layout as shown.

internal fun ChatsSurface.execute(command: ChatsCommand): Result {
    command.query?.let { search(it.text); return Result(done = Done()) }
    command.show_archived?.let { showArchived(it.on); return Result(done = Done()) }
    command.reload?.let { reload(); return Result(done = Done()) }
    invalid("Choose a chats action.")
}

internal fun chatsSlice(view: ChatsView) = ChatsSlice(
    pinned_ids = view.list.pinned,
    folders = view.list.folders.map { folder ->
        ChatFolderSection(folder_id = folder.id, name = folder.name, chat_ids = folder.chatIds, expanded = folder.expanded, show_chats = folder.showChats)
    },
    projects = view.list.projects.map { project ->
        ChatProjectSection(
            project_id = project.projectId, chat_ids = project.chatIds, total = project.total, hidden = project.hidden,
            collapsed = project.collapsed, show_all = project.showAll, show_chats = project.showChats,
            toggle_label = ChatLists.toggleLabel(project.hidden, project.showAll),
        )
    },
    other_ids = view.list.other,
    visible_ids = view.list.visible,
    archived = view.archivedChats,
    loading = view.loading,
    error = view.error.orEmpty(),
)

/** Applies one navigation edit, resolving what the sidebar and the chats list show from the runtime's state. */
internal fun CoreRuntime.applyNavigation(command: NavigationCommand): Result {
    val done = Result(done = Done())
    command.move_project?.let { move ->
        val available = workspace.state.value.projects.filterNot { it.archived }.map { it.id }
        navigation.moveProjectBefore(move.project_id, move.before_project_id.ifEmpty { null }, available, move.ungrouped)
        return done
    }
    command.pin_project?.let { navigation.pinProject(it.project_id, it.pinned); return done }
    command.move_pinned_chat?.let { move ->
        val displayed = NavigationLayout(navigationKv.values.value).pinnedChats(workspace.state.value.chats).map { it.id }
        navigation.movePinnedChat(move.chat_id, move.target_chat_id, displayed)
        return done
    }
    command.create_folder?.let { navigation.createFolder(folderScope(it.scope), it.name); return done }
    command.rename_folder?.let { navigation.renameFolder(folderScope(it.scope), it.folder_id, it.name); return done }
    command.delete_folder?.let { navigation.deleteFolder(folderScope(it.scope), it.folder_id); return done }
    command.set_folder_expanded?.let { navigation.setFolderExpanded(folderScope(it.scope), it.folder_id, it.expanded); return done }
    command.move_to_folder?.let { navigation.moveToFolder(folderScope(it.scope), it.item_id, it.folder_id.ifEmpty { null }); return done }
    invalid("Choose a navigation edit.")
}

internal fun folderScope(scope: ClientFolderScope): FolderScope = if (scope == ClientFolderScope.FOLDER_SCOPE_CHATS) FolderScope.CHATS else FolderScope.PROJECTS
