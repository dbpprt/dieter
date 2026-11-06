package com.getdieter.core.presentation

import com.getdieter.core.files.CodeLanguage
import com.getdieter.core.files.codeLanguageForPath

enum class TableAlignment {
    START,
    CENTER,
    END,
}

/**
 * Inline content of a paragraph, heading or table cell, in reading order. Nothing here is fetched
 * or executed: raw HTML stays [Text] and an [Image] is only its alt text and a link.
 */
sealed interface MarkdownInline {
    data class Text(val text: String) : MarkdownInline

    data class Code(val text: String) : MarkdownInline

    data class Emphasis(val children: List<MarkdownInline>) : MarkdownInline

    data class Strong(val children: List<MarkdownInline>) : MarkdownInline

    data class Strikethrough(val children: List<MarkdownInline>) : MarkdownInline

    /**
     * A link as written; whether it opens is the renderer's call. [autolink]: written as `<url>` or
     * detected in prose, with the address as its text.
     */
    data class Link(
        val url: String,
        val children: List<MarkdownInline>,
        val autolink: Boolean = false,
    ) : MarkdownInline

    /** An image reference: shown as [alt] with a link to [url], never loaded. */
    data class Image(val url: String, val alt: String) : MarkdownInline

    /** A line break inside a block; [hard] when written with two trailing spaces or a backslash. */
    data class Break(val hard: Boolean) : MarkdownInline
}

/** One item of a [MarkdownBlock.ListBlock]; [checked] is null unless it is a task. */
data class MarkdownListItem(val checked: Boolean?, val blocks: List<MarkdownBlock>)

/**
 * The block tree of a Markdown document. Paragraphs, headings and table cells keep their inline
 * source; [Markdown.inline] (or [Paragraph.inlines], [Heading.inlines]) parses it when a renderer
 * shows the block, so long documents parse their visible blocks only.
 */
sealed interface MarkdownBlock {
    data class Paragraph(val text: String) : MarkdownBlock {
        val inlines: List<MarkdownInline> by lazy { Markdown.inline(text) }
    }

    data class Heading(val level: Int, val text: String) : MarkdownBlock {
        val inlines: List<MarkdownInline> by lazy { Markdown.inline(text) }
    }

    data class Code(val text: String, val language: String) : MarkdownBlock

    data class Quote(val blocks: List<MarkdownBlock>) : MarkdownBlock

    /** [start] numbers the first item of an ordered list. */
    data class ListBlock(val ordered: Boolean, val start: Int, val items: List<MarkdownListItem>) :
        MarkdownBlock

    data object Rule : MarkdownBlock

    /** Every row has the header's column count; cells hold inline source. */
    data class Table(
        val header: List<String>,
        val alignments: List<TableAlignment>,
        val rows: List<List<String>>,
    ) : MarkdownBlock
}

/** Where a link in a rendered document leads under the profile. */
sealed interface MarkdownLinkTarget {
    /** An `http(s)` URL with a host, or a `mailto:` address: the system opens it. */
    data class External(val url: String) : MarkdownLinkTarget

    /** A file inside the document's workspace, relative to its root, at [line] when given. */
    data class File(val path: String, val line: Int? = null) : MarkdownLinkTarget

    /** Another scheme, or a workspace link where there is no workspace: shown, never opened. */
    data object Inert : MarkdownLinkTarget
}

/**
 * The Markdown profile every client renders (docs/proposals/agent-mail.md §3.7): ATX headings,
 * paragraphs and breaks, emphasis, strikethrough, code, links and autolinks, ordered, bullet,
 * nested and task lists, quotes, rules, fenced code and GFM tables. Indented code, setext headings,
 * reference links, HTML and footnotes are not in it and read as text. The golden corpus in
 * tests/fixtures/markdown pins the trees.
 */
object Markdown {
    /** Containers nested deeper than this read as text. */
    private const val MAX_DEPTH = 16

    /** Wider pipe rows read as text. */
    private const val MAX_COLUMNS = 128

    fun parse(source: String): List<MarkdownBlock> = blocks(lines(source), 0)

    /** The inline tree of [source], e.g. a paragraph's or a table cell's text. */
    fun inline(source: String): List<MarkdownInline> =
        if (source.isEmpty()) emptyList() else InlineParser(source).parse()

    /** The text a reader sees, without markup: alt texts, link labels and code included. */
    fun plain(inlines: List<MarkdownInline>): String = buildString { appendPlain(inlines) }

    /**
     * Where [url] leads in a document whose workspace links resolve against [workspaceRoot], an
     * absolute path (null or blank when it has none, as in an operator's mail): `http(s)` and
     * `mailto:` links open outside, relative and `file:` links inside the workspace through
     * [ContentLinks], and anything else stays inert.
     */
    fun link(url: String, workspaceRoot: String?): MarkdownLinkTarget {
        val written = url.trim()
        if (written.isEmpty()) return MarkdownLinkTarget.Inert
        if (mailto.matches(written)) return MarkdownLinkTarget.External(written)
        return try {
            when (
                val resolved =
                    ContentLinks.resolve(written, workspaceRoot?.takeIf { it.isNotBlank() })
            ) {
                is ContentLink.Web -> MarkdownLinkTarget.External(resolved.url)
                is ContentLink.File -> MarkdownLinkTarget.File(resolved.path, resolved.line)
            }
        } catch (_: LinkException) {
            MarkdownLinkTarget.Inert
        }
    }

    private val mailto = Regex("^mailto:[^\\s<>]+$", RegexOption.IGNORE_CASE)

    /** The highlighter language of a fence's info string, e.g. `sh`, `kotlin` or `ts`. */
    fun codeLanguage(language: String): CodeLanguage {
        val name = language.trim().lowercase()
        return when (name) {
            "" -> CodeLanguage.PLAIN_TEXT
            "shell",
            "bash",
            "zsh",
            "console",
            "shell-session",
            "sh-session" -> CodeLanguage.SHELL
            "golang" -> CodeLanguage.GO
            "kotlin" -> CodeLanguage.KOTLIN
            "javascript",
            "node" -> CodeLanguage.JAVASCRIPT
            "typescript" -> CodeLanguage.TYPESCRIPT
            "python",
            "python3" -> CodeLanguage.PYTHON
            "rust" -> CodeLanguage.RUST
            "c++" -> CodeLanguage.CPP
            "objc",
            "objective-c",
            "objectivec" -> CodeLanguage.OBJECTIVE_C
            "ruby" -> CodeLanguage.RUBY
            "csharp",
            "c#" -> CodeLanguage.C_SHARP
            "protobuf" -> CodeLanguage.PROTOBUF
            "markdown" -> CodeLanguage.MARKDOWN
            else -> codeLanguageForPath("fence.$name")
        }
    }

    /**
     * Cells of a pipe-table row: an escaped pipe (`\|`) is a pipe, and pipes inside a code span do
     * not split. Other escapes stay for the inline parser.
     */
    fun cells(line: String): List<String>? {
        if ('|' !in line) return null
        var body = line.trim()
        if (body.startsWith("|")) body = body.substring(1)
        if (body.endsWith("|") && !body.endsWith("\\|")) body = body.dropLast(1)
        val cells = mutableListOf<String>()
        val current = StringBuilder()
        var index = 0
        while (index < body.length) {
            val char = body[index]
            when {
                char == '\\' && index + 1 < body.length -> {
                    if (body[index + 1] == '|') current.append('|')
                    else current.append(char).append(body[index + 1])
                    index += 2
                    continue
                }
                char == '`' -> {
                    val run = run(body, index, '`')
                    val close = closingBackticks(body, index + run, run)
                    if (close < 0) current.append(body, index, index + run)
                    else current.append(body.substring(index, close + run).replace("\\|", "|"))
                    index = if (close < 0) index + run else close + run
                    continue
                }
                char == '|' -> {
                    cells += current.toString().trim()
                    current.clear()
                }
                else -> current.append(char)
            }
            index++
        }
        cells += current.toString().trim()
        return cells
    }

    // Blocks ---------------------------------------------------------------------------------

    /** Lines without carriage returns, tabs in the indentation expanded to four-column stops. */
    private fun lines(source: String): List<String> =
        source.removeSuffix("\n").split('\n').map { raw ->
            val line = raw.removeSuffix("\r")
            var lead = 0
            while (lead < line.length && (line[lead] == ' ' || line[lead] == '\t')) lead++
            if (line.indexOf('\t').let { it < 0 || it >= lead }) line
            else {
                val expanded = StringBuilder()
                for (index in 0 until lead) {
                    if (line[index] == '\t') {
                        do expanded.append(' ') while (expanded.length % 4 != 0)
                    } else expanded.append(' ')
                }
                expanded.append(line, lead, line.length).toString()
            }
        }

    private class Fence(val char: Char, val length: Int, val indent: Int, val language: String)

    private class Marker(
        val indent: Int,
        val ordered: Boolean,
        /** The bullet character, or the ordered delimiter (`.` or `)`). */
        val symbol: Char,
        val number: Int,
        /** Where the item's content starts; continuation lines are indented this far. */
        val offset: Int,
        val content: String,
    )

    private fun blocks(lines: List<String>, depth: Int): List<MarkdownBlock> {
        val blocks = mutableListOf<MarkdownBlock>()
        val paragraph = mutableListOf<String>()
        val containers = depth < MAX_DEPTH

        fun flush() {
            if (paragraph.isEmpty()) return
            val text = paragraph.joinToString("\n").trimEnd()
            paragraph.clear()
            if (text.isNotBlank()) blocks += MarkdownBlock.Paragraph(text)
        }

        var index = 0
        while (index < lines.size) {
            val line = lines[index]
            if (line.isBlank()) {
                flush()
                index++
                continue
            }
            val fence = fence(line)
            if (fence != null) {
                flush()
                val code = mutableListOf<String>()
                index++
                while (index < lines.size && !closes(lines[index], fence)) {
                    code += dropIndent(lines[index], fence.indent)
                    index++
                }
                blocks += MarkdownBlock.Code(code.joinToString("\n"), fence.language)
                index++
                continue
            }
            val heading = heading(line)
            if (heading != null) {
                flush()
                blocks += heading
                index++
                continue
            }
            if (rule(line)) {
                flush()
                blocks += MarkdownBlock.Rule
                index++
                continue
            }
            if (containers && quote(line) != null) {
                flush()
                val quoted = mutableListOf<String>()
                while (index < lines.size) {
                    val next = lines[index]
                    val content = quote(next)
                    when {
                        content != null -> quoted += content
                        // A lazy continuation line extends the quote's paragraph.
                        next.isNotBlank() &&
                            quoted.lastOrNull()?.isNotBlank() == true &&
                            !starts(next, depth) -> quoted += next.trimStart()
                        else -> break
                    }
                    index++
                }
                blocks += MarkdownBlock.Quote(blocks(quoted, depth + 1))
                continue
            }
            val marker = if (containers) marker(line) else null
            if (marker != null && (paragraph.isEmpty() || interrupts(marker))) {
                flush()
                index = list(lines, index, marker, depth, blocks)
                continue
            }
            if (table(lines, index)) {
                flush()
                index = table(lines, index, blocks, depth)
                continue
            }
            // Paragraph lines lose their indentation; trailing spaces stay for hard breaks.
            paragraph += line.trimStart()
            index++
        }
        flush()
        return blocks
    }

    /** Whether [line] starts a block other than a paragraph, so it cannot continue one lazily. */
    private fun starts(line: String, depth: Int): Boolean =
        fence(line) != null ||
            heading(line) != null ||
            rule(line) ||
            (depth < MAX_DEPTH && quote(line) != null) ||
            (depth < MAX_DEPTH && marker(line)?.let(::interrupts) == true)

    /** A list interrupts a paragraph with a bullet that has content, or an ordered item 1. */
    private fun interrupts(marker: Marker) =
        marker.content.isNotBlank() && (!marker.ordered || marker.number == 1)

    private fun fence(line: String): Fence? {
        val indent = indent(line)
        val char = line.getOrNull(indent)
        if (char != '`' && char != '~') return null
        val length = run(line, indent, char)
        if (length < 3) return null
        val info = line.substring(indent + length).trim()
        if (char == '`' && '`' in info) return null
        return Fence(char, length, indent, info.substringBefore(' ').substringBefore('\t'))
    }

    private fun closes(line: String, fence: Fence): Boolean {
        val indent = indent(line)
        return line.getOrNull(indent) == fence.char &&
            run(line, indent, fence.char) >= fence.length &&
            line.substring(indent + run(line, indent, fence.char)).isBlank()
    }

    private fun heading(line: String): MarkdownBlock.Heading? {
        val indent = indent(line)
        if (indent > 3) return null
        val level = run(line, indent, '#')
        if (level !in 1..6) return null
        val after = indent + level
        if (after < line.length && line[after] != ' ' && line[after] != '\t') return null
        var text = line.substring(after).trim()
        // An optional closing sequence of #s, after a space (or alone).
        val closing = text.trimEnd('#')
        if (closing.isEmpty()) text = ""
        else if (closing.length < text.length && closing.last().let { it == ' ' || it == '\t' })
            text = closing.trimEnd()
        return MarkdownBlock.Heading(level, text)
    }

    private fun rule(line: String): Boolean {
        val indent = indent(line)
        if (indent > 3) return false
        val char = line.getOrNull(indent)
        if (char != '-' && char != '*' && char != '_') return false
        var count = 0
        for (index in indent until line.length) {
            when (line[index]) {
                char -> count++
                ' ',
                '\t' -> Unit
                else -> return false
            }
        }
        return count >= 3
    }

    /** A quote line's content after `>` and one optional space; null when it is not one. */
    private fun quote(line: String): String? {
        val indent = indent(line)
        if (indent > 3 || line.getOrNull(indent) != '>') return null
        val rest = line.substring(indent + 1)
        return if (rest.startsWith(' ')) rest.substring(1) else rest
    }

    private fun marker(line: String): Marker? {
        val indent = indent(line)
        if (indent > 3) return null
        var index = indent
        val first = line.getOrNull(index) ?: return null
        val ordered: Boolean
        val symbol: Char
        var number = 0
        if (first == '-' || first == '+' || first == '*') {
            ordered = false
            symbol = first
            index++
        } else if (first in '0'..'9') {
            val digits = run(line, index) { it in '0'..'9' }
            if (digits > 9) return null
            number = line.substring(index, index + digits).toInt()
            index += digits
            val delimiter = line.getOrNull(index)
            if (delimiter != '.' && delimiter != ')') return null
            ordered = true
            symbol = delimiter
            index++
        } else return null
        if (index < line.length && line[index] != ' ' && line[index] != '\t') return null
        val spaces = run(line, index) { it == ' ' || it == '\t' }
        val content = line.substring(index + spaces)
        // Five or more spaces would start indented code; the content then begins after one.
        val offset = if (content.isEmpty() || spaces > 4) index + 1 else index + spaces
        return Marker(
            indent,
            ordered,
            symbol,
            number,
            offset,
            if (spaces > 4) line.substring(index + 1) else content,
        )
    }

    /** Parses the list that starts at [start] into [blocks]; returns the next line's index. */
    private fun list(
        lines: List<String>,
        start: Int,
        first: Marker,
        depth: Int,
        blocks: MutableList<MarkdownBlock>,
    ): Int {
        val items = mutableListOf<MarkdownListItem>()
        var index = start
        var marker: Marker? = first
        while (marker != null) {
            val content = mutableListOf(marker.content)
            index++
            while (index < lines.size) {
                val line = lines[index]
                val indent = indent(line)
                if (line.isBlank()) {
                    // Blank lines stay in the item when indented content follows them.
                    val next = (index + 1 until lines.size).firstOrNull { lines[it].isNotBlank() }
                    if (next == null || indent(lines[next]) < marker.offset) break
                    content += ""
                } else if (indent >= marker.offset) content += line.substring(marker.offset)
                // A nested list indented less than the content, as in "1. a\n  - b", still nests.
                else if (indent >= marker.indent + 2 && marker(line) != null)
                    content += line.substring(indent)
                else if (
                    marker(line)?.let {
                        it.ordered == first.ordered && it.symbol == first.symbol
                    } == true
                )
                    break
                // A lazy continuation line extends the item's paragraph.
                else if (
                    content.last().isNotBlank() && !starts(line, depth + 1) && !table(lines, index)
                )
                    content += line.trimStart()
                else break
                index++
            }
            val (checked, body) = task(content.first())
            content[0] = body
            items += MarkdownListItem(checked, blocks(content, depth + 1))
            // The next item continues the list when it is of the same kind.
            var next = index
            while (next < lines.size && lines[next].isBlank()) next++
            val following = lines.getOrNull(next)?.let(::marker)
            marker = following?.takeIf {
                it.ordered == first.ordered && it.symbol == first.symbol && it.indent < 4
            }
            if (marker != null) index = next
        }
        blocks += MarkdownBlock.ListBlock(first.ordered, first.number, items)
        return index
    }

    /** A task item's state and the text after its box. */
    private fun task(content: String): Pair<Boolean?, String> {
        if (content.length < 3 || content[0] != '[' || content[2] != ']') return null to content
        val checked =
            when (content[1]) {
                ' ' -> false
                'x',
                'X' -> true
                else -> return null to content
            }
        if (content.length > 3 && content[3] != ' ' && content[3] != '\t') return null to content
        return checked to content.substring(minOf(4, content.length))
    }

    /** Whether a GFM table starts at [index]: a pipe row, then a delimiter row as wide. */
    private fun table(lines: List<String>, index: Int): Boolean {
        val line = lines[index]
        if ('|' !in line || index + 1 >= lines.size || '|' !in lines[index + 1]) return false
        val header = cells(line) ?: return false
        val delimiter = cells(lines[index + 1]) ?: return false
        return header.size <= MAX_COLUMNS &&
            delimiter.size == header.size &&
            delimiter.all(::isDelimiter)
    }

    private fun table(
        lines: List<String>,
        start: Int,
        blocks: MutableList<MarkdownBlock>,
        depth: Int,
    ): Int {
        val header = cells(lines[start])!!
        val alignments = cells(lines[start + 1])!!.map(::alignment)
        val rows = mutableListOf<List<String>>()
        var index = start + 2
        // Rows need a pipe, so a sentence after a table without a blank line stays a paragraph.
        while (index < lines.size && '|' in lines[index] && !starts(lines[index], depth)) {
            val row = cells(lines[index]) ?: break
            rows += List(header.size) { row.getOrElse(it) { "" } }
            index++
        }
        blocks += MarkdownBlock.Table(header, alignments, rows)
        return index
    }

    private fun isDelimiter(cell: String): Boolean {
        val dashes = cell.removePrefix(":").removeSuffix(":")
        return dashes.isNotEmpty() && dashes.all { it == '-' }
    }

    private fun alignment(cell: String): TableAlignment =
        when {
            cell.startsWith(":") && cell.endsWith(":") && cell.length > 1 -> TableAlignment.CENTER
            cell.endsWith(":") -> TableAlignment.END
            else -> TableAlignment.START
        }

    private fun indent(line: String): Int = run(line, 0, ' ')

    private fun dropIndent(line: String, count: Int): String =
        line.substring(minOf(count, indent(line)))

    internal fun run(text: String, start: Int, char: Char): Int = run(text, start) { it == char }

    private inline fun run(text: String, start: Int, matches: (Char) -> Boolean): Int {
        var end = start
        while (end < text.length && matches(text[end])) end++
        return end - start
    }

    /** The start of the next run of exactly [length] backticks from [from], or -1. */
    internal fun closingBackticks(text: String, from: Int, length: Int): Int {
        var index = text.indexOf('`', from)
        while (index >= 0) {
            val run = run(text, index, '`')
            if (run == length) return index
            index = text.indexOf('`', index + run)
        }
        return -1
    }

    private fun StringBuilder.appendPlain(inlines: List<MarkdownInline>) {
        for (inline in inlines) {
            when (inline) {
                is MarkdownInline.Text -> append(inline.text)
                is MarkdownInline.Code -> append(inline.text)
                is MarkdownInline.Emphasis -> appendPlain(inline.children)
                is MarkdownInline.Strong -> appendPlain(inline.children)
                is MarkdownInline.Strikethrough -> appendPlain(inline.children)
                is MarkdownInline.Link -> appendPlain(inline.children)
                is MarkdownInline.Image -> append(inline.alt)
                is MarkdownInline.Break -> append('\n')
            }
        }
    }
}

/**
 * CommonMark's inline algorithm for the profile: code spans and escapes first, then links and
 * images by bracket matching, then emphasis and GFM strikethrough by delimiter runs. Bare web and
 * development addresses become autolinks with the conversation rules ([DetectedLinks]).
 */
private class InlineParser(private val source: String) {
    /** [depth]: how many spans nest in [inline], bounded so hostile input cannot nest deeply. */
    private class Node(var text: String, var inline: MarkdownInline?, var depth: Int = 0) {
        var previous: Node? = null
        var next: Node? = null
    }

    private class Delimiter(
        val node: Node,
        val char: Char,
        var length: Int,
        val original: Int,
        val canOpen: Boolean,
        val canClose: Boolean,
    ) {
        var previous: Delimiter? = null
        var next: Delimiter? = null
    }

    private class Bracket(
        val node: Node,
        val image: Boolean,
        /** The delimiter on top of the stack when the bracket opened. */
        val bottom: Delimiter?,
        val previous: Bracket?,
    ) {
        var active = true
    }

    private val head = Node("", null)
    private var tail = head
    private var delimiters: Delimiter? = null
    private var brackets: Bracket? = null
    private val text = StringBuilder()

    fun parse(): List<MarkdownInline> {
        var index = 0
        while (index < source.length) {
            index =
                when (val char = source[index]) {
                    '\\' -> escape(index)
                    '`' -> code(index)
                    '*',
                    '_',
                    '~' -> delimiterRun(index, char)
                    '[' -> open(index, image = false)
                    '!' ->
                        if (source.getOrNull(index + 1) == '[') open(index, image = true)
                        else literal(index)
                    ']' -> close(index)
                    '<' -> autolink(index)
                    '\n' -> lineBreak(index, hard = false)
                    else -> literal(index)
                }
        }
        flush()
        emphasis(null)
        return detect(collect(head.next, null))
    }

    /**
     * Bare web and development addresses in text outside links become autolinks. GFM leaves
     * trailing `*`, `_` and `~` out of an address, as [DetectedLinks] does other punctuation.
     */
    private fun detect(inlines: List<MarkdownInline>): List<MarkdownInline> {
        // Kotlin/Native release builds mis-devirtualize appends through a nullable, reassigned
        // buffer (see the fence buffer note in git history); keep the buffer concrete.
        val result = ArrayList<MarkdownInline>(0)
        var changed = false
        inlines.forEachIndexed { position, inline ->
            val replaced: List<MarkdownInline>? =
                when (inline) {
                    is MarkdownInline.Text -> addresses(inline.text)
                    is MarkdownInline.Emphasis ->
                        detect(inline.children)
                            .takeIf { it !== inline.children }
                            ?.let {
                                listOf(MarkdownInline.Emphasis(it))
                            }
                    is MarkdownInline.Strong ->
                        detect(inline.children)
                            .takeIf { it !== inline.children }
                            ?.let {
                                listOf(MarkdownInline.Strong(it))
                            }
                    is MarkdownInline.Strikethrough ->
                        detect(inline.children)
                            .takeIf { it !== inline.children }
                            ?.let {
                                listOf(MarkdownInline.Strikethrough(it))
                            }
                    else -> null
                }
            if (replaced != null && !changed) {
                changed = true
                result.addAll(inlines.subList(0, position))
            }
            if (changed) {
                if (replaced != null) result.addAll(replaced) else result.add(inline)
            }
        }
        return if (changed) result else inlines
    }

    private fun addresses(value: String): List<MarkdownInline>? {
        val matches = DetectedLinks.find(value)
        if (matches.isEmpty()) return null
        val result = mutableListOf<MarkdownInline>()
        var cursor = 0
        for (match in matches) {
            val written = value.substring(match.range).trimEnd('*', '_', '~')
            if (written.isEmpty()) continue
            val trimmed = match.range.last + 1 - match.range.first - written.length
            if (match.range.first > cursor)
                result += MarkdownInline.Text(value.substring(cursor, match.range.first))
            result +=
                MarkdownInline.Link(
                    match.url.dropLast(trimmed),
                    listOf(MarkdownInline.Text(written)),
                    autolink = true,
                )
            cursor = match.range.first + written.length
        }
        if (result.isEmpty()) return null
        if (cursor < value.length) result += MarkdownInline.Text(value.substring(cursor))
        return result
    }

    private fun literal(index: Int): Int {
        text.append(source[index])
        return index + 1
    }

    private fun escape(index: Int): Int {
        val next = source.getOrNull(index + 1)
        return when {
            next == '\n' -> {
                lineBreak(index + 1, hard = true)
            }
            next != null && next.code < 128 && isPunctuation(next) -> {
                text.append(next)
                index + 2
            }
            else -> literal(index)
        }
    }

    private fun lineBreak(index: Int, hard: Boolean): Int {
        var spaces = 0
        while (spaces < text.length && text[text.length - 1 - spaces] == ' ') spaces++
        text.setLength(text.length - spaces)
        append(MarkdownInline.Break(hard || spaces >= 2))
        return index + 1
    }

    private fun code(index: Int): Int {
        val length = Markdown.run(source, index, '`')
        val close = Markdown.closingBackticks(source, index + length, length)
        if (close < 0) {
            text.append(source, index, index + length)
            return index + length
        }
        var content = source.substring(index + length, close).replace('\n', ' ')
        if (
            content.length >= 2 &&
                content.first() == ' ' &&
                content.last() == ' ' &&
                content.isNotBlank()
        )
            content = content.substring(1, content.length - 1)
        append(MarkdownInline.Code(content))
        return close + length
    }

    private fun delimiterRun(index: Int, char: Char): Int {
        val length = Markdown.run(source, index, char)
        flush()
        val before = source.getOrNull(index - 1)
        val after = source.getOrNull(index + length)
        val beforeSpace = before == null || before.isWhitespace()
        val afterSpace = after == null || after.isWhitespace()
        val beforePunctuation = before != null && isPunctuation(before)
        val afterPunctuation = after != null && isPunctuation(after)
        val left = !afterSpace && (!afterPunctuation || beforeSpace || beforePunctuation)
        val right = !beforeSpace && (!beforePunctuation || afterSpace || afterPunctuation)
        val canOpen = if (char == '_') left && (!right || beforePunctuation) else left
        val canClose = if (char == '_') right && (!left || afterPunctuation) else right
        val node = Node(source.substring(index, index + length), null)
        link(node)
        // GFM strikethrough takes one or two tildes; longer runs stay text.
        if ((canOpen || canClose) && (char != '~' || length <= 2)) {
            val delimiter = Delimiter(node, char, length, length, canOpen, canClose)
            delimiter.previous = delimiters
            delimiters?.next = delimiter
            delimiters = delimiter
        }
        return index + length
    }

    private fun open(index: Int, image: Boolean): Int {
        flush()
        val node = Node(if (image) "![" else "[", null)
        link(node)
        brackets = Bracket(node, image, delimiters, brackets)
        return index + if (image) 2 else 1
    }

    private fun close(index: Int): Int {
        val opener = brackets ?: return literal(index)
        flush()
        if (!opener.active) {
            brackets = opener.previous
            return literal(index)
        }
        val destination = destination(index + 1)
        if (destination == null) {
            brackets = opener.previous
            return literal(index)
        }
        emphasis(opener.bottom)
        val depth = depth(opener.node.next, null) + 1
        val children = bounded(collect(opener.node.next, null), depth)
        val inline =
            if (opener.image) MarkdownInline.Image(destination.first, Markdown.plain(children))
            else MarkdownInline.Link(destination.first, withoutLinks(children))
        opener.node.text = ""
        opener.node.inline = inline
        opener.node.depth = if (depth > MAX_NESTING) 1 else depth
        opener.node.next = null
        tail = opener.node
        brackets = opener.previous
        if (!opener.image) {
            // Links never contain links: earlier brackets can no longer open one.
            var earlier = brackets
            while (earlier != null) {
                if (!earlier.image) earlier.active = false
                earlier = earlier.previous
            }
        }
        return destination.second
    }

    /** `(url "title")` after a closing bracket: the URL and the index after `)`. */
    private fun destination(start: Int): Pair<String, Int>? {
        if (source.getOrNull(start) != '(') return null
        var index = spaces(start + 1)
        val url = StringBuilder()
        if (source.getOrNull(index) == '<') {
            index++
            while (index < source.length && source[index] != '>') {
                val char = source[index]
                if (char == '\n' || char == '<') return null
                if (char == '\\' && source.getOrNull(index + 1)?.let(::isPunctuation) == true) {
                    url.append(source[index + 1])
                    index += 2
                } else {
                    url.append(char)
                    index++
                }
            }
            if (index >= source.length) return null
            index++
        } else {
            var depth = 0
            while (index < source.length) {
                val char = source[index]
                if (char.isWhitespace() || char.code < 0x20) break
                if (char == '\\' && source.getOrNull(index + 1)?.let(::isPunctuation) == true) {
                    url.append(source[index + 1])
                    index += 2
                    continue
                }
                if (char == '(') {
                    depth++
                    if (depth > 32) return null
                }
                if (char == ')') {
                    if (depth == 0) break
                    depth--
                }
                url.append(char)
                index++
            }
            if (depth != 0) return null
        }
        val afterUrl = index
        index = spaces(index)
        val quote = source.getOrNull(index)
        if (index > afterUrl && (quote == '"' || quote == '\'' || quote == '(')) {
            val end = if (quote == '(') ')' else quote
            index++
            while (index < source.length && source[index] != end) {
                if (source[index] == '\\') index++
                index++
            }
            if (index >= source.length) return null
            index = spaces(index + 1)
        }
        if (source.getOrNull(index) != ')') return null
        return url.toString() to index + 1
    }

    /** Skips spaces, tabs and at most one line ending. */
    private fun spaces(start: Int): Int {
        var index = start
        var newline = false
        while (index < source.length) {
            val char = source[index]
            if (char == '\n') {
                if (newline) break
                newline = true
            } else if (char != ' ' && char != '\t') break
            index++
        }
        return index
    }

    /** `<scheme:…>` and `<user@host>` autolinks; anything else, raw HTML included, is text. */
    private fun autolink(index: Int): Int {
        var end = index + 1
        val limit = minOf(source.length, index + 2048)
        while (end < limit && source[end] != '>') {
            val char = source[end]
            if (char == '<' || char.isWhitespace()) return literal(index)
            end++
        }
        if (end >= limit) return literal(index)
        val content = source.substring(index + 1, end)
        val url =
            when {
                uri.matches(content) -> content
                email.matches(content) -> "mailto:$content"
                else -> return literal(index)
            }
        append(MarkdownInline.Link(url, listOf(MarkdownInline.Text(content)), autolink = true))
        return end + 1
    }

    /** Wraps runs between matched delimiters above [bottom] in emphasis nodes. */
    private fun emphasis(bottom: Delimiter?) {
        // Where the search for an opener stopped, per delimiter kind, so it never repeats.
        val openersBottom = arrayOfNulls<Delimiter>(18)
        val searched = BooleanArray(18)
        if (delimiters == bottom) return
        var closer = delimiters
        while (closer!!.previous != bottom) closer = closer.previous
        while (closer != null) {
            if (!closer.canClose) {
                closer = closer.next
                continue
            }
            val kind =
                (when (closer.char) {
                    '*' -> 0
                    '_' -> 1
                    else -> 2
                }) * 6 + (closer.original % 3) * 2 + if (closer.canOpen) 1 else 0
            var opener = closer.previous
            var found: Delimiter? = null
            while (
                opener != null &&
                    opener != bottom &&
                    !(searched[kind] && opener == openersBottom[kind])
            ) {
                if (opener.char == closer.char && opener.canOpen) {
                    val matches =
                        if (closer.char == '~') opener.length == closer.length
                        else
                            !((closer.canOpen || opener.canClose) &&
                                (opener.original + closer.original) % 3 == 0 &&
                                !(opener.original % 3 == 0 && closer.original % 3 == 0))
                    if (matches) {
                        found = opener
                        break
                    }
                }
                opener = opener.previous
            }
            if (found == null) {
                openersBottom[kind] = closer.previous
                searched[kind] = true
                val next = closer.next
                if (!closer.canOpen) remove(closer)
                closer = next
                continue
            }
            val used =
                if (closer.char == '~') closer.length
                else if (closer.length >= 2 && found.length >= 2) 2 else 1
            found.length -= used
            closer.length -= used
            found.node.text = found.node.text.dropLast(used)
            closer.node.text = closer.node.text.drop(used)
            val depth = depth(found.node.next, closer.node) + 1
            val children = bounded(collect(found.node.next, closer.node), depth)
            val wrapped =
                Node(
                    "",
                    when {
                        closer.char == '~' -> MarkdownInline.Strikethrough(children)
                        used == 2 -> MarkdownInline.Strong(children)
                        else -> MarkdownInline.Emphasis(children)
                    },
                    if (depth > MAX_NESTING) 1 else depth,
                )
            wrapped.previous = found.node
            wrapped.next = closer.node
            found.node.next = wrapped
            closer.node.previous = wrapped
            // Delimiters between the pair can no longer match.
            found.next = closer
            closer.previous = found
            if (found.length == 0) {
                unlink(found.node)
                remove(found)
            }
            if (closer.length == 0) {
                val next = closer.next
                unlink(closer.node)
                remove(closer)
                closer = next
            }
        }
        while (delimiters != null && delimiters != bottom) remove(delimiters!!)
    }

    private fun remove(delimiter: Delimiter) {
        delimiter.previous?.next = delimiter.next
        delimiter.next?.previous = delimiter.previous
        if (delimiters == delimiter) delimiters = delimiter.previous
    }

    private fun unlink(node: Node) {
        node.previous?.next = node.next
        node.next?.previous = node.previous
        if (tail == node) tail = node.previous ?: head
    }

    private fun depth(start: Node?, end: Node?): Int {
        var deepest = 0
        var node = start
        while (node != null && node != end) {
            deepest = maxOf(deepest, node.depth)
            node = node.next
        }
        return deepest
    }

    /** Spans nested past [MAX_NESTING] keep their text and lose their inner markup. */
    private fun bounded(children: List<MarkdownInline>, depth: Int): List<MarkdownInline> =
        if (depth <= MAX_NESTING) children
        else listOf(MarkdownInline.Text(Markdown.plain(children)))

    /** The inlines of the nodes from [start] up to (not including) [end], texts merged. */
    private fun collect(start: Node?, end: Node?): List<MarkdownInline> {
        val result = mutableListOf<MarkdownInline>()
        val pending = StringBuilder()
        fun text() {
            if (pending.isNotEmpty()) {
                result += MarkdownInline.Text(pending.toString())
                pending.clear()
            }
        }
        var node = start
        while (node != null && node != end) {
            val inline = node.inline
            if (inline == null) pending.append(node.text)
            else if (inline is MarkdownInline.Text) pending.append(inline.text)
            else {
                text()
                result += inline
            }
            node = node.next
        }
        text()
        return result
    }

    private fun withoutLinks(inlines: List<MarkdownInline>): List<MarkdownInline> =
        if (inlines.none { it is MarkdownInline.Link }) inlines
        else
            inlines.flatMap {
                if (it is MarkdownInline.Link) it.children else listOf(it)
            }

    private fun flush() {
        if (text.isEmpty()) return
        link(Node(text.toString(), null))
        text.clear()
    }

    private fun append(inline: MarkdownInline) {
        flush()
        link(Node("", inline))
    }

    private fun link(node: Node) {
        node.previous = tail
        tail.next = node
        tail = node
    }

    private companion object {
        const val MAX_NESTING = 32

        val uri = Regex("^[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\\s<>]*$")
        val email =
            Regex(
                "^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$"
            )

        fun isPunctuation(char: Char): Boolean =
            if (char.code < 128) char in "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
            else
                when (char.category) {
                    CharCategory.CONNECTOR_PUNCTUATION,
                    CharCategory.DASH_PUNCTUATION,
                    CharCategory.START_PUNCTUATION,
                    CharCategory.END_PUNCTUATION,
                    CharCategory.INITIAL_QUOTE_PUNCTUATION,
                    CharCategory.FINAL_QUOTE_PUNCTUATION,
                    CharCategory.OTHER_PUNCTUATION,
                    CharCategory.MATH_SYMBOL,
                    CharCategory.CURRENCY_SYMBOL,
                    CharCategory.MODIFIER_SYMBOL,
                    CharCategory.OTHER_SYMBOL -> true
                    else -> false
                }
    }
}
