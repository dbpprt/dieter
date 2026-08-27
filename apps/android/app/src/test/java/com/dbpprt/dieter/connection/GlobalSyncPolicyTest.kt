package com.dbpprt.dieter.connection

import com.dbpprt.dieter.v1.GlobalDelta
import com.dbpprt.dieter.v1.Project
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GlobalSyncPolicyTest {
    @Test
    fun emptyDeltaDoesNotChangeProjection() {
        assertFalse(GlobalDelta.getDefaultInstance().changesProjection())
    }

    @Test
    fun entitiesTombstonesAndSettingsChangeProjection() {
        assertTrue(
            GlobalDelta.newBuilder()
                .addProjects(Project.newBuilder().setId("p_changed"))
                .build()
                .changesProjection(),
        )
        assertTrue(
            GlobalDelta.newBuilder()
                .addRemovedConversationIds("c_removed")
                .build()
                .changesProjection(),
        )
        assertTrue(
            GlobalDelta.newBuilder()
                .setSettings(com.dbpprt.dieter.v1.Settings.getDefaultInstance())
                .build()
                .changesProjection(),
        )
    }

    @Test
    fun projectionPersistenceIsThrottledAcrossDeltaBursts() {
        assertTrue(syncProjectionShouldPersist(null, 1_000L))
        assertFalse(syncProjectionShouldPersist(1_000L, 15_999L))
        assertTrue(syncProjectionShouldPersist(1_000L, 16_000L))
    }
}
