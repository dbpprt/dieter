package com.dbpprt.dieter.core.composition

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.api.v1.HarnessModel
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.Lane
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.api.v1.ProviderOption
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** A new conversation checked against its destination machine, its catalog, and its pickers. */
class CreationPlanTest {
    private val sol = HarnessModel(id = "sol", name = "Sol", default_effort = "low", efforts = listOf("low", "high"))
    private val codex = Harness(
        id = "codex", name = "Codex", default_model = "sol", models = listOf(sol),
        options = listOf(ProviderOption(id = "fast_mode", type = "bool", default_value = "false", mutable = true)),
    )
    private val mac = Checkout(id = "k-mac", daemon_id = "mac", name = "Mac checkout")
    private val linux = Checkout(id = "k-linux", daemon_id = "linux", name = "Linux checkout")
    private val project = Project(id = "p", base_branch = "main", base_remote = "origin", checkouts = listOf(mac, linux))
    private val board = Board(id = "b", project_id = "p", lanes = listOf(Lane("todo", "Todo"), Lane("running", "Running"), Lane("review", "Review")))

    private fun input(checkoutId: String = "k-mac", chat: Boolean = false) = CreationInput(
        project, board = if (chat) null else board, checkoutId = checkoutId, chat = chat, lane = if (chat) "" else "todo",
        prompt = "Fix it", selection = HarnessSelection("codex", "sol", "low"),
    )

    @Test
    fun anOnlineDestinationWithItsCatalogValidatesLive() {
        val plan = Creation.plan(input(), CreationDestinations(online = setOf("mac"), attachedDaemonId = "mac", catalogs = mapOf("mac" to listOf(codex))))
        assertEquals(CatalogState.LIVE, plan.catalogState)
        assertEquals("mac", plan.daemonId)
        assertNull(plan.problem)
        assertEquals("Mac checkout", plan.destinationStatus)
        assertNull(plan.offlineHint)
        assertFalse(plan.needsCatalog)
        assertEquals(listOf("codex"), plan.controls.harnesses.map { it.id })
        assertEquals("Codex", plan.controls.providerLabel)
    }

    @Test
    fun anOfflineDestinationQueuesTasksAgainstItsCachedCatalogButNotChats() {
        val destinations = CreationDestinations(catalogs = mapOf("linux" to listOf(codex)))
        val task = Creation.plan(input("k-linux"), destinations)
        assertEquals(CatalogState.CACHED, task.catalogState)
        assertNull(task.problem)
        assertTrue(task.offlineHint!!.contains("queue on this device"))
        assertEquals("Machine offline · choose an online destination", task.destinationStatus)
        val chat = Creation.plan(input("k-linux", chat = true), destinations)
        assertEquals("Loading agent models…", chat.problem, "a chat starts at once and needs its machine online")
    }

    @Test
    fun aCatalogStillLoadingBlocksValidation() {
        val plan = Creation.plan(input(), CreationDestinations(online = setOf("mac"), attachedDaemonId = "mac"))
        assertEquals(CatalogState.NONE, plan.catalogState)
        assertTrue(plan.needsCatalog)
        assertEquals("Loading agent models…", plan.problem)
        assertEquals("Loading agent models…", plan.destinationStatus)
        assertTrue(plan.controls.harnesses.isEmpty())
    }

    @Test
    fun pickersShowTheProjectsMachineUntilACheckoutIsChosen() {
        val destinations = CreationDestinations(
            online = setOf("mac", "linux"), attachedDaemonId = "mac", replicas = mapOf("p" to "linux"),
            catalogs = mapOf("mac" to listOf(Harness(id = "local")), "linux" to listOf(Harness(id = "remote"))),
        )
        val unchosen = Creation.plan(input(checkoutId = ""), destinations)
        assertNull(unchosen.checkout)
        assertEquals(listOf("remote"), unchosen.harnesses.map { it.id }, "the project's machine, not the attached one")
        assertEquals("Choose where this task will run", unchosen.problem)
        assertEquals(listOf("local"), Creation.plan(input(checkoutId = "k-mac"), destinations).harnesses.map { it.id }, "the checkout's machine")
        assertEquals(listOf("local"), Creation.plan(input(checkoutId = ""), destinations.copy(replicas = emptyMap())).harnesses.map { it.id }, "else the attached machine")
    }

    @Test
    fun summariesNameTheLaneTheWorkspaceAndTheAgent() {
        val selection = HarnessSelection("codex", "sol", "low", mapOf("fast_mode" to "true"))
        assertEquals("Running · Worktree · Codex / Sol · Fast", Creation.summary(false, "running", board, WorkspaceMode.WORKTREE, selection, listOf(codex)))
        assertEquals("Project directory · Codex / Sol", Creation.summary(true, "", null, WorkspaceMode.PROJECT, selection.copy(provider_options = emptyMap()), listOf(codex)))
        assertEquals("Todo · Worktree · Agent defaults", Creation.summary(false, "missing", board, WorkspaceMode.WORKTREE, HarnessSelection(), listOf(codex)))
    }

    @Test
    fun titlesAndOpeningFollowTheInput() {
        assertEquals("Fix it", Creation.title(input()))
        assertEquals("Named", Creation.title(input().copy(title = " Named ")))
        assertEquals("Fix it", Creation.title(input(chat = true)))
        assertFalse(Creation.opensAfterCreate(chat = false, lane = "Todo"), "a saved task stays on the board, whatever the lane's case")
        assertTrue(Creation.opensAfterCreate(chat = false, lane = "running"))
        assertTrue(Creation.opensAfterCreate(chat = true, lane = "todo"))
        assertEquals(listOf("todo", "running"), Creation.startLanes(board).map { it.id })
    }

    @Test
    fun editorsNameTheirSubmitAndDestinationsTheSameWay() {
        assertEquals("Create & run", Creation.submitTitle("running"))
        assertEquals("Save", Creation.submitTitle("todo"))
        assertEquals("The first message starts immediately.", Creation.startNote("running"))
        assertEquals("The card is saved as a draft in Todo.", Creation.startNote("todo"))
        assertEquals("Mac checkout", Creation.checkoutTitle(mac))
        assertEquals("Project checkout · Offline", Creation.checkoutTitle(mac.copy(name = " "), machineOnline = false))
        assertEquals("Project checkout", Creation.destinationStatus(project, mac.copy(name = ""), true, CatalogState.LIVE))
        assertEquals(listOf("New worktree", "Project directory"), WorkspaceMode.choices.map { it.choiceTitle })
    }

    @Test
    fun preselectionsPreferTheChosenThenTheAttachedMachine() {
        assertEquals("k-linux", Creation.preferredCheckout(project, "k-linux", attachedDaemonId = "mac", replicaDaemonId = "mac")?.id)
        assertEquals("k-mac", Creation.preferredCheckout(project, null, attachedDaemonId = "mac", replicaDaemonId = "linux")?.id)
        assertEquals("k-linux", Creation.preferredCheckout(project, null, attachedDaemonId = "", replicaDaemonId = "linux")?.id)
        assertNull(Creation.preferredCheckout(project, null, attachedDaemonId = "other", replicaDaemonId = null))
        val detached = project.copy(checkouts = listOf(mac.copy(detached = true), linux))
        assertEquals("k-linux", Creation.preferredCheckout(detached, "k-mac", attachedDaemonId = "mac", replicaDaemonId = null)?.id, "a detached checkout is never preselected")
        val boards = listOf(Board(id = "a", retired = true), Board(id = "b"), Board(id = "c"))
        assertEquals("c", Creation.preferredBoard("c", boards)?.id)
        assertEquals("b", Creation.preferredBoard("a", boards)?.id, "a retired board gives way to the first live one")
        assertEquals("b", Creation.preferredBoard(null, boards)?.id)
        assertNull(Creation.preferredBoard(null, emptyList()))
    }
}
