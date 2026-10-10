@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.dbpprt.dieter.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.composition.Attachments

@Composable
internal fun CreationScreen(store: MobileStore, chat: Boolean) {
    val workspace by store.workspace.collectAsState()
    val session by store.session.collectAsState()
    val intent by store.creationIntent.collectAsState()
    val preview by store.creationPreview.collectAsState()
    val busy by store.busy.collectAsState()
    var runNow by rememberSaveable { mutableStateOf(true) }
    val prompt = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { prompt.requestFocus() } }
    val pick =
        rememberAttachmentPicker(
            { added ->
                com.dbpprt.dieter.core.composition.Attachments.appending(
                        store.creationIntent.value.attachments,
                        added,
                    )
                    .fold(
                        { store.preview(store.creationIntent.value.copy(attachments = it)) },
                        { store.error.value = it.message.orEmpty() },
                    )
            },
            { store.error.value = it },
        )
    val project = workspace.projects.firstOrNull { it.id == intent.project_id }
    val boards = workspace.boards.filter { it.project_id == intent.project_id }
    val board = boards.firstOrNull { it.id == intent.board_id }
    val ready = preview.problem.isEmpty() && intent.prompt.isNotBlank() && !busy
    fun submit() = store.action {
        val id = store.submitCreation(intent.copy(lane = if (chat || runNow) "running" else "todo"))
        store.dismiss()
        store.openConversation(id)
    }
    val chrome =
        ScreenChrome(
            when {
                chat && apple -> "New Chat"
                chat -> "New chat"
                apple -> "New Task"
                else -> "New task"
            },
            cancel = ChromeAction("cancel-creation", "Cancel", Glyph.CLOSE) { store.dismiss() },
            confirm =
                ChromeAction(
                    "start-working",
                    if (chat || runNow) "Start" else "Add",
                    if (chat || runNow) Glyph.ARROW_UP else Glyph.CHECK,
                    enabled = ready,
                ) {
                    submit()
                },
        )
    Screen(chrome) {
        LazyColumn(
            Modifier.fillMaxSize().imePadding().testTag("creation-form"),
            state = listState,
            contentPadding =
                PaddingValues(
                    top = padding.calculateTopPadding() + 8.dp,
                    bottom = padding.calculateBottomPadding() + 24.dp,
                ),
        ) {
            item("compose") {
                Column(
                    Modifier.fillMaxWidth()
                        .padding(horizontal = ScreenMargin)
                        .clip(groupShape(Position.SINGLE))
                        .background(palette.cell)
                ) {
                    BasicTextField(
                        intent.title,
                        { store.preview(intent.copy(title = it)) },
                        Modifier.fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 14.dp)
                            .testTag("task-title")
                            .semantics {
                                contentDescription = if (chat) "Chat title" else "Task title"
                            },
                        singleLine = true,
                        // Return moves on to the prompt, which then scrolls above the keyboard.
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
                        keyboardActions = KeyboardActions(onNext = { prompt.requestFocus() }),
                        textStyle = type.headline.copy(color = palette.label),
                        cursorBrush = SolidColor(if (apple) palette.info else colors.primary),
                        decorationBox = { inner ->
                            Box {
                                if (intent.title.isEmpty())
                                    Text(
                                        if (chat) "Title (optional)" else "Title (optional)",
                                        style = type.headline.copy(fontWeight = FontWeight.Normal),
                                        color = palette.tertiaryLabel,
                                    )
                                inner()
                            }
                        },
                    )
                    Hairline(inset = 16.dp)
                    BasicTextField(
                        intent.prompt,
                        { store.preview(intent.copy(prompt = it)) },
                        Modifier.fillMaxWidth()
                            .heightIn(min = 150.dp)
                            .padding(horizontal = 16.dp, vertical = 14.dp)
                            .focusRequester(prompt)
                            .testTag("task-prompt")
                            .semantics { contentDescription = "What should we do?" },
                        textStyle = type.body.copy(color = palette.label),
                        cursorBrush = SolidColor(if (apple) palette.info else colors.primary),
                        decorationBox = { inner ->
                            Box {
                                if (intent.prompt.isEmpty())
                                    Text(
                                        if (chat) "What would you like to talk about?"
                                        else "What should we do?",
                                        style = type.body,
                                        color = palette.tertiaryLabel,
                                    )
                                inner()
                            }
                        },
                    )
                    Hairline(inset = 16.dp)
                    Row(
                        Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        DButton(
                            "Attach",
                            pick,
                            kind = ButtonKind.PLAIN,
                            glyph = Glyph.ATTACH,
                            enabled = intent.attachments.size < 4,
                            modifier = Modifier.testTag("creation-attach"),
                        )
                        Spacer(Modifier.weight(1f))
                        Text(
                            if (intent.attachments.isEmpty())
                                "Up to ${Attachments.MAX_COUNT} · ${Attachments.MAX_FILE_BYTES shr 20} MB each"
                            else "${intent.attachments.size} of ${Attachments.MAX_COUNT}",
                            Modifier.padding(end = 8.dp).weight(2f, fill = false),
                            style = type.caption,
                            color = palette.tertiaryLabel,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    if (intent.attachments.isNotEmpty())
                        FlowRow(
                            Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            intent.attachments.forEachIndexed { index, part ->
                                Row(
                                    Modifier.clip(CircleShape)
                                        .background(palette.fill)
                                        .padding(
                                            start = 12.dp,
                                            end = 4.dp,
                                            top = 4.dp,
                                            bottom = 4.dp,
                                        ),
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Text(
                                        part.filename.ifEmpty { "Attachment" },
                                        style = type.footnote,
                                        color = palette.label,
                                        maxLines = 1,
                                    )
                                    Box(
                                        Modifier.size(26.dp)
                                            .clip(CircleShape)
                                            .pressable(
                                                onClick = {
                                                    store.preview(
                                                        intent.copy(
                                                            attachments =
                                                                intent.attachments.filterIndexed {
                                                                    i,
                                                                    _ ->
                                                                    i != index
                                                                }
                                                        )
                                                    )
                                                }
                                            )
                                            .semantics {
                                                contentDescription = "Remove ${part.filename}"
                                            },
                                        contentAlignment = Alignment.Center,
                                    ) {
                                        Icon(
                                            Glyph.CLOSE,
                                            null,
                                            tint = palette.secondaryLabel,
                                            size = 11.dp,
                                            weight = GlyphWeight.BOLD,
                                        )
                                    }
                                }
                            }
                        }
                }
            }
            if (!chat)
                item("when") {
                    Segmented(
                        listOf("Start now", "Add to Todo"),
                        if (runNow) 0 else 1,
                        { runNow = it == 0 },
                        Modifier.padding(start = ScreenMargin, end = ScreenMargin, top = 16.dp),
                        testTagPrefix = "creation-when",
                    )
                }
            item("destination") {
                SectionHeader("Destination")
                val rows =
                    buildList<@Composable (Position) -> Unit> {
                        add { position ->
                            PickerRow(
                                "Project",
                                project?.name.orEmpty(),
                                workspace.projects.map { it.id to it.name },
                                intent.project_id,
                                true,
                                position,
                                Glyph.FOLDER,
                            ) { id ->
                                store.preview(
                                    intent.copy(project_id = id, board_id = "", checkout_id = "")
                                )
                            }
                        }
                        if (!chat)
                            add { position ->
                                PickerRow(
                                    "Board",
                                    board?.name.orEmpty(),
                                    boards.map { it.id to it.name },
                                    intent.board_id,
                                    boards.isNotEmpty(),
                                    position,
                                    Glyph.BOARD,
                                ) {
                                    store.preview(intent.copy(board_id = it))
                                }
                            }
                        add { position ->
                            val checkouts = project?.checkouts.orEmpty()
                            val checkout = checkouts.firstOrNull { it.id == intent.checkout_id }
                            fun machineName(daemon: String, fallback: String) =
                                session.machines.firstOrNull { it.id == daemon }?.display_name
                                    ?: fallback
                            PickerRow(
                                "Run on",
                                checkout?.let { machineName(it.daemon_id, it.name) }.orEmpty(),
                                checkouts.map {
                                    it.id to
                                        (machineName(it.daemon_id, it.name) +
                                            if (
                                                checkouts.count { c ->
                                                    c.daemon_id == it.daemon_id
                                                } > 1
                                            )
                                                " · ${it.name}"
                                            else "")
                                },
                                intent.checkout_id,
                                checkouts.isNotEmpty(),
                                position,
                                Glyph.MACHINE,
                            ) {
                                store.preview(intent.copy(checkout_id = it))
                            }
                        }
                    }
                Group(rows) { row, position -> row(position) }
                val status = preview.destination_status
                val checkoutName =
                    project?.checkouts?.firstOrNull { it.id == intent.checkout_id }?.name
                // The core reports either a problem or, when all is well, the checkout's name.
                if (status.isNotEmpty())
                    SectionFooter(if (status == checkoutName) "Checkout: $status" else status)
            }
            item("agent") {
                SectionHeader("Agent")
                AgentSettings(preview.agent) { choice -> store.preview(intent, choice) }
            }
            item("workspace") {
                SectionHeader("Workspace")
                Column(
                    Modifier.fillMaxWidth()
                        .padding(horizontal = ScreenMargin)
                        .clip(groupShape(Position.SINGLE))
                        .background(palette.cell)
                        .padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Segmented(
                        listOf("New worktree", "Project directory"),
                        if (intent.workspace_mode == "worktree") 0 else 1,
                        {
                            store.preview(
                                intent.copy(workspace_mode = if (it == 0) "worktree" else "project")
                            )
                        },
                        testTagPrefix = "workspace-mode",
                    )
                    if (intent.workspace_mode == "worktree") {
                        MobileTextField(
                            intent.workspace_branch,
                            { store.preview(intent.copy(workspace_branch = it)) },
                            Modifier.fillMaxWidth(),
                            label = { Text("Branch") },
                            placeholder = { Text("Branch (automatic)") },
                            singleLine = true,
                        )
                        MobileTextField(
                            intent.workspace_base_branch,
                            { store.preview(intent.copy(workspace_base_branch = it)) },
                            Modifier.fillMaxWidth(),
                            label = { Text("Base branch") },
                            placeholder = { Text("Base branch") },
                            singleLine = true,
                        )
                    }
                }
                if (preview.workspace_detail.isNotEmpty()) SectionFooter(preview.workspace_detail)
            }
            item("vault") {
                SectionHeader("Vault")
                Group(listOf(0)) { _, position ->
                    ListRow(
                        "Allow vault access",
                        position = position,
                        subtitle = "The agent may use the account's passwords and TOTP codes",
                        trailing = {
                            DSwitch(
                                intent.vault_access,
                                { store.preview(intent.copy(vault_access = it)) },
                                Modifier.testTag("vault-access"),
                            )
                        },
                    )
                }
                SectionFooter("Set only when creating. Agents never see the vault otherwise.")
            }
            val labels = board?.labels.orEmpty()
            if (!chat && labels.isNotEmpty())
                item("labels") {
                    SectionHeader("Labels")
                    FlowRow(
                        Modifier.padding(horizontal = ScreenMargin + 4.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        labels.forEach { label ->
                            FilterPill(
                                label.name,
                                label.id in intent.label_ids,
                                {
                                    store.preview(
                                        intent.copy(
                                            label_ids =
                                                if (label.id in intent.label_ids)
                                                    intent.label_ids - label.id
                                                else intent.label_ids + label.id
                                        )
                                    )
                                },
                                dot = labelColor(label.color),
                            )
                        }
                    }
                }
            item("summary") {
                Column(
                    Modifier.padding(horizontal = ScreenMargin, vertical = 16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    if (preview.offline_hint.isNotEmpty())
                        Banner(
                            "Machine offline",
                            preview.offline_hint,
                            tone = Tone.WARNING,
                            glyph = Glyph.OFFLINE,
                        )
                    if (preview.problem.isNotEmpty() && intent.prompt.isNotBlank())
                        Text(
                            preview.problem,
                            Modifier.padding(horizontal = 16.dp),
                            style = type.footnote,
                            color = palette.destructive,
                        )
                    if (preview.summary.isNotEmpty())
                        Text(
                            preview.summary,
                            Modifier.padding(horizontal = 16.dp),
                            style = type.footnote,
                            color = palette.secondaryLabel,
                        )
                    if (!apple)
                        DButton(
                            if (chat || runNow) "Start working" else "Add to Todo",
                            ::submit,
                            Modifier.fillMaxWidth().padding(top = 8.dp).testTag("submit-creation"),
                            large = true,
                            enabled = ready,
                            loading = busy,
                        )
                }
            }
        }
    }
}
