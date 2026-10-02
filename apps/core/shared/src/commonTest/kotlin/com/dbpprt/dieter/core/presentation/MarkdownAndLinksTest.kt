package com.dbpprt.dieter.core.presentation

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class MarkdownAndLinksTest {
    @Test
    fun blankLinesSeparateParagraphsBulletsAndMultiLineFences() {
        val blocks = Markdown.parse(
            """
            ## Summary

            - Durable storage
            - Native Android client

            ```text
            go test ./...
            go vet ./...
            ```
            """.trimIndent(),
        )
        assertEquals(
            listOf(
                MarkdownBlock.Heading(2, "Summary"), MarkdownBlock.Bullet("Durable storage"), MarkdownBlock.Bullet("Native Android client"),
                MarkdownBlock.Code("go test ./...\ngo vet ./...", "text"),
            ),
            blocks,
        )
        assertEquals(listOf(MarkdownBlock.Paragraph("first line\nsecond line"), MarkdownBlock.Paragraph("next")), Markdown.parse("first line\nsecond line\n\nnext"))
        assertEquals(listOf(MarkdownBlock.Paragraph("##### too deep")), Markdown.parse("##### too deep"))
    }

    @Test
    fun blocksFollowEachOtherWithoutBlankLines() {
        val blocks = Markdown.parse("## Title\nparagraph line\n- one\n* two\n```kotlin\nval x = 1\n```\n| a | b | c | d |\n|---|---:|:---:|:---|\n| 1 | 2 | 3 | 4 |\nafter")
        assertEquals(
            listOf(MarkdownBlock.Heading(2, "Title"), MarkdownBlock.Paragraph("paragraph line"), MarkdownBlock.Bullet("one"), MarkdownBlock.Bullet("two"), MarkdownBlock.Code("val x = 1", "kotlin")),
            blocks.take(5),
        )
        val table = assertIs<MarkdownBlock.Table>(blocks[5])
        assertEquals(listOf(TableAlignment.START, TableAlignment.END, TableAlignment.CENTER, TableAlignment.START), table.alignments)
        assertEquals(listOf(listOf("1", "2", "3", "4")), table.rows)
        assertEquals(MarkdownBlock.Paragraph("after"), blocks[6])
        assertEquals(listOf("name", "a|b", "`x|y`"), Markdown.cells("| name | a\\|b | `x|y` |"), "escaped and code-span pipes stay in their cell")
        assertEquals(listOf(MarkdownBlock.Code("open", "")), Markdown.parse("```\nopen"), "an unclosed fence runs to the end")
    }

    @Test
    fun pipeTablesNeedNoSurroundingBlankLines() {
        val blocks = Markdown.parse(
            """
            Snapshot at 21:33 CEST:
            | Node | CPU | GPU | Unified RAM |
            |---|---:|:---:|---|
            | gx10-c674 | ~6% | 96% | 115.7 GiB |
            | gx10-d6c4 | ~10% | 96% | 114.8 GiB |
            Available RAM remains low.
            """.trimIndent(),
        )
        assertEquals(3, blocks.size)
        assertEquals(MarkdownBlock.Paragraph("Snapshot at 21:33 CEST:"), blocks[0])
        val table = assertIs<MarkdownBlock.Table>(blocks[1])
        assertEquals(listOf("Node", "CPU", "GPU", "Unified RAM"), table.header)
        assertEquals(listOf(TableAlignment.START, TableAlignment.END, TableAlignment.CENTER, TableAlignment.START), table.alignments)
        assertEquals(listOf(listOf("gx10-c674", "~6%", "96%", "115.7 GiB"), listOf("gx10-d6c4", "~10%", "96%", "114.8 GiB")), table.rows)
        assertEquals(MarkdownBlock.Paragraph("Available RAM remains low."), blocks[2])

        val ragged = assertIs<MarkdownBlock.Table>(Markdown.parse("| a | b |\n| --- | --- |\n| only |\n| 1 | 2 | 3 |").single())
        assertEquals(listOf(listOf("only", ""), listOf("1", "2")), ragged.rows, "rows are fitted to the header")
        assertEquals(listOf(MarkdownBlock.Paragraph("a | b\n| - | - |")), Markdown.parse("a | b\n| - | - |"), "a delimiter needs three dashes")
    }

    @Test
    fun workspaceImageLinksStayInsideTheWorkspace() {
        val root = "/remote/worktree"
        assertEquals("docs/screenshots/Preview One.PNG", WorkspaceImages.path("./docs/screenshots/Preview%20One.PNG#view"))
        assertEquals("images/result.webp", WorkspaceImages.path("images/result.webp"))
        assertEquals("docs/result.png", WorkspaceImages.path("file:///remote/worktree/docs/result.png", root))
        assertEquals("docs/result.png", WorkspaceImages.path("file://localhost/remote/worktree/docs/result.png", "$root/"))
        assertEquals("docs/Preview One.png", WorkspaceImages.path("</remote/worktree/docs/Preview One.png>", root))
        assertNull(WorkspaceImages.path("/absolute/image.png"), "an absolute path needs the workspace root")
        assertNull(WorkspaceImages.path("/remote/worktree/docs/result.png", "relative/root"))
        assertNull(WorkspaceImages.path("file:///remote/other/image.png", root))
        assertNull(WorkspaceImages.path("/remote/worktree-other/image.png", root), "a sibling sharing the root's prefix is outside")
        assertNull(WorkspaceImages.path("file:///remote/worktree/../secret.png", root))
        assertNull(WorkspaceImages.path("docs/../../secret.png"))
        assertNull(WorkspaceImages.path("ftp://example.com/image.png"))
        assertNull(WorkspaceImages.path("file://otherhost/remote/worktree/image.png", root), "another machine's file is never read")
        assertEquals("C++ notes/diagram+1.png", WorkspaceImages.path("C++%20notes/diagram+1.png"), "a plus in a path stays a plus")
        assertNull(WorkspaceImages.path("README.md"))
        assertEquals("shots/a b.png", WorkspaceImages.path("<shots/a%20b.png>"))
        assertEquals("out/x.png", WorkspaceImages.path("$root/out/x.png", root))
        assertNull(WorkspaceImages.path("https://example.com/x.png"), "a web image is not a workspace file")
    }

    @Test
    fun contentLinksStayInsideTheWorkspace() {
        val root = "/work/repo"
        assertEquals(ContentLink.File("README.md", 4), ContentLinks.resolve("README.md:4", root))
        assertEquals(ContentLink.File("src/App.kt", 10, 20), ContentLinks.resolve("src/App.kt#L10-L20", root))
        assertEquals(ContentLink.File("docs/guide.md"), ContentLinks.resolve("guide.md", root, relativeTo = "docs/index.md"))
        assertEquals(ContentLink.File("a b.txt"), ContentLinks.resolve("file:///work/repo/a%20b.txt", root))
        assertEquals(ContentLink.Web("https://example.com/x"), ContentLinks.resolve("https://example.com/x", null))
        for ((url, error) in listOf(
            "../outside.txt" to LinkError.OUTSIDE_WORKSPACE, "/etc/passwd" to LinkError.OUTSIDE_WORKSPACE,
            "file://other/work/repo/a" to LinkError.UNSUPPORTED_FILE_HOST, "mailto:x@y" to LinkError.UNSUPPORTED_SCHEME,
            "a.txt:0" to LinkError.INVALID_LINE, "https://" to LinkError.INVALID_WEB_URL,
        )) {
            assertEquals(error, assertFailsWith<LinkException> { ContentLinks.resolve(url, root) }.error, url)
        }
        assertEquals(LinkError.INVALID_WORKSPACE, assertFailsWith<LinkException> { ContentLinks.resolve("a.txt", null) }.error)
    }

    @Test
    fun developmentAddressesInProseBecomeWebLinks() {
        val match = DetectedLinks.find("Served at localhost:8080.").single()
        assertEquals("http://localhost:8080", match.url)
        assertEquals(10 until 24, match.range)
        assertEquals(
            listOf("http://[::1]:5173/app", "http://localhost:3000/a_(b)"),
            DetectedLinks.find("Try [::1]:5173/app or (localhost:3000/a_(b)).").map { it.url },
        )
        assertTrue(DetectedLinks.find("host.localhost:3000 and user@localhost:22").isEmpty())
        assertEquals(listOf("http://127.0.0.1:8080"), DetectedLinks.find("Or (127.0.0.1:8080).").map { it.url })
        assertTrue(DetectedLinks.find("src/main.go:12 and 999.1.1.1:80 and localhost:70000").isEmpty())
    }

    // Ported from the macOS ConversationContentLink and ConversationPresentedContent tests.
    private val task = "/remote/worktrees/task"

    @Test
    fun workspaceLinksKeepFileNamesAndLines() {
        for ((url, expected) in listOf(
            "docs/plan.md" to ContentLink.File("docs/plan.md"),
            "./docs/Plan%20draft.md" to ContentLink.File("docs/Plan draft.md"),
            "Sources/Feature.swift#L12" to ContentLink.File("Sources/Feature.swift", 12),
            "Sources/Feature.swift#L12-L14" to ContentLink.File("Sources/Feature.swift", 12, 14),
            "Sources/Feature.swift:12:3" to ContentLink.File("Sources/Feature.swift", 12),
            "README.md:4" to ContentLink.File("README.md", 4),
            "README.md:12?view=1" to ContentLink.File("README.md", 12),
            "Sources/Feature.swift:12#L18" to ContentLink.File("Sources/Feature.swift", 18),
            "docs/plan.md#implementation" to ContentLink.File("docs/plan.md"),
            "docs/part%231.md" to ContentLink.File("docs/part#1.md"),
            "docs/version%3A12" to ContentLink.File("docs/version:12"),
            "C++%20notes/diagram+1.md" to ContentLink.File("C++ notes/diagram+1.md"),
        )) {
            assertEquals(expected, ContentLinks.resolve(url, task), url)
        }
        for (url in listOf("$task/docs/plan.md", "file://$task/docs/plan.md", "file://localhost$task/docs/plan.md")) {
            assertEquals(ContentLink.File("docs/plan.md"), ContentLinks.resolve(url, task), url)
        }
        // Presented paths arrive encoded, with the line as a fragment; an encoded colon stays in the name.
        assertEquals(ContentLink.File("docs/plan #1? 50%.md", 17), ContentLinks.resolve("./docs/plan%20%231%3F%2050%25.md#L17", "/remote/worktree"))
        assertEquals(ContentLink.File("docs/note:12", 17), ContentLinks.resolve("./docs/note%3A12#L17", "/remote/worktree"))
        assertEquals(ContentLink.File("docs/plan #1.md", 17), ContentLinks.resolve("file:/remote/worktree/docs/plan%20%231.md#L17", "/remote/worktree"))
    }

    @Test
    fun relativeLinksResolveAgainstTheCurrentDocument() {
        assertEquals(ContentLink.File("docs/design/plan.md", 9), ContentLinks.resolve("../design/plan.md#L9", task, relativeTo = "docs/notes/overview.md"))
        assertEquals(ContentLink.File("docs/plan.md", 3), ContentLinks.resolve("#L3", task, relativeTo = "$task/docs/plan.md"))
        assertEquals(ContentLink.File("guide.md", 12), ContentLinks.resolve("../guide.md#L12", "/workspace", relativeTo = "docs/plan.md"))
        assertEquals(ContentLink.File("docs/plan.md", 17), ContentLinks.resolve("#L17", "/workspace", relativeTo = "docs/plan.md"))
        assertEquals(ContentLink.File("source.swift", 12), ContentLinks.resolve("../source.swift#L12", "/workspace", relativeTo = "docs/plan.md"))
        assertEquals(LinkError.INVALID_LINK, assertFailsWith<LinkException> { ContentLinks.resolve("#L3", task) }.error, "a fragment needs a current document")
        assertEquals(LinkError.INVALID_LINK, assertFailsWith<LinkException> { ContentLinks.resolve("", task, relativeTo = "docs/plan.md") }.error)
        assertEquals(LinkError.OUTSIDE_WORKSPACE, assertFailsWith<LinkException> { ContentLinks.resolve("plan.md", task, relativeTo = "/other/docs/readme.md") }.error)
    }

    @Test
    fun webLinksNeedAHostButNoWorkspace() {
        val url = "https://example.com/path?q=task%20plan#details"
        assertEquals(ContentLink.Web(url), ContentLinks.resolve(url, ""))
        assertEquals(LinkError.INVALID_WEB_URL, assertFailsWith<LinkException> { ContentLinks.resolve("https:example.com", task) }.error)
        assertEquals(LinkError.INVALID_WEB_URL, assertFailsWith<LinkException> { ContentLinks.resolve("https://user@/x", task) }.error)
        assertEquals(LinkError.INVALID_WORKSPACE, assertFailsWith<LinkException> { ContentLinks.resolve("docs/plan.md", "") }.error)
    }

    @Test
    fun linksCannotLeaveTheWorkspaceOrTheMachine() {
        for (url in listOf(
            "../secret.txt", "docs/../../secret.txt", "%2E%2E/secret.txt", "docs/%2E%2E/%2E%2E/secret.txt",
            "$task-other/secret.txt", "$task/../other/secret.txt", "file:///Users/local/secret.txt",
            "../task/secret.txt",
        )) {
            assertEquals(LinkError.OUTSIDE_WORKSPACE, assertFailsWith<LinkException> { ContentLinks.resolve(url, task) }.error, url)
        }
        for (url in listOf("file://other-host$task/plan.md", "//other-host/plan.md")) {
            assertEquals(LinkError.UNSUPPORTED_FILE_HOST, assertFailsWith<LinkException> { ContentLinks.resolve(url, task) }.error, url)
        }
        for ((url, scheme) in listOf("javascript:alert(1)" to "javascript", "data:text/html,test" to "data", "mailto:user@example.com" to "mailto", "vscode://file/plan.md" to "vscode")) {
            val failure = assertFailsWith<LinkException> { ContentLinks.resolve(url, task) }
            assertEquals(LinkError.UNSUPPORTED_SCHEME, failure.error, url)
            assertEquals(scheme, failure.scheme)
            assertEquals("Links using $scheme: cannot be opened in this pane.", failure.message)
        }
        for (url in listOf(".", "docs/..", "docs/bad%zz.md", "docs/%FF.md", "docs/a%E2%80%8Bb.md", "docs/a%00b.md", "docs\\plan.md")) {
            assertEquals(LinkError.INVALID_LINK, assertFailsWith<LinkException> { ContentLinks.resolve(url, task) }.error, url)
        }
    }

    @Test
    fun lineAndColumnNumbersMustBePositive() {
        for (url in listOf("file.swift:0", "file.swift:12:0", "file.swift#L0", "file.swift#L12-L2", "file.swift:9999999999999999999999")) {
            val failure = assertFailsWith<LinkException> { ContentLinks.resolve(url, task) }
            assertEquals(LinkError.INVALID_LINE, failure.error, url)
            assertEquals("This file link has an invalid line or column number.", failure.message)
        }
    }

    @Test
    fun proseLinksMatchTheMacDetector() {
        // Ported from the macOS ConversationDetectedLinks tests (Markdown parsing stays the platform's).
        assertEquals(
            listOf("http://127.0.0.1:14010", "http://127.0.0.1:4018", "http://localhost:3000/path?q=1", "http://[::1]:8080"),
            DetectedLinks.find("API at 127.0.0.1:14010 and UI at 127.0.0.1:4018. Also localhost:3000/path?q=1 and [::1]:8080.").map { it.url },
        )
        val text = "See (https://example.com/path?q=1). Then localhost:3000."
        val links = DetectedLinks.find(text)
        assertEquals(listOf("https://example.com/path?q=1", "http://localhost:3000"), links.map { it.url })
        assertEquals("https://example.com/path?q=1", text.substring(links[0].range))
        assertEquals("localhost:3000", text.substring(links[1].range))
        for (source in listOf("App.swift:42", "README.md", "example.com/docs", "999.0.0.1:4018", "localhost:99999", "localhost:0", "thing127.0.0.1:4018", "xhttps://example.com")) {
            assertTrue(DetectedLinks.find(source).isEmpty(), source)
        }
    }

    @Test
    fun webLinksTrimPunctuationAndRejectCredentials() {
        assertEquals(listOf("http://localhost:3000/a"), DetectedLinks.find("(see localhost:3000/a.)").map { it.url }, "punctuation and an unbalanced bracket alternate")
        assertEquals(listOf("https://example.com/a_(b)"), DetectedLinks.find("Visit https://example.com/a_(b)) now?").map { it.url })
        assertEquals(listOf("https://example.com"), DetectedLinks.find("Is it https://example.com?").map { it.url })
        assertEquals(listOf("https://[::1]:8443/x"), DetectedLinks.find("Open https://[::1]:8443/x").map { it.url })
        assertTrue(DetectedLinks.find("https://user:secret@example.com/x and https://example.com:0/x and https://example.com:99999").isEmpty())
        val mixed = "Open https://example.com/a or localhost:3000 then HTTPS://Example.com:8443/b"
        assertEquals(listOf("https://example.com/a", "http://localhost:3000", "HTTPS://Example.com:8443/b"), DetectedLinks.find(mixed).map { it.url })
        assertEquals(mixed.indexOf("https://"), DetectedLinks.find(mixed).first().range.first)
    }
}
