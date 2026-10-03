package com.dbpprt.dieter.core.files

import com.dbpprt.dieter.api.v1.FileDocument
import com.dbpprt.dieter.api.v1.FileEntry
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import okio.ByteString
import okio.ByteString.Companion.encodeUtf8

class FilesTest {
    private fun kinds(source: String, language: CodeLanguage, limit: Int = MAX_SYNTAX_HIGHLIGHT_CHARACTERS) =
        syntaxRanges(source, language, limit).map { source.substring(it.start, it.end) to it.kind }

    @Test
    fun detectsLanguagesFromProjectFileNames() {
        assertEquals(CodeLanguage.GO, codeLanguageForPath("cmd/main.go"))
        assertEquals(CodeLanguage.TYPESCRIPT, codeLanguageForPath("App.tsx"))
        assertEquals(CodeLanguage.KOTLIN, codeLanguageForPath("build.gradle.kts"))
        assertEquals(CodeLanguage.PROTOBUF, codeLanguageForPath("api/dieter.proto"))
        assertEquals(CodeLanguage.MARKDOWN, codeLanguageForPath("README.md"))
        assertEquals(CodeLanguage.SHELL, codeLanguageForPath("docker/Dockerfile"))
        assertEquals(CodeLanguage.SHELL, codeLanguageForPath("justfile"))
        assertEquals(CodeLanguage.C, codeLanguageForPath("x.h"))
        assertEquals(CodeLanguage.CPP, codeLanguageForPath("x.hpp"))
        assertEquals(CodeLanguage.OBJECTIVE_C, codeLanguageForPath("View.m"))
        assertEquals(CodeLanguage.RUBY, codeLanguageForPath("Gemfile.rb"))
        assertEquals(CodeLanguage.PLAIN_TEXT, codeLanguageForPath("LICENSE"))
        assertEquals(CodeLanguage.PLAIN_TEXT, codeLanguageForPath(".gitignore"))
    }

    @Test
    fun highlightsGoWithoutTreatingCommentsAsCode() {
        val ranges = kinds("func main() string { return \"hi\" } // return x", CodeLanguage.GO)
        assertTrue(("func" to SyntaxKind.KEYWORD) in ranges)
        assertTrue(("main" to SyntaxKind.FUNCTION) in ranges)
        assertTrue(("string" to SyntaxKind.TYPE) in ranges)
        assertTrue(("\"hi\"" to SyntaxKind.STRING) in ranges)
        assertEquals(SyntaxKind.COMMENT, ranges.last().second)
        assertEquals(1, ranges.count { it.first == "return" }, "return inside the comment is not a keyword")
    }

    @Test
    fun distinguishesJsonPropertiesValuesAndLiterals() {
        val ranges = kinds("{\"key\": \"value\", \"on\": true, \"n\": 5}", CodeLanguage.JSON)
        assertTrue(("\"key\"" to SyntaxKind.PROPERTY) in ranges)
        assertTrue(("\"value\"" to SyntaxKind.STRING) in ranges)
        assertTrue(("true" to SyntaxKind.KEYWORD) in ranges)
        assertTrue(("5" to SyntaxKind.NUMBER) in ranges)
    }

    @Test
    fun highlightsMarkdownAndItsFencedLanguage() {
        val source = "# Title\nUse `code` here\n```go\nfunc main() {}\n```"
        val ranges = kinds(source, CodeLanguage.MARKDOWN)
        assertTrue(("# Title" to SyntaxKind.HEADING) in ranges || ranges.any { it.second == SyntaxKind.HEADING })
        assertTrue(("`code`" to SyntaxKind.STRING) in ranges)
        assertTrue(("func" to SyntaxKind.KEYWORD) in ranges)
        assertTrue(("main" to SyntaxKind.FUNCTION) in ranges)
    }

    @Test
    fun capsHighlightingWorkForLargeFiles() {
        val source = "val first = 1\n".repeat(4) + "const last = 2"
        assertTrue(kinds(source, CodeLanguage.KOTLIN, limit = 40).none { it.first == "const" })
    }

    @Test
    fun pathsFollowTheDaemonRules() {
        assertEquals("a/b", FilePaths.normalize("./a//b/").getOrThrow())
        assertEquals("", FilePaths.normalize("", allowRoot = true).getOrThrow())
        assertTrue(FilePaths.normalize("").isFailure)
        assertTrue(FilePaths.normalize("/etc").isFailure)
        assertTrue(FilePaths.normalize("../x").isFailure)
        assertTrue(FilePaths.normalize("a/.git/config").isFailure)
        assertTrue(FilePaths.normalize("a\\b").isFailure)
        assertEquals("b", FilePaths.normalize("a/../b").getOrThrow())
        assertEquals("apps/mac", FilePaths.parent("apps/mac/Sources"))
        assertEquals("", FilePaths.parent("apps"))
        assertEquals("", FilePaths.parent(""))
        assertEquals("dir/new.txt", FilePaths.join("/dir/", "/new.txt"))
        assertEquals(1, FilePaths.countLines(""))
        assertEquals(3, FilePaths.countLines("a\nb\n"))
        FilePaths.lineRange(3, "a\n").let { assertEquals(2, it.first); assertTrue(it.isEmpty()) }
        FilePaths.lineRange(1, "").let { assertEquals(0, it.first); assertTrue(it.isEmpty()) }
        assertEquals(4..6, FilePaths.lineRange(2, "ab\r\ncde\nf"))
        assertEquals(8..8, FilePaths.lineRange(99, "ab\r\ncde\nf"))
    }

    @Test
    fun navigationHistoryIsBoundedAndSymmetric() {
        val navigation = FileNavigation()
        navigation.record("", "a")
        navigation.record("a", "a/b")
        assertEquals("a", navigation.goBack("a/b"))
        assertTrue(navigation.canGoForward)
        assertEquals("a/b", navigation.goForward("a"))
        navigation.record("a/b", "c")
        assertFalse(navigation.canGoForward, "a new visit clears forward history")
        repeat(150) { navigation.record("x$it", "y$it") }
        var steps = 0
        while (navigation.goBack("z") != null) steps++
        assertEquals(FileNavigation.LIMIT, steps)
    }

    @Test
    fun presentationHelpers() {
        assertTrue(FilePaths.isImage("photo.JPG", ""))
        assertTrue(FilePaths.isImage("blob", "image/webp"))
        assertEquals(FilePaths.Renderer.PDF, FilePaths.renderer(FileDocument(name = "a.bin", mime_type = "application/pdf; x=y", binary = true)))
        assertEquals(FilePaths.Renderer.UNSUPPORTED, FilePaths.renderer(FileDocument(name = "a.bin", binary = true)))
        assertEquals(FilePaths.Renderer.MARKDOWN, FilePaths.renderer(FileDocument(name = "README.md")))
        assertTrue(FilePaths.editable(FileDocument(name = "README.md")) && FilePaths.editable(FileDocument(name = "main.kt")))
        assertFalse(FilePaths.editable(FileDocument(name = "a.png", mime_type = "image/png", binary = true)), "images are view-only")
        assertFalse(FilePaths.editable(FileDocument(name = "a.bin", binary = true)))
        assertEquals("hé".encodeUtf8(), FilePaths.bytes(FileDocument(content = "hé")))
        val entries = listOf(FileEntry(name = "file10", kind = "file"), FileEntry(name = "file2", kind = "file"), FileEntry(name = "src", kind = "directory"))
        assertEquals(listOf("src", "file2", "file10"), entries.sortedWith(FilePaths.naturalOrder).map { it.name })
        assertEquals("1:a0:1:b0:4:path", FilesTarget("a", "", "b", "").documentKey("path"))
    }

    @Test
    fun macLanguageAndPresentationCasesHold() {
        // Ported from the macOS ProjectFileLanguage and ProjectFilePresentation tests.
        assertEquals(CodeLanguage.SWIFT, codeLanguageForPath("BoardView.swift"))
        assertEquals(CodeLanguage.GO, codeLanguageForPath("main.go"))
        assertEquals(CodeLanguage.TYPESCRIPT, codeLanguageForPath("client.tsx"))
        assertEquals(CodeLanguage.YAML, codeLanguageForPath("settings.yaml"))
        assertEquals(CodeLanguage.SHELL, codeLanguageForPath("Dockerfile"))
        assertEquals(CodeLanguage.PLAIN_TEXT, codeLanguageForPath("LICENSE"))
        assertTrue(FilePaths.isImage("preview.png", ""))
        assertTrue(FilePaths.isImage("asset", "image/webp"))
        assertFalse(FilePaths.isImage("main.swift", "text/plain"))
        assertEquals(ByteString.of(0, 1, 2), FilePaths.bytes(FileDocument(binary = true, content = "ignored", data_ = ByteString.of(0, 1, 2))))
        assertEquals("hello".encodeUtf8(), FilePaths.bytes(FileDocument(content = "hello")))
        assertEquals("apps", FilePaths.parent("apps/mac"))
        assertEquals(3, FilePaths.countLines("one\ntwo\nthree"))
        val first = FilesTarget("a:b", "c", cardId = "d")
        val second = FilesTarget("a", "b:c", cardId = "d")
        assertNotEquals(first.documentKey("same.swift"), second.documentKey("same.swift"), "separators inside IDs never collide")
        assertEquals(first.documentKey("same.swift"), first.documentKey("same.swift"))
    }

    @Test
    fun lineRangesAreUtf16AndClampStaleLineNumbers() {
        // Ported from the macOS code-link line ranges: CRLF endings and a surrogate pair before the line.
        val source = "let emoji = \"💡\"\r\nsecond line\r\nfinal"
        val second = FilePaths.lineRange(2, source)
        assertEquals("second line", source.substring(second))
        assertEquals("let emoji = \"💡\"\r\n".length, second.first)
        assertEquals("let emoji = \"💡\"", source.substring(FilePaths.lineRange(-4, source)))
        assertEquals("final", source.substring(FilePaths.lineRange(999, source)))
        assertEquals("b", "a\rb".substring(FilePaths.lineRange(2, "a\rb")), "a lone carriage return ends a line")
    }

    @Test
    fun swiftKeywordsIncludeCaseAndIsolation() {
        val ranges = kinds("switch value { case .a: nonisolated(unsafe) var x = 1 }", CodeLanguage.SWIFT)
        assertTrue(("case" to SyntaxKind.KEYWORD) in ranges)
        assertTrue(("nonisolated" to SyntaxKind.KEYWORD) in ranges, "a keyword before a parenthesis stays a keyword")
        assertTrue(("isolated" to SyntaxKind.KEYWORD) in kinds("func run(on actor: isolated Worker)", CodeLanguage.SWIFT))
        assertTrue(("Int" to SyntaxKind.TYPE) in kinds("let answer: Int = 42 // meaning", CodeLanguage.SWIFT))
    }

    @Test
    fun markdownCommentsMaySpanLines() {
        val source = "Intro <!-- note --> *after*\n<!-- open\nstill hidden --> tail **bold**\n# Heading"
        assertEquals(
            listOf(
                "<!-- note -->" to SyntaxKind.COMMENT,
                "*after*" to SyntaxKind.EMPHASIS,
                "<!-- open\nstill hidden -->" to SyntaxKind.COMMENT,
                "**bold**" to SyntaxKind.EMPHASIS,
                "# Heading" to SyntaxKind.HEADING,
            ),
            kinds(source, CodeLanguage.MARKDOWN),
        )
        val unclosed = "a <!-- never closed\n# not a heading"
        assertEquals(listOf("<!-- never closed\n# not a heading" to SyntaxKind.COMMENT), kinds(unclosed, CodeLanguage.MARKDOWN))
    }

    @Test
    fun fencedBlocksAreLexedWholeInTheirLanguage() {
        val source = "```go\n/* first\nsecond */\nfunc main() {}\n```\nafter"
        assertEquals(
            listOf(
                "```go" to SyntaxKind.KEYWORD,
                "/* first\nsecond */" to SyntaxKind.COMMENT,
                "func" to SyntaxKind.KEYWORD,
                "main" to SyntaxKind.FUNCTION,
                "```" to SyntaxKind.KEYWORD,
            ),
            kinds(source, CodeLanguage.MARKDOWN),
        )
        assertEquals(listOf("```py" to SyntaxKind.KEYWORD, "# comment" to SyntaxKind.COMMENT), kinds("```py\n# comment", CodeLanguage.MARKDOWN), "an unclosed fence runs to the end")
        assertTrue(kinds("~~~\n```\n<!-- x -->\n~~~", CodeLanguage.MARKDOWN).none { it.second == SyntaxKind.COMMENT }, "another fence marker and comments inside a fence are content")
    }

    @Test
    fun renderersFollowTheDocumentsMetadata() {
        // Ported from the macOS renderer choice; a path's folder never supplies an extension.
        assertEquals(FilePaths.Renderer.MARKDOWN, FilePaths.renderer("plan.md", "", false))
        assertEquals(FilePaths.Renderer.TEXT, FilePaths.renderer("main.swift", "", false))
        assertEquals(FilePaths.Renderer.TEXT, FilePaths.renderer("README", "", false))
        assertEquals(FilePaths.Renderer.IMAGE, FilePaths.renderer("photo.PNG", "", true))
        assertEquals(FilePaths.Renderer.IMAGE, FilePaths.renderer("asset", "image/jpeg", true))
        assertEquals(FilePaths.Renderer.PDF, FilePaths.renderer("report.PDF", "", true))
        assertEquals(FilePaths.Renderer.PDF, FilePaths.renderer("report", "application/pdf; charset=binary", true))
        assertEquals(FilePaths.Renderer.UNSUPPORTED, FilePaths.renderer("archive.zip", "", true))
        assertEquals(FilePaths.Renderer.UNSUPPORTED, FilePaths.renderer("broken.md", "", true))
        assertEquals(FilePaths.Renderer.IMAGE, FilePaths.renderer("docs/diagram.svg", "image/svg+xml", false), "an SVG is an image even as text")
        assertEquals(FilePaths.Renderer.TEXT, FilePaths.renderer("docs.v2/notes", "", false))
    }

    @Test
    fun iconsAndTypeLabelsFollowTheName() {
        assertEquals(FilePaths.Icon.DIRECTORY, FilePaths.icon("src.png", directory = true))
        assertEquals(FilePaths.Icon.IMAGE, FilePaths.icon("photo.PNG", directory = false))
        assertEquals(FilePaths.Icon.MARKDOWN, FilePaths.icon("README.md", directory = false))
        assertEquals(FilePaths.Icon.CODE, FilePaths.icon("main.swift", directory = false))
        assertEquals(FilePaths.Icon.CODE, FilePaths.icon("Dockerfile", directory = false))
        assertEquals(FilePaths.Icon.TEXT, FilePaths.icon("LICENSE", directory = false))
        assertEquals(FilePaths.Icon.TEXT, FilePaths.icon("notes.txt", directory = false))
        assertTrue(FilePaths.isDirectory(FileEntry(name = "docs", kind = "directory")))
        assertFalse(FilePaths.isDirectory(FileEntry(name = "docs", kind = "file")))
        assertEquals(FilePaths.Icon.DIRECTORY, FilePaths.icon(FileEntry(name = "photo.png", kind = "directory")), "a listing entry's kind wins over its name")
        assertEquals(FilePaths.Icon.IMAGE, FilePaths.icon(FileEntry(name = "photo.png", kind = "file")))
        assertEquals("Markdown", FilePaths.typeLabel("plan.md", "text/markdown"))
        assertEquals("application/json", FilePaths.typeLabel("data.json", "application/json"))
        assertEquals("Unknown type", FilePaths.typeLabel("blob", ""))
    }

    @Test
    fun theViewDescribesItsOpenDocument() {
        val target = FilesTarget("daemon", "project")
        val view = FilesView(target = target, selectedPath = "docs/README.md", document = FileDocument(path = "docs/README.md", name = "README.md", mime_type = "text/markdown", content = "# Hi"))
        assertEquals(target.documentKey("docs/README.md"), view.documentKey)
        assertEquals(FilePaths.Renderer.MARKDOWN, view.renderer)
        assertEquals("Markdown", view.languageName)
        assertEquals("Markdown", view.typeLabel)
        val empty = FilesView()
        assertEquals("", empty.documentKey)
        assertNull(empty.renderer)
        assertEquals("", empty.languageName)
        assertEquals("", empty.typeLabel)
    }
}
