package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.ChangesCursor
import com.dbpprt.dieter.api.v1.ChangesFrame
import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.Conversation
import com.dbpprt.dieter.api.v1.PeerSyncDiagnostic
import com.dbpprt.dieter.api.v1.PeerSyncStatus
import com.dbpprt.dieter.core.sync.TestRecords.field
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MachineReplicaTest {
    private fun cursor(records: Long, local: Long = 1) = ChangesCursor(records_epoch = "e", records_sequence = records, local_epoch = "l", local_sequence = local)
    private val title = field("item", "c", "title", "\"One\"")
    private val renamed = field("item", "c", "title", "\"Two\"").copy(revision = "rev2", value_revision = "rev2")

    @Test
    fun aResetIsShownOnlyOnceTheMachineHasCaughtUpAndTheCursorFollowsIt() {
        val replica = MachineReplica("m", ChangesFrame(daemon_id = "m", cursor = cursor(5), records = listOf(title), owned_cards = listOf(Card(id = "c"))))
        assertTrue(replica.hasView)
        val first = replica.apply(ChangesFrame(daemon_id = "m", cursor = cursor(1), reset_records = true, reset_local = true, records = listOf(renamed)))
        assertEquals(ReplicaChange.NONE, first, "a paged replay is never shown half applied")
        assertEquals(title, replica.record(recordKey(title)))
        assertEquals(cursor(5), replica.cursor, "the cursor stays with the data it covers")
        assertTrue(replica.replaying)

        val last = replica.apply(ChangesFrame(daemon_id = "m", cursor = cursor(2), caught_up = true, owned_cards = listOf(Card(id = "d"))))
        assertEquals(setOf(recordKey(title)), last.records)
        assertTrue(last.owner)
        assertEquals(renamed, replica.record(recordKey(title)))
        assertEquals(setOf("d"), replica.owner.cards.keys, "the reset replaced the owner data")
        assertEquals(cursor(2), replica.cursor)
        assertFalse(replica.replaying)
    }

    @Test
    fun liveFramesApplyAtOnceHeartbeatsChangeNothingAndRemovalsGo() {
        val replica = MachineReplica("m")
        replica.apply(ChangesFrame(daemon_id = "d", account = "acct", cursor = cursor(1), reset_records = true, reset_local = true, caught_up = true, records = listOf(title)))
        assertEquals("d", replica.daemonId)
        assertEquals("acct", replica.account)
        assertEquals(ReplicaChange.NONE, replica.apply(ChangesFrame(daemon_id = "d", account = "acct", cursor = cursor(1), heartbeat = true, caught_up = true)))
        assertEquals(ReplicaChange.NONE, replica.apply(ChangesFrame(daemon_id = "d", account = "acct", cursor = cursor(2), caught_up = true, records = listOf(title))), "the same copy again")
        assertEquals(cursor(2), replica.cursor)

        val activity = Conversation(card_id = "c", status = "running")
        val local = replica.apply(
            ChangesFrame(
                daemon_id = "d", account = "acct", cursor = cursor(3, 2), caught_up = true, owned_cards = listOf(Card(id = "c", initial_prompt = "Do it")),
                owned_checkouts = listOf(Checkout(id = "co", path = "/work")), activities = listOf(activity),
                peer_sync = PeerSyncStatus(issues = listOf(PeerSyncDiagnostic(peer_id = "x"))),
            ),
        )
        assertTrue(local.owner)
        assertEquals("/work", replica.owner.checkouts.getValue("co").path)
        assertEquals(activity, replica.owner.activities["c"])
        assertEquals(listOf("x"), replica.owner.peerSyncIssues.map { it.peer_id })

        replica.apply(
            ChangesFrame(
                daemon_id = "d", account = "acct", cursor = cursor(3, 3), caught_up = true, removed_owned_card_ids = listOf("c"),
                removed_owned_checkout_ids = listOf("co"), removed_activity_ids = listOf("c"), peer_sync = PeerSyncStatus(),
            ),
        )
        assertEquals(OwnerData(), replica.owner)
    }

    @Test
    fun aRewindKeepsTheViewDropsTheOldStreamAndReplaysFromTheBeginning() {
        val replica = MachineReplica("m")
        replica.apply(ChangesFrame(daemon_id = "d", cursor = cursor(1), reset_records = true, reset_local = true, caught_up = true, records = listOf(title)))
        replica.rewind()
        assertNull(replica.cursor)
        assertTrue(replica.hasView, "the view stays shown")
        assertEquals(ReplicaChange.NONE, replica.apply(ChangesFrame(daemon_id = "d", cursor = cursor(2), caught_up = true, records = listOf(renamed))), "the stream before the rewind")
        assertEquals(title, replica.record(recordKey(title)))
        assertNull(replica.cursor)
        replica.apply(ChangesFrame(daemon_id = "d", cursor = cursor(1), reset_records = true, reset_local = true, caught_up = true, records = listOf(renamed)))
        assertEquals(renamed, replica.record(recordKey(title)))
        assertEquals(cursor(1), replica.cursor)
        assertNull(MachineReplica("m", replica.snapshot().copy(cursor = null)).cursor, "a cached view can resume from the beginning")
    }

    @Test
    fun aSnapshotRestoresTheAppliedViewWithoutAReplayInProgress() {
        val replica = MachineReplica("m")
        replica.apply(ChangesFrame(daemon_id = "d", cursor = cursor(1), reset_records = true, reset_local = true, caught_up = true, records = listOf(title), owned_cards = listOf(Card(id = "c"))))
        replica.apply(ChangesFrame(daemon_id = "d", cursor = cursor(1), reset_records = true, records = listOf(renamed)))
        val restored = MachineReplica("m", replica.snapshot())
        assertEquals(title, restored.record(recordKey(title)))
        assertEquals(setOf("c"), restored.owner.cards.keys)
        assertEquals(cursor(1), restored.cursor)
        assertFalse(restored.replaying)
        assertNull(MachineReplica("fresh").cursor)
    }
}
