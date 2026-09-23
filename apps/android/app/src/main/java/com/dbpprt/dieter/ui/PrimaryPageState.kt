package com.dbpprt.dieter.ui

/** Keep neighboring directories warm without mounting another page's transcript. */
internal class PrimaryPageState(private val destination: Destination) {
    private var previous: DieterUiState? = null

    fun project(state: DieterUiState): DieterUiState {
        val next = if (state.destination == destination) state else state.copy(
            destination = destination,
            selectedCardId = null,
            conversation = null,
            olderMessages = emptyList(),
            historyStart = 0,
            historyTotal = 0,
            historyHasMore = false,
            historyLoading = false,
            conversationRefreshing = false,
            conversationSyncing = false,
            conversationLastRefreshedAtMillis = null,
            conversationScrollRequest = 0,
            detailTab = 0,
            composerDraft = ConversationComposerDraft(),
        )
        return previous?.takeIf { it == next } ?: next.also { previous = it }
    }
}
