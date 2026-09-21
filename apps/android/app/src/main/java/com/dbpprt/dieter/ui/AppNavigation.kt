package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Timeline
import androidx.compose.material.icons.outlined.CalendarMonth
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material.icons.outlined.Computer
import androidx.compose.material.icons.outlined.DesktopWindows
import androidx.compose.material.icons.outlined.FolderOpen
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.KeyboardArrowUp
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material.icons.outlined.ViewKanban
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarDefaults
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.ui.theme.DieterAbyss
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterShell
import com.dbpprt.dieter.ui.theme.DieterShellTint
import com.dbpprt.dieter.ui.theme.DieterSurface
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import com.dbpprt.dieter.ui.theme.DieterText

internal data class NavItem(val destination: Destination, val label: String, val icon: ImageVector)

internal val primaryNavigationItems = listOf(
    NavItem(Destination.ACTIVITY, "Activity", Icons.Outlined.Timeline),
    NavItem(Destination.BOARD, "Boards", Icons.Outlined.ViewKanban),
    NavItem(Destination.CHATS, "Chats", Icons.Outlined.ChatBubbleOutline),
)

private val toolNavigationItems = listOf(
    NavItem(Destination.MACHINES, "Machines", Icons.Outlined.Computer),
    NavItem(Destination.TERMINALS, "Terminal", Icons.Outlined.Terminal),
    NavItem(Destination.FILES, "Files", Icons.Outlined.FolderOpen),
    NavItem(Destination.SCHEDULES, "Schedules", Icons.Outlined.CalendarMonth),
    NavItem(Destination.SCREENS, "Screens", Icons.Outlined.DesktopWindows),
)

internal fun Destination.isPrimaryDestination() = primaryNavigationItems.any { it.destination == this }

@Composable
internal fun DieterBottomBar(
    selected: Destination,
    onSelect: (Destination) -> Unit,
    onTools: () -> Unit,
    toolsOpen: Boolean = false,
    windowInsets: WindowInsets = NavigationBarDefaults.windowInsets,
) {
    val colors = NavigationBarItemDefaults.colors(
        selectedIconColor = DieterText,
        selectedTextColor = DieterText,
        indicatorColor = DieterShellTint,
        unselectedIconColor = DieterMuted,
        unselectedTextColor = DieterMuted,
    )
    NavigationBar(
        containerColor = DieterSurface,
        tonalElevation = 0.dp,
        windowInsets = windowInsets,
        modifier = Modifier.fillMaxWidth(),
    ) {
        primaryNavigationItems.forEach { item ->
            NavigationBarItem(
                selected = item.destination == selected,
                onClick = { onSelect(item.destination) },
                icon = { Icon(item.icon, contentDescription = null, modifier = Modifier.size(22.dp)) },
                label = { Text(item.label) },
                colors = colors,
                modifier = Modifier.testTag("nav-${item.destination.name.lowercase()}"),
            )
        }
        NavigationBarItem(
            selected = !selected.isPrimaryDestination(),
            onClick = onTools,
            icon = {
                Icon(
                    if (toolsOpen) Icons.Outlined.KeyboardArrowDown else Icons.Outlined.KeyboardArrowUp,
                    contentDescription = if (toolsOpen) "Close tools" else "Open tools",
                )
            },
            label = { Text("Tools") },
            colors = colors,
            modifier = Modifier.testTag("nav-tools"),
        )
    }
}

@Composable
internal fun DieterNavigationRail(
    selected: Destination,
    onSelect: (Destination) -> Unit,
    projectSurfacesEnabled: Boolean,
    onSettings: () -> Unit,
    onCreate: () -> Unit,
) {
    NavigationRail(containerColor = DieterSurface) {
        if (selected != Destination.SCREENS && selected != Destination.MACHINES) {
            Surface(
                onClick = onCreate,
                color = DieterShell,
                contentColor = DieterAbyss,
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier.padding(horizontal = 12.dp, vertical = 14.dp).size(48.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Icon(Icons.Default.Add, contentDescription = "Create", modifier = Modifier.size(24.dp))
                }
            }
        }
        primaryNavigationItems.forEach { item ->
            NavigationRailItem(
                selected = item.destination == selected,
                onClick = { onSelect(item.destination) },
                icon = { Icon(item.icon, contentDescription = null) },
                label = { Text(item.label) },
                modifier = Modifier.testTag("nav-${item.destination.name.lowercase()}"),
            )
        }
        toolNavigationItems.forEach { item ->
            NavigationRailItem(
                selected = item.destination == selected,
                onClick = { onSelect(item.destination) },
                icon = { Icon(item.icon, contentDescription = null) },
                label = { Text(item.label) },
                enabled = projectSurfacesEnabled ||
                    (item.destination != Destination.FILES && item.destination != Destination.SCHEDULES),
                modifier = Modifier.testTag("nav-${item.destination.name.lowercase()}"),
            )
        }
        NavigationRailItem(
            selected = false,
            onClick = onSettings,
            icon = { Icon(Icons.Outlined.Settings, contentDescription = null) },
            label = { Text("Settings") },
            modifier = Modifier.testTag("nav-settings"),
        )
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun DieterToolsSheet(
    selected: Destination,
    projectSurfacesEnabled: Boolean,
    onSelect: (Destination) -> Unit,
    onSettings: () -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = DieterSurface,
        tonalElevation = 0.dp,
        modifier = Modifier.testTag("tools-sheet"),
    ) {
        LazyVerticalGrid(
            columns = GridCells.Adaptive(100.dp * LocalDensity.current.fontScale.coerceAtLeast(1f)),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.weight(1f, fill = false).fillMaxWidth().padding(horizontal = 16.dp)
                .testTag("tools-grid"),
        ) {
            items(toolNavigationItems, key = { it.destination }) { item ->
                ToolTile(
                    label = item.label,
                    icon = item.icon,
                    selected = selected == item.destination,
                    enabled = projectSurfacesEnabled ||
                        (item.destination != Destination.FILES && item.destination != Destination.SCHEDULES),
                    onClick = { onSelect(item.destination) },
                    modifier = Modifier.testTag("tool-${item.destination.name.lowercase()}"),
                )
            }
            item(key = "settings") {
                ToolTile(
                    label = "Settings",
                    icon = Icons.Outlined.Settings,
                    onClick = onSettings,
                    modifier = Modifier.testTag("tool-settings"),
                )
            }
        }
        DieterBottomBar(
            selected = selected,
            onSelect = onSelect,
            onTools = onDismiss,
            toolsOpen = true,
            // The sheet already applies the system bar insets.
            windowInsets = WindowInsets(0, 0, 0, 0),
        )
    }
}

@Composable
private fun ToolTile(
    label: String,
    icon: ImageVector,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    selected: Boolean = false,
    enabled: Boolean = true,
) {
    Surface(
        onClick = onClick,
        enabled = enabled,
        shape = RoundedCornerShape(16.dp),
        color = if (selected) MaterialTheme.colorScheme.primaryContainer else DieterSurfaceHigh,
        contentColor = if (enabled) DieterText else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f),
        modifier = modifier.fillMaxWidth().heightIn(min = 88.dp),
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.padding(14.dp),
        ) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(22.dp))
            Text(label, style = MaterialTheme.typography.labelLarge)
        }
    }
}
