package com.getdieter.mobile.store

import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.settings.DieterPalette
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first

/**
 * Debug builds only: replays navigation steps so screenshots of any screen can be taken without
 * touch automation. Steps are separated by ";", e.g. "tab projects; board Main; card Design; pane
 * subagents", "channel Pricing", "more mailbox; mail Dependency audit" or "project Atlas; tool
 * files". `more` opens mailbox, channels, terminals, usage, devices or settings in More.
 */
internal suspend fun MobileStore.runDebugScript(script: String) {
    workspace.slice.first { it.loaded }
    delay(600)
    for (raw in script.split(';').map { it.trim() }.filter { it.isNotEmpty() }) {
        val verb = raw.substringBefore(' ').lowercase()
        val argument = raw.substringAfter(' ', "").trim()
        val cards = workspace.slice.value.cards
        when (verb) {
            "tab" ->
                MobileTab.entries.firstOrNull { it.name.equals(argument, true) }?.let(::selectTab)
            "more" ->
                openMore(
                    when (argument.lowercase()) {
                        "mailbox",
                        "mail" -> MobileRoute.Mailbox
                        "channels" -> MobileRoute.Channels
                        else -> MobileRoute.Tool(ToolPage.valueOf(argument.uppercase()))
                    }
                )
            "project" ->
                workspace.slice.value.projects
                    .firstOrNull { it.name.startsWith(argument, true) }
                    ?.let { push(MobileRoute.Project(it.id)) }
            "board" ->
                workspace.slice.value.boards
                    .firstOrNull { it.name.startsWith(argument, true) }
                    ?.let { push(MobileRoute.Board(it.id)) }
            "channel" ->
                workspace.slice.value.projects
                    .firstOrNull { it.name.startsWith(argument, true) }
                    ?.let { openChannel(it.id) }
            "mail" ->
                mail.slice.value.sections
                    .flatMap { it.rows }
                    .firstOrNull { it.subject.startsWith(argument, true) }
                    ?.ref
                    ?.let {
                        if (MobileRoute.Mailbox !in routes.value.stack)
                            openMore(MobileRoute.Mailbox)
                        showFrom(MobileRoute.Mailbox, MobileRoute.MailMessage(it.daemon_id, it.id))
                    }
            "card",
            "chat" ->
                cards
                    .firstOrNull { it.title.startsWith(argument, true) }
                    ?.let { openConversation(it.id) }
            "pane" ->
                conversation.selectedCard.value
                    .takeIf { it.isNotEmpty() }
                    ?.let { push(MobileRoute.Pane(it, CardPane.valueOf(argument.uppercase()))) }
            // Project tools open for the project on the visible stack.
            "tool" ->
                push(
                    MobileRoute.Tool(
                        ToolPage.valueOf(argument.uppercase()),
                        (routes.value.stack.lastOrNull { it is MobileRoute.Project }
                                as? MobileRoute.Project)
                            ?.projectId
                            .orEmpty(),
                    )
                )
            "file" -> push(MobileRoute.FilePath(argument, file = true))
            "folder" -> push(MobileRoute.FilePath(argument, file = false))
            "machine" ->
                session.slice.value.machines
                    .firstOrNull {
                        it.display_name.startsWith(argument, true) || argument.isEmpty()
                    }
                    ?.let { openMore(MobileRoute.Machine(it.id)) }
            "terminal" -> openMore(MobileRoute.Tool(ToolPage.TERMINALS))
            "new" -> newConversation(chat = false)
            "newchat" -> newConversation(chat = true)
            "appearance" -> theme.setAppearance(argument)
            "palette" -> theme.setPalette(DieterPalette.resolve(argument))
            "back" -> pop()
            "wait" -> delay(argument.toLongOrNull() ?: 500)
        }
        delay(450)
    }
}
