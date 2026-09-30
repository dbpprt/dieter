package com.dbpprt.dieter.core

import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.navigation.FolderScope
import com.dbpprt.dieter.core.navigation.NavigationLayout
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.first

/** KV scenarios: shared navigation between two clients through a real daemon. */
class NavigationEndToEndTest : EndToEnd() {
    @AfterTest
    fun tearDown() = tearDownRuntimes()

    private suspend fun CoreRuntime.layout(): NavigationLayout = navigationLayout().first()

    @Test
    fun twoClientsConvergeAndOfflineEditsDrainAfterReconnect() = e2e {
        val fixture = fixture()
        val mac = runtime(fixture)
        val phone = runtime(fixture)
        mac.awaitConnected()
        phone.awaitConnected()
        mac.navigationKv.status.await(describe = { "mac caught up: ${mac.navigationKv.status.value}" }) { it.caughtUp }
        phone.navigationKv.status.await(describe = { "phone caught up" }) { it.caughtUp }

        val folder = mac.editNavigation { createFolder(FolderScope.PROJECTS, "Clients") }
        mac.editNavigation { moveToFolder(FolderScope.PROJECTS, fixture.projectId, folder) }
        mac.editNavigation { setLaneDescending(fixture.boardId, "todo", false) }
        mac.navigationKv.status.await(describe = { "mac delivered: ${mac.navigationKv.status.value}" }) { it.pending == 0 }

        phone.navigationKv.values.await(20.seconds, describe = { "phone sees the folder" }) { values ->
            NavigationLayout(values).folders(FolderScope.PROJECTS).any { it.name == "Clients" && it.itemIds == listOf(fixture.projectId) }
        }
        assertEquals(false, phone.layout().laneDescending(fixture.boardId, "todo"))

        // The phone renames while its machine is unreachable; the edit drains afterwards.
        fixture.daemonOffline()
        phone.connection.state.await { it.phase == ConnectionPhase.NO_MACHINE }
        phone.editNavigation { renameFolder(FolderScope.PROJECTS, folder, "Customers") }
        assertEquals("Customers", phone.layout().folders(FolderScope.PROJECTS).single().name, "the edit shows at once")
        assertEquals(1, phone.navigationKv.status.value.pending)
        fixture.daemonOnline()
        phone.navigationKv.status.await(45.seconds, describe = { "phone delivered: ${phone.navigationKv.status.value}" }) { it.pending == 0 }
        mac.navigationKv.values.await(45.seconds, describe = { "mac sees the rename" }) { values ->
            NavigationLayout(values).folders(FolderScope.PROJECTS).singleOrNull()?.name == "Customers"
        }
    }
}
