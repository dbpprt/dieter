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
import com.dbpprt.dieter.core.admin.BackgroundMode
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterShellTint
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh

@Composable
internal fun BackgroundSyncModeSelector(
    selected: BackgroundMode,
    onSelect: (BackgroundMode) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text("Background sync", fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
        BackgroundMode.entries.forEach { mode ->
            val title = mode.title
            val detail = mode.detail
            Surface(
                onClick = { onSelect(mode) },
                color = if (selected == mode) DieterShellTint else DieterSurfaceHigh,
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier.fillMaxWidth().testTag("background-sync-${mode.wire}"),
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
