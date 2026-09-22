package com.dbpprt.dieter.ui

/** One retained page must not redraw just because another tab was selected. */
internal class PrimaryPageState(private val destination: Destination) {
    private var previous: DieterUiState? = null

    fun project(state: DieterUiState): DieterUiState {
        val next = if (state.destination == destination) state else state.copy(destination = destination)
        return previous?.takeIf { it == next } ?: next.also { previous = it }
    }
}
