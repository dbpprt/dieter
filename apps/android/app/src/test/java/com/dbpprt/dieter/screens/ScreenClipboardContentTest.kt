package com.dbpprt.dieter.screens

import com.dbpprt.dieter.v1.RemoteDesktopClipboardItem
import com.google.protobuf.ByteString
import org.junit.Assert.*
import org.junit.Test

class ScreenClipboardContentTest {
    private fun file(name: String, bytes: ByteArray = byteArrayOf()) = RemoteDesktopClipboardItem.newBuilder()
        .setName(name).setMimeType("application/octet-stream").setData(ByteString.copyFrom(bytes)).build()

    @Test fun binaryAndEmptyFilesKeepTheirBytesAndRejectUnsafeNames() {
        val content = ScreenClipboardContent(items = listOf(file("empty.txt"), file("bytes.bin", byteArrayOf(0,-1,10))))
        content.validate()
        assertArrayEquals(byteArrayOf(0,-1,10), content.items[1].data.toByteArray())
        for (name in listOf("../escape", "/absolute", "..", "a\\b", "nul\u0000name")) {
            assertThrows(IllegalArgumentException::class.java) { ScreenClipboardContent(items = listOf(file(name))).validate() }
        }
        assertThrows(IllegalArgumentException::class.java) { ScreenClipboardContent(items = listOf(file("Readme"),file("README"))).validate() }
        assertThrows(IllegalArgumentException::class.java) { ScreenClipboardContent(text = "paths", items = content.items).validate() }
        assertThrows(IllegalArgumentException::class.java) { ScreenClipboardContent(items = listOf(file("large",ByteArray(ScreenClipboardContent.BINARY_LIMIT+1)))).validate() }
    }
}
