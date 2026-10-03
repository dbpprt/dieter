package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.client.v1.ContentFileLink
import com.dbpprt.dieter.client.v1.ContentLinkFailure
import com.dbpprt.dieter.client.v1.ContentLinkResolution
import com.dbpprt.dieter.client.v1.DetectedLink
import com.dbpprt.dieter.client.v1.DetectedLinks
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class LinkExportsTest {
    private val root = "/remote/worktrees/task"

    private fun resolve(url: String, relativeTo: String = "", workspaceRoot: String = root): ContentLinkResolution =
        ContentLinkResolution.ADAPTER.decode(ContentLinkResolution.ADAPTER.encode(LinkExports.resolveContentLink(url, workspaceRoot, relativeTo)))

    @Test
    fun resolutionsCarryFilesWebURLsOrAWordedFailure() {
        assertEquals(ContentFileLink(path = "Sources/Feature.swift", line = 12), resolve("Sources/Feature.swift:12:3").file_)
        assertEquals(ContentFileLink(path = "src/App.kt", line = 10), resolve("src/App.kt#L10-L20").file_)
        assertEquals(ContentFileLink(path = "docs/plan.md", line = 3), resolve("#L3", relativeTo = "docs/plan.md").file_)
        assertEquals(ContentFileLink(path = "docs/note:12", line = 17), resolve("./docs/note%3A12#L17").file_)
        val web = "https://example.com/path?q=task%20plan#details"
        assertEquals(web, resolve(web, workspaceRoot = "").web_url)

        val scheme = resolve("mailto:user@example.com").failure
        assertEquals(ContentLinkFailure(kind = ContentLinkFailure.Kind.KIND_UNSUPPORTED_SCHEME, message = "Links using mailto: cannot be opened in this pane.", scheme = "mailto"), scheme)
        for ((url, kind, message) in listOf(
            Triple("../secret.txt", ContentLinkFailure.Kind.KIND_OUTSIDE_WORKSPACE, "This file is outside the conversation's workspace."),
            Triple("file://other-host/plan.md", ContentLinkFailure.Kind.KIND_UNSUPPORTED_FILE_HOST, "This file link points to a different machine."),
            Triple("file.swift:0", ContentLinkFailure.Kind.KIND_INVALID_LINE, "This file link has an invalid line or column number."),
            Triple("https:example.com", ContentLinkFailure.Kind.KIND_INVALID_WEB_URL, "This web link is missing a hostname."),
            Triple(".", ContentLinkFailure.Kind.KIND_INVALID_LINK, "This link does not identify a workspace file."),
        )) {
            assertEquals(ContentLinkFailure(kind = kind, message = message), resolve(url).failure, url)
        }
        assertEquals(
            ContentLinkFailure(kind = ContentLinkFailure.Kind.KIND_INVALID_WORKSPACE, message = "The conversation's workspace path is unavailable."),
            resolve("docs/plan.md", workspaceRoot = "").failure,
        )
    }

    @Test
    fun detectedLinksAreUtf16Ranges() {
        val text = "💡 API at 127.0.0.1:4018 and https://example.com/docs."
        val start = text.indexOf("127")
        val web = text.indexOf("https")
        assertEquals(
            DetectedLinks(
                links = listOf(
                    DetectedLink(start = start, length = "127.0.0.1:4018".length, url = "http://127.0.0.1:4018"),
                    DetectedLink(start = web, length = "https://example.com/docs".length, url = "https://example.com/docs"),
                ),
            ),
            DetectedLinks.ADAPTER.decode(DetectedLinks.ADAPTER.encode(LinkExports.detectLinks(text))),
        )
        assertEquals(10, start, "the emoji counts two UTF-16 units")
    }

    @Test
    fun externalBrowserRulesMatchOnlyExplicitHostsAndPathSegments() {
        // Ported from the macOS ExternalBrowserRules tests.
        val rules = listOf("github.com", "*.signin.aws.amazon.com", "https://example.com/login")
        assertTrue(LinkExports.externalBrowserRuleMatches("https://github.com/org/repo", rules))
        assertTrue(LinkExports.externalBrowserRuleMatches("https://us.signin.aws.amazon.com/", rules))
        assertTrue(LinkExports.externalBrowserRuleMatches("https://signin.aws.amazon.com", rules))
        assertTrue(LinkExports.externalBrowserRuleMatches("https://example.com/login/callback", rules))
        assertTrue(LinkExports.externalBrowserRuleMatches("https://EXAMPLE.com/login/", rules), "hosts compare lowercased and a trailing slash is ignored")
        assertFalse(LinkExports.externalBrowserRuleMatches("https://evilgithub.com/login", rules))
        assertFalse(LinkExports.externalBrowserRuleMatches("https://example.com/login-not", rules))
        assertFalse(LinkExports.externalBrowserRuleMatches("http://example.com/login", rules), "a URL rule keeps its scheme")
        assertFalse(LinkExports.externalBrowserRuleMatches("https://example.com:8443/login", rules), "a URL rule keeps its port")
        assertFalse(LinkExports.externalBrowserRuleMatches("file:///github.com", rules))
        assertTrue(LinkExports.externalBrowserRuleMatches("https://example.com/anything", listOf("  HTTPS://Example.com  ")), "a rule without a path matches every path")
    }

    @Test
    fun externalBrowserRulesRejectAmbiguousOrCredentialedInput() {
        assertEquals("github.com", LinkExports.normalizeExternalBrowserRule("github.com"))
        assertEquals("github.com", LinkExports.normalizeExternalBrowserRule("  GitHub.COM "))
        assertEquals("*.signin.aws.amazon.com", LinkExports.normalizeExternalBrowserRule("*.signin.aws.amazon.com"))
        assertEquals("https://example.com/login", LinkExports.normalizeExternalBrowserRule("https://example.com/login"))
        for (input in listOf(
            "https://user:secret@example.com", "https://example.com/login?token=secret", "https://example.com/#top",
            "github.com/path", "localhost", "ftp://example.com", ".example.com", "exa mple.com", "", "a.".repeat(300),
        )) {
            assertEquals("", LinkExports.normalizeExternalBrowserRule(input), input)
        }
    }

    @Test
    fun browserLoopbackCoversEveryFormOfThisMachine() {
        // Ported from the macOS browser loopback test; broader than the gateway's literal-only rule.
        for (host in listOf("localhost", "app.localhost", "localhost.", "127.0.0.1", "127.1", "2130706433", "0x7f.1", "[::1]", "::1", "[::ffff:127.0.0.1]", "0.0.0.0", "::")) {
            assertTrue(LinkExports.isLoopbackBrowserHost(host), host)
        }
        for (host in listOf("example.com", "10.0.0.1", "128.0.0.1", "[::2]", "localhost.example.com", "127.0.0.1.example.com", "")) {
            assertFalse(LinkExports.isLoopbackBrowserHost(host), host)
        }
    }

    @Test
    fun workspaceImagesAreRecognizedAndResolvedInsideTheWorkspace() {
        assertTrue(LinkExports.isWorkspaceImage("file:///remote/worktrees/task/docs/result.png"))
        assertTrue(LinkExports.isWorkspaceImage("<shots/a%20b.PNG>"))
        assertFalse(LinkExports.isWorkspaceImage("https://example.com/result.png"))
        assertFalse(LinkExports.isWorkspaceImage("notes/plan.md"))
        assertEquals("docs/result.png", LinkExports.workspaceImagePath("file:///remote/worktrees/task/docs/result.png", root))
        assertEquals("shots/a b.PNG", LinkExports.workspaceImagePath("<shots/a%20b.PNG>", ""))
        assertEquals("", LinkExports.workspaceImagePath("/remote/worktrees/task/docs/result.png", ""), "an absolute link needs the workspace root")
        assertEquals("", LinkExports.workspaceImagePath("file:///remote/elsewhere/result.png", root))
        assertEquals("", LinkExports.workspaceImagePath("../secret.png", root))
    }
}
