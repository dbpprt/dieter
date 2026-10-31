package com.getdieter.mobile.tools

import androidx.compose.runtime.*
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.settings.DevicesScreen
import com.getdieter.mobile.settings.SettingsScreen
import com.getdieter.mobile.store.*

@Composable
internal fun ToolScreen(store: MobileStore, route: MobileRoute.Tool) {
    when (route.page) {
        ToolPage.TERMINALS -> TerminalsScreen(store)
        ToolPage.FILES -> FilesScreen(store, tool = route)
        ToolPage.CHANGES -> ProjectChangesScreen(store, route)
        ToolPage.SCHEDULES -> SchedulesScreen(store, route.projectId)
        ToolPage.USAGE -> UsageScreen(store)
        ToolPage.DEVICES -> DevicesScreen(store)
        ToolPage.SETTINGS -> SettingsScreen(store)
    }
}

/** "Project · Machine": what a project tool shows, so its scope is never a guess. */
@Composable
internal fun scopeSubtitle(store: MobileStore, projectId: String, daemonId: String): String {
    val workspace by store.workspace.slice.collectAsState()
    val session by store.session.slice.collectAsState()
    return listOfNotNull(
            workspace.projects.firstOrNull { it.id == projectId }?.name,
            session.machines.firstOrNull { it.id == daemonId }?.display_name,
        )
        .joinToString(" · ")
}

/**
 * The checkout menu of a project tool whose project has several checkouts. Choosing one replaces
 * the route, so back and other tabs keep their own scope.
 */
internal fun checkoutMenu(store: MobileStore, route: MobileRoute.Tool): ChromeAction? {
    val project =
        store.workspace.slice.value.projects.firstOrNull { it.id == route.projectId } ?: return null
    if (project.checkouts.size < 2) return null
    val shown = store.toolCheckout(route)?.id
    val machines = store.session.slice.value.machines
    return ChromeAction(
        "scope-checkout",
        "Checkout",
        Glyph.MACHINE,
        menu =
            listOf(
                MenuSection(
                    project.checkouts.map { checkout ->
                        val machine = machines.firstOrNull { it.id == checkout.daemon_id }
                        ChromeAction(
                            "scope-checkout-${checkout.id}",
                            machine?.display_name ?: checkout.name,
                            subtitle = checkout.path,
                            checked = checkout.id == shown,
                            enabled = !checkout.detached,
                        ) {
                            if (checkout.id != shown)
                                store.replaceTop(route.copy(checkoutId = checkout.id))
                        }
                    },
                    title = "Checkout",
                )
            ),
    )
}
