package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.connection.BackgroundSyncMode
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterShellTint
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh

@Composable
internal fun BackgroundSyncModeSelector(
    selected: BackgroundSyncMode,
    onSelect: (BackgroundSyncMode) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("Background sync", fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
        BackgroundSyncMode.entries.forEach { mode ->
            val (title, detail) = backgroundSyncModePresentation(mode)
            Surface(
                onClick = { onSelect(mode) },
                color = if (selected == mode) DieterShellTint else DieterSurfaceHigh,
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier.fillMaxWidth().testTag("background-sync-${mode.wireValue}"),
            ) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 7.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    RadioButton(selected = selected == mode, onClick = { onSelect(mode) })
                    Column(Modifier.weight(1f)) {
                        Text(title, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
                        Text(detail, color = DieterMuted, fontSize = 10.sp)
                    }
                }
            }
        }
    }
}

internal fun backgroundSyncModePresentation(mode: BackgroundSyncMode): Pair<String, String> = when (mode) {
    BackgroundSyncMode.LIVE -> "Live" to "Always connected · highest battery use"
    BackgroundSyncMode.PERIODIC -> "Smart" to "Live for active work; otherwise checks about every minute"
    BackgroundSyncMode.APP_ONLY -> "App only" to "Sleeps completely until Dieter is opened"
}
