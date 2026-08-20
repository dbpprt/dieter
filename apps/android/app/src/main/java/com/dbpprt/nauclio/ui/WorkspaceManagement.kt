@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.nauclio.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.PrimaryTabRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.graphics.toColorInt
import com.dbpprt.nauclio.ui.theme.NauclioAegean
import com.dbpprt.nauclio.ui.theme.NauclioMuted
import com.dbpprt.nauclio.ui.theme.NauclioOutline
import com.dbpprt.nauclio.ui.theme.NauclioSurfaceHigh
import com.dbpprt.nauclio.v1.Settings
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlin.random.Random

private enum class ManagementSection(val label: String) {
    PROJECT("Project"),
    BOARD("Board"),
    LIMITS("Limits"),
    ARCHIVES("Archives"),
}

internal data class LabelColorOption(val name: String, val value: String)

internal val LabelColorPalette = listOf(
    LabelColorOption("Ruby", "#d95c68"),
    LabelColorOption("Coral", "#df7650"),
    LabelColorOption("Amber", "#c9952f"),
    LabelColorOption("Lime", "#7d9e45"),
    LabelColorOption("Emerald", "#3e9970"),
    LabelColorOption("Teal", "#379799"),
    LabelColorOption("Sky", "#478dc5"),
    LabelColorOption("Indigo", "#626fd0"),
    LabelColorOption("Violet", "#8a62c3"),
    LabelColorOption("Rose", "#c65f98"),
)

internal fun randomLabelColor(exclude: String = "", random: Random = Random.Default): String {
    val choices = LabelColorPalette.filterNot { it.value.equals(exclude, ignoreCase = true) }
    val available = choices.ifEmpty { LabelColorPalette }
    return available[random.nextInt(available.size)].value
}

@Composable
fun WorkspaceManagementScreen(
    state: NauclioUiState,
    model: NauclioViewModel,
    contentPadding: PaddingValues,
) {
    val sections = ManagementSection.entries
    val pagerState = rememberPagerState(initialPage = 0, pageCount = { sections.size })
    val scope = rememberCoroutineScope()
    LaunchedEffect(pagerState) {
        snapshotFlow { pagerState.settledPage }
            .distinctUntilChanged()
            .collect { page ->
                if (sections[page] == ManagementSection.ARCHIVES || sections[page] == ManagementSection.LIMITS) {
                    model.loadAdministration()
                }
            }
    }
    Column(Modifier.fillMaxSize().padding(contentPadding)) {
        CreationHeader(
            eyebrow = "Local Nauclio",
            title = "Workspace settings",
            subtitle = state.project?.name,
            onClose = model::closeSurface,
            trailing = {
                Button(onClick = { model.openSurface(AppSurface.NEW_PROJECT) }) { Text("Add project") }
            },
        )
        SurfaceErrorBanner(state.error, model::clearError)
        PrimaryTabRow(
            selectedTabIndex = pagerState.currentPage,
            containerColor = MaterialTheme.colorScheme.background,
        ) {
            sections.forEachIndexed { index, item ->
                Tab(
                    selected = pagerState.currentPage == index,
                    onClick = { scope.launch { pagerState.animateScrollToPage(index) } },
                    text = { Text(item.label, fontSize = 13.sp, maxLines = 1) },
                )
            }
        }
        HorizontalPager(
            state = pagerState,
            modifier = Modifier.fillMaxWidth().weight(1f),
            beyondViewportPageCount = 1,
            key = { sections[it] },
        ) { page ->
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)) {
                when (sections[page]) {
                    ManagementSection.PROJECT -> ProjectManagement(state, model)
                    ManagementSection.BOARD -> BoardManagement(state, model)
                    ManagementSection.LIMITS -> LimitsManagement(state, model)
                    ManagementSection.ARCHIVES -> ArchivesManagement(state, model)
                }
                Spacer(Modifier.height(32.dp))
            }
        }
    }
}

@Composable
fun NewProjectScreen(
    state: NauclioUiState,
    model: NauclioViewModel,
    contentPadding: PaddingValues,
) {
    Column(Modifier.fillMaxSize().padding(contentPadding)) {
        CreationHeader(
            eyebrow = "New workspace",
            title = "Add a Git project",
            onClose = { model.openSurface(AppSurface.WORKSPACE) },
        )
        SurfaceErrorBanner(state.error, model::clearError)
        Column(
            Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            AddProjectManagement(state, model)
            Spacer(Modifier.height(32.dp))
        }
    }
}

@Composable
private fun ProjectManagement(state: NauclioUiState, model: NauclioViewModel) {
    val project = state.project
    var name by remember(project?.id, project?.name) { mutableStateOf(project?.name.orEmpty()) }
    var summary by remember(project?.id, project?.summary) { mutableStateOf(project?.summary.orEmpty()) }
    var prompt by remember(project?.id, project?.prompt) { mutableStateOf(project?.prompt.orEmpty()) }
    var confirmArchive by remember { mutableStateOf(false) }
    SectionTitle("Project")
    if (project == null) {
        Text("Select or add a project.", color = NauclioMuted)
        return
    }
    Text(project.path, color = NauclioMuted, style = MaterialTheme.typography.bodySmall)
    Spacer(Modifier.height(8.dp))
    OutlinedTextField(name, { name = it }, label = { Text("Name") }, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(summary, { summary = it }, label = { Text("Summary") }, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(prompt, { prompt = it }, label = { Text("Project instructions") }, minLines = 4, modifier = Modifier.fillMaxWidth())
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 10.dp)) {
        Button(onClick = { model.updateProject(name, summary, prompt) }, enabled = !state.working) { Text("Save project") }
        OutlinedButton(onClick = { confirmArchive = true }, enabled = !state.working) { Text("Archive") }
    }
    if (confirmArchive) {
        AlertDialog(
            onDismissRequest = { confirmArchive = false },
            title = { Text("Archive ${project.name}?") },
            text = { Text("The working tree is untouched. The project can be restored from Archives.") },
            confirmButton = { Button(onClick = { confirmArchive = false; model.archiveCurrentProject() }) { Text("Archive") } },
            dismissButton = { TextButton(onClick = { confirmArchive = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun BoardManagement(state: NauclioUiState, model: NauclioViewModel) {
    val board = state.board
    var newBoardName by remember { mutableStateOf("") }
    var workflow by remember { mutableStateOf("review") }
    var description by remember { mutableStateOf("") }
    var labelName by remember { mutableStateOf("") }
    var labelColor by remember(board?.id) { mutableStateOf(randomLabelColor()) }
    SectionTitle("Current board")
    if (board != null) {
        Text(board.name, fontWeight = FontWeight.SemiBold)
        Text(board.description.ifBlank { "${board.workflow} workflow" }, color = NauclioMuted)
        Text("Archive completed cards", color = NauclioMuted, modifier = Modifier.padding(top = 8.dp))
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            listOf("never", "immediately", "after_1_day", "after_7_days", "after_30_days", "after_90_days").forEach { policy ->
                FilterChip(
                    selected = board.doneArchivePolicy == policy,
                    onClick = { model.setBoardArchivePolicy(policy) },
                    label = { Text(policy.replace('_', ' ')) },
                )
            }
        }
        SectionTitle("Labels")
        board.labelsList.forEach { label ->
            Row(
                Modifier.fillMaxWidth().padding(vertical = 3.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ManagementLabelPill(label.name, label.color)
                TextButton(onClick = { model.deleteBoardLabel(label.id) }) { Text("Delete") }
            }
        }
        OutlinedTextField(labelName, { labelName = it }, label = { Text("New label") }, modifier = Modifier.fillMaxWidth())
        LabelColorPicker(labelColor, onSelected = { labelColor = it }, enabled = !state.working)
        Button(
            onClick = {
                val previousColor = labelColor
                model.createBoardLabel(labelName, labelColor)
                labelName = ""
                labelColor = randomLabelColor(previousColor)
            },
            enabled = labelName.isNotBlank() && !state.working,
            modifier = Modifier.padding(top = 8.dp),
        ) { Text("Add label") }
    }
    HorizontalDivider(Modifier.padding(vertical = 14.dp))
    SectionTitle("Create board")
    OutlinedTextField(newBoardName, { newBoardName = it }, label = { Text("Board name") }, modifier = Modifier.fillMaxWidth())
    OutlinedTextField(description, { description = it }, label = { Text("Description") }, modifier = Modifier.fillMaxWidth())
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FilterChip(selected = workflow == "review", onClick = { workflow = "review" }, label = { Text("Review") })
        FilterChip(selected = workflow == "direct", onClick = { workflow = "direct" }, label = { Text("Direct") })
    }
    Button(
        onClick = { model.createBoard(newBoardName, workflow, description); newBoardName = "" },
        enabled = newBoardName.isNotBlank() && state.selectedProjectId.isNotBlank() && !state.working,
    ) { Text("Create board") }
}

@Composable
private fun LabelColorPicker(selectedColor: String, onSelected: (String) -> Unit, enabled: Boolean) {
    val selected = LabelColorPalette.firstOrNull { it.value.equals(selectedColor, ignoreCase = true) }
        ?: LabelColorPalette.first()
    Column(
        Modifier.padding(top = 10.dp).widthIn(max = 340.dp),
        verticalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Color", fontWeight = FontWeight.Medium)
            Text(selected.name, color = NauclioMuted, fontSize = 12.sp)
        }
        LabelColorPalette.chunked(5).forEach { colors ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                colors.forEach { option ->
                    val color = Color(option.value.toColorInt())
                    val isSelected = option.value.equals(selected.value, ignoreCase = true)
                    Box(
                        Modifier.size(46.dp)
                            .clip(CircleShape)
                            .selectable(
                                selected = isSelected,
                                enabled = enabled,
                                onClick = { onSelected(option.value) },
                            )
                            .semantics { contentDescription = "${option.name} label color" }
                            .border(
                                width = if (isSelected) 2.dp else 1.dp,
                                color = if (isSelected) NauclioAegean else NauclioOutline,
                                shape = CircleShape,
                            )
                            .padding(4.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Box(Modifier.fillMaxSize().clip(CircleShape).background(color))
                        if (isSelected) {
                            androidx.compose.material3.Icon(
                                Icons.Default.Check,
                                contentDescription = null,
                                tint = if (color.luminance() > 0.32f) Color(0xFF071426) else Color.White,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ManagementLabelPill(name: String, colorValue: String) {
    val color = runCatching { Color(colorValue.toColorInt()) }.getOrDefault(NauclioAegean)
    Surface(shape = RoundedCornerShape(50), color = color.copy(alpha = 0.16f)) {
        Row(
            Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
            horizontalArrangement = Arrangement.spacedBy(7.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.size(7.dp).clip(CircleShape).background(color))
            Text(name, color = color, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun LimitsManagement(state: NauclioUiState, model: NauclioViewModel) {
    val current = state.settings
    val options = state.settingsOptions
    var global by remember(current?.updatedAt) { mutableStateOf((current?.globalParallelLimit ?: 0).toString()) }
    var agentLimits by remember(current?.updatedAt, options) {
        mutableStateOf(current?.agentParallelLimitsMap.orEmpty().mapValues { it.value.toString() })
    }
    var boardLimits by remember(current?.updatedAt, options) {
        mutableStateOf(current?.boardParallelLimitsMap.orEmpty().mapValues { it.value.toString() })
    }
    SectionTitle("Admission limits")
    Text("All HTTP, CLI, Android, and scheduled starts share these limits.", color = NauclioMuted)
    OutlinedTextField(
        global,
        { global = it.filter(Char::isDigit) },
        label = { Text("Global parallel sessions") },
        modifier = Modifier.fillMaxWidth(),
    )
    SectionTitle("Per agent")
    options?.agents?.harnessesList.orEmpty().forEach { harness ->
        OutlinedTextField(
            value = agentLimits[harness.id] ?: "0",
            onValueChange = { value -> agentLimits = agentLimits + (harness.id to value.filter(Char::isDigit)) },
            label = { Text("${harness.name} sessions") },
            supportingText = { Text(harness.id) },
            modifier = Modifier.fillMaxWidth(),
        )
    }
    SectionTitle("Per board")
    options?.boardsList.orEmpty().forEach { board ->
        val project = options?.projectsList?.firstOrNull { it.id == board.projectId }?.name.orEmpty()
        OutlinedTextField(
            value = boardLimits[board.id] ?: "0",
            onValueChange = { value -> boardLimits = boardLimits + (board.id to value.filter(Char::isDigit)) },
            label = { Text("${board.name} sessions") },
            supportingText = { if (project.isNotBlank()) Text(project) },
            modifier = Modifier.fillMaxWidth(),
        )
    }
    Button(
        onClick = {
            val value = global.toIntOrNull() ?: return@Button
            val updated = (current ?: Settings.getDefaultInstance()).toBuilder()
                .setGlobalParallelLimit(value)
                .clearAgentParallelLimits()
                .putAllAgentParallelLimits(agentLimits.mapValues { it.value.toIntOrNull() ?: 0 })
                .clearBoardParallelLimits()
                .putAllBoardParallelLimits(boardLimits.mapValues { it.value.toIntOrNull() ?: 0 })
                .build()
            model.updateSettings(updated)
        },
        enabled = global.toIntOrNull() != null && !state.working,
        modifier = Modifier.padding(top = 8.dp),
    ) { Text("Save limits") }
    Text("Use 0 for no override.", color = NauclioMuted, style = MaterialTheme.typography.bodySmall)
}

@Composable
private fun ArchivesManagement(state: NauclioUiState, model: NauclioViewModel) {
    SectionTitle("Archived projects")
    if (state.archivedProjects.isEmpty()) Text("No archived projects", color = NauclioMuted)
    state.archivedProjects.forEach { project ->
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(project.name, Modifier.weight(1f))
            TextButton(onClick = { model.restoreProject(project) }) { Text("Restore") }
        }
    }
    SectionTitle("Archived cards")
    if (state.archivedCards.isEmpty()) Text("No archived cards in this board", color = NauclioMuted)
    state.archivedCards.forEach { card ->
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(card.title, Modifier.weight(1f))
            TextButton(onClick = { model.restoreCard(card) }) { Text("Restore") }
        }
    }
}

@Composable
private fun AddProjectManagement(state: NauclioUiState, model: NauclioViewModel) {
    var mode by remember { mutableStateOf("open") }
    var path by remember { mutableStateOf("") }
    var name by remember { mutableStateOf("") }
    var prompt by remember { mutableStateOf("") }
    var boardName by remember { mutableStateOf("Main") }
    var workflow by remember { mutableStateOf("review") }
    var workflowOpen by remember { mutableStateOf(false) }
    var showBrowser by remember { mutableStateOf(false) }
    LaunchedEffect(showBrowser, state.directoryListing?.path) {
        if (!showBrowser) return@LaunchedEffect
        state.directoryListing?.path?.takeIf { it.isNotBlank() }?.let { path = it }
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        FilterChip(
            selected = mode == "open",
            onClick = { mode = "open" },
            label = { Text("✓  Existing Git repo") },
            modifier = Modifier.weight(1f),
        )
        FilterChip(
            selected = mode == "create",
            onClick = { mode = "create" },
            label = { Text("New Git project") },
            modifier = Modifier.weight(1f),
        )
    }
    Spacer(Modifier.height(10.dp))
    Text(if (mode == "create") "New project path" else "Git working tree", color = NauclioMuted, style = MaterialTheme.typography.labelMedium)
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(
            path,
            { path = it },
            placeholder = { Text("/Users/you/Development/project") },
            singleLine = true,
            modifier = Modifier.weight(1f),
        )
        OutlinedButton(
            onClick = { showBrowser = true; model.listDirectories(path) },
            modifier = Modifier.height(56.dp),
        ) { Text("Browse") }
    }
    if (showBrowser) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
            state.directoryListing?.parent?.takeIf { it.isNotBlank() }?.let { parent ->
                OutlinedButton(onClick = { path = parent; model.listDirectories(parent) }) { Text("Parent") }
            }
            TextButton(onClick = { showBrowser = false }) { Text("Close browser") }
        }
        if ((state.directoryListing?.locationsCount ?: 0) > 0) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                state.directoryListing?.locationsList.orEmpty().forEach { location ->
                    FilterChip(
                        selected = path == location.path,
                        onClick = { path = location.path; model.listDirectories(location.path) },
                        label = { Text(location.name) },
                    )
                }
            }
        }
        state.directoryListing?.entriesList.orEmpty().filterNot { it.name.startsWith('.') }.take(10).forEach { entry ->
            TextButton(onClick = { path = entry.path; model.listDirectories(entry.path) }, modifier = Modifier.fillMaxWidth()) {
                Text("${if (entry.gitRepository) "Git · " else ""}${entry.name}", modifier = Modifier.fillMaxWidth())
            }
        }
    }
    Spacer(Modifier.height(10.dp))
    OutlinedTextField(name, { name = it }, label = { Text("Project name") }, modifier = Modifier.fillMaxWidth())
    Text("Optional; the directory name is used by default.", color = NauclioMuted, style = MaterialTheme.typography.bodySmall)
    Spacer(Modifier.height(14.dp))
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        OutlinedTextField(boardName, { boardName = it }, label = { Text("First board") }, modifier = Modifier.weight(1f))
        Box(Modifier.weight(1f)) {
            OutlinedButton(onClick = { workflowOpen = true }, modifier = Modifier.fillMaxWidth().height(56.dp)) {
                Text(if (workflow == "review") "With review" else "Direct workflow")
            }
            DropdownMenu(expanded = workflowOpen, onDismissRequest = { workflowOpen = false }) {
                DropdownMenuItem(text = { Text("With review") }, onClick = { workflow = "review"; workflowOpen = false })
                DropdownMenuItem(text = { Text("Direct workflow") }, onClick = { workflow = "direct"; workflowOpen = false })
            }
        }
    }
    Spacer(Modifier.height(8.dp))
    OutlinedTextField(
        prompt,
        { prompt = it },
        label = { Text("Project instructions") },
        placeholder = { Text("How should agents work in this project?") },
        minLines = 7,
        modifier = Modifier.fillMaxWidth(),
    )
    Text("Stored centrally and included in every new card conversation.", color = NauclioMuted, style = MaterialTheme.typography.bodySmall)
    Row(Modifier.fillMaxWidth().padding(top = 18.dp), horizontalArrangement = Arrangement.End) {
        TextButton(onClick = { model.openSurface(AppSurface.WORKSPACE) }) { Text("Cancel") }
        Button(
            onClick = { model.createProject(mode, path, name, "", prompt, boardName, workflow) },
            enabled = path.isNotBlank() && !state.working,
        ) { Text("＋  Add project") }
    }
}

@Composable
private fun SectionTitle(value: String) {
    Text(value, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(vertical = 8.dp))
}
