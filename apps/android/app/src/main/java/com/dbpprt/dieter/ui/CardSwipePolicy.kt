package com.dbpprt.dieter.ui

internal const val CARD_ACTION_REVEAL_FRACTION = 0.35f

internal fun shouldRevealCardActions(dragOffset: Float, revealDistance: Float): Boolean =
    revealDistance > 0f && dragOffset <= -revealDistance * CARD_ACTION_REVEAL_FRACTION
