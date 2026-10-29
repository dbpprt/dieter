package com.getdieter.mobile.tools

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.getdieter.api.v1.ChangedFile
import com.getdieter.client.v1.*
import com.getdieter.mobile.design.*

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
