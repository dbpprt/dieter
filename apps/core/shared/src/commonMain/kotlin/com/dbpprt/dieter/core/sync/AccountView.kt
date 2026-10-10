package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.BoardRetirementVersion
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.CardStateField
import com.dbpprt.dieter.api.v1.CardStateVersion
import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.Conversation
import com.dbpprt.dieter.api.v1.KVEntry
import com.dbpprt.dieter.api.v1.Label
import com.dbpprt.dieter.api.v1.Lane
import com.dbpprt.dieter.api.v1.MachinePrivacy
import com.dbpprt.dieter.api.v1.PeerRecord
import com.dbpprt.dieter.api.v1.PeerSyncDiagnostic
import com.dbpprt.dieter.api.v1.PeerVersion
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.board.Cards
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.longOrNull
import okio.ByteString

/** One register joined across machines, with the machines whose own copy is exactly the join. */
class JoinedRecord(
    val kind: String,
    val id: String,
    val versions: List<PeerVersion>,
    private val copies: Map<String, PeerRecord>,
) {
    /**
     * Machines that have observed every version of the join, so a compare-and-swap there sees it.
     */
    val observers: List<String> =
        copies.filterValues { Registers.same(it.versions, versions) }.keys.sorted()

    /**
     * The register's value revision on a machine that observed the whole join, else
     * [UNOBSERVED_JOIN].
     */
    val valueRevision: String
        get() =
            observers.firstOrNull()?.let { copies.getValue(it).value_revision } ?: UNOBSERVED_JOIN

    /**
     * The register's revision on a machine that observed the whole join, else [UNOBSERVED_JOIN].
     */
    val revision: String
        get() = observers.firstOrNull()?.let { copies.getValue(it).revision } ?: UNOBSERVED_JOIN
}

/**
 * Every machine's records joined per register. Updating a key recomputes only that register, so a
 * change costs what changed.
 */
class AccountRecords {
    private val joined = HashMap<String, JoinedRecord>()
    private val byKind = HashMap<String, HashSet<String>>()

    operator fun get(key: String): JoinedRecord? = joined[key]

    fun keys(kind: String): Set<String> = byKind[kind].orEmpty()

    val kinds: Set<String>
        get() = byKind.keys

    /** Recomputes [keys] from [replicas]' current copies. */
    fun update(replicas: Collection<MachineReplica>, keys: Collection<String>) {
        for (key in keys) {
            val copies = HashMap<String, PeerRecord>()
            for (replica in replicas) replica.record(key)?.let { copies[replica.machineId] = it }
            val any = copies.values.firstOrNull()
            if (any == null) {
                joined.remove(key)?.let { byKind[it.kind]?.remove(key) }
                continue
            }
            joined[key] =
                JoinedRecord(
                    any.kind,
                    any.id,
                    Registers.join(copies.values.map { it.versions }),
                    copies,
                )
            byKind.getOrPut(any.kind) { HashSet() }.add(key)
        }
    }

    fun clear() {
        joined.clear()
        byKind.clear()
    }
}

/** The merged, account-wide directory every view derives from. */
data class DirectoryProjection(
    /** Listed projects: ready, not archived, not consolidated into another. */
    val projects: Map<String, Project> = emptyMap(),
    /** Project ID → its live boards, by ID. */
    val boards: Map<String, List<Board>> = emptyMap(),
    val retiredBoards: Map<String, Board> = emptyMap(),
    /** Project ID → its live board items (and chats filed on a board), by ID. */
    val cards: Map<String, List<Card>> = emptyMap(),
    /** Live unfiled chats, newest activity first. */
    val chats: List<Card> = emptyList(),
    /** Card ID → its owner's latest turn. */
    val activities: Map<String, Conversation> = emptyMap(),
    /** Peer identity (as owner and checkout fields name it) → the machine that streams it. */
    val machinesByDaemon: Map<String, String> = emptyMap(),
) {
    val allItems: List<Card>
        get() = cards.values.flatten() + chats

    private val itemsById: Map<String, Card> by lazy { allItems.associateBy(Card::id) }

    fun board(id: String): Board? =
        boards.values.firstNotNullOfOrNull { list -> list.firstOrNull { it.id == id } }

    fun item(id: String): Card? = itemsById[id]

    /** The machine that holds [projectId]'s checkout [checkoutId]. */
    fun checkoutMachine(projectId: String, checkoutId: String): String? =
        projects[projectId]
            ?.checkouts
            ?.firstOrNull { it.id == checkoutId }
            ?.daemon_id
            ?.ifEmpty { null }
            ?.let(::machine)

    /**
     * The machine that runs [card]'s conversation: its recorded owner, else its checkout's machine.
     */
    fun owner(card: Card): String? =
        card.owner_daemon_id.ifEmpty { null }?.let(::machine)
            ?: checkoutMachine(card.project_id, card.checkout_id)

    /**
     * The machine streaming the peer identity [daemonId]; enrolled machines use one ID for both.
     */
    fun machine(daemonId: String): String = machinesByDaemon[daemonId] ?: daemonId

    companion object {
        val EMPTY = DirectoryProjection()
    }
}

/** The account view the machines' streams add up to. */
data class AccountSnapshot(
    val directory: DirectoryProjection = DirectoryProjection.EMPTY,
    /** KV namespace → key → its joined entry. */
    val kv: Map<String, Map<String, KVEntry>> = emptyMap(),
    /** Machine ID → its current peer replication issues. */
    val peerSyncIssues: Map<String, List<PeerSyncDiagnostic>> = emptyMap(),
    val privacy: Map<String, MachinePrivacy> = emptyMap(),
)

/**
 * Projects joined records into the account view. A port of the daemon's projection (internal/store
 * `shared.go`, `consolidate.go`, `board_lifecycle.go`, `shared_order.go`, `materialized_state.go`),
 * checked against fixtures the daemon generates. Decoded values are cached by version rank between
 * passes.
 */
class AccountProjector {
    private var decoded = HashMap<String, JsonElement?>()
    private var used = HashSet<String>()

    fun project(records: AccountRecords, replicas: Collection<MachineReplica>): AccountSnapshot {
        used = HashSet()
        val machinesByDaemon = HashMap<String, String>()
        for (replica in replicas.sortedBy { it.machineId }) {
            if (replica.daemonId.isNotEmpty())
                machinesByDaemon.getOrPut(replica.daemonId) { replica.machineId }
        }
        val owners = HashMap<String, OwnerData>()
        for (replica in replicas.sortedBy { it.machineId }) if (replica.daemonId.isNotEmpty())
            owners.getOrPut(replica.daemonId) { replica.owner }
        val view = Pass(records, owners).run(machinesByDaemon)
        decoded.keys.retainAll(used)
        return AccountSnapshot(
            directory = view,
            kv = kv(records),
            privacy =
                replicas
                    .mapNotNull { replica ->
                        replica.owner.privacy?.let { replica.machineId to it }
                    }
                    .toMap(),
            peerSyncIssues =
                replicas
                    .filter { it.owner.peerSyncIssues.isNotEmpty() }
                    .associate { it.machineId to it.owner.peerSyncIssues },
        )
    }

    fun clear() {
        decoded.clear()
    }

    private fun json(version: PeerVersion): JsonElement? {
        used += version.rank
        return decoded.getOrPut(version.rank) {
            runCatching { Json.parseToJsonElement(version.value_json.utf8()) }.getOrNull()
        }
    }

    private fun kv(records: AccountRecords): Map<String, Map<String, KVEntry>> = buildMap {
        for (kind in records.kinds) {
            if (!kind.startsWith(KV_KIND_PREFIX)) continue
            val namespace = kind.removePrefix(KV_KIND_PREFIX)
            put(
                namespace,
                records
                    .keys(kind)
                    .mapNotNull { records[it] }
                    .associate { record ->
                        val selected = Registers.selectedKv(record.versions)
                        record.id to
                            KVEntry(
                                namespace = namespace,
                                key = record.id,
                                revision =
                                    record.revision.takeIf { it != UNOBSERVED_JOIN }.orEmpty(),
                                value_json =
                                    selected?.takeUnless { it.deleted }?.value_json
                                        ?: ByteString.EMPTY,
                                deleted = selected?.deleted == true,
                                versions = record.versions,
                            )
                    },
            )
        }
    }

    /** The selected values of one entity's registers (`sharedFields`). */
    private class Fields(val values: Map<String, JsonElement>, val conflicts: List<String>) {
        operator fun contains(field: String): Boolean = field in values

        /**
         * A field, looking inside the identity, placement and object summary as `decodeFields`
         * flattens them.
         */
        fun flat(name: String): JsonElement? {
            values[name]?.let {
                return it
            }
            for (container in FLATTENED) (values[container] as? JsonObject)?.get(name)?.let {
                return it
            }
            return null
        }

        fun string(name: String): String = flat(name).string()

        fun bool(name: String): Boolean = flat(name).bool()

        fun long(name: String): Long = flat(name).long()

        fun strings(name: String): List<String> = flat(name).strings()
    }

    private inner class Pass(
        private val records: AccountRecords,
        private val owners: Map<String, OwnerData>,
    ) {
        private val fieldCache = HashMap<String, Fields>()

        fun run(machinesByDaemon: Map<String, String>): DirectoryProjection {
            val checkouts = checkouts()
            val references = boardReferences()
            val labels = labels()
            val assignments = assignments()
            val projects = projects(checkouts)
            val boards = entities("board", "identity").mapNotNull { board(it, references, labels) }
            val items =
                entities("item", "identity")
                    .mapNotNull { item(it, assignments, labels) }
                    .toMutableList()
            materializePositions(items)
            val live = projects.filterValues { !it.archived }
            val liveBoards = boards.filter { it.project_id in live && !it.retired }
            val retired = boards.filter { it.project_id in live && it.retired }
            val liveItems = items.filter { it.project_id in live && !it.archived }
            val boardCounts = liveBoards.groupingBy { it.project_id }.eachCount()
            val cardCounts =
                liveItems.filter { it.scope != SCOPE_CHAT }.groupingBy { it.project_id }.eachCount()
            val chatCounts =
                liveItems.filter { it.scope == SCOPE_CHAT }.groupingBy { it.project_id }.eachCount()
            val counted = live.mapValues { (id, project) ->
                project.copy(
                    board_count = boardCounts[id] ?: 0,
                    card_count = cardCounts[id] ?: 0,
                    chat_count = chatCounts[id] ?: 0,
                )
            }
            val (chats, cards) = liveItems.partition(Cards::isChat)
            val activities = HashMap<String, Conversation>()
            for (card in liveItems) owners[card.owner_daemon_id]?.activities?.get(card.id)?.let {
                activities[card.id] = it
            }
            return DirectoryProjection(
                projects = counted,
                boards =
                    liveBoards
                        .groupBy { it.project_id }
                        .mapValues { (_, list) -> list.sortedBy { it.id } },
                retiredBoards = retired.associateBy { it.id },
                cards = cards.sortedBy { it.id }.groupBy { it.project_id },
                chats =
                    chats.sortedWith(
                        compareByDescending<Card> { activityTime(it) }.thenBy { it.id }
                    ),
                activities = activities,
                machinesByDaemon = machinesByDaemon,
            )
        }

        /** Entities of [kind] whose [field] register selects a value (`entityIDs`). */
        private fun entities(kind: String, field: String): List<String> =
            records
                .keys(kind)
                .mapNotNull { key ->
                    val record = records[key] ?: return@mapNotNull null
                    val (entity, suffix) = splitField(record.id) ?: return@mapNotNull null
                    entity.takeIf { suffix == field && Registers.selected(record.versions) != null }
                }
                .sorted()

        private fun fields(kind: String, id: String): Fields =
            fieldCache.getOrPut("$kind/$id") {
                val values = HashMap<String, JsonElement>()
                val conflicts = ArrayList<String>()
                for (field in DOMAIN_FIELDS.getValue(kind)) {
                    val record = records["$kind/$id.$field"] ?: continue
                    if (record.versions.size > 1 && field != "updatedAt")
                        conflicts += "$kind/$id.$field"
                    if (Registers.selected(record.versions) != null)
                        json(record.versions.maxBy { it.rank })?.let { values[field] = it }
                    if (field == "archived" || field == "deleted") {
                        if (record.versions.any { !it.deleted && it.value_json.utf8() == "true" })
                            values[field] = JsonPrimitive(true)
                    }
                }
                Fields(values, conflicts.sorted())
            }

        private fun ready(kind: String, id: String): Boolean {
            val fields = fields(kind, id)
            return when (kind) {
                "project" -> "identity" in fields && "name" in fields && "archived" in fields
                "board" -> "identity" in fields && "name" in fields && "workflow" in fields
                "checkout" -> "registration" in fields
                else -> false
            }
        }

        /**
         * `canonicalProjectID`: follows consolidation redirects; a cycle resolves to its smallest
         * ID.
         */
        fun canonicalProject(start: String): String {
            var id = start
            val seen = HashMap<String, Int>()
            val path = ArrayList<String>()
            while (path.size < MAX_RECORDS) {
                seen[id]?.let { at ->
                    return path.subList(at, path.size).fold(id) { root, candidate ->
                        if (candidate < root) candidate else root
                    }
                }
                seen[id] = path.size
                path += id
                val record = records["project/$id.consolidatedInto"] ?: return id
                if (record.versions.size != 1) return id
                Registers.selected(record.versions) ?: return id
                val next = json(record.versions.single()).string()
                if (next.isEmpty()) return id
                val identity = records["project/$next.identity"]
                if (identity == null || Registers.selected(identity.versions) == null) return start
                id = next
            }
            return start
        }

        private fun checkouts(): List<Checkout> =
            entities("checkout", "registration").map { id ->
                val registration = fields("checkout", id).values["registration"]
                val checkout =
                    Checkout(
                        id = registration.at("id"),
                        project_id = canonicalProject(registration.at("projectId")),
                        daemon_id = registration.at("daemonId"),
                        name = registration.at("name"),
                        detached = (registration as? JsonObject)?.get("detached").bool(),
                    )
                val owned = owners[checkout.daemon_id]?.checkouts?.get(checkout.id)
                if (owned != null)
                    checkout.copy(
                        path = owned.path,
                        validation_commands = owned.validation_commands,
                    )
                else checkout
            }

        private fun projects(checkouts: List<Checkout>): Map<String, Project> {
            val result = HashMap<String, Project>()
            for (id in entities("project", "identity")) {
                if (canonicalProject(id) != id) continue
                val fields = fields("project", id)
                if ("name" !in fields || "archived" !in fields) continue
                val own = checkouts.filter { it.project_id == id }.sortedBy { it.id }
                val local = own.filter { it.path.isNotEmpty() && !it.detached }.singleOrNull()
                val created = fields.string("createdAt")
                result[id] =
                    Project(
                        id = fields.string("id"),
                        name = fields.string("name"),
                        summary = fields.string("summary"),
                        prompt = fields.string("prompt"),
                        prompt_template = fields.string("promptTemplate"),
                        hostnames = fields.strings("hostnames"),
                        base_remote = fields.string("baseRemote"),
                        base_branch = fields.string("baseBranch"),
                        archived = fields.bool("archived"),
                        created_at = created,
                        updated_at = fields.string("updatedAt").ifEmpty { created },
                        checkouts = own,
                        path = local?.path.orEmpty(),
                        validation_commands = local?.validation_commands.orEmpty(),
                        conflict_keys = fields.conflicts,
                    )
            }
            return result
        }

        private fun labels(): Map<String, Pair<Label, Fields>> =
            entities("label", "identity").associateWith { id ->
                val fields = fields("label", id)
                Label(
                    id = fields.string("id"),
                    name = fields.string("name"),
                    color = fields.string("color"),
                    instructions = fields.string("instructions"),
                ) to fields
            }

        private fun board(
            id: String,
            references: Map<String, List<String>>,
            labels: Map<String, Pair<Label, Fields>>,
        ): Board? {
            val fields = fields("board", id)
            val projectId = canonicalProject(fields.string("projectId"))
            if (!ready("project", projectId) || "name" !in fields || "workflow" !in fields)
                return null
            val own =
                labels.values.filter { (_, label) ->
                    label.string("boardId") == id && !label.bool("deleted")
                }
            val created = fields.string("createdAt")
            val workflow = fields.string("workflow")
            val retirement = records["board/$id.retired"]
            val versions = retirement?.versions.orEmpty()
            val requested = versions.any { !it.deleted && json(it).bool() }
            val blocked = requested && (versions.size != 1 || references[id].orEmpty().isNotEmpty())
            return Board(
                id = fields.string("id"),
                project_id = projectId,
                name = fields.string("name"),
                workflow = workflow,
                description = fields.string("description"),
                prompt_template = fields.string("promptTemplate"),
                hostnames = fields.strings("hostnames"),
                base_remote = fields.string("baseRemote"),
                remote_publish_mode = fields.string("remotePublishMode").ifEmpty { PUBLISH_MANUAL },
                done_archive_policy = fields.string("doneArchivePolicy").ifEmpty { ARCHIVE_NEVER },
                created_at = created,
                updated_at = fields.string("updatedAt").ifEmpty { created },
                labels = own.map { it.first },
                lanes = lanes(workflow),
                conflict_keys = fields.conflicts + own.flatMap { it.second.conflicts },
                retirement_revision = retirement?.revision ?: ABSENT_RETIREMENT,
                retirement_versions =
                    versions.map {
                        BoardRetirementVersion(
                            clock = it.clock,
                            rank = it.rank,
                            retired = !it.deleted && json(it).bool(),
                            deleted = it.deleted,
                        )
                    },
                retired = requested && !blocked,
                retirement_blocked = blocked,
                retirement_references = if (requested) references[id].orEmpty() else emptyList(),
            )
        }

        /**
         * Every surviving placement and schedule reference to a board, archived ones included
         * (`boardReferenceIndex`).
         */
        private fun boardReferences(): Map<String, List<String>> {
            val references = HashMap<String, LinkedHashSet<String>>()
            for ((kind, field) in listOf("item" to "placement", "schedule" to "summary")) {
                for (key in records.keys(kind).sorted()) {
                    val record = records[key] ?: continue
                    val (entity, suffix) = splitField(record.id) ?: continue
                    if (suffix != field) continue
                    for (version in record.versions) {
                        if (version.deleted) continue
                        val value = json(version) as? JsonObject ?: continue
                        val board = value["boardId"].string()
                        if (board.isEmpty() || value["deleted"].bool()) continue
                        val set = references.getOrPut(board) { LinkedHashSet() }
                        if (set.size < MAX_REFERENCES) set += "$kind/$entity"
                    }
                }
            }
            return references.mapValues { (_, values) -> values.sorted().take(MAX_REFERENCES) }
        }

        /** Card ID → its assignment entity IDs (`cardId.labelId`). */
        private fun assignments(): Map<String, List<String>> =
            records
                .keys("assignment")
                .mapNotNull { key ->
                    val record = records[key] ?: return@mapNotNull null
                    val (entity, field) = splitField(record.id) ?: return@mapNotNull null
                    if (field != "membership") return@mapNotNull null
                    val card =
                        entity.substringBefore('.', "").ifEmpty {
                            return@mapNotNull null
                        }
                    card to entity
                }
                .groupBy({ it.first }, { it.second })

        private fun item(
            id: String,
            assignments: Map<String, List<String>>,
            labels: Map<String, Pair<Label, Fields>>,
        ): Card? {
            val fields = fields("item", id)
            if ("identity" !in fields) return null
            val projectId = canonicalProject(fields.string("projectId"))
            val checkoutId = fields.string("checkoutId")
            val scope = fields.string("scope")
            val boardId = fields.string("boardId")
            if (
                !ready("project", projectId) ||
                    !ready("checkout", checkoutId) ||
                    "title" !in fields ||
                    "placement" !in fields ||
                    "archived" !in fields
            )
                return null
            if (scope == SCOPE_BOARD && !ready("board", boardId)) return null
            val labelIds =
                assignments[id]
                    .orEmpty()
                    .mapNotNull { assignment ->
                        val labelId = assignment.substringAfter('.')
                        val membership =
                            records["assignment/$assignment.membership"]?.versions.orEmpty()
                        val member = membership.any {
                            !it.deleted && it.value_json.utf8() == "true"
                        }
                        val removed = membership.any {
                            it.deleted || it.value_json.utf8() != "true"
                        }
                        val label = labels[labelId]?.second
                        labelId.takeIf {
                            member && !removed && label != null && !label.bool("deleted")
                        }
                    }
                    .sorted()
            val placement = records["item/$id.placement"]
            val shared =
                Card(
                    id = fields.string("id"),
                    project_id = projectId,
                    owner_daemon_id = fields.string("ownerDaemonId"),
                    checkout_id = checkoutId,
                    scope = scope,
                    created_at = fields.string("createdAt"),
                    title = fields.string("title"),
                    board_id = boardId,
                    lane = fields.string("lane"),
                    order_key = fields.string("orderKey"),
                    phase_changed_at = fields.string("phaseChangedAt"),
                    archived = fields.bool("archived"),
                    pinned = fields.bool("pinned"),
                    done_archive_exempt = fields.bool("doneArchiveExempt"),
                    runtime = fields.string("runtime"),
                    runtime_updated_at = fields.string("runtimeUpdatedAt"),
                    last_activity_at = fields.string("lastActivityAt"),
                    provider = fields.string("provider"),
                    model = fields.string("model"),
                    effort = fields.string("effort"),
                    initial_prompt_sent_at = fields.string("initialPromptSentAt"),
                    response_seq = fields.long("responseSeq"),
                    response_message_id = fields.string("responseMessageId"),
                    seen_response_seq = fields.long("seenResponseSeq"),
                    merged_into_card_id = fields.string("mergedIntoCardId"),
                    label_ids = labelIds,
                    conflict_keys = fields.conflicts,
                    placement_revision = placement?.valueRevision.orEmpty(),
                    state_fields =
                        listOf("placement", "summary").map { name ->
                            stateField(name, records["item/$id.$name"])
                        },
                )
            return ownerDetails(shared)
        }

        private fun stateField(name: String, record: JoinedRecord?): CardStateField =
            CardStateField(
                name = name,
                revision = record?.valueRevision.orEmpty(),
                versions =
                    record?.versions.orEmpty().map { version ->
                        CardStateVersion(
                            clock = version.clock,
                            rank = version.rank,
                            deleted = version.deleted,
                            value_ = if (version.deleted) Card() else stateValue(json(version)),
                        )
                    },
            )

        private fun stateValue(value: JsonElement?): Card {
            val fields = value as? JsonObject ?: return Card()
            fun s(name: String) = fields[name].string()
            return Card(
                board_id = s("boardId"),
                lane = s("lane"),
                position = fields["position"].long(),
                order_key = s("orderKey"),
                phase_changed_at = s("phaseChangedAt"),
                runtime = s("runtime"),
                runtime_updated_at = s("runtimeUpdatedAt"),
                last_activity_at = s("lastActivityAt"),
                provider = s("provider"),
                model = s("model"),
                effort = s("effort"),
                initial_prompt_sent_at = s("initialPromptSentAt"),
                response_seq = fields["responseSeq"].long(),
                response_message_id = s("responseMessageId"),
                seen_response_seq = fields["seenResponseSeq"].long(),
                merged_into_card_id = s("mergedIntoCardId"),
            )
        }

        /**
         * What only the owner knows, from its own stream; delegated agents only while it holds a
         * turn.
         */
        private fun ownerDetails(card: Card): Card {
            val owner = owners[card.owner_daemon_id] ?: return card
            val activity = owner.activities[card.id]
            val subagents =
                activity
                    ?.subagents
                    .orEmpty()
                    .takeIf { card.runtime in TURN_RUNTIMES }
                    .orEmpty()
                    .filter { it.status == "running" || it.status == "pending" }
            val owned = owner.cards[card.id] ?: return card.copy(active_subagents = subagents)
            return card.copy(
                initial_prompt = owned.initial_prompt,
                summary = owned.summary,
                origin = owned.origin,
                provider_options = owned.provider_options,
                provider_account_key = owned.provider_account_key,
                workspace_mode = owned.workspace_mode,
                workspace_branch = owned.workspace_branch,
                workspace_base_branch = owned.workspace_base_branch,
                workspace_base_remote = owned.workspace_base_remote,
                remote_publish_mode = owned.remote_publish_mode,
                vault_access = owned.vault_access,
                workspace = owned.workspace,
                pull_request = owned.pull_request,
                token_usage = owned.token_usage,
                updated_at = owned.updated_at,
                active_subagents = subagents,
            )
        }
    }

    companion object {
        const val KV_KIND_PREFIX = "kv."
        private const val SCOPE_BOARD = "board"
        private const val SCOPE_CHAT = "chat"
        private const val ABSENT_RETIREMENT = "absent"
        private const val PUBLISH_MANUAL = "manual"
        private const val ARCHIVE_NEVER = "never"
        private const val MAX_REFERENCES = 64
        private const val MAX_RECORDS = 65_536
        private val FLATTENED = listOf("identity", "placement", "summary")

        /** Runtimes in which a turn holds the conversation (`model.RuntimeHoldsTurn`). */
        private val TURN_RUNTIMES = setOf("starting", "running", "finishing", "cancelling")

        /** `peerstore.DomainFields`: the registers of each shared kind. */
        val DOMAIN_FIELDS: Map<String, List<String>> =
            mapOf(
                "schedule" to listOf("summary"),
                "project" to
                    listOf(
                        "updatedAt",
                        "identity",
                        "name",
                        "summary",
                        "prompt",
                        "promptTemplate",
                        "hostnames",
                        "baseRemote",
                        "baseBranch",
                        "archived",
                        "consolidatedInto",
                    ),
                "board" to
                    listOf(
                        "retired",
                        "updatedAt",
                        "identity",
                        "name",
                        "description",
                        "promptTemplate",
                        "hostnames",
                        "baseRemote",
                        "remotePublishMode",
                        "doneArchivePolicy",
                        "workflow",
                    ),
                "label" to listOf("identity", "name", "color", "instructions", "deleted"),
                "item" to
                    listOf(
                        "identity",
                        "title",
                        "placement",
                        "archived",
                        "pinned",
                        "doneArchiveExempt",
                        "summary",
                    ),
                "assignment" to listOf("membership"),
                "checkout" to listOf("registration"),
            )

        /** `model.WorkflowLanes`. */
        fun lanes(workflow: String): List<Lane> = buildList {
            add(Lane("todo", "Todo"))
            add(Lane("running", "Running"))
            if (workflow == "review") add(Lane("review", "Review"))
            add(Lane("done", "Done"))
        }

        /** `materializeCardPositions`: every item's place in (lane, order key, ID) order. */
        fun materializePositions(items: MutableList<Card>) {
            items.sortWith(compareBy<Card> { it.lane }.thenBy { it.order_key }.thenBy { it.id })
            for (index in items.indices) items[index] =
                items[index].copy(position = (index + 1) * 1024L)
        }

        fun activityTime(card: Card): String = card.last_activity_at.ifEmpty { card.updated_at }

        /** `peerstore.SplitField`: entity and field of a record ID. */
        fun splitField(id: String): Pair<String, String>? {
            val at = id.lastIndexOf('.')
            if (at < 1) return null
            return id.substring(0, at) to id.substring(at + 1)
        }

        private fun JsonElement?.string(): String =
            (this as? JsonPrimitive)?.takeIf { it.isString }?.content.orEmpty()

        private fun JsonElement?.bool(): Boolean =
            (this as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull ?: false

        private fun JsonElement?.long(): Long =
            (this as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull ?: 0L

        private fun JsonElement?.strings(): List<String> =
            (this as? JsonArray)
                ?.mapNotNull { element ->
                    element.string().takeIf { (element as? JsonPrimitive)?.isString == true }
                }
                .orEmpty()

        private fun JsonElement?.at(name: String): String =
            (this as? JsonObject)?.get(name).string()
    }
}
