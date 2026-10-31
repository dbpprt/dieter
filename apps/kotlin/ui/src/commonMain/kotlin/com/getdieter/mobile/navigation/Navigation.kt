package com.getdieter.mobile.navigation

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import com.getdieter.mobile.design.*

/**
 * The primary destinations, in navigation order. More holds everything else: mail, channels,
 * terminals, the machines and the account pages.
 */
enum class MobileTab(val title: String) {
    INBOX("Inbox"),
    PROJECTS("Projects"),
    CHATS("Chats"),
    MORE("More"),
}

internal val MobileTab.glyph: Glyph
    get() =
        when (this) {
            MobileTab.INBOX -> Glyph.INBOX
            MobileTab.PROJECTS -> Glyph.PROJECTS
            MobileTab.CHATS -> Glyph.CHATS
            MobileTab.MORE -> Glyph.TOOLS
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
            MobileTab.MORE ->
                EmptyDetail(
                    Glyph.TOOLS,
                    "Nothing selected",
                    "Choose mail, a channel, a machine or a setting.",
                )
        }

/** A list's empty detail column, where the list has its own wording. */
internal fun MobileRoute.emptyDetail(tab: MobileTab): EmptyDetail =
    when (this) {
        is MobileRoute.Mailbox ->
            EmptyDetail(Glyph.MAIL, "No message selected", "Choose a message to read it.")
        is MobileRoute.Channels ->
            EmptyDetail(
                Glyph.TAG,
                "No channel selected",
                "Choose a channel to read what its agents tell each other.",
            )
        else -> tab.emptyDetail
    }

/** Secondary views of an open conversation. */
enum class CardPane(val title: String, internal val glyph: Glyph) {
    SUBAGENTS("Subagents", Glyph.SUBAGENTS),
    CHANGES("Changes", Glyph.CHANGES),
    FILES("Files", Glyph.FOLDER),
    TERMINAL("Terminal", Glyph.TERMINAL),
    PROCESSES("Processes", Glyph.PROCESSES),
}

/**
 * Pages opened from a context. Files, Changes and Schedules belong to a project and always carry
 * its ID; Terminals lists every machine's shells; the rest are account pages in More.
 */
enum class ToolPage(val title: String, internal val glyph: Glyph, internal val tint: Long) {
    TERMINALS("Terminals", Glyph.TERMINAL, 0xFF3A3A3C),
    FILES("Files", Glyph.FOLDER, 0xFF0A9EF5),
    CHANGES("Changes", Glyph.CHANGES, 0xFFFF9F0A),
    SCHEDULES("Schedules", Glyph.SCHEDULES, 0xFFFF453A),
    USAGE("Usage", Glyph.USAGE, 0xFF30B158),
    DEVICES("Devices", Glyph.DEVICES, 0xFF32ADE6),
    SETTINGS("Settings", Glyph.SETTINGS, 0xFF8E8E93),
}

/** Tools that need a project. */
internal val ToolPage.projectScoped: Boolean
    get() = this == ToolPage.FILES || this == ToolPage.CHANGES || this == ToolPage.SCHEDULES

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

    /** The account's project channels; opened from More. */
    data object Channels : MobileRoute() {
        override val key = "channels"
        override val list = true
    }

    /** Mail folders and the message list; opened from More. */
    data object Mailbox : MobileRoute() {
        override val key = "mailbox"
        override val list = true
    }

    /** A project's agent channel: its stream, composer and members. */
    data class Channel(val projectId: String) : MobileRoute() {
        override val key = "channel/$projectId"
        override val immersive = true
    }

    data class Pane(val cardId: String, val pane: CardPane) : MobileRoute() {
        override val key = "pane/$cardId/${pane.name.lowercase()}"
        override val immersive = true
    }

    /**
     * A tool page. Project tools carry their [projectId]; Files and Changes also the [checkoutId]
     * they show, empty for the project's default.
     */
    data class Tool(val page: ToolPage, val projectId: String = "", val checkoutId: String = "") :
        MobileRoute() {
        override val key = "tool/${page.name.lowercase()}/$projectId/$checkoutId"
    }

    data class NewTask(val chat: Boolean) : MobileRoute() {
        override val key = "new/${if (chat) "chat" else "task"}"
    }

    /** Picks the existing task or chat that shared items go to. */
    data class ShareTarget(val chat: Boolean) : MobileRoute() {
        override val key = "share/${if (chat) "chat" else "task"}"
    }

    /**
     * A folder or document below a Files root; [cardId] scopes it to a conversation, a [checkoutId]
     * on [daemonId] (in [projectId]) to that checkout, e.g. a workspace link in mail.
     */
    data class FilePath(
        val path: String,
        val file: Boolean,
        val cardId: String = "",
        val daemonId: String = "",
        val projectId: String = "",
        val checkoutId: String = "",
    ) : MobileRoute() {
        override val key =
            "file/" +
                (if (checkoutId.isEmpty()) cardId else "$daemonId:$checkoutId") +
                "/${if (file) "doc" else "dir"}/$path"
        override val immersive = cardId.isNotEmpty() || file
    }

    /** A mail message on [daemonId], beside the mailbox on wide layouts. */
    data class MailMessage(val daemonId: String, val id: String) : MobileRoute() {
        override val key = "mail/$daemonId/$id"
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
