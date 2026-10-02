package com.dbpprt.dieter.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.ui.theme.DieterDivider
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.presentation.Counts

@Composable
internal fun ChatSectionHeading(title: String, icon: ImageVector, count: Int, tint: Color = DieterMuted) {
    Row(
        Modifier.fillMaxWidth().padding(top = 18.dp, bottom = 8.dp, start = 4.dp, end = 4.dp)
            .semantics { heading() },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(8.dp))
        Text(title, color = tint, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.width(8.dp))
        Text("$count", color = DieterMuted, fontSize = 12.sp)
        Spacer(Modifier.width(12.dp))
        Box(Modifier.weight(1f).size(1.dp).background(DieterDivider))
    }
}

@Composable
internal fun ChatProjectHeader(project: Project, count: Int, collapsed: Boolean, onToggle: () -> Unit, onNewChat: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Row(
            Modifier.weight(1f).heightIn(min = 60.dp).clip(RoundedCornerShape(12.dp))
                .clickable(onClick = onToggle).testTag("project-chat-toggle-${project.id}")
                .semantics { heading(); stateDescription = if (collapsed) "Collapsed" else "Expanded" }
                .padding(start = 4.dp, end = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.size(34.dp).background(DieterSurfaceHigh, RoundedCornerShape(10.dp)), contentAlignment = Alignment.Center) {
                Text(project.name.take(1).uppercase(), color = DieterShell, fontSize = 15.sp, fontWeight = FontWeight.Bold)
            }
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(project.name, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold,
                    maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text("Project · ${Counts.of(count, "chat")}", color = DieterMuted, fontSize = 11.sp)
            }
            Icon(Icons.Outlined.KeyboardArrowDown,
                if (collapsed) "Expand ${project.name} chats" else "Collapse ${project.name} chats",
                tint = DieterMuted, modifier = Modifier.size(20.dp).rotate(if (collapsed) -90f else 0f))
        }
        IconButton(onClick = onNewChat, modifier = Modifier.size(48.dp)) {
            Icon(Icons.Default.Add, "New chat in ${project.name}", tint = DieterShell, modifier = Modifier.size(20.dp))
        }
    }
}

/** A continuous gutter connects lazy rows without composing a whole group at once. */
internal fun Modifier.chatGroupRail(color: Color): Modifier = drawBehind {
    drawLine(color, Offset(8.dp.toPx(), 0f), Offset(8.dp.toPx(), size.height), 2.dp.toPx())
}.padding(start = 20.dp)
