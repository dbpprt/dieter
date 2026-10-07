package com.dbpprt.dieter.core.machines

import com.dbpprt.dieter.api.v1.ChangesFrame
import com.dbpprt.dieter.api.v1.MachineInformation
import com.dbpprt.dieter.api.v1.MachineOperationAction
import com.dbpprt.dieter.api.v1.MachinePrivacy
import com.dbpprt.dieter.core.admin.MachineOperations
import com.dbpprt.dieter.core.sync.MachineReplica
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PrivacyPresentationTest {
    private val on =
        MachinePrivacy(supported = true, requested = true, state = MachinePrivacy.State.STATE_ON)

    @Test
    fun offlineAndDegradedNeverImplyFreshProtection() {
        val live = PrivacyPresentation.of(on, true)
        assertTrue(live.active)
        assertFalse(live.stale)
        val stale = PrivacyPresentation.of(on, false)
        assertTrue(stale.active && stale.stale)
        assertTrue(stale.label.startsWith("Last known:"))
        val degraded =
            PrivacyPresentation.of(
                on.copy(state = MachinePrivacy.State.STATE_DEGRADED, reason = "tap disabled"),
                true,
            )
        assertFalse(degraded.active)
        assertTrue(degraded.warning)
        assertTrue(degraded.label.contains("tap disabled"))
    }

    @Test
    fun ownerStreamCachesAndResetsPrivacyAtomically() {
        val replica = MachineReplica("mini")
        replica.apply(ChangesFrame(daemon_id = "mini", privacy = on, caught_up = true))
        assertEquals(on, MachineReplica("mini", replica.snapshot()).owner.privacy)
        replica.apply(ChangesFrame(daemon_id = "mini", reset_local = true))
        assertEquals(on, replica.owner.privacy)
        replica.apply(
            ChangesFrame(daemon_id = "mini", caught_up = true, privacy = MachinePrivacy())
        )
        assertFalse(replica.owner.privacy!!.requested)
        assertEquals(MachinePrivacy.State.STATE_OFF, replica.owner.privacy!!.state)
    }

    @Test
    fun menuOffersLockOrUnlockAccordingToOwnerRequest() {
        val offInfo =
            MachineInformation(os_name = "macOS", privacy = MachinePrivacy(supported = true))
        assertTrue(
            MachineOperations.availability(offInfo).any {
                it.action == MachineOperationAction.MACHINE_OPERATION_ACTION_PRIVACY_ON
            }
        )
        assertFalse(
            MachineOperations.availability(offInfo).any {
                it.action == MachineOperationAction.MACHINE_OPERATION_ACTION_PRIVACY_OFF
            }
        )
        val locked = offInfo.copy(privacy = on)
        assertTrue(
            MachineOperations.availability(locked).any {
                it.action == MachineOperationAction.MACHINE_OPERATION_ACTION_PRIVACY_OFF
            }
        )
        assertFalse(
            MachineOperations.availability(locked).any {
                it.action == MachineOperationAction.MACHINE_OPERATION_ACTION_PRIVACY_ON
            }
        )
        assertFalse(
            MachineOperations.copy(MachineOperationAction.MACHINE_OPERATION_ACTION_PRIVACY_ON)
                .destructive
        )
        assertTrue(
            MachineOperations.copy(MachineOperationAction.MACHINE_OPERATION_ACTION_PRIVACY_ON)
                .explanation
                .contains("reboot")
        )
    }

    @Test
    fun setupAppearsOnlyWhenTheOwnerRequiresLocalApproval() {
        val info =
            MachineInformation(
                os_name = "macOS",
                privacy = MachinePrivacy(helper_setup_required = true),
            )
        assertTrue(
            MachineOperations.availability(info).any {
                it.action == MachineOperationAction.MACHINE_OPERATION_ACTION_PRIVACY_SETUP
            }
        )
        assertFalse(
            MachineOperations.availability(info.copy(privacy = MachinePrivacy(supported = true)))
                .any { it.action == MachineOperationAction.MACHINE_OPERATION_ACTION_PRIVACY_SETUP }
        )
        assertTrue(
            MachineOperations.copy(MachineOperationAction.MACHINE_OPERATION_ACTION_PRIVACY_SETUP)
                .explanation
                .contains("administrator")
        )
    }
}
