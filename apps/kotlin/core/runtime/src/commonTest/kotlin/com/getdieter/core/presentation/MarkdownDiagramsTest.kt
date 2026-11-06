package com.getdieter.core.presentation

import kotlin.test.*

class MarkdownDiagramsTest {
    @Test
    fun supportedFencesAndAliases() {
        for ((input, kind) in
            listOf(
                " mermaid " to "mermaid",
                "MERMAID title" to "mermaid",
                "vega-lite" to "vega-lite",
                "vegalite" to "vega-lite",
                "vega" to "vega",
            )) assertEquals(kind, MarkdownDiagrams.kind(input))
        for (input in listOf("", "svg", "html", "vega-remote", "javascript")) assertNull(
            MarkdownDiagrams.kind(input)
        )
        val code = Markdown.parse("```vegalite\n{broken}\n```").single() as MarkdownBlock.Code
        assertEquals("vega-lite", MarkdownDiagrams.kind(code.language))
        assertEquals("{broken}", code.text.trim())
    }

    @Test
    fun onlyExactPackagedAssetsAreReadable() {
        for (name in listOf("index.html", "app.js", "app.css")) assertEquals(
            name,
            MarkdownDiagrams.asset(MarkdownDiagrams.ORIGIN + name),
        )
        for (url in
            listOf(
                "file:///etc/passwd",
                "https://example.com/app.js",
                MarkdownDiagrams.ORIGIN + "../app.js",
                MarkdownDiagrams.ORIGIN + "app.js?x=1",
                MarkdownDiagrams.ORIGIN + "app.js#x",
                "https://markdown.dieter.invalid:443/app.js",
                "https://user@markdown.dieter.invalid/app.js",
            )) assertNull(MarkdownDiagrams.asset(url))
    }
}
