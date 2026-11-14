package com.getdieter.core.folders

/** One parsed rule: "+PATTERN" includes, "-PATTERN" excludes. */
class FolderRule(val pattern: String, val include: Boolean) {
    internal val codes: IntArray = Glob.slashless(pattern)

    override fun equals(other: Any?): Boolean =
        other is FolderRule && other.pattern == pattern && other.include == include

    override fun hashCode(): Int = pattern.hashCode() * 31 + include.hashCode()

    override fun toString(): String = (if (include) "+" else "-") + pattern
}

/**
 * A folder's rules (`internal/folders/rules.go`). Patterns use Go's `path.Match` syntax where `*`
 * also matches `/`; a path syncs when neither it nor an ancestor is excluded and no component is
 * protected. The last matching rule wins.
 */
object FolderRules {
    /** The shared `strings` field cap. */
    const val MAX_RULES = 64

    /** Operating system and editor droppings, at any depth. */
    val DEFAULT_RULES: List<String> =
        listOf(
            "-.DS_Store",
            "-*/.DS_Store",
            "-._*",
            "-*/._*",
            "-Thumbs.db",
            "-*/Thumbs.db",
            "-desktop.ini",
            "-*/desktop.ini",
            "-~$*",
            "-*/~$*",
            "-*.tmp",
            "-*.swp",
        )

    /** Parses and validates [values]; throws [IllegalArgumentException] for an invalid rule. */
    fun parse(values: List<String>): List<FolderRule> {
        require(values.size <= MAX_RULES) { "A folder has at most 64 rules." }
        return values.map { value ->
            val bytes = FolderNames.utf8Length(value)
            require(bytes in 2..512 && (value[0] == '+' || value[0] == '-')) {
                "A rule is +PATTERN or -PATTERN: $value"
            }
            val rule = FolderRule(value.substring(1), value[0] == '+')
            try {
                Glob.match(rule.codes, IntArray(0))
            } catch (bad: Glob.BadPattern) {
                throw IllegalArgumentException("Invalid rule pattern ${rule.pattern}")
            }
            rule
        }
    }

    /** [values] parsed, or null when one is invalid. */
    fun parseOrNull(values: List<String>): List<FolderRule>? =
        try {
            parse(values)
        } catch (invalid: IllegalArgumentException) {
            null
        }

    private fun matches(path: String, rules: List<FolderRule>): Boolean {
        var included = true
        val name = Glob.slashless(path)
        for (rule in rules) {
            val matched =
                try {
                    Glob.match(rule.codes, name)
                } catch (bad: Glob.BadPattern) {
                    false
                }
            if (matched) included = rule.include
        }
        return included
    }

    /** [path] syncs: neither it nor any ancestor is excluded, and no component is protected. */
    fun included(path: String, rules: List<FolderRule>): Boolean {
        val parts = path.split('/')
        if (parts.any(FolderNames::protected)) return false
        val prefix = StringBuilder()
        for ((index, part) in parts.withIndex()) {
            if (index > 0) prefix.append('/')
            prefix.append(part)
            if (!matches(prefix.toString(), rules)) return false
        }
        return true
    }
}

/**
 * Go's `path.Match` over code points: `*` matches any run of characters except `/`, `?` one
 * character except `/`, `[...]` a class (`^` negates, `a-z` ranges, `\` escapes). Rules replace `/`
 * with U+0001 on both sides first, so their `*` crosses directories.
 */
internal object Glob {
    class BadPattern : Exception("syntax error in pattern")

    private const val SLASH = '/'.code
    private const val STAR = '*'.code
    private const val QUESTION = '?'.code
    private const val OPEN = '['.code
    private const val CLOSE = ']'.code
    private const val CARET = '^'.code
    private const val DASH = '-'.code
    private const val ESCAPE = '\\'.code

    fun slashless(value: String): IntArray =
        FolderNames.codePoints(value).also { codes ->
            for (index in codes.indices) if (codes[index] == SLASH) codes[index] = 1
        }

    /** Whether [name] matches [pattern]; throws [BadPattern] for a malformed pattern. */
    fun match(pattern: IntArray, name: IntArray): Boolean {
        var p = 0
        var n = 0
        outer@ while (p < pattern.size) {
            var star = false
            while (p < pattern.size && pattern[p] == STAR) {
                p++
                star = true
            }
            val chunkStart = p
            val chunkEnd = scanChunk(pattern, p)
            p = chunkEnd
            if (star && chunkStart == chunkEnd) {
                // A trailing star matches the rest of the name unless it has a slash.
                for (index in n until name.size) if (name[index] == SLASH) return false
                return true
            }
            val rest = matchChunk(pattern, chunkStart, chunkEnd, name, n)
            if (rest >= 0 && (rest == name.size || p < pattern.size)) {
                n = rest
                continue
            }
            if (star) {
                var skip = n
                while (skip < name.size && name[skip] != SLASH) {
                    val after = matchChunk(pattern, chunkStart, chunkEnd, name, skip + 1)
                    if (after >= 0) {
                        if (p == pattern.size && after < name.size) {
                            skip++
                            continue
                        }
                        n = after
                        continue@outer
                    }
                    skip++
                }
            }
            // Before failing, check that the rest of the pattern is well formed.
            while (p < pattern.size) {
                while (p < pattern.size && pattern[p] == STAR) p++
                val start = p
                val end = scanChunk(pattern, p)
                p = end
                matchChunk(pattern, start, end, IntArray(0), 0)
            }
            return false
        }
        return n == name.size
    }

    /** The end of the chunk that starts at [from]: up to the next star outside a class. */
    private fun scanChunk(pattern: IntArray, from: Int): Int {
        var inRange = false
        var index = from
        while (index < pattern.size) {
            when (pattern[index]) {
                ESCAPE -> if (index + 1 < pattern.size) index++
                OPEN -> inRange = true
                CLOSE -> inRange = false
                STAR -> if (!inRange) return index
            }
            index++
        }
        return index
    }

    /**
     * Matches pattern[from, to) at name[start]: the index after the match, or -1. Keeps checking
     * the chunk's syntax after a mismatch, as Go does.
     */
    private fun matchChunk(pattern: IntArray, from: Int, to: Int, name: IntArray, start: Int): Int {
        var c = from
        var s = start
        var failed = false
        while (c < to) {
            if (!failed && s == name.size) failed = true
            when (pattern[c]) {
                OPEN -> {
                    var rune = 0
                    if (!failed) rune = name[s++]
                    c++
                    var negated = false
                    if (c < to && pattern[c] == CARET) {
                        negated = true
                        c++
                    }
                    var matched = false
                    var ranges = 0
                    while (true) {
                        if (c < to && pattern[c] == CLOSE && ranges > 0) {
                            c++
                            break
                        }
                        val low = escaped(pattern, c, to)
                        c = low.second
                        var high = low.first
                        if (pattern[c] == DASH) {
                            val upper = escaped(pattern, c + 1, to)
                            high = upper.first
                            c = upper.second
                        }
                        if (low.first <= rune && rune <= high) matched = true
                        ranges++
                    }
                    if (matched == negated) failed = true
                }
                QUESTION -> {
                    if (!failed) {
                        if (name[s] == SLASH) failed = true
                        s++
                    }
                    c++
                }
                else -> {
                    if (pattern[c] == ESCAPE) {
                        c++
                        if (c == to) throw BadPattern()
                    }
                    if (!failed) {
                        if (pattern[c] != name[s]) failed = true
                        s++
                    }
                    c++
                }
            }
        }
        return if (failed) -1 else s
    }

    /** One possibly escaped character of a class and the index after it (`getEsc`). */
    private fun escaped(pattern: IntArray, from: Int, to: Int): Pair<Int, Int> {
        var index = from
        if (index >= to || pattern[index] == DASH || pattern[index] == CLOSE) throw BadPattern()
        if (pattern[index] == ESCAPE) {
            index++
            if (index >= to) throw BadPattern()
        }
        val rune = pattern[index]
        index++
        if (index >= to) throw BadPattern()
        return rune to index
    }
}
