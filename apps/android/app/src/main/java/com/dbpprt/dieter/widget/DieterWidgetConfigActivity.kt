package com.dbpprt.dieter.widget

import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
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
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.ui.theme.DieterTheme

/** Per-instance widget options; also launched for reconfiguration from the launcher. */
class DieterWidgetConfigActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val appWidgetId = intent?.extras?.getInt(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID,
        ) ?: AppWidgetManager.INVALID_APPWIDGET_ID
        setResult(RESULT_CANCELED, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId))
        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
            return
        }
        setContent {
            DieterTheme {
                WidgetConfigScreen(
                    initial = DieterWidgetPrefs.config(this, appWidgetId),
                    onCancel = { finish() },
                    onSave = { config ->
                        DieterWidgetPrefs.saveConfig(this, appWidgetId, config)
                        DieterActivityWidgetProvider.render(this, AppWidgetManager.getInstance(this), appWidgetId)
                        setResult(RESULT_OK, Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId))
                        finish()
                    },
                )
            }
        }
    }
}

@Composable
private fun WidgetConfigScreen(
    initial: WidgetConfig,
    onCancel: () -> Unit,
    onSave: (WidgetConfig) -> Unit,
) {
    var style by remember { mutableStateOf(initial.style) }
    var maxItems by remember { mutableStateOf(initial.maxItems) }
    var showSections by remember { mutableStateOf(initial.showSections) }
    var includeChats by remember { mutableStateOf(initial.includeChats) }

    Scaffold { padding ->
        Surface(Modifier.fillMaxSize()) {
            Column(
                Modifier
                    .padding(padding)
                    .padding(horizontal = 20.dp, vertical = 12.dp)
                    .verticalScroll(rememberScrollState()),
            ) {
                Text("Widget options", style = MaterialTheme.typography.titleLarge)
                Spacer(Modifier.height(4.dp))
                Text(
                    "Choose what this widget shows on your home screen.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(20.dp))

                Text("Style", style = MaterialTheme.typography.titleSmall)
                StyleOption(
                    title = "Automatic",
                    subtitle = "Full feed when wide, last finished when small",
                    selected = style == WidgetStyle.AUTO,
                ) { style = WidgetStyle.AUTO }
                StyleOption(
                    title = "Activity feed",
                    subtitle = "Waiting, running, and finished work",
                    selected = style == WidgetStyle.ACTIVITY,
                ) { style = WidgetStyle.ACTIVITY }
                StyleOption(
                    title = "Last finished",
                    subtitle = "Compact list of recently finished work",
                    selected = style == WidgetStyle.LAST_FINISHED,
                ) { style = WidgetStyle.LAST_FINISHED }

                Spacer(Modifier.height(16.dp))
                Text("Items", style = MaterialTheme.typography.titleSmall)
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    WidgetConfig.MAX_ITEM_CHOICES.forEach { choice ->
                        FilterChip(
                            selected = maxItems == choice,
                            onClick = { maxItems = choice },
                            label = { Text("$choice") },
                        )
                    }
                }

                Spacer(Modifier.height(16.dp))
                ToggleRow("Date sections", "Group finished work by day", showSections) { showSections = it }
                ToggleRow("Include chats", "Show standalone chat activity", includeChats) { includeChats = it }

                Spacer(Modifier.height(24.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    TextButton(onClick = onCancel) { Text("Cancel") }
                    Spacer(Modifier.height(0.dp))
                    Button(
                        onClick = {
                            onSave(
                                WidgetConfig(
                                    style = style,
                                    maxItems = maxItems,
                                    showSections = showSections,
                                    includeChats = includeChats,
                                ),
                            )
                        },
                    ) { Text("Save") }
                }
            }
        }
    }
}

@Composable
private fun StyleOption(title: String, subtitle: String, selected: Boolean, onSelect: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .selectable(selected = selected, onClick = onSelect)
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = onSelect)
        Column(Modifier.padding(start = 4.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(
                subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun ToggleRow(title: String, subtitle: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            Text(
                subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Switch(checked = checked, onCheckedChange = onChange)
    }
}
