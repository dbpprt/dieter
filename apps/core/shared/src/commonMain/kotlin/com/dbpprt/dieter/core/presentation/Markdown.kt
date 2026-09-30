package com.dbpprt.dieter.core.presentation

enum class TableAlignment { START, CENTER, END }

/** Block structure of message markdown; inline styling is left to the platform renderer. */
sealed interface MarkdownBlock {
    data class Paragraph(val text: String) : MarkdownBlock
    data class Heading(val level: Int, val text: String) : MarkdownBlock
    data class Bullet(val text: String) : MarkdownBlock
    data class Code(val text: String, val language: String) : MarkdownBlock
    data class Table(val header: List<String>, val alignments: List<TableAlignment>, val rows: List<List<String>>) : MarkdownBlock
}

/** The conversation markdown grammar shared by every client: fences, pipe tables, headings, bullets, paragraphs. */
object Markdown {
    fun parse(source: String): List<MarkdownBlock> {
        val lines = source.split('\n')
        val blocks = mutableListOf<MarkdownBlock>()
        val pending = mutableListOf<String>()
        var code: MutableList<String>? = null
        var language = ""

        fun flush() {
            val text = pending.joinToString("\n").trim('\n').trimEnd()
            pending.clear()
            if (text.isNotBlank()) blocks += MarkdownBlock.Paragraph(text)
        }

        var index = 0
        while (index < lines.size) {
            val line = lines[index]
            val trimmedStart = line.trimStart()
            if (trimmedStart.startsWith("```")) {
                if (code == null) {
                    flush()
                    code = mutableListOf()
                    language = trimmedStart.removePrefix("```").trim()
                } else {
                    blocks += MarkdownBlock.Code(code.joinToString("\n"), language)
                    code = null
                }
                index++
                continue
            }
            if (code != null) {
                code += line
                index++
                continue
            }
            val header = cells(line)
            val delimiter = lines.getOrNull(index + 1)?.let(::cells)
            if (header != null && delimiter != null && delimiter.size == header.size && delimiter.all(::isDelimiter)) {
                flush()
                val rows = mutableListOf<List<String>>()
                var cursor = index + 2
                while (cursor < lines.size && lines[cursor].contains('|')) {
                    val row = cells(lines[cursor]) ?: break
                    rows += List(header.size) { row.getOrElse(it) { "" } }
                    cursor++
                }
                blocks += MarkdownBlock.Table(header, delimiter.map(::alignment), rows)
                index = cursor
                continue
            }
            if (line.isBlank()) {
                flush()
                index++
                continue
            }
            val heading = Regex("^(#{1,4}) (.*)$").find(line.trim())
            if (heading != null) {
                flush()
                blocks += MarkdownBlock.Heading(heading.groupValues[1].length, heading.groupValues[2].trim())
                index++
                continue
            }
            if (trimmedStart.startsWith("- ") || trimmedStart.startsWith("* ")) {
                flush()
                blocks += MarkdownBlock.Bullet(trimmedStart.drop(2))
                index++
                continue
            }
            pending += line
            index++
        }
        code?.let { blocks += MarkdownBlock.Code(it.joinToString("\n"), language) }
        flush()
        return blocks
    }

    /** Cells of a pipe-table row: pipes inside code spans or escaped with `\` do not split. */
    fun cells(line: String): List<String>? {
        if (!line.contains('|')) return null
        var body = line.trim()
        if (body.startsWith("|")) body = body.drop(1)
        if (body.endsWith("|") && !body.endsWith("\\|")) body = body.dropLast(1)
        val cells = mutableListOf<String>()
        val current = StringBuilder()
        var inCode = false
        var index = 0
        while (index < body.length) {
            val char = body[index]
            when {
                char == '\\' && index + 1 < body.length -> {
                    current.append(body[index + 1])
                    index++
                }
                char == '`' -> {
                    inCode = !inCode
                    current.append(char)
                }
                char == '|' && !inCode -> {
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

    private fun isDelimiter(cell: String): Boolean {
        val dashes = cell.trim(':')
        return dashes.length >= 3 && dashes.all { it == '-' }
    }

    private fun alignment(cell: String): TableAlignment = when {
        cell.startsWith(":") && cell.endsWith(":") -> TableAlignment.CENTER
        cell.endsWith(":") -> TableAlignment.END
        else -> TableAlignment.START
    }
}
