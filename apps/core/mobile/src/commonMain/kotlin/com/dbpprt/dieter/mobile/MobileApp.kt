@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.mobile

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.mobile.icons.*

internal val primaryTabs =
    listOf(MobileTab.INBOX, MobileTab.PROJECTS, MobileTab.CHATS, MobileTab.TOOLS)

internal fun MobileTab.title() =
    when (this) {
        MobileTab.BOARD -> "Board"
        MobileTab.INBOX -> "Inbox"
        MobileTab.PROJECTS -> "Projects"
        MobileTab.CHATS -> "Chats"
        MobileTab.TOOLS -> "Tools"
        MobileTab.MACHINES -> "Machines"
        MobileTab.FILES -> "Files"
        MobileTab.SCHEDULES -> "Schedules"
        MobileTab.TERMINALS -> "Terminal"
        MobileTab.SCREENS -> "Screens"
        MobileTab.USAGE -> "Usage"
        MobileTab.SETTINGS -> "Settings"
        MobileTab.PROJECT_CHANGES -> "Changes"
    }

internal fun MobileTab.icon(): ImageVector =
    when (this) {
        MobileTab.INBOX -> Icons.Outlined.Inbox
        MobileTab.PROJECTS,
        MobileTab.BOARD -> Icons.Outlined.ViewKanban
        MobileTab.CHATS -> Icons.Outlined.ChatBubbleOutline
        MobileTab.TOOLS -> Icons.Outlined.GridView
        MobileTab.MACHINES -> Icons.Outlined.Computer
        MobileTab.FILES -> Icons.Outlined.Folder
        MobileTab.SCHEDULES -> Icons.Outlined.CalendarMonth
        MobileTab.TERMINALS -> Icons.Outlined.Terminal
        MobileTab.SCREENS -> Icons.Outlined.DesktopWindows
        MobileTab.USAGE -> Icons.Outlined.DataUsage
        MobileTab.SETTINGS -> Icons.Outlined.Settings
        MobileTab.PROJECT_CHANGES -> Icons.Outlined.CompareArrows
    }

/** All destinations use the same core and screens. Apple supplies native glass chrome. */
@Composable
fun MobileApp(store: MobileStore, apple: Boolean = false, openUrl: (String) -> Unit = {}) {
    val tab by store.tab.collectAsState()
    val selected by store.selectedCard.collectAsState()
    val creating by store.creating.collectAsState()
    val workspace by store.workspace.collectAsState()
    val selectedBoard by store.selectedBoard.collectAsState()
    val session by store.session.collectAsState()
    val error by store.error.collectAsState()
    val signInUrl by store.signInUrl.collectAsState()
    LaunchedEffect(signInUrl) {
        if (signInUrl.isNotEmpty()) {
            openUrl(signInUrl)
            store.signInUrl.value = ""
        }
    }
    LaunchedEffect(workspace.boards.map { it.id }) {
        if (workspace.boards.isNotEmpty() && workspace.boards.none { it.id == selectedBoard })
            store.chooseBoard(workspace.boards.first().id)
    }
    MobileTheme(store, apple) {
        Surface(Modifier.fillMaxSize(), color = colors.background) {
            BoxWithConstraints {
                val wide = maxWidth >= 840.dp
                val split =
                    maxWidth >= 600.dp &&
                        (tab in listOf(MobileTab.INBOX, MobileTab.CHATS) ||
                            (tab == MobileTab.BOARD && selected.isNotEmpty()))
                Row(Modifier.fillMaxSize()) {
                    if (wide && !apple)
                        NavigationRail(containerColor = colors.surface) {
                            Spacer(Modifier.height(12.dp))
                            primaryTabs.forEach { item ->
                                NavigationRailItem(
                                    selected =
                                        tab == item ||
                                            (item == MobileTab.PROJECTS && tab == MobileTab.BOARD),
                                    onClick = { store.navigate(item) },
                                    icon = { Icon(item.icon(), item.title()) },
                                    label = { Text(item.title()) },
                                )
                            }
                            Spacer(Modifier.weight(1f))
                            IconButton(onClick = { store.navigate(MobileTab.SETTINGS) }) {
                                Icon(Icons.Outlined.Settings, "Settings")
                            }
                        }
                    Column(Modifier.weight(1f)) {
                        session.notice?.let { notice ->
                            Notice(notice.title, notice.detail, store::retry)
                        }
                        if (error.isNotEmpty())
                            Notice(
                                "Action unavailable",
                                error,
                                { store.error.value = "" },
                                "Dismiss",
                                danger = true,
                            )
                        Box(Modifier.weight(1f)) {
                            when {
                                session.phase == SessionSlice.Phase.PHASE_AUTH_REQUIRED &&
                                    !workspace.loaded -> SignInScreen(store)
                                creating -> CreationScreen(store)
                                selected.isNotEmpty() && !split ->
                                    ConversationScreen(store, openUrl)
                                split ->
                                    Row(Modifier.fillMaxSize()) {
                                        Box(
                                            Modifier.width(if (wide) 360.dp else 280.dp)
                                                .fillMaxHeight()
                                        ) {
                                            MainDestination(store, openUrl)
                                        }
                                        VerticalDivider(color = colors.outlineVariant)
                                        Box(Modifier.weight(1f)) {
                                            if (selected.isNotEmpty())
                                                ConversationScreen(store, openUrl)
                                            else
                                                Empty(
                                                    "Choose a conversation",
                                                    "Your project and conversations stay within reach.",
                                                )
                                        }
                                    }
                                else -> MainDestination(store, openUrl)
                            }
                        }
                        if (!apple && !wide && !creating && selected.isEmpty())
                            NavigationBar(containerColor = colors.surface, tonalElevation = 0.dp) {
                                primaryTabs.forEach { item ->
                                    NavigationBarItem(
                                        selected =
                                            tab == item ||
                                                (item == MobileTab.PROJECTS &&
                                                    tab == MobileTab.BOARD),
                                        onClick = { store.navigate(item) },
                                        icon = { Icon(item.icon(), null) },
                                        label = { Text(item.title()) },
                                        modifier = Modifier.testTag("nav-${item.name.lowercase()}"),
                                    )
                                }
                            }
                    }
                }
            }
        }
    }
}

@Composable
private fun MainDestination(store: MobileStore, openUrl: (String) -> Unit) {
    val tab by store.tab.collectAsState()
    when (tab) {
        MobileTab.BOARD -> BoardScreen(store)
        MobileTab.INBOX -> InboxScreen(store)
        MobileTab.PROJECTS -> ProjectsScreen(store)
        MobileTab.CHATS -> ChatsScreen(store)
        MobileTab.TOOLS -> ToolsScreen(store)
        MobileTab.MACHINES -> MachinesScreen(store)
        MobileTab.FILES -> FilesScreen(store)
        MobileTab.SCHEDULES -> SchedulesScreen(store)
        MobileTab.USAGE -> UsageScreen(store)
        MobileTab.SETTINGS -> SettingsScreen(store)
        MobileTab.PROJECT_CHANGES -> ProjectChangesScreen(store)
        MobileTab.TERMINALS -> TerminalsScreen(store)
        MobileTab.SCREENS -> ScreensScreen(store)
    }
}

@Composable
internal fun PageHeader(
    title: String,
    subtitle: String = "",
    back: (() -> Unit)? = null,
    actions: @Composable RowScope.() -> Unit = {},
) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (back != null) IconButton(onClick = back) { Icon(Icons.Outlined.ArrowBack, "Back") }
        Column(Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.SemiBold,
            )
            if (subtitle.isNotEmpty())
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = colors.onSurfaceVariant,
                )
        }
        actions()
    }
}

@Composable
internal fun Notice(
    title: String,
    detail: String,
    action: () -> Unit,
    actionLabel: String = "Retry",
    danger: Boolean = false,
) {
    Surface(color = if (danger) colors.errorContainer else colors.surfaceContainerHigh) {
        Row(
            Modifier.fillMaxWidth().padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f)) {
                Text(title, fontWeight = FontWeight.SemiBold)
                Text(detail, style = MaterialTheme.typography.bodySmall)
            }
            TextButton(onClick = action) { Text(actionLabel) }
        }
    }
}

@Composable
internal fun Empty(title: String, detail: String) {
    Column(
        Modifier.fillMaxSize().padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(Icons.Outlined.Forum, null, Modifier.size(30.dp), tint = colors.onSurfaceVariant)
        Spacer(Modifier.height(14.dp))
        Text(title, style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(6.dp))
        Text(detail, style = MaterialTheme.typography.bodyMedium, color = colors.onSurfaceVariant)
    }
}

@Composable
private fun ToolsScreen(store: MobileStore) {
    Column {
        PageHeader("Tools", "Your machines and project workspace")
        LazyColumn(
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            items(
                listOf(
                        MobileTab.MACHINES,
                        MobileTab.TERMINALS,
                        MobileTab.FILES,
                        MobileTab.SCHEDULES,
                        MobileTab.SCREENS,
                        MobileTab.USAGE,
                        MobileTab.SETTINGS,
                    )
                    .chunked(2)
            ) { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    row.forEach { tool ->
                        Surface(
                            onClick = { store.navigate(tool) },
                            color = colors.surfaceContainerHigh,
                            shape = RoundedCornerShape(16.dp),
                            modifier = Modifier.weight(1f),
                        ) {
                            Column(
                                Modifier.padding(16.dp).heightIn(min = 64.dp),
                                verticalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                Icon(tool.icon(), null)
                                Text(tool.title(), style = MaterialTheme.typography.labelLarge)
                            }
                        }
                    }
                    if (row.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun SignInScreen(store: MobileStore) {
    var gateway by remember { mutableStateOf("https://") }
    val busy by store.busy.collectAsState()
    Column(
        Modifier.fillMaxSize().imePadding().verticalScroll(rememberScrollState()).padding(24.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Text("Connect to Dieter", style = MaterialTheme.typography.headlineMedium)
        Spacer(Modifier.height(12.dp))
        Text("Sign in to see your projects and enrolled machines.", color = colors.onSurfaceVariant)
        Spacer(Modifier.height(24.dp))
        MobileTextField(
            gateway,
            { gateway = it },
            Modifier.fillMaxWidth(),
            label = { Text("Gateway address") },
            singleLine = true,
        )
        Spacer(Modifier.height(16.dp))
        Button(onClick = { store.signIn(gateway) }, enabled = !busy) { Text("Sign in") }
    }
}
