@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.mobile

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.workspace.GitFormField
import com.dbpprt.dieter.core.workspace.GitOperationForm as OperationForm
import com.dbpprt.dieter.core.workspace.GitOperations
import com.dbpprt.dieter.mobile.icons.*

@Composable
internal fun ReviewScreen(store: MobileStore) {
    val view by store.review.collectAsState()
    val conversation by store.conversation.collectAsState()
    var operation by remember { mutableStateOf<String?>(null) }
    var comment by remember { mutableStateOf<Int?>(null) }
    var merging by remember { mutableStateOf(false) }
    val urls = LocalUriHandler.current
    fun send(value: ReviewCommand) =
        store.command(Command(review = value.copy(scope = MobileStore.REVIEW_SCOPE)))
    DisposableEffect(store) {
        send(ReviewCommand(active = Toggle(true)))
        onDispose { send(ReviewCommand(active = Toggle(false))) }
    }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.padding(horizontal = 12.dp).horizontalScroll(rememberScrollState())) {
            IconButton(onClick = { send(ReviewCommand(refresh = Step())) }) {
                Icon(Icons.Outlined.Refresh, "Refresh changes")
            }
            FilterChip(
                view.split,
                { send(ReviewCommand(layout = ReviewLayout(!view.split))) },
                label = { Text("Split diff") },
            )
            view.availability?.allowed.orEmpty().forEach { kind ->
                AssistChip(
                    onClick = { operation = kind },
                    label = { Text(GitOperations.title(kind)) },
                )
            }
            if (view.availability?.allows_merge_flow == true)
                AssistChip(
                    onClick = { merging = true },
                    label = {
                        Text(view.merge_readiness?.merge_title?.ifEmpty { "Merge" } ?: "Merge")
                    },
                    enabled = !view.submitting && view.merge_readiness?.blocked != true,
                )
        }
        if (view.error.isNotEmpty())
            Notice("Changes unavailable", view.error, { send(ReviewCommand(refresh = Step())) })
        if (view.loading || view.diff_loading || view.submitting)
            LinearProgressIndicator(Modifier.fillMaxWidth())
        LazyColumn(
            contentPadding = PaddingValues(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (view.workspace_state.isNotEmpty())
                item {
                    Text(
                        view.workspace_state + " · " + view.changeset?.branch.orEmpty(),
                        style = MaterialTheme.typography.labelLarge,
                    )
                }
            if (view.conflict_title.isNotEmpty())
                item {
                    Notice(
                        view.conflict_title,
                        "Resolve the files, then continue the paused operation.",
                        { store.action { store.send(view.conflict_prompt) } },
                        "Ask agent",
                        true,
                    )
                }
            view.pull_request?.let { pr ->
                item {
                    FormSection("Pull request #${pr.number} · ${pr.state_label}") {
                        pr.signals.forEach { Text(it.text) }
                        if (pr.url.isNotEmpty())
                            TextButton(onClick = { urls.openUri(pr.url) }) {
                                Text("Open pull request")
                            }
                        if (pr.merge_blocked_reason.isNotEmpty()) Text(pr.merge_blocked_reason)
                        if (pr.can_ask_agent)
                            TextButton(
                                onClick = { store.action { store.send(pr.ask_agent_prompt) } }
                            ) {
                                Text("Ask agent to address feedback")
                            }
                    }
                }
            }
            view.merge_readiness?.items.orEmpty().forEach { check ->
                item {
                    ListItem(
                        headlineContent = { Text(check.text) },
                        supportingContent = { if (check.detail.isNotEmpty()) Text(check.detail) },
                        leadingContent = {
                            Icon(
                                if (check.tone == WorkspaceTone.WORKSPACE_TONE_DANGER)
                                    Icons.Outlined.ErrorOutline
                                else Icons.Outlined.CheckCircle,
                                null,
                                tint =
                                    if (check.tone == WorkspaceTone.WORKSPACE_TONE_DANGER)
                                        colors.error
                                    else colors.onSurfaceVariant,
                            )
                        },
                    )
                }
            }
            if (view.operation_visible)
                item {
                    FormSection(GitOperations.title(view.operation?.kind.orEmpty())) {
                        Text(view.operation?.status.orEmpty())
                        if (view.operation_cancelable)
                            TextButton(
                                onClick = { send(ReviewCommand(cancel_operation = Step())) }
                            ) {
                                Text("Cancel operation")
                            }
                        SelectionContainer {
                            Text(
                                view.logs.joinToString("\n") { it.message },
                                fontFamily = FontFamily.Monospace,
                                style = MaterialTheme.typography.bodySmall,
                            )
                        }
                    }
                }
            items(view.changeset?.files.orEmpty(), key = { it.path }) { file ->
                ListItem(
                    headlineContent = { Text(file.path) },
                    supportingContent = {
                        Text("${file.status} · +${file.additions} −${file.deletions}")
                    },
                    modifier =
                        Modifier.clickable {
                            send(ReviewCommand(select = ReviewSelect(path = file.path)))
                        },
                )
            }
            items(view.changeset?.commits.orEmpty(), key = { it.sha }) { commit ->
                ListItem(
                    headlineContent = { Text(commit.subject) },
                    supportingContent = { Text(commit.short_sha + " · " + commit.author_name) },
                    modifier =
                        Modifier.clickable {
                            send(ReviewCommand(select = ReviewSelect(commit = commit.sha)))
                        },
                )
            }
            if (view.selected_path.isNotEmpty())
                item { Text(view.selected_path, style = MaterialTheme.typography.titleSmall) }
            itemsIndexed(view.display_rows) { _, row -> DiffRowView(row) { comment = it } }
            if (view.diff_note.isNotEmpty())
                item { Text(view.diff_note, style = MaterialTheme.typography.bodySmall) }
            if (view.diff_more)
                item {
                    TextButton(onClick = { send(ReviewCommand(load_more_diff = Step())) }) {
                        Text("Load the rest of this diff")
                    }
                }
            if (
                !view.loading &&
                    view.changeset?.files.isNullOrEmpty() &&
                    view.changeset?.commits.isNullOrEmpty()
            )
                item {
                    Box(Modifier.height(180.dp)) {
                        Empty(
                            "No changes",
                            "Changes and commits appear here as the workspace evolves.",
                        )
                    }
                }
        }
    }
    operation?.let { kind ->
        GitOperationEditor(kind, conversation.card, onDismiss = { operation = null }) { form ->
            send(ReviewCommand(start = form))
            operation = null
        }
    }
    if (merging)
        MergeEditor(view, conversation.card?.title.orEmpty(), { merging = false }) {
            send(ReviewCommand(merge = it))
            merging = false
        }
    comment?.let { row ->
        var text by remember(row) { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { comment = null },
            title = { Text("Comment on change") },
            text = {
                MobileTextField(
                    text,
                    { text = it },
                    minLines = 3,
                    label = { Text("Review comment") },
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        send(ReviewCommand(add_comment = ReviewComment(row_id = row, body = text)))
                        comment = null
                    },
                    enabled = text.isNotBlank(),
                ) {
                    Text("Add comment")
                }
            },
            dismissButton = { TextButton(onClick = { comment = null }) { Text("Cancel") } },
        )
    }
}

@Composable
internal fun DiffRowView(value: DiffDisplayRow, comment: ((Int) -> Unit)? = null) {
    var expanded by remember(value) { mutableStateOf(false) }
    when {
        value.line != null ->
            value.line?.let { line ->
                DiffLine(line.row, line.commentable && comment != null) { comment?.invoke(it) }
            }
        value.pair != null ->
            value.pair?.let { pair ->
                Row(Modifier.fillMaxWidth()) {
                    Box(Modifier.weight(1f)) {
                        DiffLine(
                            pair.before,
                            comment != null &&
                                ((pair.before?.old_line ?: 0) > 0 ||
                                    (pair.before?.new_line ?: 0) > 0),
                        ) {
                            comment?.invoke(it)
                        }
                    }
                    Box(Modifier.weight(1f)) {
                        DiffLine(
                            pair.after,
                            comment != null &&
                                ((pair.after?.old_line ?: 0) > 0 ||
                                    (pair.after?.new_line ?: 0) > 0),
                        ) {
                            comment?.invoke(it)
                        }
                    }
                }
            }
        else ->
            Surface(color = colors.surfaceContainerHigh, modifier = Modifier.fillMaxWidth()) {
                Text(
                    value.file_boundary?.path
                        ?: value.hunk?.text
                        ?: value.fold?.let { "${it.count} unchanged lines" }.orEmpty(),
                    Modifier.padding(8.dp),
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                )
            }
    }
    value.line?.comments.orEmpty().forEach {
        Text(it.body, Modifier.padding(start = 12.dp), style = MaterialTheme.typography.bodySmall)
    }
    value.fold?.let { fold ->
        TextButton(onClick = { expanded = !expanded }) {
            Text(if (expanded) "Hide context" else "Show context")
        }
        if (expanded) {
            fold.lines.forEach { DiffRowView(DiffDisplayRow(line = it), comment) }
            fold.pairs.forEach { DiffRowView(DiffDisplayRow(pair = it), comment) }
        }
    }
}

@Composable
private fun DiffLine(row: DiffRow?, commentable: Boolean, comment: (Int) -> Unit) {
    val tone =
        when (row?.kind) {
            DiffRow.Kind.KIND_ADDITION -> Color(0xFF45A66A)
            DiffRow.Kind.KIND_DELETION -> colors.error
            else -> colors.onSurfaceVariant
        }
    Surface(
        color =
            tone.copy(
                alpha =
                    if (row?.kind in listOf(DiffRow.Kind.KIND_ADDITION, DiffRow.Kind.KIND_DELETION))
                        .14f
                    else .04f
            ),
        modifier =
            Modifier.fillMaxWidth()
                .combinedClickable(
                    enabled = commentable,
                    onClick = { row?.let { comment(it.id) } },
                    onLongClick = { row?.let { comment(it.id) } },
                ),
    ) {
        Row(Modifier.padding(6.dp), verticalAlignment = Alignment.Top) {
            Text(
                listOf(row?.old_line ?: 0, row?.new_line ?: 0).joinToString(" ") {
                    if (it == 0) "·" else it.toString()
                },
                Modifier.width(64.dp),
                style = MaterialTheme.typography.labelSmall,
                color = colors.onSurfaceVariant,
                fontFamily = FontFamily.Monospace,
            )
            SelectionContainer {
                Text(
                    row?.text.orEmpty(),
                    Modifier.horizontalScroll(rememberScrollState()),
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                )
            }
        }
    }
}

@Composable
private fun MergeEditor(
    view: ReviewSlice,
    title: String,
    dismiss: () -> Unit,
    submit: (ReviewMerge) -> Unit,
) {
    var strategy by remember {
        mutableStateOf(view.merge_readiness?.strategies?.firstOrNull()?.strategy ?: "squash")
    }
    var subject by remember { mutableStateOf(title) }
    var body by remember { mutableStateOf("") }
    var validate by remember { mutableStateOf(true) }
    var remove by remember { mutableStateOf(false) }
    var done by remember { mutableStateOf(true) }
    ModalBottomSheet(onDismissRequest = dismiss) {
        Column(
            Modifier.imePadding().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                "Merge into ${view.availability?.merge_destination.orEmpty()}",
                style = MaterialTheme.typography.titleLarge,
            )
            view.merge_readiness?.items.orEmpty().forEach {
                Text(it.text, style = MaterialTheme.typography.bodySmall)
            }
            ChoiceChip(
                view.merge_readiness?.strategies?.firstOrNull { it.strategy == strategy }?.title
                    ?: strategy,
                view.merge_readiness?.strategies.orEmpty().map { it.strategy to it.title },
            ) {
                strategy = it
            }
            Text(
                view.merge_readiness
                    ?.strategies
                    ?.firstOrNull { it.strategy == strategy }
                    ?.caption
                    .orEmpty(),
                style = MaterialTheme.typography.bodySmall,
            )
            if (strategy != "fast_forward") {
                MobileTextField(
                    subject,
                    { subject = it },
                    label = { Text("Commit subject") },
                    modifier = Modifier.fillMaxWidth(),
                )
                MobileTextField(
                    body,
                    { body = it },
                    label = { Text("Commit body") },
                    minLines = 3,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(validate, { validate = it })
                Text("Run validation before merging")
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(remove, { remove = it })
                Text("Remove workspace after merging")
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Checkbox(done, { done = it })
                Text("Move card to Done")
            }
            Button(
                onClick = { submit(ReviewMerge(strategy, subject, body, validate, remove, done)) },
                enabled =
                    view.merge_readiness?.blocked != true &&
                        !view.submitting &&
                        (strategy == "fast_forward" || subject.isNotBlank()),
            ) {
                Text("Merge")
            }
        }
    }
}

@Composable
internal fun GitOperationEditor(
    kind: String,
    card: com.dbpprt.dieter.api.v1.Card?,
    onDismiss: () -> Unit,
    submit: (GitOperationForm) -> Unit,
) {
    var form by remember(kind) { mutableStateOf(OperationForm.initial(kind, card)) }
    val copy = GitOperations.copy(kind)
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            Modifier.imePadding().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(GitOperations.title(kind), style = MaterialTheme.typography.titleLarge)
            GitOperations.description(kind, card?.workspace?.base_branch.orEmpty())?.let {
                Text(it)
            }
            GitOperations.fields(kind).filter(form::shows).forEach { field ->
                when (field) {
                    GitFormField.SUBJECT ->
                        MobileTextField(
                            form.subject,
                            { form = form.copy(subject = it) },
                            label = { Text(copy.subject) },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    GitFormField.BODY ->
                        MobileTextField(
                            form.body,
                            { form = form.copy(body = it) },
                            label = { Text(copy.body) },
                            minLines = 3,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    GitFormField.STRATEGY ->
                        ChoiceChip(form.strategy, GitOperations.strategies(kind)) {
                            form = form.copy(strategy = it)
                        }
                    GitFormField.EXPECTED_REMOTE_SHA ->
                        MobileTextField(
                            form.expectedRemoteSha,
                            { form = form.copy(expectedRemoteSha = it) },
                            label = { Text(copy.expectedRemoteSha) },
                            supportingText = { Text(copy.expectedRemoteShaHelp) },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    GitFormField.TARGET_CARD_ID ->
                        MobileTextField(
                            form.targetCardId,
                            { form = form.copy(targetCardId = it) },
                            label = { Text(copy.targetCardId) },
                            modifier = Modifier.fillMaxWidth(),
                        )
                    else -> {
                        val (title, checked) =
                            when (field) {
                                GitFormField.STAGE_ALL -> copy.stageAll to form.stageAll
                                GitFormField.FETCH -> copy.fetch to form.fetch
                                GitFormField.VALIDATE -> copy.validate to form.validate
                                GitFormField.DRAFT -> copy.draft to form.draft
                                GitFormField.PUSH -> copy.push to form.push
                                else -> copy.forceWithLease to form.forceWithLease
                            }
                        Row {
                            Checkbox(
                                checked,
                                { on ->
                                    form =
                                        when (field) {
                                            GitFormField.STAGE_ALL -> form.copy(stageAll = on)
                                            GitFormField.FETCH -> form.copy(fetch = on)
                                            GitFormField.VALIDATE -> form.copy(validate = on)
                                            GitFormField.DRAFT -> form.copy(draft = on)
                                            GitFormField.PUSH -> form.copy(push = on)
                                            else -> form.copy(forceWithLease = on)
                                        }
                                },
                            )
                            Text(title, Modifier.padding(top = 12.dp))
                        }
                    }
                }
            }
            GitOperations.notice(kind)?.let {
                Text(it.title + "\n" + it.detail, style = MaterialTheme.typography.bodySmall)
            }
            Button(
                onClick = {
                    submit(
                        GitOperationForm(
                            kind = kind,
                            subject = form.subject,
                            body = form.body,
                            stage_all = form.stageAll,
                            validate = form.validate,
                            fetch = form.fetch,
                            draft = form.draft,
                            push = form.push,
                            strategy = form.strategy,
                            force_with_lease = form.forceWithLease,
                            expected_remote_sha = form.expectedRemoteSha,
                            target_card_id = form.targetCardId,
                        )
                    )
                },
                enabled = form.ready,
            ) {
                Text(GitOperations.title(kind))
            }
        }
    }
}
