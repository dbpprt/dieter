package com.dbpprt.dieter.core.composition

import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.client.v1.ChatDestinationMachine
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ChatDestinationsTest {
    private val studio = ChatDestinationMachine(daemon_id = "d-studio", id = "studio", name = "Studio", online = true, version = "1.2.0")
    private val laptop = ChatDestinationMachine(daemon_id = "d-laptop", id = "laptop", name = "Air", online = false)

    private fun project(id: String, name: String, vararg checkouts: Checkout) = Project(id = id, name = name, checkouts = checkouts.toList())

    @Test
    fun checkoutsGroupByMachineOnlineFirstThenByName() {
        val app = project(
            "p-app", "app",
            Checkout(id = "c1", daemon_id = "d-studio", path = "/Users/me/src/app"),
            Checkout(id = "c2", daemon_id = "d-laptop", path = "/Users/me/app"),
            Checkout(id = "gone", daemon_id = "d-studio", detached = true),
        )
        val api = project("p-api", "API", Checkout(id = "c3", daemon_id = "d-studio", path = "/srv/api"))
        val orphan = project("p-old", "Old", Checkout(id = "c4", daemon_id = "d-unknown"))
        val groups = ChatDestinations.groups(listOf(app, api, orphan), listOf(laptop, studio))
        assertEquals(listOf("studio", "laptop", "unavailable:d-unknown"), groups.map { it.machine_id }, "online first, then by name")
        assertEquals("Studio · Online", groups[0].title)
        assertEquals(listOf("c3", "c1"), groups[0].destinations.map { it.checkout_id }, "by project name; detached checkouts are left out")
        assertEquals("Online · ~/src/app", groups[0].destinations[1].detail)
        assertEquals("app · Studio", groups[0].destinations[1].title)
        assertEquals("Offline · ~/app", groups[1].destinations.single().detail)
    }

    @Test
    fun theSameProjectTwiceOnAMachineIsToldApartByItsCheckout() {
        val app = project(
            "p-app", "app",
            Checkout(id = "c1", daemon_id = "d-studio", name = "Release", path = "/src/app"),
            Checkout(id = "c2", daemon_id = "d-studio", path = "/src/app-next/"),
        )
        val titles = ChatDestinations.groups(listOf(app), listOf(studio)).single().destinations.map { it.option_title }
        assertEquals(listOf("app · Release", "app · app-next"), titles)
    }

    @Test
    fun thePreferredDestinationFollowsCheckoutThenMachineThenProject() {
        val app = project("p-app", "app", Checkout(id = "c1", daemon_id = "d-studio"), Checkout(id = "c2", daemon_id = "d-laptop"))
        val api = project("p-api", "api", Checkout(id = "c3", daemon_id = "d-studio"))
        val groups = ChatDestinations.groups(listOf(app, api), listOf(studio, laptop))
        assertEquals("c2", ChatDestinations.preferred(groups, "studio", "p-app", "c2")?.checkout_id, "the chosen checkout wins")
        assertEquals("c1", ChatDestinations.preferred(groups, "studio", "p-app", "")?.checkout_id)
        assertEquals("c3", ChatDestinations.preferred(groups, "studio", "", "")?.checkout_id, "the machine's first, by name")
        assertEquals("c1", ChatDestinations.preferred(groups, "missing", "p-app", "")?.checkout_id, "else the project on the first machine listing it")
        assertNull(ChatDestinations.preferred(emptyList(), "studio", "p-app", "c1"))
    }
}
