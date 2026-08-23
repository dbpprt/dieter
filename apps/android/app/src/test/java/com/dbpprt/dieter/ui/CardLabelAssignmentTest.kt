package com.dbpprt.dieter.ui

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class CardLabelAssignmentTest {
    @Test
    fun appendsANewLabelWithoutDisturbingExistingAssignments() {
        assertEquals(listOf("first", "second"), assignCardLabel(listOf("first"), "second"))
    }

    @Test
    fun leavesExistingAndBlankAssignmentsUnchanged() {
        val existing = listOf("first")

        assertSame(existing, assignCardLabel(existing, "first"))
        assertSame(existing, assignCardLabel(existing, ""))
    }

    @Test
    fun resolvesTheCardUnderTheReleasePoint() {
        val cards = mapOf(
            "first" to Rect(0f, 100f, 300f, 300f),
            "second" to Rect(0f, 320f, 300f, 520f),
        )

        assertEquals("second", labelDropTargetAt(cards, Offset(140f, 410f)))
        assertNull(labelDropTargetAt(cards, Offset(340f, 410f)))
        assertNull(labelDropTargetAt(cards, Offset.Unspecified))
    }
}
