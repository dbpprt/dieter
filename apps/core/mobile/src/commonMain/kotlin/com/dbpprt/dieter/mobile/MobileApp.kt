package com.dbpprt.dieter.mobile

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.ArrowBack
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.mobile.icons.*

private val Coral = Color(0xFFEF654A)
private val Ink = Color(0xFF262923)
private val Green = Color(0xFF377359)
private val Paper = Color(0xFFF7F8F3)
private val Scheme =
    lightColorScheme(
        primary = Coral,
        onPrimary = Color.White,
        secondary = Green,
        background = Paper,
        surface = Color.White,
        onSurface = Ink,
        onBackground = Ink,
        surfaceVariant = Color(0xFFEEF0E8),
        onSurfaceVariant = Color(0xFF686D62),
    )

/** iOS uses native glass navigation around this content; Android includes Material navigation. */
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
    MaterialTheme(colorScheme = Scheme) {
        BoxWithConstraints(Modifier.fillMaxSize().background(Paper)) {
            val wide = maxWidth >= 700.dp
            Column(Modifier.fillMaxSize()) {
                if (!apple && selected.isEmpty() && !creating) {
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 22.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            "dieter",
                            style = MaterialTheme.typography.headlineSmall,
                            fontWeight = FontWeight.Bold,
                        )
                        Spacer(Modifier.weight(1f))
                        Text(
                            session.phase_label.ifEmpty { "Connecting" },
                            color = Green,
                            style = MaterialTheme.typography.labelMedium,
                        )
                        IconButton(onClick = { store.retry() }) {
                            Icon(Icons.Outlined.Refresh, "Reconnect")
                        }
                    }
                }
                if (session.notice != null) {
                    Surface(color = Scheme.surfaceVariant) {
                        Column(Modifier.fillMaxWidth().padding(12.dp)) {
                            Text(session.notice!!.title)
                            Text(
                                session.notice!!.detail,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    }
                }
                if (error.isNotEmpty())
                    Surface(color = Color(0xFFFFE6E0)) {
                        Row(Modifier.padding(12.dp)) {
                            Text(error, Modifier.weight(1f))
                            TextButton(onClick = { store.error.value = "" }) { Text("Dismiss") }
                        }
                    }
                Box(Modifier.weight(1f)) {
                    if (
                        session.phase == SessionSlice.Phase.PHASE_AUTH_REQUIRED && !workspace.loaded
                    )
                        SignInScreen(store)
                    else if (creating) CreationScreen(store)
                    else if (wide && tab == MobileTab.BOARD)
                        Row(Modifier.fillMaxSize()) {
                            Box(Modifier.width(360.dp).fillMaxHeight()) {
                                BoardScreen(store, apple)
                            }
                            VerticalDivider()
                            Box(Modifier.weight(1f)) {
                                if (selected.isNotEmpty()) ConversationScreen(store)
                                else
                                    Empty(
                                        "Your work, in one place",
                                        "Choose a task to follow its conversation.",
                                    )
                            }
                        }
                    else if (selected.isNotEmpty()) ConversationScreen(store)
                    else
                        when (tab) {
                            MobileTab.BOARD -> BoardScreen(store, apple)
                            MobileTab.CHATS -> ChatsScreen(store)
                            MobileTab.MACHINES -> MachinesScreen(store)
                        }
                }
                if (!apple && selected.isEmpty() && !creating)
                    NavigationBar(containerColor = Color.White) {
                        listOf(
                                MobileTab.BOARD to Icons.Outlined.Dashboard,
                                MobileTab.CHATS to Icons.Outlined.ChatBubbleOutline,
                                MobileTab.MACHINES to Icons.Outlined.Computer,
                            )
                            .forEach { (item, icon) ->
                                NavigationBarItem(
                                    selected = tab == item,
                                    onClick = { store.tab.value = item },
                                    icon = { Icon(icon, item.name.lowercase()) },
                                    label = {
                                        Text(
                                            when (item) {
                                                MobileTab.BOARD -> "Board"
                                                MobileTab.CHATS -> "Chats"
                                                MobileTab.MACHINES -> "Machines"
                                            }
                                        )
                                    },
                                )
                            }
                    }
            }
        }
    }
}

@Composable
private fun BoardScreen(store: MobileStore, apple: Boolean) {
    val workspace by store.workspace.collectAsState()
    val board by store.board.collectAsState()
    val selectedBoard by store.selectedBoard.collectAsState()
    var lane by rememberSaveable { mutableStateOf("running") }
    var search by rememberSaveable { mutableStateOf("") }
    var boardsOpen by remember { mutableStateOf(false) }
    val destination = workspace.boards.firstOrNull { it.id == selectedBoard }
    val project = workspace.projects.firstOrNull { it.id == destination?.project_id }
    Column(Modifier.fillMaxSize()) {
        Column(Modifier.padding(horizontal = 22.dp)) {
            Spacer(Modifier.height(16.dp))
            Text(
                project?.name ?: "Workspace",
                style = MaterialTheme.typography.labelLarge,
                color = Green,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Your board",
                    style = MaterialTheme.typography.headlineLarge,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.weight(1f),
                )
                if (!apple)
                    FilledIconButton(onClick = { store.creating.value = true }) {
                        Icon(Icons.Outlined.Add, "New task")
                    }
            }
            Box {
                TextButton(onClick = { boardsOpen = true }, contentPadding = PaddingValues(0.dp)) {
                    Text(destination?.name ?: "Choose a board")
                    Icon(Icons.Outlined.ExpandMore, null)
                }
                DropdownMenu(expanded = boardsOpen, onDismissRequest = { boardsOpen = false }) {
                    workspace.boards.forEach { item ->
                        DropdownMenuItem(
                            text = { Text(item.name) },
                            onClick = {
                                store.chooseBoard(item.id)
                                boardsOpen = false
                            },
                        )
                    }
                }
            }
            OutlinedTextField(
                search,
                { search = it },
                Modifier.fillMaxWidth(),
                placeholder = { Text("Find a task") },
                leadingIcon = { Icon(Icons.Outlined.Search, null) },
                singleLine = true,
                shape = RoundedCornerShape(18.dp),
            )
            Spacer(Modifier.height(14.dp))
        }
        Row(
            Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 22.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            board.lanes.forEach { item ->
                FilterChip(
                    selected = item.lane_id == lane,
                    onClick = { lane = item.lane_id },
                    label = { Text("${item.name}  ${item.card_ids.size}") },
                )
            }
        }
        val visibleLane =
            board.lanes.firstOrNull { it.lane_id == lane } ?: board.lanes.firstOrNull()
        val cards =
            visibleLane
                ?.card_ids
                .orEmpty()
                .mapNotNull { id -> workspace.cards.firstOrNull { it.id == id } }
                .filter { search.isBlank() || it.title.contains(search, true) }
        if (!workspace.loaded)
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        else if (cards.isEmpty())
            Empty("Room for the next idea", "Create a task or choose another lane.")
        else
            LazyColumn(
                contentPadding = PaddingValues(22.dp, 12.dp, 22.dp, 24.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                items(cards, key = { it.id }) { card ->
                    TaskCard(card, board.cards[card.id], { store.openCard(card.id) })
                }
                item {
                    Text(
                        "Every task stays with its conversation.",
                        color = Scheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(top = 6.dp),
                    )
                }
            }
    }
}

@Composable
private fun TaskCard(card: Card, flags: BoardCardFlags?, click: () -> Unit) {
    Surface(
        onClick = click,
        shape = RoundedCornerShape(22.dp),
        color = Color.White,
        border = BorderStroke(1.dp, Color(0xFFE4E7DD)),
    ) {
        Column(Modifier.padding(18.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier.size(7.dp)
                        .background(
                            if (flags?.can_cancel == true) Green else Coral,
                            RoundedCornerShape(4.dp),
                        )
                )
                Spacer(Modifier.width(7.dp))
                Text(
                    flags?.runtime_label?.ifEmpty { card.lane } ?: card.lane,
                    style = MaterialTheme.typography.labelMedium,
                    color = Green,
                )
                Spacer(Modifier.weight(1f))
                Icon(
                    Icons.Outlined.ArrowOutward,
                    null,
                    Modifier.size(17.dp),
                    tint = Scheme.onSurfaceVariant,
                )
            }
            Text(
                card.title,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                card.summary.ifEmpty { card.initial_prompt },
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                color = Scheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodyMedium,
            )
            HorizontalDivider(color = Color(0xFFEEF0E8))
            Row {
                Icon(Icons.Outlined.AutoAwesome, null, Modifier.size(15.dp), tint = Coral)
                Spacer(Modifier.width(6.dp))
                Text(
                    card.model.ifEmpty { card.provider.ifEmpty { "Agent" } },
                    style = MaterialTheme.typography.labelSmall,
                    color = Scheme.onSurfaceVariant,
                )
                Spacer(Modifier.weight(1f))
                Text(
                    "Open conversation",
                    style = MaterialTheme.typography.labelSmall,
                    color = Scheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun ConversationScreen(store: MobileStore) {
    val view by store.conversation.collectAsState()
    val busy by store.busy.collectAsState()
    val id by store.selectedCard.collectAsState()
    var draft by rememberSaveable(id) { mutableStateOf("") }
    val list = rememberLazyListState()
    LaunchedEffect(view.timeline.size) {
        if (view.timeline.isNotEmpty()) list.animateScrollToItem(view.timeline.lastIndex)
    }
    Column(Modifier.fillMaxSize().imePadding()) {
        Row(
            Modifier.fillMaxWidth().padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = store::back) { Icon(Icons.Outlined.ArrowBack, "Back to board") }
            Column(Modifier.weight(1f)) {
                Text(
                    view.card?.title ?: "Conversation",
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    style = MaterialTheme.typography.titleMedium,
                )
                Text(
                    view.state?.live_activity?.ifEmpty { view.card?.lane ?: "" }.orEmpty(),
                    color = Green,
                    style = MaterialTheme.typography.labelSmall,
                )
            }
            if (view.state?.can_start == true)
                TextButton(onClick = store::start, enabled = !busy) { Text("Start") }
            if (view.state?.can_halt == true)
                IconButton(onClick = store::stop, enabled = !busy) {
                    Icon(Icons.Outlined.StopCircle, "Stop agent")
                }
            else
                TextButton(
                    onClick = { store.move("review") },
                    enabled = !busy && view.card != null,
                ) {
                    Text("Review")
                }
        }
        HorizontalDivider(color = Color(0xFFE4E7DD))
        if (view.error.isNotEmpty())
            Text(view.error, color = Scheme.error, modifier = Modifier.padding(16.dp))
        view.turn_failure?.let { failure ->
            Surface(color = Scheme.errorContainer) {
                Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(failure.summary, Modifier.weight(1f), color = Scheme.onErrorContainer)
                    if (failure.retryable)
                        TextButton(onClick = store::retryTurn, enabled = !busy) {
                            Text("Retry turn")
                        }
                }
            }
        }
        if (view.loading && view.timeline.isEmpty())
            LinearProgressIndicator(Modifier.fillMaxWidth())
        LazyColumn(
            state = list,
            modifier = Modifier.weight(1f),
            contentPadding = PaddingValues(22.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            if (view.has_earlier)
                item {
                    TextButton(onClick = store::loadEarlier, enabled = !view.loading_earlier) {
                        Text("Load earlier messages")
                    }
                }
            if (view.state?.unsent_task?.isNotEmpty() == true)
                item { Text(view.state!!.unsent_task, style = MaterialTheme.typography.bodyLarge) }
            items(view.timeline, key = { it.id }) { row ->
                if (row.activity)
                    Surface(color = Scheme.surfaceVariant, shape = RoundedCornerShape(14.dp)) {
                        Text(
                            row.summary,
                            Modifier.padding(12.dp),
                            style = MaterialTheme.typography.labelMedium,
                            color = Scheme.onSurfaceVariant,
                        )
                    }
                else
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(
                            if (row.user) "YOU" else "DIETER",
                            color = if (row.user) Scheme.onSurfaceVariant else Coral,
                            style = MaterialTheme.typography.labelSmall,
                            fontWeight = FontWeight.Bold,
                        )
                        row.groups
                            .flatMap { it.steps }
                            .forEach { step ->
                                val message = view.messages.firstOrNull { it.id == step.message_id }
                                val part = message?.parts?.getOrNull(step.part_index)
                                val text = step.text.ifEmpty { part?.text.orEmpty() }
                                if (
                                    step.kind == TimelineStepKind.TIMELINE_STEP_KIND_TEXT &&
                                        text.isNotEmpty()
                                ) {
                                    if (row.user)
                                        Surface(
                                            shape = RoundedCornerShape(18.dp),
                                            color = Color.White,
                                        ) {
                                            Text(
                                                text,
                                                Modifier.padding(16.dp),
                                                style = MaterialTheme.typography.bodyLarge,
                                            )
                                        }
                                    else Text(text, style = MaterialTheme.typography.bodyLarge)
                                } else if (step.tool_title.isNotEmpty())
                                    Text(
                                        "${step.tool_title} · ${step.tool_status_label}",
                                        color = Green,
                                        style = MaterialTheme.typography.labelMedium,
                                    )
                            }
                        if (row.delivery_label.isNotEmpty())
                            Text(
                                row.delivery_label,
                                style = MaterialTheme.typography.labelSmall,
                                color = Scheme.onSurfaceVariant,
                            )
                    }
            }
        }
        Surface(color = Color.White, shadowElevation = 6.dp) {
            Column(Modifier.padding(16.dp)) {
                val agent = view.state?.agent
                Text(
                    listOfNotNull(agent?.provider_label, agent?.model_label, agent?.effort_label)
                        .filter { it.isNotBlank() }
                        .joinToString("  ·  "),
                    style = MaterialTheme.typography.labelSmall,
                    color = Scheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(8.dp))
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    OutlinedTextField(
                        draft,
                        { draft = it },
                        Modifier.weight(1f),
                        placeholder = { Text("Keep the conversation going…") },
                        shape = RoundedCornerShape(20.dp),
                        maxLines = 5,
                    )
                    FilledIconButton(
                        onClick = {
                            val text = draft
                            val target = id
                            store.action {
                                store.send(text, target)
                                draft = ""
                            }
                        },
                        enabled = draft.isNotBlank() && !busy && view.card != null,
                    ) {
                        Icon(Icons.Outlined.ArrowUpward, "Send message")
                    }
                }
            }
        }
    }
}

@Composable
private fun CreationScreen(store: MobileStore) {
    var title by rememberSaveable { mutableStateOf("") }
    var prompt by rememberSaveable { mutableStateOf("") }
    val busy by store.busy.collectAsState()
    Column(
        Modifier.fillMaxSize().imePadding().verticalScroll(rememberScrollState()).padding(22.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = store::back) { Icon(Icons.Outlined.Close, "Close new task") }
            Text(
                "A new idea",
                style = MaterialTheme.typography.headlineMedium,
                fontWeight = FontWeight.Bold,
            )
        }
        Text("Give your agent something to work on.", color = Scheme.onSurfaceVariant)
        OutlinedTextField(
            title,
            { title = it },
            label = { Text("Task title") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(18.dp),
        )
        OutlinedTextField(
            prompt,
            { prompt = it },
            label = { Text("What should we do?") },
            modifier = Modifier.fillMaxWidth().heightIn(min = 180.dp),
            shape = RoundedCornerShape(18.dp),
        )
        Text(
            "Uses this board’s agent defaults and a project workspace.",
            style = MaterialTheme.typography.bodySmall,
            color = Scheme.onSurfaceVariant,
        )
        Button(
            onClick = { store.action { store.openCard(store.create(title, prompt, true)) } },
            enabled = prompt.isNotBlank() && !busy,
            modifier = Modifier.fillMaxWidth().heightIn(min = 50.dp),
        ) {
            Text(if (busy) "Creating…" else "Start working")
        }
        OutlinedButton(
            onClick = { store.action { store.openCard(store.create(title, prompt, false)) } },
            enabled = prompt.isNotBlank() && !busy,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text("Save to Todo")
        }
    }
}

@Composable
private fun ChatsScreen(store: MobileStore) {
    val view by store.workspace.collectAsState()
    val chats = view.cards.filter { it.scope == "chat" }
    Column(Modifier.fillMaxSize().padding(22.dp)) {
        Text(
            "Conversations",
            style = MaterialTheme.typography.headlineLarge,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(20.dp))
        if (chats.isEmpty()) Empty("A little space to think", "Standalone chats appear here.")
        else
            LazyColumn(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                items(chats, key = { it.id }) { TaskCard(it, null) { store.openCard(it.id) } }
            }
    }
}

@Composable
private fun MachinesScreen(store: MobileStore) {
    val session by store.session.collectAsState()
    Column(
        Modifier.fillMaxSize().padding(22.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        Text(
            "Your machines",
            style = MaterialTheme.typography.headlineLarge,
            fontWeight = FontWeight.Bold,
        )
        Text("The work happens where your code lives.", color = Scheme.onSurfaceVariant)
        session.machines.forEach { machine ->
            Surface(shape = RoundedCornerShape(22.dp), color = Color.White) {
                Row(
                    Modifier.fillMaxWidth().padding(20.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Outlined.Computer, null, tint = Green)
                    Spacer(Modifier.width(16.dp))
                    Column {
                        Text(machine.display_name, fontWeight = FontWeight.SemiBold)
                        Text(
                            machine.detail,
                            color = Scheme.onSurfaceVariant,
                            style = MaterialTheme.typography.bodySmall,
                        )
                        Text(
                            machine.route,
                            style = MaterialTheme.typography.labelSmall,
                            color = Green,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun Empty(title: String, detail: String) {
    Column(
        Modifier.fillMaxSize().padding(30.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(Icons.Outlined.AutoAwesome, null, Modifier.size(32.dp), tint = Coral)
        Spacer(Modifier.height(16.dp))
        Text(title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        Text(detail, color = Scheme.onSurfaceVariant)
    }
}

@Composable
private fun SignInScreen(store: MobileStore) {
    var gateway by rememberSaveable { mutableStateOf("https://") }
    val busy by store.busy.collectAsState()
    Column(Modifier.fillMaxSize().padding(28.dp), verticalArrangement = Arrangement.Center) {
        Text(
            "Bring your work with you",
            style = MaterialTheme.typography.headlineLarge,
            fontWeight = FontWeight.Bold,
        )
        Spacer(Modifier.height(12.dp))
        Text(
            "Connect to your Dieter gateway to see your projects and machines.",
            color = Scheme.onSurfaceVariant,
        )
        Spacer(Modifier.height(24.dp))
        OutlinedTextField(
            gateway,
            { gateway = it },
            Modifier.fillMaxWidth(),
            label = { Text("Gateway address") },
            singleLine = true,
            shape = RoundedCornerShape(18.dp),
        )
        Spacer(Modifier.height(16.dp))
        Button(
            onClick = { store.signIn(gateway) },
            enabled = !busy,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text("Sign in")
        }
    }
}
