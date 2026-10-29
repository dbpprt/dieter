@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.getdieter.mobile.admin

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.*
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*

@Composable
internal fun ProjectEditor(store: MobileStore, onDismiss: () -> Unit) {
    val session by store.session.slice.collectAsState()
    val busy by store.busy.collectAsState()
    var name by remember { mutableStateOf("") }
    var path by remember { mutableStateOf("") }
    var machine by remember { mutableStateOf("") }
    var create by remember { mutableStateOf(false) }
    var review by remember { mutableStateOf(true) }
    val machines = session.machines.filter { it.available }
    Sheet(
        "New Project",
        onDismiss,
        confirm =
            ChromeAction(
                "create-project",
                "Create",
                Glyph.CHECK,
                enabled = name.isNotBlank() && path.isNotBlank() && machine.isNotBlank() && !busy,
            ) {
                store.action {
                    val result =
                        store.core.dispatch(
                            Command(
                                admin =
                                    AdminCommand(
                                        create_project =
                                            AdminCreateProject(
                                                daemon_id = machine,
                                                path = path,
                                                name = name,
                                                create = create,
                                                board_name = "Main",
                                                workflow = if (review) "review" else "direct",
                                            )
                                    )
                            )
                        )
                    onDismiss()
                    result.created_project?.board?.let { store.push(MobileRoute.Board(it.id)) }
                }
            },
    ) {
        Group(listOf(0)) { _, position ->
            PickerRow(
                "Machine",
                machines.firstOrNull { it.id == machine }?.display_name.orEmpty(),
                machines.map { it.id to it.display_name },
                machine,
                machines.isNotEmpty(),
                position,
                Glyph.MACHINE,
            ) {
                machine = it
            }
        }
        Spacer(Modifier.height(16.dp))
        FormColumn {
            MobileTextField(
                name,
                { name = it },
                Modifier.fillMaxWidth().testTag("project-name"),
                label = { Text("Name") },
                placeholder = { Text("Project name") },
                singleLine = true,
            )
            MobileTextField(
                path,
                { path = it },
                Modifier.fillMaxWidth().testTag("project-path"),
                label = { Text("Path") },
                placeholder = { Text("Repository path on the machine") },
                singleLine = true,
            )
        }
        SectionHeader("Options")
        Group(listOf(0, 1)) { index, position ->
            if (index == 0)
                ListRow(
                    "Create a new Git repository",
                    position = position,
                    trailing = { DSwitch(create, { create = it }) },
                )
            else
                ListRow(
                    "Review before merging",
                    position = position,
                    subtitle = "Cards move to Review before Done",
                    trailing = { DSwitch(review, { review = it }) },
                )
        }
    }
}
