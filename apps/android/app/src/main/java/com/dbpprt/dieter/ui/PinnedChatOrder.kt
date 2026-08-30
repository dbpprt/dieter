package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.Card

internal fun orderedPinnedChats(chats: List<Card>, pinnedChatOrder: List<String>): List<Card> {
    if (chats.size < 2 || pinnedChatOrder.isEmpty()) return chats

    val chatsById = chats.associateBy(Card::getId)
    val orderedIds = pinnedChatOrder.asSequence().filter(chatsById::containsKey).distinct().toSet()
    return buildList(chats.size) {
        pinnedChatOrder.asSequence().distinct().mapNotNull(chatsById::get).forEach { add(it) }
        chats.asSequence()
            .filterNot { it.id in orderedIds }
            .sortedWith(compareBy<Card> { it.position }.thenBy(Card::getId))
            .forEach { add(it) }
    }
}

internal fun movePinnedChatToTarget(
    pinnedChatIds: List<String>,
    chatId: String,
    targetChatId: String,
): List<String> {
    val sourceIndex = pinnedChatIds.indexOf(chatId)
    val targetIndex = pinnedChatIds.indexOf(targetChatId)
    if (sourceIndex < 0 || targetIndex < 0 || sourceIndex == targetIndex) return pinnedChatIds

    return pinnedChatIds.toMutableList().apply {
        removeAt(sourceIndex)
        add(targetIndex, chatId)
    }
}
