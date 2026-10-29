package com.getdieter.mobile.tools

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.*
import com.getdieter.core.workspace.GitOperations
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.design.Tone
import com.getdieter.mobile.store.*

@Composable
internal fun ReviewScreen(store: MobileStore) {
    val view by store.review.slice.collectAsState()
    val conversation by store.conversation.slice.collectAsState()
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
                            store.action { store.conversation.send(view.conflict_prompt) }
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
                                    {
                                        store.action {
                                            store.conversation.send(pr.ask_agent_prompt)
                                        }
                                    },
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
