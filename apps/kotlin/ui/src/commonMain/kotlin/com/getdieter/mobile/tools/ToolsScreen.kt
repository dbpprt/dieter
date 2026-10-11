@file:OptIn(
    androidx.compose.foundation.layout.ExperimentalLayoutApi::class,
    androidx.compose.material3.ExperimentalMaterial3Api::class,
)

package com.getdieter.mobile.tools

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.screens.*
import com.getdieter.mobile.settings.SettingsScreen
import com.getdieter.mobile.store.*

/** "Project" and "Checkout" menus for project-scoped tools. */
internal fun projectScopeMenu(store: MobileStore, rebind: () -> Unit): List<ChromeAction> {
    val workspace = store.workspace.slice.value
    val current = store.boards.currentProjectId()
    val project = workspace.projects.firstOrNull { it.id == current }
    val checkout =
        store.boards.selectedCheckout.value
            .ifEmpty { store.creation.defaults.value.checkouts[current].orEmpty() }
            .ifEmpty { project?.checkouts?.singleOrNull()?.id.orEmpty() }
    val machines = store.session.slice.value.machines
    return listOfNotNull(
        ChromeAction(
            "scope-project",
            "Project",
            Glyph.FOLDER,
            subtitle = project?.name.orEmpty(),
            menu =
                listOf(
                    MenuSection(
                        workspace.projects.map { item ->
                            ChromeAction(
                                "scope-project-${item.id}",
                                item.name,
                                checked = item.id == current,
                            ) {
                                store.boards.selectedProject.value = item.id
                                store.boards.selectedCheckout.value = ""
                                rebind()
                            }
                        }
                    )
                ),
        ),
        if ((project?.checkouts?.size ?: 0) > 1)
            ChromeAction(
                "scope-checkout",
                "Checkout",
                Glyph.MACHINE,
                menu =
                    listOf(
                        MenuSection(
                            project!!.checkouts.map { item ->
                                ChromeAction(
                                    "scope-checkout-${item.id}",
                                    (machines.firstOrNull { it.id == item.daemon_id }?.display_name
                                        ?: item.name) + " · " + item.name,
                                    checked = item.id == checkout,
                                ) {
                                    store.boards.selectedCheckout.value = item.id
                                    rebind()
                                }
                            }
                        )
                    ),
            )
        else null,
    )
}

@Composable
internal fun ToolScreen(store: MobileStore, page: ToolPage) {
    when (page) {
        ToolPage.MACHINES -> MachinesScreen(store)
        ToolPage.TERMINALS -> TerminalsScreen(store)
        ToolPage.SCREENS -> ScreensScreen(store)
        ToolPage.FILES -> FilesScreen(store)
        ToolPage.CHANGES -> ProjectChangesScreen(store)
        ToolPage.SCHEDULES -> SchedulesScreen(store)
        ToolPage.USAGE -> UsageScreen(store)
        ToolPage.SETTINGS -> SettingsScreen(store)
    }
}

@Composable
internal fun ToolsScreen(store: MobileStore) {
    val session by store.session.slice.collectAsState()
    val workspace by store.workspace.slice.collectAsState()
    val quotas by store.machines.quotas.collectAsState()
    val selectedProject by store.boards.selectedProject.collectAsState()
    val project = workspace.projects.firstOrNull { it.id == store.boards.currentProjectId() }
    val online = session.machines.count { it.online }
    Screen(ScreenChrome("Tools", large = true)) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("tools-list"),
            state = listState,
            contentPadding = padding,
        ) {
            titleHeader()
            item { ConnectionNotice(store) }
            item { SectionHeader("Machines") }
            item {
                Group(listOf(ToolPage.MACHINES, ToolPage.TERMINALS, ToolPage.SCREENS)) {
                    page,
                    position ->
                    ListRow(
                        page.title,
                        Modifier.testTag("tool-${page.name.lowercase()}"),
                        position = position,
                        glyph = page.glyph,
                        tile = page.color,
                        value =
                            when (page) {
                                ToolPage.MACHINES ->
                                    if (session.machines.isEmpty()) ""
                                    else "$online of ${session.machines.size} online"
                                else -> null
                            },
                        accessory = Accessory.CHEVRON,
                        onClick = {
                            store.showFrom(
                                MobileRoute.Root(MobileTab.TOOLS),
                                MobileRoute.Tool(page),
                            )
                        },
                    )
                }
            }
            item {
                SectionHeader(
                    "Workspace",
                    trailing = {
                        if (project != null)
                            Text(
                                project.name,
                                style = type.footnote,
                                color = palette.secondaryLabel,
                            )
                    },
                )
            }
            item {
                Group(listOf(ToolPage.FILES, ToolPage.CHANGES, ToolPage.SCHEDULES)) { page, position
                    ->
                    ListRow(
                        page.title,
                        Modifier.testTag("tool-${page.name.lowercase()}"),
                        position = position,
                        glyph = page.glyph,
                        tile = page.color,
                        accessory = Accessory.CHEVRON,
                        onClick = {
                            store.showFrom(
                                MobileRoute.Root(MobileTab.TOOLS),
                                MobileRoute.Tool(
                                    page,
                                    selectedProject.ifEmpty { project?.id.orEmpty() },
                                ),
                            )
                        },
                    )
                }
            }
            item { SectionHeader("Account") }
            item {
                Group(listOf(ToolPage.USAGE, ToolPage.SETTINGS)) { page, position ->
                    val lowest =
                        quotas.group_rows
                            .filter { it.lowest_remaining >= 0 }
                            .minOfOrNull { it.lowest_remaining }
                    ListRow(
                        page.title,
                        Modifier.testTag("tool-${page.name.lowercase()}"),
                        position = position,
                        glyph = page.glyph,
                        tile = page.color,
                        value =
                            if (page == ToolPage.USAGE && lowest != null) "$lowest% left" else null,
                        accessory = Accessory.CHEVRON,
                        onClick = {
                            store.showFrom(
                                MobileRoute.Root(MobileTab.TOOLS),
                                MobileRoute.Tool(page),
                            )
                        },
                    )
                }
            }
        }
    }
}
