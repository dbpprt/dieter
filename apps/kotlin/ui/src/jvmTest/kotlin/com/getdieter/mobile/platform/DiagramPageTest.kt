package com.getdieter.mobile.platform

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DiagramPageTest {
    @Test
    fun diagramShellStartsInTheReaderThemeWithoutChangingTheOfflineHead() {
        val index =
            generateSequence(File(".").absoluteFile) { it.parentFile }
                .map { File(it, "apps/apple/mac/MarkdownPreview/src/index.html") }
                .first { it.isFile }
                .readBytes()
        val original = index.decodeToString()
        for (dark in listOf(false, true)) {
            val page = diagramPage(index, dark).decodeToString()
            assertEquals(
                original.substringAfter("<head>").substringBefore("</head>"),
                page.substringAfter("<head>").substringBefore("</head>"),
                "CSP, asset URLs and script loading remain unchanged",
            )
            assertTrue(page.contains("data-surface=\"diagram\""))
            assertTrue(page.contains("id=\"preview\" data-mode=\"diagram\""))
            assertTrue(page.contains("style=\"background:transparent;color-scheme:normal\""))
            assertTrue(page.contains("<body style=\"margin:0;background:transparent\">"))
            assertTrue(page.contains("data-theme=\"${if (dark) "dark" else "light"}\""))
            assertFalse(page.contains("data-theme=\"${if (dark) "light" else "dark"}\""))
        }
    }
}
