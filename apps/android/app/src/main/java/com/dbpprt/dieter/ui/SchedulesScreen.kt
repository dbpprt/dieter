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
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Refresh
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.api.v1.Schedule
import com.dbpprt.dieter.client.v1.ScheduleRow
import com.dbpprt.dieter.client.v1.ScheduleRunRow
import com.dbpprt.dieter.core.schedules.ScheduleDrafts
import com.dbpprt.dieter.core.schedules.SchedulePresentations
import com.dbpprt.dieter.core.schedules.SchedulesPresentation
import com.dbpprt.dieter.core.schedules.SchedulesView
import com.dbpprt.dieter.ui.theme.DieterAbyss
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterPane
import com.dbpprt.dieter.ui.theme.DieterRunning
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterShellTint
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

@Composable
fun SchedulesScreen(state: DieterUiState, model: DieterViewModel, contentPadding: PaddingValues) {
    val view = state.scheduleWorkspace
    Box(Modifier.fillMaxSize().padding(contentPadding)) {
        Column(Modifier.fillMaxSize()) {
            ProjectCheckoutSelector(state, model)
            SimpleScreenHeader("Schedules", view.subtitle) {
                IconButton(onClick = model::refreshSchedules) { Icon(Icons.Outlined.Refresh, "Refresh schedules") }
                IconButton(onClick = { model.openSurface(AppSurface.APP_SETTINGS) }) {
                    Icon(Icons.Outlined.Settings, "App settings", tint = DieterMuted)
                }
            }
            SurfaceErrorBanner(state.error, model::clearError)
            SurfaceErrorBanner(view.actionError, model::clearScheduleActionError)
            if (!state.connected && state.projects.isEmpty()) {
                ConnectionEmptyState(state, model)
            } else when (view.presentation) {
                SchedulesPresentation.LOADING -> LoadingState()
                SchedulesPresentation.FAILED -> ScheduleFailedState(view.error.orEmpty(), model::refreshSchedules)
                SchedulesPresentation.EMPTY -> ScheduleEmptyState { model.openSurface(AppSurface.SCHEDULE_EDITOR) }
                SchedulesPresentation.LOADED -> ScheduleList(view, model)
            }
        }
        if (view.schedules.isNotEmpty()) {
            ExtendedFloatingActionButton(
                onClick = { model.openSurface(AppSurface.SCHEDULE_EDITOR) },
                icon = { Icon(Icons.Default.Add, null) },
                text = { Text(ScheduleDrafts.NEW_TITLE, fontWeight = FontWeight.SemiBold) },
                modifier = Modifier.align(Alignment.BottomEnd).padding(16.dp).height(52.dp).testTag("new-schedule"),
                containerColor = DieterPane,
                contentColor = DieterAbyss,
                shape = RoundedCornerShape(50),
            )
        }
    }
}

@Composable
private fun ScheduleList(view: SchedulesView, model: DieterViewModel) {
    val rows = view.rows()
    LazyColumn(
        contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 96.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        view.schedules.zip(rows).forEach { (schedule, row) ->
            val selected = view.selectedId == schedule.id
            item(key = schedule.id) {
                ScheduleCard(schedule, row, selected, model, onEdit = { model.openSurface(AppSurface.SCHEDULE_EDITOR, schedule) })
            }
            if (selected) {
                item(key = "${schedule.id}-runs-heading") {
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text("Recent runs", fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                        if (view.runsLoading) CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    }
                }
                if (view.runs.isEmpty()) {
                    item(key = "${schedule.id}-runs-empty") {
                        Text(
                            if (view.runsLoading) SchedulePresentations.RUNS_LOADING else SchedulePresentations.RUNS_EMPTY,
                            color = DieterMuted,
                            fontSize = 12.sp,
                            modifier = Modifier.padding(horizontal = 4.dp),
                        )
                    }
                }
                items(view.runRows, key = { it.id }) { run -> ScheduleRunItem(run, schedule.timezone) }
                if (view.runsNextPageToken.isNotBlank()) {
                    item(key = "${schedule.id}-runs-more") {
                        LoadMoreButton(
                            loading = view.runsLoadingMore,
                            title = if (view.runsLoadingMore) SchedulePresentations.LOADING_OLDER_RUNS else SchedulePresentations.LOAD_OLDER_RUNS,
                            onClick = model::loadMoreScheduleRuns,
                        )
                    }
                }
            }
        }
        if (view.nextPageToken.isNotBlank()) {
            item(key = "schedules-load-more") {
                LoadMoreButton(
                    loading = view.loadingMore,
                    title = if (view.loadingMore) SchedulePresentations.LOADING_MORE else SchedulePresentations.LOAD_MORE,
                    onClick = model::loadMoreSchedules,
                )
            }
        }
    }
}

@Composable
private fun LoadMoreButton(loading: Boolean, title: String, onClick: () -> Unit) {
    OutlinedButton(onClick = onClick, enabled = !loading, modifier = Modifier.fillMaxWidth()) {
        if (loading) {
            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
            Spacer(Modifier.width(8.dp))
        }
        Text(title)
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
            Text(SchedulePresentations.EMPTY_TITLE, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))
            Text(
                SchedulePresentations.EMPTY_DETAIL,
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
                Text(ScheduleDrafts.NEW_TITLE)
            }
        }
    }
}

/** The list could not be read and nothing is shown: why, and a retry. */
@Composable
private fun ScheduleFailedState(error: String, onRetry: () -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Icon(Icons.Outlined.ErrorOutline, null, Modifier.size(40.dp), tint = MaterialTheme.colorScheme.error)
        Spacer(Modifier.height(12.dp))
        Text(error, color = DieterMuted, fontSize = 13.sp, lineHeight = 19.sp, textAlign = TextAlign.Center)
        Spacer(Modifier.height(12.dp))
        TextButton(onClick = onRetry, modifier = Modifier.testTag("schedules-retry")) { Text("Try again") }
    }
}

@Composable
internal fun ScheduleCard(
    schedule: Schedule,
    row: ScheduleRow,
    selected: Boolean,
    model: DieterViewModel,
    onEdit: () -> Unit,
) {
    var confirmDelete by remember { mutableStateOf(false) }
    Card(
        onClick = { model.selectSchedule(if (selected) null else schedule) },
        colors = CardDefaults.cardColors(containerColor = DieterSurfaceHigh),
        shape = RoundedCornerShape(18.dp),
    ) {
        Column(Modifier.fillMaxWidth().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(schedule.name, fontWeight = FontWeight.SemiBold)
                    Text(row.timing, color = DieterMuted, fontSize = 13.sp)
                }
                Switch(checked = schedule.enabled, onCheckedChange = { model.toggleSchedule(schedule) })
            }
            Text(row.subtitle, color = DieterMuted)
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
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("${row.placement} · ${row.status}", color = DieterMuted, fontSize = 12.sp, modifier = Modifier.weight(1f))
                Text(row.next_run_fallback.ifEmpty { scheduleTimeLabel(schedule.next_run_at, schedule.timezone) }, color = DieterShell, fontSize = 12.sp)
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
private fun ScheduleRunItem(run: ScheduleRunRow, timezone: String) {
    Surface(color = DieterSurfaceHigh, shape = RoundedCornerShape(14.dp)) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(run.status, color = runToneColor(run.tone), fontSize = 12.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                Text("${run.trigger} · ${scheduleTimeLabel(run.at, timezone)}", color = DieterMuted, fontSize = 12.sp)
            }
            if (run.message.isNotBlank()) {
                Text(run.message, color = DieterMuted, fontSize = 12.sp, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

@Composable
private fun runToneColor(tone: ScheduleRunRow.Tone): Color = when (tone) {
    ScheduleRunRow.Tone.TONE_ACTIVE -> DieterRunning
    ScheduleRunRow.Tone.TONE_SUCCESS -> DieterShell
    ScheduleRunRow.Tone.TONE_FAILURE -> MaterialTheme.colorScheme.error
    else -> DieterMuted
}

/** A schedule's time (RFC 3339) in the schedule's own zone, formatted for this device: "Aug 25, 09:00". */
internal fun scheduleTimeLabel(timestamp: String, timezone: String): String = runCatching {
    DateTimeFormatter.ofPattern("MMM d, HH:mm", Locale.getDefault())
        .format(Instant.parse(timestamp).atZone(ZoneId.of(timezone)))
}.getOrElse { timestamp.replace('T', ' ').substringBefore('+').substringBefore('Z').takeLast(11) }
