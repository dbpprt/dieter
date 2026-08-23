package com.dbpprt.dieter.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CardSwipePolicyTest {
    @Test
    fun revealsAfterThirtyFivePercentOfTheActionWidth() {
        assertFalse(shouldRevealCardActions(dragOffset = -34f, revealDistance = 100f))
        assertTrue(shouldRevealCardActions(dragOffset = -35f, revealDistance = 100f))
        assertTrue(shouldRevealCardActions(dragOffset = -100f, revealDistance = 100f))
    }

    @Test
    fun ignoresInvalidRevealDistanceAndRightwardDrags() {
        assertFalse(shouldRevealCardActions(dragOffset = -10f, revealDistance = 0f))
        assertFalse(shouldRevealCardActions(dragOffset = 100f, revealDistance = 100f))
    }
}
