package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.ChangesCursor
import com.dbpprt.dieter.api.v1.ChangesFrame
import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.Conversation
import com.dbpprt.dieter.api.v1.PeerRecord
import com.dbpprt.dieter.api.v1.PeerSyncDiagnostic
import com.dbpprt.dieter.api.v1.PeerSyncStatus

/** Key of a streamed record: `kind/id`, as the peer store names it. */
fun recordKey(record: PeerRecord): String = record.kind + "/" + record.id

/** What one machine owns and only it reports: its cards' details, checkouts, activity, and replication issues. */
data class OwnerData(
    val cards: Map<String, Card> = emptyMap(),
    val checkouts: Map<String, Checkout> = emptyMap(),
    val activities: Map<String, Conversation> = emptyMap(),
    val peerSyncIssues: List<PeerSyncDiagnostic> = emptyList(),
)

/** What one applied frame changed: the record keys whose copy differs, and whether owner data changed. */
data class ReplicaChange(val records: Set<String> = emptySet(), val owner: Boolean = false, val identity: Boolean = false) {
    val any: Boolean get() = records.isNotEmpty() || owner || identity

    companion object {
        val NONE = ReplicaChange()
    }
}

/**
 * One machine's copy of the account as its change stream delivers it. A
 * half that resets is rebuilt aside and replaces the old one only once the
 * machine has caught up, so a paged replay is never shown half applied, and
 * the cursor only advances with data it covers. Not thread-safe; the core
 * confines it to its dispatcher.
 */
class MachineReplica(val machineId: String, restored: ChangesFrame? = null) {
    /** The machine's peer identity, which owner fields name; empty until its first frame. */
    var daemonId: String = restored?.daemon_id.orEmpty()
        private set

    /** The peer account its records belong to. */
    var account: String = restored?.account.orEmpty()
        private set

    var cursor: ChangesCursor? = restored?.cursor
        private set

    private var records: HashMap<String, PeerRecord> = HashMap<String, PeerRecord>().also { map ->
        restored?.records?.forEach { map[recordKey(it)] = it }
    }

    var owner: OwnerData = restored?.let {
        OwnerData(
            cards = it.owned_cards.associateBy(Card::id), checkouts = it.owned_checkouts.associateBy(Checkout::id),
            activities = it.activities.associateBy(Conversation::card_id), peerSyncIssues = it.peer_sync?.issues.orEmpty(),
        )
    } ?: OwnerData()
        private set

    private var stagedRecords: HashMap<String, PeerRecord>? = null
    private var stagedOwner: OwnerData? = null
    private var pendingCursor: ChangesCursor? = null

    /** Frames of the stream before a [rewind] are dropped until the replay begins. */
    private var rewound = false

    /** A machine that never delivered a complete view holds nothing to show; a cached view is complete. */
    var hasView: Boolean = restored != null
        private set

    val recordKeys: Set<String> get() = records.keys

    fun record(key: String): PeerRecord? = records[key]

    /** A reset is still being replayed. */
    val replaying: Boolean get() = stagedRecords != null || stagedOwner != null

    /**
     * Replays the stream from the beginning: the view stays until the replay
     * caught up and then is replaced as a whole.
     */
    fun rewind() {
        rewound = true
        cursor = null
        stagedRecords = null
        stagedOwner = null
        pendingCursor = null
    }

    fun apply(frame: ChangesFrame): ReplicaChange {
        if (frame.heartbeat) return ReplicaChange.NONE
        if (rewound) {
            // A replay from the beginning resets both halves; anything else is the stream before the rewind.
            if (!frame.reset_records || !frame.reset_local) return ReplicaChange.NONE
            rewound = false
        }
        val identity = frame.daemon_id != daemonId || frame.account != account
        daemonId = frame.daemon_id
        account = frame.account
        if (frame.reset_records) stagedRecords = HashMap()
        if (frame.reset_local) stagedOwner = OwnerData()
        val changed = HashSet<String>()
        val targetRecords = stagedRecords
        for (record in frame.records) {
            val key = recordKey(record)
            if (targetRecords != null) {
                targetRecords[key] = record
            } else if (records[key] != record) {
                records[key] = record
                changed += key
            }
        }
        val local = frame.owned_cards.isNotEmpty() || frame.removed_owned_card_ids.isNotEmpty() ||
            frame.owned_checkouts.isNotEmpty() || frame.removed_owned_checkout_ids.isNotEmpty() ||
            frame.activities.isNotEmpty() || frame.removed_activity_ids.isNotEmpty() || frame.peer_sync != null
        var ownerChanged = false
        if (local) {
            val staged = stagedOwner
            if (staged != null) {
                stagedOwner = staged.applying(frame)
            } else {
                val next = owner.applying(frame)
                ownerChanged = next != owner
                owner = next
            }
        }
        if (replaying) {
            pendingCursor = frame.cursor
        } else {
            cursor = frame.cursor
            hasView = true
        }
        if (frame.caught_up && replaying) {
            stagedRecords?.let { next ->
                for ((key, record) in next) if (records[key] != record) changed += key
                for (key in records.keys) if (key !in next) changed += key
                records = next
            }
            stagedOwner?.let { next ->
                ownerChanged = ownerChanged || next != owner
                owner = next
            }
            stagedRecords = null
            stagedOwner = null
            cursor = pendingCursor
            pendingCursor = null
            hasView = true
        }
        return ReplicaChange(changed, ownerChanged, identity)
    }

    /** The applied view, for the persisted cache; a replay in progress is not part of it. */
    fun snapshot(): ChangesFrame = ChangesFrame(
        daemon_id = daemonId, account = account, cursor = cursor, reset_records = true, reset_local = true, caught_up = true,
        records = records.values.sortedBy(::recordKey), owned_cards = owner.cards.values.sortedBy(Card::id),
        owned_checkouts = owner.checkouts.values.sortedBy(Checkout::id),
        activities = owner.activities.values.sortedBy(Conversation::card_id),
        peer_sync = PeerSyncStatus(issues = owner.peerSyncIssues),
    )

    private fun OwnerData.applying(frame: ChangesFrame): OwnerData = copy(
        cards = cards.updated(frame.owned_cards, frame.removed_owned_card_ids, Card::id),
        checkouts = checkouts.updated(frame.owned_checkouts, frame.removed_owned_checkout_ids, Checkout::id),
        activities = activities.updated(frame.activities, frame.removed_activity_ids, Conversation::card_id),
        peerSyncIssues = frame.peer_sync?.issues ?: peerSyncIssues,
    )

    private fun <T> Map<String, T>.updated(upserted: List<T>, removed: List<String>, key: (T) -> String): Map<String, T> {
        if (upserted.isEmpty() && removed.isEmpty()) return this
        val next = HashMap(this)
        for (id in removed) next.remove(id)
        for (value in upserted) next[key(value)] = value
        return next
    }
}
