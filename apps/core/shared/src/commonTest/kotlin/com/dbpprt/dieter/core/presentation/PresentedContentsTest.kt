package com.dbpprt.dieter.core.presentation

import com.dbpprt.dieter.api.v1.ContentPresentation
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class PresentedContentsTest {
    @Test
    fun claudeDesignProjectsNeedTheSystemBrowser() {
        assertTrue(BrowserRules.isClaudeDesign("https://claude.ai/design/p/0b7c"))
        assertTrue(BrowserRules.isClaudeDesign("https://claude.ai/design"))
        assertFalse(BrowserRules.isClaudeDesign("https://claude.ai/designer"))
        assertFalse(BrowserRules.isClaudeDesign("http://claude.ai/design/p/1"))
        assertFalse(BrowserRules.isClaudeDesign("https://claude.ai.example.com/design/p/1"))
        assertFalse(BrowserRules.isClaudeDesign("https://user@claude.ai/design/p/1"))
        assertTrue(
            BrowserRules.systemBrowserNotice("https://claude.ai/design/p/1")!!.contains(
                "default browser"
            )
        )
        assertNull(BrowserRules.systemBrowserNotice("https://example.com/design/p/1"))
    }

    @Test
    fun claudeArtifactsAreClaudeDesignPages() {
        for (url in listOf(
            "https://claude.ai/artifact/Y1obmAX2rujH3HrxmxXrBx",
            "https://claude.ai/code/artifact/0b7c4f2e-1d2a-4c55-9a51-4b8c7a0d1e2f",
            "https://www.claude.ai/artifact/abc?v=2#top",
        )) {
            assertTrue(BrowserRules.isClaudeArtifact(url), url)
            assertTrue(BrowserRules.isClaudeDesign(url), url)
            assertTrue(BrowserRules.isClaudeAccountPage(url), url)
            assertTrue(BrowserRules.systemBrowserNotice(url)!!.contains("signed in to claude.ai"), url)
        }
        assertFalse(BrowserRules.isClaudeArtifact("https://claude.ai/artifacts"))
        assertFalse(BrowserRules.isClaudeArtifact("https://claude.ai/code/artifacts"))
        assertFalse(BrowserRules.isClaudeArtifact("https://example.com/artifact/abc"))
        assertFalse(BrowserRules.isClaudeArtifact("https://claude.ai:8443/artifact/abc"))
        assertFalse(BrowserRules.isClaudeDesign("https://claude.ai/new"))
        assertTrue(BrowserRules.isClaudeAccountPage("https://claude.ai/login"))
        assertTrue(BrowserRules.isClaudeAccountPage("https://claude.ai"))
        assertFalse(BrowserRules.isClaudeAccountPage("https://claude.ai.example.com/login"))
        assertFalse(BrowserRules.isClaudeAccountPage("https://user@claude.ai/login"))
        assertFalse(BrowserRules.isClaudeAccountPage("http://claude.ai/login"))
        assertFalse(BrowserRules.isClaudeAccountPage("https://accounts.google.com/"))

        val artifact =
            PresentedContents.view(
                ContentPresentation(id = "a1", url = "https://claude.ai/artifact/Y1obmAX2rujH3HrxmxXrBx")
            )!!
        assertEquals("Claude artifact", artifact.title)
        assertEquals("Claude artifact", artifact.subtitle)
        assertTrue(artifact.claude_design && artifact.system_browser)
    }

    @Test
    fun presentedPagesAndFilesBecomeChips() {
        val design =
            PresentedContents.view(
                ContentPresentation(id = "p1", url = "https://claude.ai/design/p/0b7c")
            )!!
        assertEquals("Claude Design project", design.title)
        assertEquals("claude.ai/design", design.subtitle)
        assertTrue(design.claude_design && design.system_browser)
        assertEquals("https://claude.ai/design/p/0b7c", design.url)

        val page =
            PresentedContents.view(
                ContentPresentation(id = "p2", url = "https://Example.com/docs?a=1", title = "Docs")
            )!!
        assertEquals("Docs", page.title)
        assertEquals("example.com", page.subtitle)
        assertFalse(page.system_browser)

        val file =
            PresentedContents.view(
                ContentPresentation(id = "p3", path = "./reports/summary.md", line = 12)
            )!!
        assertEquals("summary.md", file.title)
        assertEquals("reports/summary.md · line 12", file.subtitle)
        assertEquals("reports/summary.md", file.path)
        assertEquals("", file.url)

        assertNull(PresentedContents.view(null))
        assertNull(
            PresentedContents.view(ContentPresentation(id = "x", url = "javascript:alert(1)"))
        )
        assertNull(
            PresentedContents.view(
                ContentPresentation(id = "x", url = "https://user:pass@example.com")
            )
        )
        assertNull(PresentedContents.view(ContentPresentation(id = "x", path = "../outside.md")))
        assertNull(PresentedContents.view(ContentPresentation(id = "x", path = ".git/config")))
        assertNull(PresentedContents.view(ContentPresentation(id = "x")))
    }
}
