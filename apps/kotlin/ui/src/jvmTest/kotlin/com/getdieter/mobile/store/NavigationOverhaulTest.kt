package com.getdieter.mobile.store

import com.getdieter.api.v1.Checkout
import com.getdieter.api.v1.Project
import com.getdieter.client.v1.*
import com.getdieter.mobile.app.shown
import com.getdieter.mobile.navigation.*
import kotlin.test.*
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.*

@OptIn(ExperimentalCoroutinesApi::class)
class NavigationOverhaulTest {
    private fun TestScope.store(core: FakeMobileCore) =
        MobileStore(core, StandardTestDispatcher(testScheduler))

    private val more = MobileRoute.Root(MobileTab.MORE)

    @Test
    fun morePlacesOpenAboveTheMorePageAndBackReturnsThere() = runTest {
        val store = store(FakeMobileCore())
        try {
            store.selectTab(MobileTab.PROJECTS)
            store.openMore(MobileRoute.Channels)
            assertEquals(MobileTab.MORE, store.routes.value.tab)
            assertEquals(listOf(more, MobileRoute.Channels), store.routes.value.stack)
            // Choosing another place replaces the open one.
            store.openMore(MobileRoute.Tool(ToolPage.SETTINGS))
            assertEquals(
                listOf(more, MobileRoute.Tool(ToolPage.SETTINGS)),
                store.routes.value.stack,
            )
            assertEquals(
                listOf(MobileRoute.Root(MobileTab.PROJECTS)),
                store.routes.value.stacks[MobileTab.PROJECTS],
            )
            assertTrue(store.handleBack())
            assertEquals(listOf(more), store.routes.value.stack)
            assertTrue(store.handleBack())
            assertEquals(MobileTab.INBOX, store.routes.value.tab)
        } finally {
            store.close()
        }
    }

    @Test
    fun projectToolsBindTheirOwnProjectAndCheckoutNotTheLastOneOpened() = runTest {
        val core = FakeMobileCore()
        val store = store(core)
        try {
            runCurrent()
            core.publish(
                Slice.SLICE_SESSION,
                update =
                    Update(
                        session =
                            SessionSlice(
                                machines =
                                    listOf(
                                        MachineEntry(id = "d_mini", available = true),
                                        MachineEntry(id = "d_book", available = false),
                                    )
                            )
                    ),
            )
            core.publish(
                Slice.SLICE_WORKSPACE,
                update =
                    Update(
                        workspace =
                            WorkspaceSlice(
                                loaded = true,
                                projects =
                                    listOf(
                                        Project(
                                            id = "p_atlas",
                                            name = "Atlas",
                                            checkouts =
                                                listOf(
                                                    Checkout(id = "co_atlas", daemon_id = "d_mini")
                                                ),
                                        ),
                                        Project(
                                            id = "p_pocket",
                                            name = "Pocket",
                                            checkouts =
                                                listOf(
                                                    // The offline machine's checkout comes first.
                                                    Checkout(id = "co_book", daemon_id = "d_book"),
                                                    Checkout(id = "co_mini", daemon_id = "d_mini"),
                                                ),
                                        ),
                                    ),
                            )
                    ),
            )
            runCurrent()
            // Atlas was opened last; Pocket's tools still show Pocket.
            store.selectTab(MobileTab.PROJECTS)
            store.push(MobileRoute.Project("p_atlas"))
            store.push(MobileRoute.Tool(ToolPage.FILES, "p_pocket"))
            runCurrent()
            assertEquals(
                FilesTarget(daemon_id = "d_mini", project_id = "p_pocket", checkout_id = "co_mini"),
                core.sentOf { it.files }.mapNotNull { it.bind }.last(),
            )
            // A chosen checkout replaces the route and binds that checkout.
            store.replaceTop(MobileRoute.Tool(ToolPage.FILES, "p_pocket", "co_book"))
            runCurrent()
            assertEquals(
                "co_book",
                core.sentOf { it.files }.mapNotNull { it.bind }.last().checkout_id,
            )
            store.replaceTop(MobileRoute.Tool(ToolPage.CHANGES, "p_pocket"))
            runCurrent()
            val changes = core.sentOf { it.project_changes }.mapNotNull { it.bind }.single()
            assertEquals(ProjectChangesTarget("p_pocket", "co_mini", "d_mini", true), changes)
            store.replaceTop(MobileRoute.Tool(ToolPage.SCHEDULES, "p_pocket"))
            runCurrent()
            assertEquals(
                "p_pocket",
                core.sentOf { it.schedules }.mapNotNull { it.bind }.single().project_id,
            )
        } finally {
            store.close()
        }
    }

    @Test
    fun theSplitKeepsBothPanesReadable() {
        // A Fold's inner display: the list keeps 280 dp and the detail 320 dp.
        assertEquals(315f, PaneSplit.listWidth(750f, PaneSplit.DEFAULT_FRACTION), .5f)
        assertEquals(280f, PaneSplit.listWidth(750f, .1f))
        assertEquals(430f, PaneSplit.listWidth(750f, .9f))
        // Too narrow to divide: the list keeps its minimum.
        assertEquals(280f, PaneSplit.listWidth(560f, .9f))
        assertEquals(430f / 750f, PaneSplit.fraction(750f, 900f), .001f)
    }

    @Test
    fun aPaneDraggedFarEnoughGoesAwayAndTheChoiceIsKept() {
        // Released well below its 280 dp minimum, the list goes; near it, the split snaps back.
        assertEquals(PaneCollapse.LIST, PaneSplit.collapse(750f, 120f))
        assertEquals(PaneCollapse.NONE, PaneSplit.collapse(750f, 200f))
        // The same for the detail's 320 dp.
        assertEquals(PaneCollapse.DETAIL, PaneSplit.collapse(750f, 600f))
        assertEquals(PaneCollapse.NONE, PaneSplit.collapse(750f, 540f))

        val saved = mutableMapOf<String, String>()
        val preferences = MobilePreferences(saved::get) { key, value -> saved[key] = value }
        val layout = LayoutModel(preferences)
        layout.settle(750f, 100f)
        assertEquals(PaneCollapse.LIST, layout.paneCollapse.value)
        assertEquals(PaneCollapse.LIST, LayoutModel(preferences).paneCollapse.value)
        assertEquals(0f, PaneSplit.shownWidth(750f, layout.paneFraction.value, PaneCollapse.LIST))
        // A list sent away shows again while nothing is open beside it.
        assertEquals(PaneCollapse.NONE, PaneCollapse.LIST.shown(detailOpen = false))
        layout.settle(750f, 400f)
        assertEquals(PaneCollapse.NONE, layout.paneCollapse.value)
        assertEquals(400f / 750f, layout.paneFraction.value, .001f)
        layout.settle(750f, 700f)
        assertEquals(
            750f,
            PaneSplit.shownWidth(750f, layout.paneFraction.value, PaneCollapse.DETAIL),
        )
        layout.resetPanes()
        assertEquals(PaneCollapse.NONE, LayoutModel(preferences).paneCollapse.value)
        assertEquals(PaneSplit.DEFAULT_FRACTION, LayoutModel(preferences).paneFraction.value)
    }
}
