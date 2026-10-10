package com.dbpprt.dieter.mobile

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color

/** The four primary destinations. */
enum class MobileTab(val title: String) {
    INBOX("Inbox"),
    PROJECTS("Projects"),
    CHATS("Chats"),
    TOOLS("Tools"),
}

internal val MobileTab.glyph: Glyph
    get() =
        when (this) {
            MobileTab.INBOX -> Glyph.INBOX
            MobileTab.PROJECTS -> Glyph.PROJECTS
            MobileTab.CHATS -> Glyph.CHATS
            MobileTab.TOOLS -> Glyph.TOOLS
        }

/** What a tablet's empty detail column shows for each tab. */
internal class EmptyDetail(val glyph: Glyph, val title: String, val message: String)

internal val MobileTab.emptyDetail: EmptyDetail
    get() =
        when (this) {
            MobileTab.INBOX ->
                EmptyDetail(
                    Glyph.INBOX,
                    "No conversation selected",
                    "Choose an item from your inbox.",
                )
            MobileTab.PROJECTS ->
                EmptyDetail(Glyph.BOARD, "No task selected", "Open a board and choose a task.")
            MobileTab.CHATS ->
                EmptyDetail(Glyph.CHATS, "No chat selected", "Choose a chat or start a new one.")
            MobileTab.TOOLS ->
                EmptyDetail(Glyph.TOOLS, "No tool selected", "Choose a tool to open it here.")
        }

/** Secondary views of an open conversation. */
enum class CardPane(val title: String, internal val glyph: Glyph) {
    SUBAGENTS("Subagents", Glyph.SUBAGENTS),
    CHANGES("Changes", Glyph.CHANGES),
    FILES("Files", Glyph.FOLDER),
    TERMINAL("Terminal", Glyph.TERMINAL),
    PROCESSES("Processes", Glyph.PROCESSES),
}

/** Machine, workspace and app tools. */
enum class ToolPage(val title: String, internal val glyph: Glyph, internal val tint: Long) {
    MACHINES("Machines", Glyph.MACHINE, 0xFF0A84FF),
    TERMINALS("Terminals", Glyph.TERMINAL, 0xFF3A3A3C),
    SCREENS("Screens", Glyph.SCREENS, 0xFF5E5CE6),
    FILES("Files", Glyph.FOLDER, 0xFF0A9EF5),
    CHANGES("Changes", Glyph.CHANGES, 0xFFFF9F0A),
    SCHEDULES("Schedules", Glyph.SCHEDULES, 0xFFFF453A),
    USAGE("Usage", Glyph.USAGE, 0xFF30B158),
    SETTINGS("Settings", Glyph.SETTINGS, 0xFF8E8E93),
}

internal val ToolPage.color: Color
    get() = Color(tint)

/** A navigable screen. Each tab owns a stack of routes; creation is presented modally. */
@Immutable
sealed class MobileRoute {
    abstract val key: String

    /** Lists stay in the leading pane on wide layouts; other routes open beside them. */
    open val list: Boolean
        get() = false

    /** Conversation screens hide the tab bar while open on phones. */
    open val immersive: Boolean
        get() = false

    data class Root(val tab: MobileTab) : MobileRoute() {
        override val key = "root/${tab.name.lowercase()}"
        override val list = true
    }

    data class Project(val projectId: String) : MobileRoute() {
        override val key = "project/$projectId"
        override val list = true
    }

    data class Board(val boardId: String) : MobileRoute() {
        override val key = "board/$boardId"
        override val list = true
    }

    data class Conversation(val cardId: String) : MobileRoute() {
        override val key = "conversation/$cardId"
        override val immersive = true
    }

    data class Pane(val cardId: String, val pane: CardPane) : MobileRoute() {
        override val key = "pane/$cardId/${pane.name.lowercase()}"
        override val immersive = true
    }

    data class Tool(val page: ToolPage, val projectId: String = "") : MobileRoute() {
        override val key = "tool/${page.name.lowercase()}/$projectId"
    }

    data class NewTask(val chat: Boolean) : MobileRoute() {
        override val key = "new/${if (chat) "chat" else "task"}"
    }

    /** Picks the existing task or chat that shared items go to. */
    data class ShareTarget(val chat: Boolean) : MobileRoute() {
        override val key = "share/${if (chat) "chat" else "task"}"
    }

    /** A folder or document below a Files root; [cardId] scopes it to a conversation. */
    data class FilePath(val path: String, val file: Boolean, val cardId: String = "") :
        MobileRoute() {
        override val key = "file/$cardId/${if (file) "doc" else "dir"}/$path"
        override val immersive = cardId.isNotEmpty() || file
    }

    data class Machine(val machineId: String) : MobileRoute() {
        override val key = "machine/$machineId"
    }

    data class TerminalSession(val terminalId: String, val cardId: String = "") : MobileRoute() {
        override val key = "terminal/$cardId/$terminalId"
        override val immersive = true
    }

    data class ScreenSession(val machineId: String) : MobileRoute() {
        override val key = "screen/$machineId"
        override val immersive = true
    }

    /** Routes that keep a conversation bound while they are open. */
    internal val isDetail: Boolean
        get() =
            this is Conversation ||
                this is Pane ||
                (this is FilePath && cardId.isNotEmpty()) ||
                (this is TerminalSession && cardId.isNotEmpty())

    internal val cardScope: String?
        get() =
            when (this) {
                is Conversation -> cardId
                is Pane -> cardId
                is FilePath -> cardId.ifEmpty { null }
                is TerminalSession -> cardId.ifEmpty { null }
                else -> null
            }
}

@Immutable
data class MobileNavigation(
    val tab: MobileTab = MobileTab.INBOX,
    val stacks: Map<MobileTab, List<MobileRoute>> =
        MobileTab.entries.associateWith { listOf(MobileRoute.Root(it)) },
    val modal: MobileRoute? = null,
) {
    val stack: List<MobileRoute>
        get() = stacks.getValue(tab)

    val top: MobileRoute
        get() = stack.last()

    fun with(tab: MobileTab, stack: List<MobileRoute>) = copy(stacks = stacks + (tab to stack))
}
