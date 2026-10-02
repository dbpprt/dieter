package com.dbpprt.dieter.core.workspace

enum class DiffLineKind { HEADER, HUNK, CONTEXT, ADDITION, DELETION }

data class DiffLine(val id: Int, val kind: DiffLineKind, val text: String, val oldLine: Int? = null, val newLine: Int? = null)

/** Unified diff lines with old/new numbering; commit patches reset numbering per file. */
object UnifiedDiff {
    private val metadata = listOf(
        "+++", "---", "index ", "new file mode", "deleted file mode", "old mode", "new mode", "similarity index",
        "dissimilarity index", "rename from", "rename to", "copy from", "copy to", "Binary files",
    )

    fun parse(patch: String): List<DiffLine> {
        val lines = mutableListOf<DiffLine>()
        var old: Int? = null
        var new: Int? = null
        for ((index, raw) in patch.split('\n').withIndex()) {
            // The patch terminator is not a line; a blank context line is " ".
            if (raw.isEmpty()) continue
            val ranges = if (raw.startsWith("@@")) hunkStarts(raw) else null
            when {
                ranges != null -> {
                    lines += DiffLine(index, DiffLineKind.HUNK, raw)
                    old = ranges.first
                    new = ranges.second
                }
                raw.startsWith("diff ") -> {
                    lines += DiffLine(index, DiffLineKind.HEADER, raw)
                    old = null
                    new = null
                }
                raw.startsWith("\\ No newline") -> lines += DiffLine(index, DiffLineKind.HEADER, raw)
                old == null && new == null && metadata.any { raw.startsWith(it) } -> lines += DiffLine(index, DiffLineKind.HEADER, raw)
                raw.startsWith("+") -> {
                    lines += DiffLine(index, DiffLineKind.ADDITION, raw, null, new)
                    new = new?.plus(1)
                }
                raw.startsWith("-") -> {
                    lines += DiffLine(index, DiffLineKind.DELETION, raw, old, null)
                    old = old?.plus(1)
                }
                else -> {
                    lines += DiffLine(index, DiffLineKind.CONTEXT, raw, old, new)
                    old = old?.plus(1)
                    new = new?.plus(1)
                }
            }
        }
        return lines
    }

    /** `@@ -10,3 +20,4 @@` → (10, 20); null when the ranges do not parse. */
    fun hunkStarts(line: String): Pair<Int, Int>? {
        val pieces = line.split(' ')
        if (pieces.size < 3) return null
        val old = pieces[1].drop(1).substringBefore(',').toIntOrNull() ?: return null
        val new = pieces[2].drop(1).substringBefore(',').toIntOrNull() ?: return null
        return old to new
    }
}

data class HunkSummary(val oldStart: Int, val oldCount: Int, val newStart: Int, val newCount: Int)

sealed interface DiffRow {
    val id: Int

    data class Line(val line: DiffLine) : DiffRow { override val id get() = line.id }
    data class Pair(override val id: Int, val old: DiffLine?, val new: DiffLine?) : DiffRow
    data class File(override val id: Int, val path: String) : DiffRow

    /** A hunk boundary: its header text, the unchanged lines since the previous hunk, and its changed lines. */
    data class Hunk(override val id: Int, val text: String, val skippedLines: Int, val additions: Int = 0, val deletions: Int = 0) : DiffRow

    /** Unchanged lines hidden until expanded; [pairs] mirrors them on both sides in the split layout. */
    data class Fold(override val id: Int, val count: Int, val lines: List<DiffLine>, val pairs: List<Pair> = emptyList()) : DiffRow
}

/** A diff laid out for one view: its rows and its widest code line. */
class DiffLayout(val rows: List<DiffRow>, val maxColumns: Int) {
    companion object {
        /** No diff shown. */
        val EMPTY = DiffLayout(emptyList(), 0)

        /** Lays out [lines]; a whole commit ([wholeCommit]) gets a row per file. */
        fun of(lines: List<DiffLine>, split: Boolean, wholeCommit: Boolean = false): DiffLayout =
            if (lines.isEmpty()) EMPTY else DiffLayout(DiffDisplay.rows(lines, split, wholeCommit), DiffDisplay.maximumColumns(lines))
    }
}

/**
 * Display rows: headers dropped, long unchanged runs folded, optional
 * side-by-side pairing. Fold and hunk IDs are their first line's ID, so the
 * same diff keeps them in either layout.
 */
object DiffDisplay {
    const val FOLD_THRESHOLD = 16
    const val FOLD_MARGIN = 5

    fun rows(lines: List<DiffLine>, split: Boolean, wholeCommit: Boolean = false): List<DiffRow> {
        val rows = mutableListOf<DiffRow>()
        val context = mutableListOf<DiffLine>()
        val deletions = mutableListOf<DiffLine>()
        val additions = mutableListOf<DiffLine>()
        val deltas = hunkDeltas(lines)
        var previousOldEnd: Int? = null

        fun flushChanges() {
            if (split) {
                for (index in 0 until maxOf(deletions.size, additions.size)) {
                    val old = deletions.getOrNull(index)
                    val new = additions.getOrNull(index)
                    rows += DiffRow.Pair(old?.id ?: new!!.id, old, new)
                }
            } else {
                (deletions + additions).sortedBy { it.id }.forEach { rows += DiffRow.Line(it) }
            }
            deletions.clear()
            additions.clear()
        }

        fun emit(line: DiffLine) {
            rows += if (split) DiffRow.Pair(line.id, line, line) else DiffRow.Line(line)
        }

        /** Short runs stay; long runs keep 5 lines of margin on each side that touches a change. */
        fun flushContext(trailing: Boolean) {
            if (context.size <= FOLD_THRESHOLD) {
                context.forEach(::emit)
            } else {
                val head = if (rows.isEmpty()) 0 else FOLD_MARGIN
                val tail = if (trailing) 0 else FOLD_MARGIN
                context.take(head).forEach(::emit)
                val hidden = context.drop(head).dropLast(tail)
                if (hidden.isNotEmpty()) {
                    val pairs = if (split) hidden.map { DiffRow.Pair(it.id, it, it) } else emptyList()
                    rows += DiffRow.Fold(hidden.first().id, hidden.size, hidden, pairs)
                }
                context.takeLast(tail).forEach(::emit)
            }
            context.clear()
        }

        for (line in lines) {
            when (line.kind) {
                DiffLineKind.HEADER -> {
                    val path = if (wholeCommit) filePath(line.text) else null
                    if (path != null) {
                        flushChanges()
                        flushContext(trailing = true)
                        previousOldEnd = null
                        rows += DiffRow.File(line.id, path)
                    }
                }
                DiffLineKind.HUNK -> {
                    flushChanges()
                    flushContext(trailing = true)
                    val summary = hunkSummary(line.text)
                    val skipped = if (summary != null && previousOldEnd != null) maxOf(0, summary.oldStart - previousOldEnd) else 0
                    // An unreadable header breaks the chain: the next hunk counts no gap.
                    previousOldEnd = summary?.let { it.oldStart + it.oldCount }
                    val (added, deleted) = deltas[line.id] ?: (0 to 0)
                    rows += DiffRow.Hunk(line.id, hunkText(line.text), skipped, added, deleted)
                }
                DiffLineKind.CONTEXT -> {
                    flushChanges()
                    context += line
                }
                DiffLineKind.ADDITION, DiffLineKind.DELETION -> {
                    flushContext(trailing = false)
                    if (line.kind == DiffLineKind.ADDITION) additions += line else deletions += line
                }
            }
        }
        flushChanges()
        flushContext(trailing = true)
        return rows
    }

    /** The last path of a `diff --git a/x b/x` line, without its `b/` prefix. */
    fun filePath(header: String): String? {
        if (!header.startsWith("diff ")) return null
        return header.substringAfterLast(' ').removePrefix("b/").ifEmpty { null }
    }

    /**
     * `@@ -1284,9 +1284,16 @@ fn` → its ranges; null unless the header opens
     * with exactly "@@" and both ranges have a start. A missing or unreadable
     * count is 1.
     */
    fun hunkSummary(text: String): HunkSummary? {
        val pieces = text.split(' ').filter { it.isNotEmpty() }
        if (pieces.size < 3 || pieces[0] != "@@") return null
        fun range(value: String): kotlin.Pair<Int, Int>? {
            val body = value.drop(1)
            val start = body.substringBefore(',').toIntOrNull() ?: return null
            val count = if (',' in body) body.substringAfter(',').toIntOrNull() ?: 1 else 1
            return start to count
        }
        val old = range(pieces[1]) ?: return null
        val new = range(pieces[2]) ?: return null
        return HunkSummary(old.first, old.second, new.first, new.second)
    }

    /**
     * The header up to the "@@" that closes its ranges, then any function
     * context: "@@ -1,2 +1,3 @@ funcName". The closing "@@" is the first one
     * after the opening one, so context containing "@@" stays whole.
     */
    fun hunkText(text: String): String {
        val end = text.indexOf("@@", 2)
        if (end < 0) return text
        val ranges = text.substring(0, end + 2).trim()
        val context = text.substring(end + 2).trim()
        return if (context.isEmpty()) ranges else "$ranges $context"
    }

    /** Additions and deletions per hunk, keyed by hunk line ID. */
    fun hunkDeltas(lines: List<DiffLine>): Map<Int, kotlin.Pair<Int, Int>> {
        val deltas = LinkedHashMap<Int, kotlin.Pair<Int, Int>>()
        var current: Int? = null
        for (line in lines) {
            when (line.kind) {
                DiffLineKind.HUNK -> {
                    current = line.id
                    deltas[line.id] = 0 to 0
                }
                DiffLineKind.ADDITION -> current?.let { deltas[it] = deltas.getValue(it).let { (a, d) -> a + 1 to d } }
                DiffLineKind.DELETION -> current?.let { deltas[it] = deltas.getValue(it).let { (a, d) -> a to d + 1 } }
                else -> Unit
            }
        }
        return deltas
    }

    /**
     * The widest code line (context, addition, or deletion) in display
     * columns, so a layout can reserve the width once: a tab counts 4, an
     * ASCII character 1, any other character (one Unicode scalar) 2.
     */
    fun maximumColumns(lines: List<DiffLine>): Int {
        var widest = 0
        for (line in lines) {
            if (line.kind != DiffLineKind.CONTEXT && line.kind != DiffLineKind.ADDITION && line.kind != DiffLineKind.DELETION) continue
            val text = line.text
            var columns = 0
            var index = 0
            while (index < text.length) {
                val char = text[index]
                columns += when {
                    char == '\t' -> 4
                    char.code < 128 -> 1
                    else -> 2
                }
                // A surrogate pair is one scalar.
                index += if (char.isHighSurrogate() && index + 1 < text.length && text[index + 1].isLowSurrogate()) 2 else 1
            }
            if (columns > widest) widest = columns
        }
        return widest
    }
}
