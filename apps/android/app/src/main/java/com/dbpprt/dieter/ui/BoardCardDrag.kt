package com.dbpprt.dieter.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.isSpecified
import com.dbpprt.dieter.api.v1.Card

internal data class BoardCardLaneDrop(val cardId: String, val laneId: String)

internal class BoardCardDragState {
    var card by mutableStateOf<Card?>(null)
        private set
    var pointerInRoot by mutableStateOf(Offset.Unspecified)
        private set
    private val laneBounds = mutableStateMapOf<String, Rect>()

    val targetLaneId: String?
        get() = if (card == null || !pointerInRoot.isSpecified) null else
            laneBounds.entries.firstOrNull { it.value.contains(pointerInRoot) }?.key

    fun registerLane(id: String, bounds: Rect) { laneBounds[id] = bounds }
    fun unregisterLane(id: String) { laneBounds.remove(id) }

    fun start(card: Card, pointer: Offset) {
        this.card = card
        pointerInRoot = pointer
    }

    fun moveTo(pointer: Offset) {
        if (card != null) pointerInRoot = pointer
    }

    fun finish(): BoardCardLaneDrop? {
        val source = card
        val target = targetLaneId
        reset()
        return if (source != null && target != null && target != source.lane) {
            BoardCardLaneDrop(source.id, target)
        } else null
    }

    fun reset() {
        card = null
        pointerInRoot = Offset.Unspecified
    }
}

internal fun boardDragScrollDelta(position: Float, start: Float, end: Float, edge: Float): Float = when {
    position < start || position > end || end <= start -> 0f
    position < start + edge -> -((start + edge - position) / edge).coerceIn(0f, 1f)
    position > end - edge -> ((position - end + edge) / edge).coerceIn(0f, 1f)
    else -> 0f
}
