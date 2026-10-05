package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.ChangesCursor
import com.dbpprt.dieter.api.v1.ChangesFrame
import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.Conversation
import com.dbpprt.dieter.api.v1.PeerRecord
import com.dbpprt.dieter.api.v1.PeerVersion
import okio.ByteString.Companion.encodeUtf8

/** Peer records as machines stream them, for projection tests. Ranks and revisions are derived from content. */
internal object TestRecords {
    fun version(json: String?, vararg clock: Pair<String, Long>): PeerVersion {
        val clocks = clock.toMap().ifEmpty { mapOf("a" to 1L) }
        return PeerVersion(
            clock = clocks, value_json = json?.encodeUtf8() ?: okio.ByteString.EMPTY, deleted = json == null,
            rank = "${clocks.entries.sortedBy { it.key }}=$json",
        )
    }

    fun record(key: String, vararg versions: PeerVersion): PeerRecord {
        val kind = key.substringBefore('/')
        val revision = "rev:$key:" + versions.map { it.rank }.sorted().joinToString("|")
        return PeerRecord(kind = kind, id = key.substringAfter('/'), versions = versions.toList(), revision = revision, value_revision = revision)
    }

    fun field(kind: String, entity: String, field: String, json: String): PeerRecord = record("$kind/$entity.$field", version(json))

    fun project(id: String, name: String = id, archived: Boolean = false): List<PeerRecord> = listOf(
        field("project", id, "identity", """{"id":"$id","createdAt":"2026-10-01T10:00:00Z"}"""),
        field("project", id, "name", "\"$name\""),
        field("project", id, "archived", archived.toString()),
    )

    fun checkout(id: String, projectId: String, daemonId: String, detached: Boolean = false): List<PeerRecord> = listOf(
        field("checkout", id, "registration", """{"id":"$id","projectId":"$projectId","daemonId":"$daemonId","name":"$id","detached":$detached}"""),
    )

    fun board(id: String, projectId: String, name: String = id, workflow: String = "review"): List<PeerRecord> = listOf(
        field("board", id, "identity", """{"id":"$id","projectId":"$projectId","createdAt":"2026-10-01T10:00:00Z"}"""),
        field("board", id, "name", "\"$name\""),
        field("board", id, "workflow", "\"$workflow\""),
    )

    fun label(id: String, boardId: String, name: String = id): List<PeerRecord> = listOf(
        field("label", id, "identity", """{"id":"$id","boardId":"$boardId"}"""),
        field("label", id, "name", "\"$name\""),
    )

    fun item(
        id: String,
        projectId: String,
        checkoutId: String,
        owner: String,
        boardId: String = "",
        lane: String = "todo",
        orderKey: String = id,
        title: String = id,
        runtime: String = "idle",
    ): List<PeerRecord> = listOf(
        field("item", id, "identity", """{"id":"$id","projectId":"$projectId","ownerDaemonId":"$owner","checkoutId":"$checkoutId","scope":"${if (boardId.isEmpty()) "chat" else "board"}","createdAt":"2026-10-01T10:00:00Z"}"""),
        field("item", id, "title", "\"$title\""),
        field("item", id, "placement", """{"boardId":"$boardId","lane":"$lane","orderKey":"$orderKey","phaseChangedAt":"2026-10-01T10:00:00Z"}"""),
        field("item", id, "archived", "false"),
        field("item", id, "summary", """{"runtime":"$runtime","lastActivityAt":"2026-10-01T10:00:00Z","responseSeq":0}"""),
    )

    /** A machine whose stream delivered [records] and the owner data, caught up. */
    fun replica(
        machineId: String,
        records: List<PeerRecord>,
        daemonId: String = machineId,
        owned: List<Card> = emptyList(),
        checkouts: List<Checkout> = emptyList(),
        activities: List<Conversation> = emptyList(),
    ): MachineReplica = MachineReplica(machineId).also {
        it.apply(
            ChangesFrame(
                daemon_id = daemonId, account = "account", cursor = ChangesCursor(records_epoch = "e", records_sequence = 1, local_epoch = "l", local_sequence = 1),
                reset_records = true, reset_local = true, caught_up = true, records = records, owned_cards = owned,
                owned_checkouts = checkouts, activities = activities,
            ),
        )
    }

    fun project(vararg replicas: MachineReplica): AccountSnapshot {
        val records = AccountRecords()
        records.update(replicas.toList(), replicas.flatMap { it.recordKeys }.toSet())
        return AccountProjector().project(records, replicas.toList())
    }
}
