package com.dbpprt.dieter.core.sync

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.Conversation
import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.core.sync.TestRecords.board
import com.dbpprt.dieter.core.sync.TestRecords.checkout
import com.dbpprt.dieter.core.sync.TestRecords.field
import com.dbpprt.dieter.core.sync.TestRecords.item
import com.dbpprt.dieter.core.sync.TestRecords.label
import com.dbpprt.dieter.core.sync.TestRecords.project
import com.dbpprt.dieter.core.sync.TestRecords.record
import com.dbpprt.dieter.core.sync.TestRecords.replica
import com.dbpprt.dieter.core.sync.TestRecords.version
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The daemon's projection rules, applied to joined records (`internal/store/shared.go`). */
class AccountViewTest {
    private val base =
        project("p", "Atlas") + checkout("co", "p", "studio") + board("b", "p", "Main")

    @Test
    fun anItemShowsOnlyOnceEveryRecordItDependsOnArrived() {
        val card = item("c", "p", "co", owner = "studio", boardId = "b")
        assertEquals(
            listOf("c"),
            TestRecords.project(replica("studio", base + card)).directory.allItems.map { it.id },
        )
        // Without its title, checkout, or board it is not ready, on any machine.
        val withoutTitle = card.filterNot { it.id == "c.title" }
        assertTrue(
            TestRecords.project(replica("studio", base + withoutTitle)).directory.allItems.isEmpty()
        )
        assertTrue(
            TestRecords.project(replica("studio", project("p") + board("b", "p") + card))
                .directory
                .allItems
                .isEmpty()
        )
        assertTrue(
            TestRecords.project(
                    replica("studio", project("p") + checkout("co", "p", "studio") + card)
                )
                .directory
                .allItems
                .isEmpty()
        )
        // The missing record can come from another machine.
        val joined =
            TestRecords.project(
                replica("studio", base + withoutTitle),
                replica("laptop", card.filter { it.id == "c.title" }),
            )
        assertEquals(listOf("c"), joined.directory.allItems.map { it.id })
    }

    @Test
    fun anArchiveAnywhereWinsAndHidesTheItem() {
        val card = item("c", "p", "co", owner = "studio", boardId = "b")
        val archived = record("item/c.archived", version("true", "laptop" to 1L))
        val view =
            TestRecords.project(replica("studio", base + card), replica("laptop", listOf(archived)))
                .directory
        assertTrue(view.allItems.isEmpty())
        // An archived project hides its boards and items; a project archived elsewhere counts too.
        val shelved = record("project/p.archived", version("true", "laptop" to 1L))
        val hidden =
            TestRecords.project(replica("studio", base + card), replica("laptop", listOf(shelved)))
                .directory
        assertTrue(hidden.projects.isEmpty())
        assertTrue(hidden.boards.isEmpty())
        assertTrue(hidden.allItems.isEmpty())
    }

    @Test
    fun consolidatedProjectsRedirectTheirBoardsItemsAndCheckouts() {
        val source =
            project("s", "Sidecar") +
                checkout("cs", "s", "studio") +
                board("bs", "s") +
                item("x", "s", "cs", owner = "studio", boardId = "bs") +
                field("project", "s", "consolidatedInto", "\"p\"")
        val view = TestRecords.project(replica("studio", base + source)).directory
        assertEquals(setOf("p"), view.projects.keys)
        assertEquals(listOf("b", "bs"), view.boards.getValue("p").map { it.id })
        assertEquals("p", view.item("x")?.project_id)
        assertEquals(listOf("co", "cs"), view.projects.getValue("p").checkouts.map { it.id })

        // A redirect to a project that does not exist yet keeps the source; a cycle resolves to its
        // smallest ID.
        val dangling = project("s") + field("project", "s", "consolidatedInto", "\"missing\"")
        assertEquals(
            setOf("p", "s"),
            TestRecords.project(replica("studio", base + dangling)).directory.projects.keys,
        )
        val cycle =
            project("q") +
                project("r") +
                field("project", "q", "consolidatedInto", "\"r\"") +
                field("project", "r", "consolidatedInto", "\"q\"")
        assertEquals(
            setOf("p", "q"),
            TestRecords.project(replica("studio", base + cycle)).directory.projects.keys,
        )
    }

    @Test
    fun labelsAndAssignmentsFollowTheirRegisters() {
        val card = item("c", "p", "co", owner = "studio", boardId = "b")
        val labels = label("l1", "b", "bug") + label("l2", "b", "chore") + label("l3", "other")
        val assigned =
            listOf(
                field("assignment", "c.l1", "membership", "true"),
                field("assignment", "c.l2", "membership", "true"),
                // An observed removal wins a concurrent add.
                record(
                    "assignment/c.l3.membership",
                    version("true", "a" to 1L),
                    version("false", "b" to 1L),
                ),
            )
        val deleted = field("label", "l2", "deleted", "true")
        val view =
            TestRecords.project(
                    replica("studio", base + card + labels + assigned),
                    replica("laptop", listOf(deleted)),
                )
                .directory
        assertEquals(listOf("l1"), view.item("c")?.label_ids)
        assertEquals(listOf("bug"), view.boards.getValue("p").single().labels.map { it.name })
    }

    @Test
    fun ownerDetailsComeFromTheOwnerAloneAndCheckoutPathsFromTheirMachine() {
        val card = item("c", "p", "co", owner = "studio", boardId = "b", runtime = "running")
        val owned =
            Card(
                id = "c",
                initial_prompt = "Only the owner knows",
                summary = "Doing it",
                updated_at = "2026-10-01T11:00:00Z",
            )
        val activity =
            Conversation(
                card_id = "c",
                status = "running",
                subagents =
                    listOf(
                        Subagent(id = "s1", status = "running"),
                        Subagent(id = "s2", status = "completed"),
                    ),
            )
        val path = Checkout(id = "co", path = "/work/atlas")
        val studio =
            replica(
                "studio",
                base + card,
                owned = listOf(owned),
                checkouts = listOf(path),
                activities = listOf(activity),
            )
        val laptop =
            replica(
                "laptop",
                base + card,
                owned = listOf(owned.copy(initial_prompt = "A stale copy")),
                checkouts = listOf(path.copy(path = "/elsewhere")),
            )
        val view = TestRecords.project(laptop, studio).directory
        val shown = view.item("c")!!
        assertEquals("Only the owner knows", shown.initial_prompt)
        assertEquals("Doing it", shown.summary)
        assertEquals("2026-10-01T11:00:00Z", shown.updated_at)
        assertEquals(listOf("s1"), shown.active_subagents.map { it.id })
        assertEquals(activity, view.activities["c"])
        assertEquals("/work/atlas", view.projects.getValue("p").checkouts.single().path)
        assertEquals(
            "/work/atlas",
            view.projects.getValue("p").path,
            "a project with one known checkout path shows it",
        )
        assertEquals("studio", view.owner(shown))

        // Without its owner's stream, an item has only the shared fields.
        val shared = TestRecords.project(laptop).directory.item("c")!!
        assertEquals("", shared.initial_prompt)
        assertTrue(shared.active_subagents.isEmpty())
    }

    @Test
    fun anUnboundMachinesPeerIdentityRoutesToTheMachineThatStreamsIt() {
        val card = item("c", "p", "co", owner = "local_studio", boardId = "b")
        val view =
            TestRecords.project(replica("d_studio", base + card, daemonId = "local_studio"))
                .directory
        assertEquals("d_studio", view.owner(view.item("c")!!))
        assertEquals("d_studio", view.machine("local_studio"))
        assertEquals("unknown", view.machine("unknown"))
    }

    @Test
    fun positionsCountsAndTheChatListFollowTheDaemon() {
        val items =
            item("c2", "p", "co", owner = "studio", boardId = "b", orderKey = "b") +
                item("c1", "p", "co", owner = "studio", boardId = "b", orderKey = "a") +
                item(
                    "c3",
                    "p",
                    "co",
                    owner = "studio",
                    boardId = "b",
                    lane = "done",
                    orderKey = "a",
                ) +
                item("h", "p", "co", owner = "studio")
        val view = TestRecords.project(replica("studio", base + items)).directory
        // By lane, then order key, then ID, over every item: "done" sorts before "todo".
        assertEquals(
            mapOf("c3" to 1024L, "c1" to 2048L, "c2" to 3072L, "h" to 4096L),
            view.allItems.associate { it.id to it.position },
        )
        val atlas = view.projects.getValue("p")
        assertEquals(listOf(1, 3, 1), listOf(atlas.board_count, atlas.card_count, atlas.chat_count))
        assertEquals(listOf("h"), view.chats.map { it.id })
        assertEquals(listOf("c1", "c2", "c3"), view.cards.getValue("p").map { it.id })
    }

    @Test
    fun aMoveTargetsAMachineThatObservedEveryPlacement() {
        val card = item("c", "p", "co", owner = "studio", boardId = "b")
        val moved =
            record("item/c.placement", version("""{"boardId":"b","lane":"done"}""", "laptop" to 1L))
        val other =
            record(
                "item/c.placement",
                version("""{"boardId":"b","lane":"running"}""", "studio" to 2L),
            )
        val agreed = TestRecords.project(replica("studio", base + card)).directory.item("c")!!
        assertEquals(
            card.first { it.id == "c.placement" }.value_revision,
            agreed.placement_revision,
        )
        val split =
            TestRecords.project(
                    replica("studio", base + card.filterNot { it.id == "c.placement" } + other),
                    replica("laptop", listOf(moved)),
                )
                .directory
                .item("c")!!
        assertEquals(UNOBSERVED_JOIN, split.placement_revision)
        assertEquals(listOf("item/c.placement"), split.conflict_keys)
        assertEquals(2, split.state_fields.first { it.name == "placement" }.versions.size)
        assertEquals(
            listOf(moved, other)
                .flatMap { it.versions }
                .maxBy { it.rank }
                .let { if ("done" in it.value_json.utf8()) "done" else "running" },
            split.lane,
        )
    }

    @Test
    fun keyValueEntriesJoinAcrossMachines() {
        val older = record("kv.navigation/lane.b.todo.sort", version("\"ascending\"", "a" to 1L))
        val newer = record("kv.navigation/lane.b.todo.sort", version("\"descending\"", "a" to 2L))
        val snapshot =
            TestRecords.project(replica("studio", listOf(older)), replica("laptop", listOf(newer)))
        val entry = snapshot.kv.getValue("navigation").getValue("lane.b.todo.sort")
        assertEquals("\"descending\"", entry.value_json.utf8())
        assertEquals(
            newer.revision,
            entry.revision,
            "the revision of the machine that has the joined entry",
        )
        assertFalse(entry.deleted)
        val deleted =
            TestRecords.project(
                    replica("studio", listOf(record("kv.navigation/x", version(null, "a" to 1L))))
                )
                .kv
                .getValue("navigation")
                .getValue("x")
        assertTrue(deleted.deleted)
        assertNull(snapshot.kv["other"])
    }
}
