package com.dbpprt.dieter.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterEyes
import com.dbpprt.dieter.ui.theme.DieterAmber
import com.dbpprt.dieter.ui.theme.DieterCoral
import com.dbpprt.dieter.ui.theme.DieterRunning

internal const val MaxSyntaxHighlightCharacters = 200_000
internal const val MaxEditableSyntaxHighlightCharacters = 20_000

internal enum class CodeLanguage(val displayName: String) {
    PLAIN_TEXT("Plain text"),
    GO("Go"),
    KOTLIN("Kotlin"),
    JAVA("Java"),
    JAVASCRIPT("JavaScript"),
    TYPESCRIPT("TypeScript"),
    PYTHON("Python"),
    RUST("Rust"),
    C_CPP("C / C++"),
    C_SHARP("C#"),
    SWIFT("Swift"),
    DART("Dart"),
    SHELL("Shell"),
    SQL("SQL"),
    PROTOBUF("Protocol Buffer"),
    JSON("JSON"),
    YAML("YAML"),
    TOML("TOML"),
    MARKDOWN("Markdown"),
    HTML("HTML"),
    XML("XML"),
    CSS("CSS"),
}

internal enum class SyntaxKind {
    COMMENT,
    STRING,
    NUMBER,
    KEYWORD,
    TYPE,
    FUNCTION,
    ANNOTATION,
    PROPERTY,
    TAG,
    ATTRIBUTE,
    HEADING,
    LINK,
    EMPHASIS,
    VARIABLE,
    CONSTANT,
}

internal data class SyntaxRange(
    val start: Int,
    val end: Int,
    val kind: SyntaxKind,
)

internal fun codeLanguageForPath(path: String): CodeLanguage {
    val name = path.substringAfterLast('/').lowercase()
    val extension = name.substringAfterLast('.', missingDelimiterValue = "")
    return when {
        name == "dockerfile" || name.startsWith("dockerfile.") || name == "makefile" -> CodeLanguage.SHELL
        name == "go.mod" || name == "go.sum" -> CodeLanguage.GO
        name == "package.json" || name == "tsconfig.json" -> CodeLanguage.JSON
        name == "cargo.toml" || name == "pyproject.toml" -> CodeLanguage.TOML
        extension in setOf("kt", "kts", "gradle") -> CodeLanguage.KOTLIN
        extension == "java" -> CodeLanguage.JAVA
        extension == "go" -> CodeLanguage.GO
        extension in setOf("js", "jsx", "mjs", "cjs") -> CodeLanguage.JAVASCRIPT
        extension in setOf("ts", "tsx", "mts", "cts") -> CodeLanguage.TYPESCRIPT
        extension in setOf("py", "pyw") -> CodeLanguage.PYTHON
        extension == "rs" -> CodeLanguage.RUST
        extension in setOf("c", "h", "cc", "cpp", "cxx", "h++", "hpp", "hh") -> CodeLanguage.C_CPP
        extension == "cs" -> CodeLanguage.C_SHARP
        extension == "swift" -> CodeLanguage.SWIFT
        extension == "dart" -> CodeLanguage.DART
        extension in setOf("sh", "bash", "zsh", "fish", "command") -> CodeLanguage.SHELL
        extension == "sql" -> CodeLanguage.SQL
        extension == "proto" -> CodeLanguage.PROTOBUF
        extension in setOf("json", "jsonc") -> CodeLanguage.JSON
        extension in setOf("yaml", "yml") -> CodeLanguage.YAML
        extension in setOf("toml", "ini", "cfg", "conf", "properties") -> CodeLanguage.TOML
        extension in setOf("md", "mdx", "markdown") -> CodeLanguage.MARKDOWN
        extension in setOf("html", "htm", "xhtml", "vue", "svelte") -> CodeLanguage.HTML
        extension in setOf("xml", "svg", "plist") -> CodeLanguage.XML
        extension in setOf("css", "scss", "sass", "less") -> CodeLanguage.CSS
        else -> CodeLanguage.PLAIN_TEXT
    }
}

internal fun syntaxRanges(
    source: String,
    language: CodeLanguage,
    characterLimit: Int = MaxSyntaxHighlightCharacters,
): List<SyntaxRange> {
    if (source.isEmpty() || language == CodeLanguage.PLAIN_TEXT || characterLimit <= 0) return emptyList()
    val limit = minOf(source.length, characterLimit)
    return when (language) {
        CodeLanguage.MARKDOWN -> markdownRanges(source, limit)
        CodeLanguage.HTML, CodeLanguage.XML -> markupRanges(source, limit)
        else -> codeRanges(source, limit, profileFor(language))
    }
}

internal class CodeSyntaxVisualTransformation(
    path: String,
    private val characterLimit: Int = MaxSyntaxHighlightCharacters,
) : VisualTransformation {
    val language: CodeLanguage = codeLanguageForPath(path)
    private var cachedSource: String? = null
    private var cachedResult = AnnotatedString("")

    override fun filter(text: AnnotatedString): TransformedText {
        if (cachedSource != text.text) {
            cachedSource = text.text
            cachedResult = highlightedText(text.text, language, characterLimit)
        }
        return TransformedText(cachedResult, OffsetMapping.Identity)
    }
}

private data class LanguageProfile(
    val keywords: Set<String> = emptySet(),
    val types: Set<String> = emptySet(),
    val lineComments: List<String> = listOf("//"),
    val blockComments: List<Pair<String, String>> = listOf("/*" to "*/"),
    val caseInsensitive: Boolean = false,
    val propertySeparators: Set<Char> = emptySet(),
)

private fun profileFor(language: CodeLanguage): LanguageProfile = when (language) {
    CodeLanguage.GO -> LanguageProfile(
        keywords = words("break default func interface select case defer go map struct chan else goto package switch const fallthrough if range type continue for import return var"),
        types = words("any bool byte comparable complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr"),
    )
    CodeLanguage.KOTLIN -> LanguageProfile(
        keywords = words("as break class continue do else false for fun if in interface is null object package return super this throw true try typealias typeof val var when while by catch constructor delegate dynamic field file finally get import init param property receiver set setparam where actual abstract annotation companion const crossinline data enum expect external final infix inline inner internal lateinit noinline open operator out override private protected public reified sealed suspend tailrec vararg"),
        types = words("Any Boolean Byte Char Double Float Int Long Nothing Short String UInt ULong Unit List Map Set MutableList MutableMap MutableSet Array"),
    )
    CodeLanguage.JAVA -> LanguageProfile(
        keywords = words("abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while true false null record sealed permits non-sealed var yield"),
        types = words("Boolean Byte Character Double Float Integer Long Number Object Short String StringBuilder Throwable List Map Set Collection Optional Stream"),
    )
    CodeLanguage.JAVASCRIPT, CodeLanguage.TYPESCRIPT -> LanguageProfile(
        keywords = words("as async await break case catch class const continue debugger default delete do else export extends false finally for from function get if implements import in instanceof interface let new null of package private protected public return set static super switch this throw true try typeof undefined var void while with yield abstract any boolean constructor declare enum infer keyof module namespace never number object readonly require string symbol type unknown satisfies"),
        types = words("Array BigInt Boolean Date Error Function JSON Map Math Number Object Promise Proxy Reflect RegExp Set String Symbol WeakMap WeakSet HTMLElement ReactNode Record Partial Pick Omit"),
    )
    CodeLanguage.PYTHON -> LanguageProfile(
        keywords = words("and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield match case"),
        types = words("bool bytes dict float frozenset int list object set str tuple type Exception Iterable Iterator Optional Any"),
        lineComments = listOf("#"),
        blockComments = emptyList(),
    )
    CodeLanguage.RUST -> LanguageProfile(
        keywords = words("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while abstract become box do final macro override priv typeof unsized virtual yield try"),
        types = words("bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize Box Option Result String Vec HashMap HashSet"),
    )
    CodeLanguage.C_CPP -> LanguageProfile(
        keywords = words("alignas alignof and and_eq asm atomic_cancel atomic_commit atomic_noexcept auto bitand bitor break case catch class compl concept const consteval constexpr constinit const_cast continue co_await co_return co_yield decltype default delete do dynamic_cast else enum explicit export extern false for friend goto if inline mutable namespace new noexcept not not_eq nullptr operator or or_eq private protected public reflexpr register reinterpret_cast requires return sizeof static static_assert static_cast struct switch synchronized template this thread_local throw true try typedef typeid typename union unsigned using virtual volatile while xor xor_eq"),
        types = words("bool char char8_t char16_t char32_t double float int long short signed size_t std string uint8_t uint16_t uint32_t uint64_t void wchar_t"),
    )
    CodeLanguage.C_SHARP -> LanguageProfile(
        keywords = words("abstract as base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern false finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new null object operator out override params private protected public readonly record ref return sbyte sealed short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using virtual void volatile while async await dynamic get init partial set value var when where yield"),
        types = words("DateTime Dictionary Exception IEnumerable List Nullable String Task Type Uri"),
    )
    CodeLanguage.SWIFT -> LanguageProfile(
        keywords = words("associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private protocol public rethrows static struct subscript typealias var break continue default defer do else fallthrough for guard if in repeat return switch where while as Any catch false is nil super self Self throw throws true try async await actor some any"),
        types = words("Any AnyObject Array Bool Character Dictionary Double Error Float Int Never Optional Result Set String UInt URL Void"),
    )
    CodeLanguage.DART -> LanguageProfile(
        keywords = words("abstract as assert async await break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory false final finally for Function get hide if implements import in interface is late library mixin new null on operator part required rethrow return set show static super switch sync this throw true try typedef var void while with yield"),
        types = words("bool double int num Object String List Map Set Future Stream Iterable Never Null"),
    )
    CodeLanguage.SHELL -> LanguageProfile(
        keywords = words("if then elif else fi for while until do done case esac function in select time coproc return exit export local readonly declare typeset unset shift source alias unalias set true false"),
        lineComments = listOf("#"),
        blockComments = emptyList(),
    )
    CodeLanguage.SQL -> LanguageProfile(
        keywords = words("add all alter and any as asc backup between by case check column constraint create database default delete desc distinct drop exec exists foreign from full group having in index inner insert into is join key left like limit not null on or order outer primary procedure right rownum select set table top truncate union unique update values view where with returning conflict offset begin commit rollback grant revoke trigger function language declare end when then else loop raise"),
        types = words("bigint boolean char date decimal double float int integer interval json jsonb numeric real serial smallint text time timestamp uuid varchar"),
        lineComments = listOf("--"),
        caseInsensitive = true,
    )
    CodeLanguage.PROTOBUF -> LanguageProfile(
        keywords = words("syntax package import option message enum service rpc returns stream repeated optional required reserved oneof map extensions extend to max public weak"),
        types = words("bool bytes double fixed32 fixed64 float int32 int64 sfixed32 sfixed64 sint32 sint64 string uint32 uint64"),
    )
    CodeLanguage.JSON -> LanguageProfile(
        keywords = words("true false null"),
        lineComments = emptyList(),
        blockComments = emptyList(),
        propertySeparators = setOf(':'),
    )
    CodeLanguage.YAML -> LanguageProfile(
        keywords = words("true false null yes no on off include"),
        lineComments = listOf("#"),
        blockComments = emptyList(),
        caseInsensitive = true,
        propertySeparators = setOf(':'),
    )
    CodeLanguage.TOML -> LanguageProfile(
        keywords = words("true false null"),
        lineComments = listOf("#", ";"),
        blockComments = emptyList(),
        caseInsensitive = true,
        propertySeparators = setOf('='),
    )
    CodeLanguage.CSS -> LanguageProfile(
        keywords = words("important inherit initial revert unset auto none block inline flex grid absolute relative fixed sticky transparent currentcolor var calc min max clamp"),
        lineComments = emptyList(),
        propertySeparators = setOf(':'),
    )
    else -> LanguageProfile()
}

private fun codeRanges(source: String, limit: Int, profile: LanguageProfile): List<SyntaxRange> {
    val ranges = ArrayList<SyntaxRange>()
    var index = 0
    while (index < limit) {
        val lineComment = profile.lineComments.firstOrNull { source.startsWith(it, index) }
        if (lineComment != null) {
            val end = source.indexOf('\n', index).let { if (it == -1 || it > limit) limit else it }
            ranges += SyntaxRange(index, end, SyntaxKind.COMMENT)
            index = end
            continue
        }
        val blockComment = profile.blockComments.firstOrNull { source.startsWith(it.first, index) }
        if (blockComment != null) {
            val closing = source.indexOf(blockComment.second, index + blockComment.first.length)
            val end = if (closing == -1 || closing + blockComment.second.length > limit) limit else closing + blockComment.second.length
            ranges += SyntaxRange(index, end, SyntaxKind.COMMENT)
            index = end
            continue
        }

        val current = source[index]
        if (current == '"' || current == '\'' || current == '`') {
            val end = stringEnd(source, index, limit, current)
            val next = nextNonWhitespace(source, end, limit)
            val kind = if (next < limit && source[next] in profile.propertySeparators) SyntaxKind.PROPERTY else SyntaxKind.STRING
            ranges += SyntaxRange(index, end, kind)
            index = end
            continue
        }
        if (current == '@' && index + 1 < limit && isIdentifierStart(source[index + 1])) {
            val end = identifierEnd(source, index + 1, limit)
            ranges += SyntaxRange(index, end, SyntaxKind.ANNOTATION)
            index = end
            continue
        }
        if (current == '$' && index + 1 < limit && (isIdentifierStart(source[index + 1]) || source[index + 1] == '{')) {
            var end = index + 1
            if (source[end] == '{') {
                val closing = source.indexOf('}', end + 1)
                end = if (closing == -1 || closing >= limit) limit else closing + 1
            } else {
                end = identifierEnd(source, end, limit)
            }
            ranges += SyntaxRange(index, end, SyntaxKind.VARIABLE)
            index = end
            continue
        }
        if (current.isDigit() && (index == 0 || !isIdentifierPart(source[index - 1]))) {
            var end = index + 1
            while (end < limit && (source[end].isLetterOrDigit() || source[end] in ".xXbBoO_+-")) end++
            ranges += SyntaxRange(index, end, SyntaxKind.NUMBER)
            index = end
            continue
        }
        if (isIdentifierStart(current)) {
            val end = identifierEnd(source, index, limit)
            val word = source.substring(index, end)
            val comparable = if (profile.caseInsensitive) word.lowercase() else word
            val next = nextNonWhitespace(source, end, limit)
            val kind = when {
                comparable in profile.keywords -> SyntaxKind.KEYWORD
                comparable in profile.types -> SyntaxKind.TYPE
                next < limit && source[next] in profile.propertySeparators -> SyntaxKind.PROPERTY
                next < limit && source[next] == '(' -> SyntaxKind.FUNCTION
                word.length > 1 && word.all { it.isUpperCase() || it.isDigit() || it == '_' } -> SyntaxKind.CONSTANT
                word.first().isUpperCase() -> SyntaxKind.TYPE
                else -> null
            }
            if (kind != null) ranges += SyntaxRange(index, end, kind)
            index = end
            continue
        }
        if (current == '#' && index + 1 < limit && source[index + 1].isLetterOrDigit()) {
            var end = index + 2
            while (end < limit && source[end].isLetterOrDigit()) end++
            if (end - index in 4..9) ranges += SyntaxRange(index, end, SyntaxKind.CONSTANT)
            index = end
            continue
        }
        index++
    }
    return ranges
}

private fun markupRanges(source: String, limit: Int): List<SyntaxRange> {
    val ranges = ArrayList<SyntaxRange>()
    var index = 0
    while (index < limit) {
        if (source.startsWith("<!--", index)) {
            val closing = source.indexOf("-->", index + 4)
            val end = if (closing == -1 || closing + 3 > limit) limit else closing + 3
            ranges += SyntaxRange(index, end, SyntaxKind.COMMENT)
            index = end
            continue
        }
        if (source[index] != '<') {
            index++
            continue
        }
        val tagEnd = source.indexOf('>', index + 1).let { if (it == -1 || it >= limit) limit else it + 1 }
        ranges += SyntaxRange(index, minOf(index + 1, tagEnd), SyntaxKind.TAG)
        var cursor = index + 1
        if (cursor < tagEnd && source[cursor] == '/') cursor++
        cursor = nextNonWhitespace(source, cursor, tagEnd)
        val nameEnd = markupNameEnd(source, cursor, tagEnd)
        if (nameEnd > cursor) ranges += SyntaxRange(cursor, nameEnd, SyntaxKind.TAG)
        cursor = nameEnd
        while (cursor < tagEnd) {
            cursor = nextNonWhitespace(source, cursor, tagEnd)
            if (cursor >= tagEnd || source[cursor] == '>' || source[cursor] == '/') break
            val attributeEnd = markupNameEnd(source, cursor, tagEnd)
            if (attributeEnd == cursor) {
                cursor++
                continue
            }
            ranges += SyntaxRange(cursor, attributeEnd, SyntaxKind.ATTRIBUTE)
            cursor = nextNonWhitespace(source, attributeEnd, tagEnd)
            if (cursor < tagEnd && source[cursor] == '=') {
                cursor = nextNonWhitespace(source, cursor + 1, tagEnd)
                if (cursor < tagEnd && (source[cursor] == '"' || source[cursor] == '\'')) {
                    val valueEnd = stringEnd(source, cursor, tagEnd, source[cursor])
                    ranges += SyntaxRange(cursor, valueEnd, SyntaxKind.STRING)
                    cursor = valueEnd
                }
            }
        }
        if (tagEnd > index + 1) ranges += SyntaxRange(tagEnd - 1, tagEnd, SyntaxKind.TAG)
        index = tagEnd
    }
    return ranges
}

private fun markdownRanges(source: String, limit: Int): List<SyntaxRange> {
    val ranges = ArrayList<SyntaxRange>()
    var lineStart = 0
    var fenceMarker: String? = null
    var fencedLanguage = CodeLanguage.PLAIN_TEXT
    while (lineStart < limit) {
        val lineEnd = source.indexOf('\n', lineStart).let { if (it == -1 || it > limit) limit else it }
        val contentStart = nextNonWhitespace(source, lineStart, lineEnd)
        val fence = when {
            source.startsWith("```", contentStart) -> "```"
            source.startsWith("~~~", contentStart) -> "~~~"
            else -> null
        }
        if (fence != null) {
            ranges += SyntaxRange(contentStart, lineEnd, SyntaxKind.KEYWORD)
            if (fenceMarker == null) {
                fenceMarker = fence
                val hint = source.substring(minOf(contentStart + fence.length, lineEnd), lineEnd).trim()
                fencedLanguage = languageForFence(hint)
            } else if (fence == fenceMarker) {
                fenceMarker = null
                fencedLanguage = CodeLanguage.PLAIN_TEXT
            }
        } else if (fenceMarker != null) {
            if (fencedLanguage != CodeLanguage.PLAIN_TEXT) {
                val line = source.substring(lineStart, lineEnd)
                ranges += syntaxRanges(line, fencedLanguage, line.length).map { it.copy(start = it.start + lineStart, end = it.end + lineStart) }
            }
        } else {
            var hashes = contentStart
            while (hashes < lineEnd && source[hashes] == '#') hashes++
            if (hashes > contentStart && hashes - contentStart <= 6 && hashes < lineEnd && source[hashes].isWhitespace()) {
                ranges += SyntaxRange(contentStart, lineEnd, SyntaxKind.HEADING)
            } else if (contentStart < lineEnd && source[contentStart] == '>') {
                ranges += SyntaxRange(contentStart, lineEnd, SyntaxKind.EMPHASIS)
            }
            inlineMarkdownRanges(source, lineStart, lineEnd, ranges)
        }
        lineStart = if (lineEnd < limit) lineEnd + 1 else limit
    }
    return ranges
}

private fun inlineMarkdownRanges(source: String, start: Int, end: Int, ranges: MutableList<SyntaxRange>) {
    var index = start
    while (index < end) {
        when {
            source[index] == '`' -> {
                val closing = source.indexOf('`', index + 1)
                val tokenEnd = if (closing == -1 || closing >= end) end else closing + 1
                ranges += SyntaxRange(index, tokenEnd, SyntaxKind.STRING)
                index = tokenEnd
            }
            source[index] == '[' -> {
                val labelEnd = source.indexOf(']', index + 1)
                if (labelEnd in (index + 1) until end && labelEnd + 1 < end && source[labelEnd + 1] == '(') {
                    val urlEnd = source.indexOf(')', labelEnd + 2)
                    if (urlEnd in (labelEnd + 2) until end) {
                        ranges += SyntaxRange(index, labelEnd + 1, SyntaxKind.LINK)
                        ranges += SyntaxRange(labelEnd + 1, urlEnd + 1, SyntaxKind.STRING)
                        index = urlEnd + 1
                        continue
                    }
                }
                index++
            }
            source[index] == '*' || source[index] == '_' -> {
                val marker = if (index + 1 < end && source[index + 1] == source[index]) 2 else 1
                val delimiter = source.substring(index, index + marker)
                val closing = source.indexOf(delimiter, index + marker)
                if (closing in (index + marker) until end) {
                    ranges += SyntaxRange(index, closing + marker, SyntaxKind.EMPHASIS)
                    index = closing + marker
                } else {
                    index++
                }
            }
            else -> index++
        }
    }
}

private fun highlightedText(source: String, language: CodeLanguage, characterLimit: Int): AnnotatedString {
    val builder = AnnotatedString.Builder(source)
    syntaxRanges(source, language, characterLimit).forEach { range ->
        builder.addStyle(styleFor(range.kind), range.start, range.end)
    }
    return builder.toAnnotatedString()
}

private fun styleFor(kind: SyntaxKind): SpanStyle = when (kind) {
    SyntaxKind.COMMENT -> SpanStyle(color = DieterMuted, fontStyle = FontStyle.Italic)
    SyntaxKind.STRING -> SpanStyle(color = DieterEyes)
    SyntaxKind.NUMBER -> SpanStyle(color = DieterCoral)
    SyntaxKind.KEYWORD -> SpanStyle(color = DieterRunning, fontWeight = FontWeight.SemiBold)
    SyntaxKind.TYPE -> SpanStyle(color = DieterAmber)
    SyntaxKind.FUNCTION -> SpanStyle(color = DieterRunning)
    SyntaxKind.ANNOTATION -> SpanStyle(color = DieterCoral)
    SyntaxKind.PROPERTY -> SpanStyle(color = DieterRunning)
    SyntaxKind.TAG -> SpanStyle(color = DieterRunning)
    SyntaxKind.ATTRIBUTE -> SpanStyle(color = DieterAmber)
    SyntaxKind.HEADING -> SpanStyle(color = DieterRunning, fontWeight = FontWeight.Bold)
    SyntaxKind.LINK -> SpanStyle(color = DieterRunning)
    SyntaxKind.EMPHASIS -> SpanStyle(color = DieterAmber, fontStyle = FontStyle.Italic)
    SyntaxKind.VARIABLE -> SpanStyle(color = DieterAmber)
    SyntaxKind.CONSTANT -> SpanStyle(color = DieterCoral)
}

private fun words(value: String): Set<String> = value.split(' ').toSet()

private fun stringEnd(source: String, start: Int, limit: Int, quote: Char): Int {
    val triple = start + 2 < limit && source[start + 1] == quote && source[start + 2] == quote
    var index = start + if (triple) 3 else 1
    while (index < limit) {
        if (!triple && source[index] == '\\') {
            index = minOf(index + 2, limit)
            continue
        }
        if (triple && index + 2 < limit && source[index] == quote && source[index + 1] == quote && source[index + 2] == quote) {
            return index + 3
        }
        if (!triple && source[index] == quote) return index + 1
        index++
    }
    return limit
}

private fun nextNonWhitespace(source: String, start: Int, limit: Int): Int {
    var index = start
    while (index < limit && source[index].isWhitespace()) index++
    return index
}

private fun identifierEnd(source: String, start: Int, limit: Int): Int {
    var index = start + 1
    while (index < limit && isIdentifierPart(source[index])) index++
    return index
}

private fun markupNameEnd(source: String, start: Int, limit: Int): Int {
    var index = start
    while (index < limit && (source[index].isLetterOrDigit() || source[index] in "_:-.@")) index++
    return index
}

private fun isIdentifierStart(char: Char): Boolean = char.isLetter() || char == '_' || char == '$'

private fun isIdentifierPart(char: Char): Boolean = char.isLetterOrDigit() || char == '_' || char == '$'

private fun languageForFence(hint: String): CodeLanguage = when (hint.lowercase().substringBefore(' ')) {
    "go", "golang" -> CodeLanguage.GO
    "kotlin", "kt" -> CodeLanguage.KOTLIN
    "java" -> CodeLanguage.JAVA
    "js", "javascript", "jsx" -> CodeLanguage.JAVASCRIPT
    "ts", "typescript", "tsx" -> CodeLanguage.TYPESCRIPT
    "py", "python" -> CodeLanguage.PYTHON
    "rust", "rs" -> CodeLanguage.RUST
    "c", "cpp", "c++" -> CodeLanguage.C_CPP
    "cs", "csharp" -> CodeLanguage.C_SHARP
    "swift" -> CodeLanguage.SWIFT
    "dart" -> CodeLanguage.DART
    "sh", "shell", "bash", "zsh" -> CodeLanguage.SHELL
    "sql" -> CodeLanguage.SQL
    "proto", "protobuf" -> CodeLanguage.PROTOBUF
    "json", "jsonc" -> CodeLanguage.JSON
    "yaml", "yml" -> CodeLanguage.YAML
    "toml" -> CodeLanguage.TOML
    "html" -> CodeLanguage.HTML
    "xml", "svg" -> CodeLanguage.XML
    "css", "scss", "sass", "less" -> CodeLanguage.CSS
    else -> CodeLanguage.PLAIN_TEXT
}
