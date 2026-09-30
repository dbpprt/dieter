package com.dbpprt.dieter.core.files

import com.dbpprt.dieter.api.v1.FileDocument
import com.dbpprt.dieter.api.v1.FileEntry
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
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
        assertTrue(syntaxRangesInRange(source, CodeLanguage.KOTLIN, source.length - 14, source.length).any { source.substring(it.start, it.end) == "const" })
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
        assertEquals("hé".encodeUtf8(), FilePaths.bytes(FileDocument(content = "hé")))
        val entries = listOf(FileEntry(name = "file10", kind = "file"), FileEntry(name = "file2", kind = "file"), FileEntry(name = "src", kind = "directory"))
        assertEquals(listOf("src", "file2", "file10"), entries.sortedWith(FilePaths.naturalOrder).map { it.name })
        assertEquals("1:a0:1:b0:4:path", FilesTarget("a", "", "b", "").documentKey("path"))
    }
}
