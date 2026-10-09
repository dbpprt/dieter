package com.dbpprt.dieter.mobile

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.api.v1.ChangedFile
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.workspace.GitFormField
import com.dbpprt.dieter.core.workspace.GitOperationForm as OperationForm
import com.dbpprt.dieter.core.workspace.GitOperations

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
    val changeset = view.changeset
    val operations = view.availability?.allowed.orEmpty()
    val chrome =
        ScreenChrome(
            "Changes",
            subtitle =
                listOfNotNull(
                        changeset?.branch?.takeIf { it.isNotEmpty() },
                        changeset?.let {
                            if (it.additions + it.deletions > 0) "+${it.additions} −${it.deletions}"
                            else null
                        },
                    )
                    .joinToString(" · "),
            actions =
                listOf(
                    ChromeAction(
                        "review-menu",
                        "Git actions",
                        Glyph.MORE_HORIZONTAL,
                        menu =
                            listOfNotNull(
                                if (
                                    operations.isNotEmpty() ||
                                        view.availability?.allows_merge_flow == true
                                )
                                    MenuSection(
                                        operations.map { kind ->
                                            ChromeAction(
                                                "git-$kind",
                                                GitOperations.title(kind),
                                                gitGlyph(kind),
                                                enabled = !view.submitting,
                                            ) {
                                                operation = kind
                                            }
                                        } +
                                            listOfNotNull(
                                                if (view.availability?.allows_merge_flow == true)
                                                    ChromeAction(
                                                        "merge",
                                                        view.merge_readiness?.merge_title?.ifEmpty {
                                                            "Merge"
                                                        } ?: "Merge",
                                                        Glyph.MERGE,
                                                        enabled =
                                                            !view.submitting &&
                                                                view.merge_readiness?.blocked !=
                                                                    true,
                                                    ) {
                                                        merging = true
                                                    }
                                                else null
                                            )
                                    )
                                else null,
                                MenuSection(
                                    listOf(
                                        ChromeAction(
                                            "split",
                                            "Side-by-side diff",
                                            Glyph.CHANGES,
                                            checked = view.split,
                                        ) {
                                            send(ReviewCommand(layout = ReviewLayout(!view.split)))
                                        },
                                        ChromeAction("refresh-review", "Refresh", Glyph.REFRESH) {
                                            send(ReviewCommand(refresh = Step()))
                                        },
                                    )
                                ),
                            ),
                    )
                ),
        )
    Screen(chrome) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("review"),
            state = listState,
            contentPadding = padding,
        ) {
            item { Spacer(Modifier.height(4.dp)) }
            if (view.error.isNotEmpty())
                item {
                    Banner(
                        "Changes unavailable",
                        view.error,
                        Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                        tone = Tone.DANGER,
                        actionLabel = "Retry",
                        onAction = { send(ReviewCommand(refresh = Step())) },
                    )
                }
            if (view.loading && changeset == null)
                item {
                    Box(
                        Modifier.fillMaxWidth().padding(40.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Spinner(Modifier.size(24.dp))
                    }
                }
            if (view.workspace_state.isNotEmpty())
                item {
                    Row(
                        Modifier.padding(horizontal = ScreenMargin + 4.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Glyph.BRANCH, null, tint = palette.secondaryLabel, size = 15.dp)
                        Spacer(Modifier.width(6.dp))
                        Text(
                            view.workspace_state,
                            style = type.subheadline,
                            color = palette.secondaryLabel,
                        )
                    }
                }
            if (view.conflict_title.isNotEmpty())
                item {
                    Banner(
                        view.conflict_title,
                        "Resolve the files, then continue the paused operation.",
                        Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                        tone = Tone.DANGER,
                        actionLabel = "Ask agent",
                        onAction = {
                            store.action { store.send(view.conflict_prompt) }
                        },
                    )
                }
            view.pull_request?.let { pr ->
                item {
                    ContentCard(Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Glyph.MERGE, null, tint = palette.purple, size = 18.dp)
                            Spacer(Modifier.width(8.dp))
                            Text(
                                "Pull request #${pr.number}",
                                Modifier.weight(1f),
                                style = type.headline,
                                color = palette.label,
                            )
                            Text(
                                pr.state_label,
                                style = type.footnote,
                                color = palette.secondaryLabel,
                            )
                        }
                        pr.signals.forEach {
                            Text(
                                it.text,
                                Modifier.padding(top = 6.dp),
                                style = type.subheadline,
                                color = palette.secondaryLabel,
                            )
                        }
                        if (pr.merge_blocked_reason.isNotEmpty())
                            Text(
                                pr.merge_blocked_reason,
                                Modifier.padding(top = 6.dp),
                                style = type.subheadline,
                                color = palette.warning.readableOn(palette.cell),
                            )
                        Row(
                            Modifier.padding(top = 8.dp),
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            if (pr.url.isNotEmpty())
                                DButton(
                                    "Open",
                                    { urls.openUri(pr.url) },
                                    kind = ButtonKind.TONAL,
                                    glyph = Glyph.OPEN,
                                )
                            if (pr.can_ask_agent)
                                DButton(
                                    "Address feedback",
                                    { store.action { store.send(pr.ask_agent_prompt) } },
                                    kind = ButtonKind.PLAIN,
                                )
                        }
                    }
                }
            }
            val checks = view.merge_readiness?.items.orEmpty()
            if (checks.isNotEmpty()) {
                item { SectionHeader("Merge readiness") }
                itemsIndexed(checks) { index, check ->
                    val danger = check.tone == WorkspaceTone.WORKSPACE_TONE_DANGER
                    ListRow(
                        check.text,
                        position = Position.of(index, checks.size),
                        subtitle = check.detail.takeIf { it.isNotEmpty() },
                        glyph = if (danger) Glyph.ERROR else Glyph.CHECK_CIRCLE,
                        glyphTint = if (danger) palette.destructive else palette.success,
                        titleMaxLines = 2,
                    )
                }
            }
            if (view.operation_visible)
                item {
                    ContentCard(Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            if (view.operation_active) Spinner(Modifier.size(16.dp))
                            else
                                Icon(
                                    Glyph.TERMINAL,
                                    null,
                                    tint = palette.secondaryLabel,
                                    size = 16.dp,
                                )
                            Spacer(Modifier.width(8.dp))
                            Text(
                                GitOperations.title(view.operation?.kind.orEmpty()),
                                Modifier.weight(1f),
                                style = type.headline,
                                color = palette.label,
                            )
                            if (view.operation_cancelable)
                                DButton(
                                    "Cancel",
                                    { send(ReviewCommand(cancel_operation = Step())) },
                                    kind = ButtonKind.PLAIN,
                                )
                        }
                        Text(
                            view.operation?.status.orEmpty(),
                            style = type.footnote,
                            color = palette.secondaryLabel,
                        )
                        if (view.logs.isNotEmpty())
                            SelectionContainer {
                                Text(
                                    view.logs.joinToString("\n") { it.message },
                                    Modifier.fillMaxWidth()
                                        .padding(top = 8.dp)
                                        .clip(RoundedCornerShape(10.dp))
                                        .background(palette.inset)
                                        .padding(10.dp),
                                    style = type.monoSmall,
                                    color = palette.label,
                                )
                            }
                    }
                }
            val files = changeset?.files.orEmpty()
            if (files.isNotEmpty()) {
                item {
                    SectionHeader("${files.size} changed file${if (files.size == 1) "" else "s"}")
                }
                changedFiles(
                    files,
                    view.selected_path,
                    view.display_rows,
                    view,
                    onSelect = { path ->
                        send(
                            ReviewCommand(
                                select =
                                    ReviewSelect(
                                        path = if (path == view.selected_path) "" else path
                                    )
                            )
                        )
                    },
                    onComment = { comment = it },
                    onMore = { send(ReviewCommand(load_more_diff = Step())) },
                )
            }
            val commits = changeset?.commits.orEmpty()
            if (commits.isNotEmpty()) {
                item { SectionHeader("Commits") }
                itemsIndexed(commits, key = { _, commit -> commit.sha }) { index, commit ->
                    ListRow(
                        commit.subject,
                        position = Position.of(index, commits.size),
                        subtitle = commit.short_sha + " · " + commit.author_name,
                        glyph = Glyph.COMMIT,
                        selected = commit.sha == view.selected_commit,
                        onClick = {
                            send(ReviewCommand(select = ReviewSelect(commit = commit.sha)))
                        },
                    )
                }
                if (view.selected_commit.isNotEmpty() && view.display_rows.isNotEmpty())
                    item {
                        DiffBlock(
                            view.display_rows,
                            view.diff_note,
                            view.diff_more,
                            { comment = it },
                        ) {
                            send(ReviewCommand(load_more_diff = Step()))
                        }
                    }
            }
            if (!view.loading && files.isEmpty() && commits.isEmpty() && view.error.isEmpty())
                item {
                    EmptyState(
                        Glyph.CHANGES,
                        "No changes yet",
                        "Edits and commits from this conversation appear here.",
                        Modifier.padding(top = 40.dp),
                    )
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
        PromptDialog(
            "Comment on change",
            "",
            "Add comment",
            { text ->
                send(ReviewCommand(add_comment = ReviewComment(row_id = row, body = text)))
                comment = null
            },
            { comment = null },
            placeholder = "Review comment",
        )
    }
}

internal fun gitGlyph(kind: String): Glyph =
    when (kind) {
        "commit" -> Glyph.COMMIT
        "push" -> Glyph.PUSH
        "pull",
        "fetch" -> Glyph.PULL
        "rebase",
        "merge" -> Glyph.MERGE
        "stage" -> Glyph.ADD
        else -> Glyph.BRANCH
    }

/** Changed files as an accordion: the selected file shows its diff directly beneath it. */
internal fun LazyListScope.changedFiles(
    files: List<ChangedFile>,
    selected: String,
    rows: List<DiffDisplayRow>,
    view: Any?,
    onSelect: (String) -> Unit,
    onComment: ((Int) -> Unit)?,
    onMore: () -> Unit,
    trailing: (@Composable (ChangedFile) -> Unit)? = null,
) {
    val note =
        (view as? ReviewSlice)?.diff_note ?: (view as? ProjectChangesSlice)?.diff_note.orEmpty()
    val more =
        (view as? ReviewSlice)?.diff_more ?: (view as? ProjectChangesSlice)?.diff_more ?: false
    val loading =
        (view as? ReviewSlice)?.diff_loading
            ?: (view as? ProjectChangesSlice)?.diff_loading
            ?: false
    files.forEachIndexed { index, file ->
        item("file-${file.path}") {
            ChangedFileRow(file, Position.of(index, files.size), file.path == selected, trailing) {
                onSelect(file.path)
            }
        }
        if (file.path == selected)
            item("diff-${file.path}") {
                if (loading && rows.isEmpty())
                    Box(
                        Modifier.fillMaxWidth().padding(24.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Spinner()
                    }
                else DiffBlock(rows, note, more, onComment, onMore)
            }
    }
}

@Composable
private fun ChangedFileRow(
    file: ChangedFile,
    position: Position,
    selected: Boolean,
    trailing: (@Composable (ChangedFile) -> Unit)?,
    onClick: () -> Unit,
) {
    val status = file.status.ifEmpty { if (file.untracked) "?" else "M" }.take(1).uppercase()
    val tint =
        when (status) {
            "A",
            "?" -> palette.success
            "D" -> palette.destructive
            "R" -> palette.purple
            else -> palette.warning
        }
    GroupItem(
        position,
        Modifier.testTag("changed-${file.path}"),
        separatorInset = 52.dp,
        onClick = onClick,
        selected = selected,
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(24.dp)
                    .clip(RoundedCornerShape(6.dp))
                    .background(tint.copy(alpha = .16f)),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    status,
                    style = type.caption.copy(fontWeight = FontWeight.Bold),
                    color = tint.readableOn(palette.cell),
                )
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    file.path.substringAfterLast('/'),
                    style = type.subheadline.copy(fontWeight = FontWeight.Medium),
                    color = palette.label,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                val directory = file.path.substringBeforeLast('/', "")
                if (directory.isNotEmpty())
                    Text(
                        directory,
                        style = type.caption,
                        color = palette.secondaryLabel,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
            }
            Spacer(Modifier.width(8.dp))
            if (file.binary) Text("Binary", style = type.caption, color = palette.secondaryLabel)
            else {
                Text(
                    "+${file.additions}",
                    style = type.caption.copy(fontWeight = FontWeight.SemiBold),
                    color = palette.success.readableOn(palette.cell),
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    "−${file.deletions}",
                    style = type.caption.copy(fontWeight = FontWeight.SemiBold),
                    color = palette.destructive,
                )
            }
            trailing?.invoke(file)
            Spacer(Modifier.width(6.dp))
            DisclosureChevron(selected)
        }
    }
}

/** Unified or split diff lines, monospaced and soft-wrapped for small screens. */
@Composable
internal fun DiffBlock(
    rows: List<DiffDisplayRow>,
    note: String,
    more: Boolean,
    comment: ((Int) -> Unit)?,
    onMore: () -> Unit,
) {
    Column(
        Modifier.fillMaxWidth()
            .padding(horizontal = ScreenMargin, vertical = 6.dp)
            .clip(RoundedCornerShape(14.dp))
            .background(palette.cell)
            .padding(vertical = 6.dp)
    ) {
        rows.forEach { DiffRowView(it, comment) }
        if (note.isNotEmpty())
            Text(
                note,
                Modifier.padding(12.dp),
                style = type.footnote,
                color = palette.secondaryLabel,
            )
        if (more)
            DButton(
                "Load the rest of this diff",
                onMore,
                Modifier.padding(horizontal = 6.dp),
                kind = ButtonKind.PLAIN,
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
                                (pair.before?.old_line ?: 0) + (pair.before?.new_line ?: 0) > 0,
                        ) {
                            comment?.invoke(it)
                        }
                    }
                    Box(Modifier.weight(1f)) {
                        DiffLine(
                            pair.after,
                            comment != null &&
                                (pair.after?.old_line ?: 0) + (pair.after?.new_line ?: 0) > 0,
                        ) {
                            comment?.invoke(it)
                        }
                    }
                }
            }
        else ->
            Text(
                value.file_boundary?.path
                    ?: value.hunk?.text
                    ?: value.fold?.let { "${it.count} unchanged lines" }.orEmpty(),
                Modifier.fillMaxWidth()
                    .background(palette.info.copy(alpha = .08f))
                    .padding(horizontal = 12.dp, vertical = 5.dp),
                style = type.monoSmall,
                color = palette.info.readableOn(palette.cell),
            )
    }
    value.line?.comments.orEmpty().forEach {
        Text(
            it.body,
            Modifier.fillMaxWidth()
                .background(palette.warning.copy(alpha = .1f))
                .padding(horizontal = 12.dp, vertical = 6.dp),
            style = type.footnote,
            color = palette.label,
        )
    }
    value.fold?.let { fold ->
        DButton(
            if (expanded) "Hide context" else "Show ${fold.count} lines",
            { expanded = !expanded },
            Modifier.padding(horizontal = 6.dp),
            kind = ButtonKind.PLAIN,
        )
        if (expanded) {
            fold.lines.forEach { DiffRowView(DiffDisplayRow(line = it), comment) }
            fold.pairs.forEach { DiffRowView(DiffDisplayRow(pair = it), comment) }
        }
    }
}

@Composable
private fun DiffLine(row: DiffRow?, commentable: Boolean, comment: (Int) -> Unit) {
    val addition = row?.kind == DiffRow.Kind.KIND_ADDITION
    val deletion = row?.kind == DiffRow.Kind.KIND_DELETION
    val tone =
        if (addition) palette.success else if (deletion) palette.destructive else Color.Transparent
    Row(
        Modifier.fillMaxWidth()
            .background(
                tone.copy(
                    alpha = if (addition || deletion) (if (palette.dark) .2f else .12f) else 0f
                )
            )
            .then(
                if (commentable)
                    Modifier.pressable(
                        onClick = { row?.let { comment(it.id) } },
                        onLongClick = { row?.let { comment(it.id) } },
                    )
                else Modifier
            )
            .padding(vertical = 1.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Text(
            (row?.new_line?.takeIf { it > 0 } ?: row?.old_line?.takeIf { it > 0 })
                ?.toString()
                .orEmpty(),
            Modifier.width(38.dp).padding(end = 6.dp),
            style = type.monoSmall,
            color = palette.tertiaryLabel,
            maxLines = 1,
            textAlign = androidx.compose.ui.text.style.TextAlign.End,
        )
        Text(
            if (addition) "+" else if (deletion) "−" else " ",
            Modifier.width(12.dp),
            style = type.monoSmall,
            color =
                tone.takeIf { addition || deletion }?.readableOn(palette.cell)
                    ?: palette.tertiaryLabel,
        )
        Text(
            row?.text.orEmpty(),
            Modifier.weight(1f).padding(end = 10.dp),
            style = type.monoSmall,
            color = palette.label,
        )
    }
}

@Composable
internal fun MergeEditor(
    view: ReviewSlice,
    title: String,
    dismiss: () -> Unit,
    submit: (ReviewMerge) -> Unit,
) {
    val strategies = view.merge_readiness?.strategies.orEmpty()
    var strategy by remember { mutableStateOf(strategies.firstOrNull()?.strategy ?: "squash") }
    var subject by remember { mutableStateOf(title) }
    var body by remember { mutableStateOf("") }
    var validate by remember { mutableStateOf(true) }
    var remove by remember { mutableStateOf(false) }
    var done by remember { mutableStateOf(true) }
    Sheet(
        "Merge into ${view.availability?.merge_destination.orEmpty()}",
        dismiss,
        confirm =
            ChromeAction(
                "merge-confirm",
                "Merge",
                Glyph.MERGE,
                enabled =
                    view.merge_readiness?.blocked != true &&
                        !view.submitting &&
                        (strategy == "fast_forward" || subject.isNotBlank()),
            ) {
                submit(ReviewMerge(strategy, subject, body, validate, remove, done))
            },
    ) {
        Group(listOf(0)) { _, position ->
            PickerRow(
                "Strategy",
                strategies.firstOrNull { it.strategy == strategy }?.title ?: strategy,
                strategies.map { it.strategy to it.title },
                strategy,
                strategies.isNotEmpty(),
                position,
                Glyph.MERGE,
            ) {
                strategy = it
            }
        }
        strategies
            .firstOrNull { it.strategy == strategy }
            ?.caption
            ?.takeIf { it.isNotEmpty() }
            ?.let { SectionFooter(it) }
        if (strategy != "fast_forward") {
            SectionHeader("Commit message")
            FormColumn {
                MobileTextField(
                    subject,
                    { subject = it },
                    Modifier.fillMaxWidth(),
                    label = { Text("Subject") },
                    placeholder = { Text("Subject") },
                    singleLine = true,
                )
                MobileTextField(
                    body,
                    { body = it },
                    Modifier.fillMaxWidth(),
                    label = { Text("Body") },
                    placeholder = { Text("Description (optional)") },
                    minLines = 3,
                )
            }
        }
        SectionHeader("Options")
        Group(listOf(0, 1, 2)) { index, position ->
            when (index) {
                0 ->
                    ListRow(
                        "Run validation first",
                        position = position,
                        trailing = { DSwitch(validate, { validate = it }) },
                    )
                1 ->
                    ListRow(
                        "Remove workspace afterwards",
                        position = position,
                        trailing = { DSwitch(remove, { remove = it }) },
                    )
                else ->
                    ListRow(
                        "Move card to Done",
                        position = position,
                        trailing = { DSwitch(done, { done = it }) },
                    )
            }
        }
        val checks = view.merge_readiness?.items.orEmpty()
        if (checks.isNotEmpty()) {
            SectionHeader("Readiness")
            Group(checks) { check, position ->
                val danger = check.tone == WorkspaceTone.WORKSPACE_TONE_DANGER
                ListRow(
                    check.text,
                    position = position,
                    glyph = if (danger) Glyph.ERROR else Glyph.CHECK_CIRCLE,
                    glyphTint = if (danger) palette.destructive else palette.success,
                    titleMaxLines = 2,
                )
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
    Sheet(
        GitOperations.title(kind),
        onDismiss,
        confirm =
            ChromeAction(
                "git-confirm",
                GitOperations.title(kind),
                gitGlyph(kind),
                enabled = form.ready,
            ) {
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
    ) {
        GitOperations.description(kind, card?.workspace?.base_branch.orEmpty())?.let {
            Text(
                it,
                Modifier.padding(horizontal = ScreenMargin + 4.dp, vertical = 6.dp),
                style = type.subheadline,
                color = palette.secondaryLabel,
            )
        }
        val fields = GitOperations.fields(kind).filter(form::shows)
        val texts = fields.filter {
            it in
                listOf(
                    GitFormField.SUBJECT,
                    GitFormField.BODY,
                    GitFormField.EXPECTED_REMOTE_SHA,
                    GitFormField.TARGET_CARD_ID,
                )
        }
        val toggles = fields.filter { it !in texts && it != GitFormField.STRATEGY }
        if (texts.isNotEmpty())
            FormColumn {
                texts.forEach { field ->
                    when (field) {
                        GitFormField.SUBJECT ->
                            MobileTextField(
                                form.subject,
                                { form = form.copy(subject = it) },
                                Modifier.fillMaxWidth(),
                                label = { Text(copy.subject) },
                                placeholder = { Text(copy.subject) },
                                singleLine = true,
                            )
                        GitFormField.BODY ->
                            MobileTextField(
                                form.body,
                                { form = form.copy(body = it) },
                                Modifier.fillMaxWidth(),
                                label = { Text(copy.body) },
                                placeholder = { Text(copy.body) },
                                minLines = 3,
                            )
                        GitFormField.EXPECTED_REMOTE_SHA ->
                            MobileTextField(
                                form.expectedRemoteSha,
                                { form = form.copy(expectedRemoteSha = it) },
                                Modifier.fillMaxWidth(),
                                label = { Text(copy.expectedRemoteSha) },
                                placeholder = { Text(copy.expectedRemoteSha) },
                                supportingText = { Text(copy.expectedRemoteShaHelp) },
                                singleLine = true,
                            )
                        else ->
                            MobileTextField(
                                form.targetCardId,
                                { form = form.copy(targetCardId = it) },
                                Modifier.fillMaxWidth(),
                                label = { Text(copy.targetCardId) },
                                placeholder = { Text(copy.targetCardId) },
                                singleLine = true,
                            )
                    }
                }
            }
        if (GitFormField.STRATEGY in fields)
            Group(listOf(0)) { _, position ->
                val strategies = GitOperations.strategies(kind)
                PickerRow(
                    "Strategy",
                    strategies.firstOrNull { it.first == form.strategy }?.second ?: form.strategy,
                    strategies,
                    form.strategy,
                    true,
                    position,
                ) {
                    form = form.copy(strategy = it)
                }
            }
        if (toggles.isNotEmpty()) {
            SectionHeader("Options")
            Group(toggles) { field, position ->
                val (title, checked) =
                    when (field) {
                        GitFormField.STAGE_ALL -> copy.stageAll to form.stageAll
                        GitFormField.FETCH -> copy.fetch to form.fetch
                        GitFormField.VALIDATE -> copy.validate to form.validate
                        GitFormField.DRAFT -> copy.draft to form.draft
                        GitFormField.PUSH -> copy.push to form.push
                        else -> copy.forceWithLease to form.forceWithLease
                    }
                ListRow(
                    title,
                    position = position,
                    trailing = {
                        DSwitch(
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
                    },
                )
            }
        }
        GitOperations.notice(kind)?.let {
            Banner(
                it.title,
                it.detail,
                Modifier.padding(horizontal = ScreenMargin, vertical = 12.dp),
                tone = Tone.WARNING,
            )
        }
    }
}
