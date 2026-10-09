package com.dbpprt.dieter.core.files

import com.dbpprt.dieter.api.v1.FileDocument
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class HtmlPreviewTest {
    @Test
    fun htmlRendersAsAnEditablePreview() {
        assertEquals(
            FilePaths.Renderer.HTML,
            FilePaths.renderer("exports/Landing page.html", "", false),
        )
        assertEquals(FilePaths.Renderer.HTML, FilePaths.renderer("index.HTM", "", false))
        assertEquals(
            FilePaths.Renderer.HTML,
            FilePaths.renderer("page", "text/html; charset=utf-8", false),
        )
        assertEquals(
            FilePaths.Renderer.UNSUPPORTED,
            FilePaths.renderer("page.html", "", true),
            "a binary is never previewed",
        )
        assertEquals(FilePaths.Renderer.TEXT, FilePaths.renderer("Component.vue", "", false))
        assertTrue(FilePaths.editable(FileDocument(name = "index.html")))
    }

    @Test
    fun previewsLoadOnlyWorkspaceFilesFromTheirOwnOrigin() {
        val document = HtmlPreview.documentUrl("design/Landing page.html")
        assertEquals("dieter-preview://workspace/design/Landing%20page.html", document)
        assertEquals("design/Landing page.html", HtmlPreview.resource(document))
        assertEquals(
            "design/assets/app.css",
            HtmlPreview.resource("dieter-preview://workspace/design/assets/app.css?v=2#top"),
        )
        assertEquals(
            "shared/logo.svg",
            HtmlPreview.resource("dieter-preview://workspace/design/../shared/logo.svg"),
        )
        assertNull(HtmlPreview.resource("dieter-preview://workspace/../outside.css"))
        assertNull(HtmlPreview.resource("dieter-preview://workspace/.git/config"))
        assertNull(HtmlPreview.resource("dieter-preview://workspace/"))
        assertNull(HtmlPreview.resource("dieter-preview://elsewhere/app.css"))
        assertNull(HtmlPreview.resource("https://example.com/app.css"))
        assertNull(HtmlPreview.resource("dieter-preview://workspace/a%5C..%5C..%5Csecret"))
    }

    @Test
    fun resourcesCarryTheirMediaTypeAndNoNetworkAccess() {
        assertEquals("text/css", HtmlPreview.mimeType("app.CSS", "text/plain"))
        assertEquals("text/javascript", HtmlPreview.mimeType("bundle.mjs", ""))
        assertEquals("font/woff2", HtmlPreview.mimeType("fonts/Inter.woff2", ""))
        assertEquals(
            "application/x-custom",
            HtmlPreview.mimeType("data.bin", "application/x-custom; q=1"),
        )
        assertEquals("application/octet-stream", HtmlPreview.mimeType("data.bin", ""))
        val policy = HtmlPreview.CONTENT_SECURITY_POLICY
        assertTrue("connect-src dieter-preview: data: blob:" in policy)
        assertTrue("frame-src 'none'" in policy && "form-action 'none'" in policy)
        assertFalse("http" in policy, "no directive allows the network")
    }
}
