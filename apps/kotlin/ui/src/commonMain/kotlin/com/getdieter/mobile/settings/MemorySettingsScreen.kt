package com.getdieter.mobile.settings

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.getdieter.core.memory.MemoryForm
import com.getdieter.core.providers.AgentAccountRules
import com.getdieter.mobile.app.*
import com.getdieter.mobile.creation.AgentSettings
import com.getdieter.mobile.design.*
import com.getdieter.mobile.design.Tone
import com.getdieter.mobile.providers.rememberProviders
import com.getdieter.mobile.store.*

/**
 * Settings › Agent memory: the account's one memory setting, which decides whether and how dreams
 * keep projects' saved memories tidy. Projects turn memory on in their own settings. The core words
 * and checks it; the pickers show the edited machine's catalog.
 */
@Composable
internal fun MemorySettingsScreen(store: MobileStore) {
    val session by store.session.slice.collectAsState()
    val settings by store.memory.settings.collectAsState()
    val metadata by store.memory.metadata.collectAsState()
    val daemonId by store.memory.daemonId.collectAsState()
    val problem by store.memory.problem.collectAsState()
    val saving by store.memory.saving.collectAsState()
    val providers = rememberProviders(store)
    val available = MemoryForm.machine(session.machines)
    DisposableEffect(store) { onDispose(store.memory.show(session.machines)) }
    // A machine that comes online after the screen opened is read then.
    LaunchedEffect(available) {
        if (available != null && available != store.memory.daemonId.value)
            store.memory.load(session.machines)
    }
    val harnesses = MemoryForm.harnesses(metadata, daemonId)
    var draft by remember(settings) { mutableStateOf(settings) }
    val current = draft
    Screen(
        ScreenChrome(
            "Agent memory",
            subtitle = settings?.let { MemoryForm.status(it, harnesses) }.orEmpty(),
        )
    ) {
        LazyColumn(
            Modifier.fillMaxSize().imePadding().testTag("memory-settings"),
            state = listState,
            contentPadding = padding,
        ) {
            item("intro") {
                Spacer(Modifier.height(8.dp))
                SectionFooter(
                    "Turn memory on for a project in its settings. Dreams keep its saved " +
                        "memories tidy: an agent merges duplicates, retires outdated ones and " +
                        "adds what recent conversations settled. One setting for all your machines."
                )
            }
            if (problem.isNotEmpty())
                item("problem") {
                    Banner(
                        "Agent memory",
                        problem,
                        Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                        tone = Tone.DANGER,
                        actionLabel = "Retry",
                        onAction = { store.memory.load(session.machines) },
                    )
                }
            if (current == null) {
                if (problem.isEmpty())
                    item("loading") {
                        Box(
                            Modifier.fillMaxWidth().padding(40.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Spinner(Modifier.size(24.dp))
                        }
                    }
                return@LazyColumn
            }
            item("dreaming") {
                SectionHeader("Dreams")
                ListRow(
                    "Dream automatically",
                    position = Position.SINGLE,
                    subtitle = "On the schedule below; you can always start one from a project",
                    trailing = {
                        DSwitch(
                            current.dreaming,
                            { draft = current.copy(dreaming = it) },
                            Modifier.testTag("memory-dreaming"),
                        )
                    },
                )
            }
            item("agent") {
                SectionHeader("Dreamer")
                val accounts = AgentAccountRules.fromSlice(providers, current.run_on)
                AgentSettings(
                    if (harnesses.isEmpty()) null
                    else MemoryForm.agent(current, harnesses, accounts)
                ) { choice ->
                    draft = MemoryForm.choosing(current, harnesses, choice, accounts)
                }
                Group(listOf(0)) { _, position ->
                    PickerRow(
                        "Run on",
                        MemoryForm.runOnTitle(session.machines, current.run_on),
                        MemoryForm.runOnChoices(session.machines, current.run_on),
                        current.run_on,
                        true,
                        position,
                        Glyph.MACHINE,
                        tag = "memory-run-on",
                    ) {
                        draft = current.copy(run_on = it)
                    }
                }
                SectionFooter(
                    listOfNotNull(
                            MemoryForm.runOnDetail(current.run_on),
                            MemoryForm.DEFAULTS.takeIf { !current.configured },
                        )
                        .joinToString(" ")
                )
            }
            item("apply") {
                SectionHeader("Changes")
                Column(
                    Modifier.fillMaxWidth()
                        .padding(horizontal = ScreenMargin)
                        .clip(groupShape(Position.SINGLE))
                        .background(palette.cell)
                        .padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    val modes = MemoryForm.APPLY_MODES
                    Segmented(
                        modes.map(MemoryForm::applyTitle),
                        modes.indexOf(current.apply.ifEmpty { MemoryForm.AUTO }).coerceAtLeast(0),
                        { draft = current.copy(apply = modes[it]) },
                        testTagPrefix = "memory-apply",
                    )
                    Text(
                        MemoryForm.applyDetail(current.apply),
                        style = type.footnote,
                        color = palette.secondaryLabel,
                    )
                }
            }
            item("schedule") {
                SectionHeader("Schedule")
                Group(listOf(0, 1)) { index, position ->
                    if (index == 0)
                        StepperRow(
                            "Hours between dreams",
                            current.min_hours,
                            MemoryForm.MIN_HOURS,
                            position,
                            "memory-hours",
                        ) {
                            draft = current.copy(min_hours = it)
                        }
                    else
                        StepperRow(
                            "Finished conversations",
                            current.min_new_tasks,
                            MemoryForm.MIN_NEW_TASKS,
                            position,
                            "memory-tasks",
                        ) {
                            draft = current.copy(min_new_tasks = it)
                        }
                }
                Spacer(Modifier.height(8.dp))
                MobileTextField(
                    current.window,
                    { draft = current.copy(window = it) },
                    Modifier.fillMaxWidth()
                        .padding(horizontal = ScreenMargin)
                        .testTag("memory-window"),
                    label = { Text("Start window") },
                    placeholder = { Text("Any time") },
                    singleLine = true,
                )
                SectionFooter(
                    MemoryForm.windowProblem(current.window)
                        ?: "Local time on the dreaming machine, e.g. ${MemoryForm.DEFAULT_WINDOW}. " +
                            "Empty: any time."
                )
            }
            item("limits") {
                SectionHeader("Limits")
                Group(listOf(0, 1)) { index, position ->
                    if (index == 0)
                        StepperRow(
                            "Changes per dream",
                            current.max_operations,
                            MemoryForm.MAX_OPERATIONS,
                            position,
                            "memory-changes",
                        ) {
                            draft = current.copy(max_operations = it)
                        }
                    else
                        StepperRow(
                            "Retired at most (%)",
                            current.max_retire_percent,
                            MemoryForm.MAX_RETIRE_PERCENT,
                            position,
                            "memory-retire",
                        ) {
                            draft = current.copy(max_retire_percent = it)
                        }
                }
                SectionFooter("Dieter refuses a dream that goes beyond them.")
            }
            item("instructions") {
                SectionHeader("Extra instructions")
                MobileTextField(
                    current.instructions,
                    { draft = current.copy(instructions = it) },
                    Modifier.fillMaxWidth()
                        .padding(horizontal = ScreenMargin)
                        .testTag("memory-instructions"),
                    placeholder = { Text("What every dream should keep in mind") },
                    minLines = 3,
                    maxLines = 8,
                )
                SectionFooter("Added to every dream.")
            }
            item("save") {
                val invalid = MemoryForm.problem(current)
                Column(
                    Modifier.padding(horizontal = ScreenMargin, vertical = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    if (invalid != null && current != settings)
                        Text(
                            invalid,
                            Modifier.padding(horizontal = 16.dp),
                            style = type.footnote,
                            color = palette.destructive,
                        )
                    DButton(
                        "Save",
                        { store.memory.save(current) },
                        Modifier.fillMaxWidth().testTag("memory-save"),
                        large = true,
                        enabled =
                            invalid == null &&
                                !saving &&
                                daemonId != null &&
                                MemoryForm.changed(current, settings),
                        loading = saving,
                    )
                }
            }
        }
    }
}
