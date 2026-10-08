package com.dbpprt.dieter.mobile

import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first

/**
 * Debug builds only: replays navigation steps so screenshots of any screen can be taken without
 * touch automation. Steps are separated by ";", e.g. "tab projects; board Main; card Design; pane
 * subagents".
 */
internal suspend fun MobileStore.runDebugScript(script: String) {
    workspace.first { it.loaded }
    delay(600)
    for (raw in script.split(';').map { it.trim() }.filter { it.isNotEmpty() }) {
        val verb = raw.substringBefore(' ').lowercase()
        val argument = raw.substringAfter(' ', "").trim()
        val cards = workspace.value.cards
        when (verb) {
            "tab" -> selectTab(MobileTab.valueOf(argument.uppercase()))
            "project" ->
                workspace.value.projects
                    .firstOrNull { it.name.startsWith(argument, true) }
                    ?.let { push(MobileRoute.Project(it.id)) }
            "board" ->
                workspace.value.boards
                    .firstOrNull { it.name.startsWith(argument, true) }
                    ?.let { push(MobileRoute.Board(it.id)) }
            "card",
            "chat" ->
                cards
                    .firstOrNull { it.title.startsWith(argument, true) }
                    ?.let { openConversation(it.id) }
            "pane" ->
                selectedCard.value
                    .takeIf { it.isNotEmpty() }
                    ?.let { push(MobileRoute.Pane(it, CardPane.valueOf(argument.uppercase()))) }
            "tool" ->
                push(MobileRoute.Tool(ToolPage.valueOf(argument.uppercase()), currentProjectId()))
            "file" -> push(MobileRoute.FilePath(argument, file = true))
            "folder" -> push(MobileRoute.FilePath(argument, file = false))
            "machine" ->
                session.value.machines
                    .firstOrNull {
                        it.display_name.startsWith(argument, true) || argument.isEmpty()
                    }
                    ?.let { push(MobileRoute.Machine(it.id)) }
            "terminal" -> push(MobileRoute.Tool(ToolPage.TERMINALS))
            "new" -> newConversation(chat = false)
            "newchat" -> newConversation(chat = true)
            "appearance" -> setAppearance(argument)
            "palette" -> setPalette(com.dbpprt.dieter.settings.DieterPalette.resolve(argument))
            "back" -> pop()
            "wait" -> delay(argument.toLongOrNull() ?: 500)
        }
        delay(450)
    }
}
