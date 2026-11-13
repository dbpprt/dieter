package com.getdieter.mobile.desktop

import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*

/**
 * Where the desktop shell is: one sidebar destination, or a project's page. It is read from the
 * store's tab stacks, which keep binding the core's scopes, so the desktop and touch shells show
 * the same state.
 */
enum class DesktopSection(val title: String) {
    INBOX("Inbox"),
    MAIL("Mail"),
    CHANNELS("Channels"),
    CHATS("Chats"),
    TERMINALS("Terminals"),
    /** Synced folders: the list beside the open folder. */
    FOLDERS("Folders"),
    /** Every project, before one is chosen. */
    PROJECTS("Projects"),
    /** A project's board, files, changes or schedules. */
    PROJECT("Project"),
    MACHINE("Machine"),
    USAGE("Usage"),
    DEVICES("Devices"),
    SETTINGS("Settings"),
    /** More's own page, reached only from the touch shell. */
    PLACES("Places"),
}

/** The sidebar's destinations, in order. */
internal val DesktopDestinations =
    listOf(
        DesktopSection.INBOX,
        DesktopSection.MAIL,
        DesktopSection.CHANNELS,
        DesktopSection.CHATS,
        DesktopSection.TERMINALS,
    )

/** A project's pages, as the sidebar's segment track under an expanded project offers them. */
enum class ProjectPage(val title: String) {
    BOARD("Board"),
    FILES("Files"),
    CHANGES("Changes"),
    SCHEDULES("Schedules"),
}

internal val ProjectPage.tool: ToolPage?
    get() =
        when (this) {
            ProjectPage.BOARD -> null
            ProjectPage.FILES -> ToolPage.FILES
            ProjectPage.CHANGES -> ToolPage.CHANGES
            ProjectPage.SCHEDULES -> ToolPage.SCHEDULES
        }

/**
 * What the shell shows. [base] counts the routes of [MobileNavigation.stack] that make up the
 * section itself (its list or board); everything after them opens in its detail panel.
 */
data class DesktopPlace(
    val section: DesktopSection,
    val base: Int,
    val projectId: String = "",
    val boardId: String = "",
    val page: ProjectPage? = null,
    val machineId: String = "",
)

/** The place [MobileNavigation] shows on the desktop. */
fun MobileNavigation.desktopPlace(): DesktopPlace {
    val stack = stack
    return when (tab) {
        MobileTab.INBOX -> DesktopPlace(DesktopSection.INBOX, 1)
        MobileTab.MAIL -> DesktopPlace(DesktopSection.MAIL, 1)
        MobileTab.CHATS -> DesktopPlace(DesktopSection.CHATS, 1)
        MobileTab.PROJECTS -> {
            val project = stack.indexOfFirst { it is MobileRoute.Project }
            val board = stack.indexOfFirst { it is MobileRoute.Board }
            val projectId = (stack.getOrNull(project) as? MobileRoute.Project)?.projectId.orEmpty()
            when {
                board >= 0 ->
                    DesktopPlace(
                        DesktopSection.PROJECT,
                        board + 1,
                        projectId,
                        (stack[board] as MobileRoute.Board).boardId,
                        ProjectPage.BOARD,
                    )
                project >= 0 -> {
                    val tool = stack.getOrNull(project + 1) as? MobileRoute.Tool
                    val page =
                        ProjectPage.entries.firstOrNull { it.tool != null && it.tool == tool?.page }
                    DesktopPlace(
                        DesktopSection.PROJECT,
                        if (page != null) project + 2 else project + 1,
                        projectId,
                        page = page,
                    )
                }
                else -> DesktopPlace(DesktopSection.PROJECTS, 1)
            }
        }
        MobileTab.MORE -> {
            when (val first = stack.getOrNull(1)) {
                null -> DesktopPlace(DesktopSection.PLACES, 1)
                is MobileRoute.Channels,
                is MobileRoute.Channel ->
                    DesktopPlace(
                        DesktopSection.CHANNELS,
                        if (first is MobileRoute.Channels) 2 else 1,
                    )
                is MobileRoute.Machine ->
                    DesktopPlace(DesktopSection.MACHINE, 2, machineId = first.machineId)
                is MobileRoute.ScreenSession ->
                    DesktopPlace(DesktopSection.MACHINE, 1, machineId = first.machineId)
                is MobileRoute.TerminalSession -> DesktopPlace(DesktopSection.TERMINALS, 1)
                is MobileRoute.Tool ->
                    when (first.page) {
                        ToolPage.TERMINALS -> DesktopPlace(DesktopSection.TERMINALS, 2)
                        ToolPage.FOLDERS -> DesktopPlace(DesktopSection.FOLDERS, 2)
                        ToolPage.USAGE -> DesktopPlace(DesktopSection.USAGE, 2)
                        ToolPage.DEVICES -> DesktopPlace(DesktopSection.DEVICES, 2)
                        ToolPage.SETTINGS -> DesktopPlace(DesktopSection.SETTINGS, 2)
                        else ->
                            DesktopPlace(
                                DesktopSection.PROJECT,
                                2,
                                first.projectId,
                                page = ProjectPage.entries.firstOrNull { it.tool == first.page },
                            )
                    }
                else -> DesktopPlace(DesktopSection.PLACES, 1)
            }
        }
    }
}

/** The routes after the section's own, shown in its detail panel; empty when nothing is open. */
internal fun MobileNavigation.desktopDetail(
    place: DesktopPlace = desktopPlace()
): List<MobileRoute> = stack.drop(place.base)

/** Shows a sidebar destination with what it showed last. */
fun MobileStore.openSection(section: DesktopSection) {
    val current = routes.value
    val more = current.stacks.getValue(MobileTab.MORE)
    fun moreStack(route: MobileRoute): List<MobileRoute> =
        if (current.tab == MobileTab.MORE && more.getOrNull(1) == route) more
        else listOf(MobileRoute.Root(MobileTab.MORE), route)
    when (section) {
        DesktopSection.INBOX -> show(MobileTab.INBOX)
        DesktopSection.MAIL -> show(MobileTab.MAIL)
        DesktopSection.CHATS -> show(MobileTab.CHATS)
        DesktopSection.PROJECTS ->
            show(MobileTab.PROJECTS, listOf(MobileRoute.Root(MobileTab.PROJECTS)))
        DesktopSection.CHANNELS -> show(MobileTab.MORE, moreStack(MobileRoute.Channels))
        DesktopSection.TERMINALS ->
            show(MobileTab.MORE, moreStack(MobileRoute.Tool(ToolPage.TERMINALS)))
        DesktopSection.FOLDERS ->
            show(MobileTab.MORE, moreStack(MobileRoute.Tool(ToolPage.FOLDERS)))
        DesktopSection.USAGE -> show(MobileTab.MORE, moreStack(MobileRoute.Tool(ToolPage.USAGE)))
        DesktopSection.DEVICES ->
            show(MobileTab.MORE, moreStack(MobileRoute.Tool(ToolPage.DEVICES)))
        DesktopSection.SETTINGS ->
            show(MobileTab.MORE, moreStack(MobileRoute.Tool(ToolPage.SETTINGS)))
        DesktopSection.PLACES -> show(MobileTab.MORE, listOf(MobileRoute.Root(MobileTab.MORE)))
        DesktopSection.PROJECT,
        DesktopSection.MACHINE -> Unit
    }
}

/** Opens a project's [page]; its board is [boardId], else the project's first board. */
fun MobileStore.openProject(
    projectId: String,
    page: ProjectPage = ProjectPage.BOARD,
    boardId: String = "",
) {
    val root = listOf(MobileRoute.Root(MobileTab.PROJECTS), MobileRoute.Project(projectId))
    val current = routes.value
    val place = current.desktopPlace()
    if (page == ProjectPage.BOARD) {
        val board = boardId.ifEmpty {
            place.boardId.takeIf { place.projectId == projectId && it.isNotEmpty() }
                ?: workspace.slice.value.boards.firstOrNull { it.project_id == projectId }?.id
                ?: ""
        }
        // Already on it: keep the open conversation.
        if (current.tab == MobileTab.PROJECTS && place.boardId == board && board.isNotEmpty())
            return
        show(MobileTab.PROJECTS, if (board.isEmpty()) root else root + MobileRoute.Board(board))
        return
    }
    val tool = MobileRoute.Tool(page.tool!!, projectId)
    if (current.tab == MobileTab.PROJECTS && current.stack.getOrNull(2) == tool) return
    show(MobileTab.PROJECTS, root + tool)
}

/** Opens a machine's page: its screen, terminals and projects. */
fun MobileStore.openMachine(machineId: String) =
    show(MobileTab.MORE, listOf(MobileRoute.Root(MobileTab.MORE), MobileRoute.Machine(machineId)))

/**
 * Opens a conversation where it lives: a board card over its board, a chat in Chats. The sidebar's
 * active conversations and the command palette open conversations this way.
 */
fun MobileStore.openCard(cardId: String) {
    val workspace = workspace.slice.value
    val card = workspace.cards.firstOrNull { it.id == cardId }
    val board = card?.board_id?.takeIf { it.isNotEmpty() && card.scope != "chat" }
    if (board == null) {
        show(MobileTab.CHATS, listOf(MobileRoute.Root(MobileTab.CHATS)))
    } else {
        show(
            MobileTab.PROJECTS,
            listOf(
                MobileRoute.Root(MobileTab.PROJECTS),
                MobileRoute.Project(card.project_id),
                MobileRoute.Board(board),
            ),
        )
    }
    openConversation(cardId)
}

/**
 * Shows [pane] of the conversation [cardId] open in the detail panel, or its transcript for null:
 * the conversation's tab track.
 */
fun MobileStore.showConversationPane(cardId: String, pane: CardPane?) {
    val current = routes.value
    val index = current.stack.indexOfLast { it is MobileRoute.Conversation && it.cardId == cardId }
    if (index < 0) return
    val base = current.stack.take(index + 1)
    val next = if (pane == null) base else base + MobileRoute.Pane(cardId, pane)
    if (next == current.stack) return
    show(current.tab, next)
}

/** Closes the detail panel: the section's list or board shows alone. */
fun MobileStore.closeDetail() {
    val current = routes.value
    val place = current.desktopPlace()
    if (current.stack.size <= place.base) return
    show(current.tab, current.stack.take(place.base))
}

/** The conversation a detail panel shows, with the pane open in it (null for the transcript). */
internal fun List<MobileRoute>.conversationScope(): Pair<String, CardPane?>? {
    val conversation =
        lastOrNull { it is MobileRoute.Conversation } as? MobileRoute.Conversation ?: return null
    val after = drop(indexOf(conversation) + 1)
    if (after.any { it.cardScope == null }) return null
    val pane = after.lastOrNull { it is MobileRoute.Pane } as? MobileRoute.Pane
    return conversation.cardId to pane?.pane
}
