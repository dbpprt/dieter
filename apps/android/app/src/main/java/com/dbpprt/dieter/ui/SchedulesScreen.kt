@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.DeleteOutline
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterPane
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.v1.Schedule
import com.dbpprt.dieter.ui.theme.DieterShellTint
import com.dbpprt.dieter.ui.theme.DieterAbyss

@Composable
fun SchedulesScreen(state: DieterUiState, model: DieterViewModel, contentPadding: PaddingValues) {
    Box(Modifier.fillMaxSize().padding(contentPadding)) {
        Column(Modifier.fillMaxSize()) {
            SimpleScreenHeader(
                "Schedules",
                "${state.project?.name?.lowercase() ?: "project"} · ${state.schedulesTotalCount} configured",
            ) {
                IconButton(onClick = model::refreshSchedules) { Icon(Icons.Outlined.Refresh, "Refresh schedules") }
                IconButton(onClick = { model.openSurface(AppSurface.APP_SETTINGS) }) {
                    Icon(Icons.Outlined.Settings, "App settings", tint = DieterMuted)
                }
            }
            SurfaceErrorBanner(state.error, model::clearError)
            if (!state.connected && state.projects.isEmpty()) {
                ConnectionEmptyState(state, model)
            } else if (state.schedulesLoading && state.schedules.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            } else if (state.schedules.isEmpty()) {
                ScheduleEmptyState { model.openSurface(AppSurface.SCHEDULE_EDITOR) }
            } else {
                LazyColumn(
                    contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 96.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    state.schedules.forEach { schedule ->
                        item(key = schedule.id) {
                            ScheduleCard(schedule, state, model, onEdit = { model.openSurface(AppSurface.SCHEDULE_EDITOR, schedule) })
                        }
                        if (state.selectedScheduleId == schedule.id) {
                            item(key = "${schedule.id}-runs-heading") {
                                Row(
                                    Modifier.fillMaxWidth().padding(horizontal = 4.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                ) {
                                    Text("Recent runs", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                                    if (state.scheduleRunsLoading) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                                }
                            }
                            if (!state.scheduleRunsLoading && state.scheduleRuns.isEmpty()) {
                                item(key = "${schedule.id}-runs-empty") {
                                    Text("No occurrences yet", color = DieterMuted, fontSize = 12.sp, modifier = Modifier.padding(horizontal = 4.dp))
                                }
                            }
                            items(state.scheduleRuns, key = { it.id }) { run -> ScheduleRunRow(run) }
                            if (state.scheduleRunsNextPageToken.isNotBlank()) {
                                item(key = "${schedule.id}-runs-more") {
                                    OutlinedButton(
                                        onClick = model::loadMoreScheduleRuns,
                                        enabled = !state.scheduleRunsLoadingMore,
                                        modifier = Modifier.fillMaxWidth(),
                                    ) {
                                        if (state.scheduleRunsLoadingMore) {
                                            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                                            Spacer(Modifier.width(8.dp))
                                        }
                                        Text(if (state.scheduleRunsLoadingMore) "Loading older runs…" else "Load older runs")
                                    }
                                }
                            }
                        }
                    }
                    if (state.schedulesNextPageToken.isNotBlank()) {
                        item(key = "schedules-load-more") {
                            OutlinedButton(
                                onClick = model::loadMoreSchedules,
                                enabled = !state.schedulesLoadingMore,
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                if (state.schedulesLoadingMore) {
                                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                                    Spacer(Modifier.width(8.dp))
                                }
                                Text(if (state.schedulesLoadingMore) "Loading schedules…" else "Load more schedules")
                            }
                        }
                    }
                }
            }
        }
        if (state.schedules.isNotEmpty()) {
            ExtendedFloatingActionButton(
                onClick = { model.openSurface(AppSurface.SCHEDULE_EDITOR) },
                icon = { Icon(Icons.Default.Add, null) },
                text = { Text("New schedule", fontWeight = FontWeight.SemiBold) },
                modifier = Modifier.align(Alignment.BottomEnd).padding(16.dp).height(52.dp).testTag("new-schedule"),
                containerColor = DieterPane,
                contentColor = DieterAbyss,
                shape = RoundedCornerShape(50),
            )
        }
    }
}

@Composable
internal fun ScheduleEmptyState(onCreate: () -> Unit) {
    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        Column(
            Modifier.fillMaxWidth()
                .dashedBorder(DieterOutline.copy(alpha = 0.9f), cornerRadius = 24.dp)
                .padding(horizontal = 28.dp, vertical = 34.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Surface(shape = RoundedCornerShape(18.dp), color = DieterShellTint, modifier = Modifier.size(64.dp)) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Outlined.CalendarMonth, null, tint = DieterShell, modifier = Modifier.size(28.dp))
                }
            }
            Spacer(Modifier.height(18.dp))
            Text("Automate recurring work", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))
            Text(
                "Create cards on a project calendar, then optionally start their local agents when capacity is available.",
                color = DieterMuted,
                fontSize = 13.sp,
                lineHeight = 19.sp,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(18.dp))
            Button(
                onClick = onCreate,
                shape = RoundedCornerShape(50),
                modifier = Modifier.testTag("new-schedule"),
            ) {
                Icon(Icons.Default.Add, null, Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("Create the first schedule")
            }
        }
    }
}

@Composable
internal fun ScheduleCard(
    schedule: Schedule,
    state: DieterUiState,
    model: DieterViewModel,
    onEdit: () -> Unit,
) {
    var confirmDelete by remember { mutableStateOf(false) }
    Card(
        onClick = { model.selectSchedule(if (state.selectedScheduleId == schedule.id) null else schedule) },
        colors = CardDefaults.cardColors(containerColor = DieterSurfaceHigh),
        shape = RoundedCornerShape(18.dp),
    ) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(schedule.name, fontWeight = FontWeight.SemiBold)
                    Text(schedule.cron + " · " + schedule.timezone, color = DieterMuted, fontSize = 13.sp)
                }
                Switch(checked = schedule.enabled, onCheckedChange = { model.toggleSchedule(schedule) })
            }
            if (schedule.description.isNotBlank()) Text(schedule.description, color = DieterMuted)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilledTonalButton(onClick = { model.runSchedule(schedule) }) {
                    Icon(Icons.Outlined.Sync, null, Modifier.size(17.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Run now")
                }
                TextButton(onClick = { confirmDelete = true }) {
                    Icon(Icons.Outlined.DeleteOutline, null, Modifier.size(17.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Delete")
                }
                TextButton(onClick = onEdit) {
                    Icon(Icons.Outlined.Edit, null, Modifier.size(17.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Edit")
                }
            }
            if (schedule.nextRunAt.isNotBlank()) {
                Text("Next · ${shortTimestamp(schedule.nextRunAt)}", color = DieterShell, fontSize = 12.sp)
            }
        }
    }
    if (confirmDelete) {
        ConfirmDialog("Delete schedule?", schedule.name, "Delete", { confirmDelete = false }) {
            confirmDelete = false
            model.deleteSchedule(schedule)
        }
    }
}

@Composable
internal fun ScheduleRunRow(run: com.dbpprt.dieter.v1.ScheduleRun) {
    Surface(color = DieterSurfaceHigh, shape = RoundedCornerShape(14.dp)) {
        Text(
            "${run.status.ifBlank { "unknown" }} · ${shortTimestamp(run.scheduledFor.ifBlank { run.createdAt })}${run.message.takeIf { it.isNotBlank() }?.let { " · $it" }.orEmpty()}",
            color = if (run.status == "failed") MaterialTheme.colorScheme.error else DieterMuted,
            fontSize = 12.sp,
            maxLines = 3,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
        )
    }
}
