package com.dbpprt.dieter.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Computer
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.PlayCircleOutline
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.ui.theme.*
import java.time.Instant

@Composable
internal fun ActivityRow(
    entry: ActivityEntry, project: String?, board: String?, machine: String, now: Instant,
    isSelected: Boolean = false, actions: ActivityItemActions? = null, onClick: () -> Unit,
) {
    val accent = stableAccent(entry.card.projectId)
    val statusColor = when {
        entry.needsYou -> DieterAmber
        entry.kind == ActivityKind.FAILED -> DieterCoral
        entry.running -> DieterEyes
        else -> DieterMuted
    }
    val age = activityAge(entry.at, now).let {
        if (entry.at == null || it == "Just now") it else "$it ago"
    }
    ActivityItem(
        card = entry.card, onOpen = { onClick() }, actions = actions,
        color = if (isSelected) DieterShellTint else DieterSurface,
        shape = RoundedCornerShape(20.dp),
        border = BorderStroke(1.dp, if (isSelected) DieterShell else DieterOutline.copy(alpha = .45f)),
        modifier = Modifier.fillMaxWidth().testTag("activity-row-${entry.card.id}")
            .semantics { selected = isSelected },
    ) {
        Column(
            Modifier.background(Brush.linearGradient(listOf(accent.copy(alpha = .08f), Color.Transparent)))
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Box(Modifier.size(7.dp).background(accent, CircleShape))
                Text(
                    listOfNotNull(project, board?.takeIf { entry.card.scope != "chat" },
                        "Chat".takeIf { entry.card.scope == "chat" }).joinToString(" · "),
                    color = DieterMuted, style = MaterialTheme.typography.labelSmall,
                    maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
                )
                Row(
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
                    modifier = Modifier.testTag("activity-age-${entry.card.id}").clearAndSetSemantics {
                        contentDescription = if (entry.at == null) "Last activity time unavailable" else "Last activity: $age"
                    },
                ) {
                    Icon(Icons.Outlined.Schedule, null, Modifier.size(12.dp), tint = DieterMuted)
                    Text(age, style = MaterialTheme.typography.labelSmall, color = DieterMuted)
                }
            }
            Text(entry.card.title.ifBlank { "Untitled" }, fontWeight = FontWeight.SemiBold,
                style = MaterialTheme.typography.titleMedium, color = DieterText,
                maxLines = 3, overflow = TextOverflow.Ellipsis)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(when {
                    entry.running -> Icons.Outlined.PlayCircleOutline
                    entry.needsYou || entry.kind == ActivityKind.FAILED -> Icons.Outlined.ErrorOutline
                    else -> Icons.Outlined.CheckCircle
                }, null, Modifier.size(15.dp), tint = statusColor)
                Text(entry.detail, color = statusColor, style = MaterialTheme.typography.bodySmall,
                    maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Surface(
                    color = DieterSurfaceHigh, shape = RoundedCornerShape(8.dp),
                    border = BorderStroke(1.dp, DieterOutline.copy(alpha = .55f)),
                    modifier = Modifier.widthIn(max = 220.dp).testTag("activity-machine-${entry.card.id}")
                        .clearAndSetSemantics { contentDescription = "Machine: $machine" },
                ) {
                    Row(Modifier.padding(horizontal = 8.dp, vertical = 5.dp),
                        horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Outlined.Computer, null, Modifier.size(14.dp), tint = DieterMuted)
                        Text(machine, color = DieterText, style = MaterialTheme.typography.labelSmall,
                            fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                if (entry.needsYou) Surface(shape = RoundedCornerShape(8.dp), color = DieterAmberTint) {
                    Text(entry.kind.label, color = DieterAmber, style = MaterialTheme.typography.labelSmall,
                        fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(horizontal = 8.dp, vertical = 5.dp))
                }
            }
        }
    }
}
