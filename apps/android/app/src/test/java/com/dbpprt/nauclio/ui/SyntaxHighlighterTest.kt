package com.dbpprt.nauclio.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyntaxHighlighterTest {
    @Test
    fun detectsLanguagesFromProjectFileNames() {
        assertEquals(CodeLanguage.GO, codeLanguageForPath("internal/app/app.go"))
        assertEquals(CodeLanguage.TYPESCRIPT, codeLanguageForPath("src/App.tsx"))
        assertEquals(CodeLanguage.KOTLIN, codeLanguageForPath("apps/android/build.gradle.kts"))
        assertEquals(CodeLanguage.PROTOBUF, codeLanguageForPath("api/proto/nauclio.proto"))
        assertEquals(CodeLanguage.MARKDOWN, codeLanguageForPath("README.md"))
        assertEquals(CodeLanguage.SHELL, codeLanguageForPath("Dockerfile"))
    }

    @Test
    fun highlightsGoTokensWithoutTreatingCommentContentAsCode() {
        val source = "package app\n// return is only prose\nfunc Serve(port int) string { return \"ready\" }"
        val ranges = syntaxRanges(source, CodeLanguage.GO)

        assertToken(source, ranges, "package", SyntaxKind.KEYWORD)
        assertToken(source, ranges, "func", SyntaxKind.KEYWORD)
        assertToken(source, ranges, "Serve", SyntaxKind.FUNCTION)
        assertToken(source, ranges, "int", SyntaxKind.TYPE)
        assertToken(source, ranges, "\"ready\"", SyntaxKind.STRING)
        val commentReturn = source.indexOf("return is")
        assertFalse(ranges.any { it.kind == SyntaxKind.KEYWORD && commentReturn in it.start until it.end })
        assertTrue(ranges.any { it.kind == SyntaxKind.COMMENT && commentReturn in it.start until it.end })
    }

    @Test
    fun distinguishesJsonPropertiesValuesAndLiterals() {
        val source = "{\"name\": \"board\", \"enabled\": true, \"retries\": 5}"
        val ranges = syntaxRanges(source, CodeLanguage.JSON)

        assertToken(source, ranges, "\"name\"", SyntaxKind.PROPERTY)
        assertToken(source, ranges, "\"board\"", SyntaxKind.STRING)
        assertToken(source, ranges, "true", SyntaxKind.KEYWORD)
        assertToken(source, ranges, "5", SyntaxKind.NUMBER)
    }

    @Test
    fun highlightsMarkdownAndItsFencedLanguage() {
        val source = "# Nauclio\n\nUse `nauclio serve`.\n\n```go\nfunc main() {}\n```"
        val ranges = syntaxRanges(source, CodeLanguage.MARKDOWN)

        assertToken(source, ranges, "# Nauclio", SyntaxKind.HEADING)
        assertToken(source, ranges, "`nauclio serve`", SyntaxKind.STRING)
        assertToken(source, ranges, "func", SyntaxKind.KEYWORD)
        assertToken(source, ranges, "main", SyntaxKind.FUNCTION)
    }

    @Test
    fun capsHighlightingWorkForLargeFiles() {
        val source = "const before = true\n" + " ".repeat(100) + "const after = false"
        val ranges = syntaxRanges(source, CodeLanguage.TYPESCRIPT, characterLimit = 40)

        assertToken(source, ranges, "const", SyntaxKind.KEYWORD)
        val finalConst = source.lastIndexOf("const")
        assertFalse(ranges.any { finalConst in it.start until it.end })
    }

    private fun assertToken(source: String, ranges: List<SyntaxRange>, token: String, kind: SyntaxKind) {
        val start = source.indexOf(token)
        assertTrue("Missing $kind for $token in $ranges", ranges.any { it.start == start && it.end == start + token.length && it.kind == kind })
    }
}
