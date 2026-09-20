package com.dbpprt.dieter.screens

import com.dbpprt.dieter.v1.RemoteDesktopCapabilities
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ScreenLinuxCapabilityTest {
    @Test
    fun portalPermissionIsPromptableAndCursorIsEmbedded() {
        val linux = RemoteDesktopCapabilities.newBuilder()
            .setPlatform("linux")
            .setCapturePermission("not_requested")
            .setControlSupported(true)
            .setControlPermission("not_requested")
            .setCursorSupported(false)
            .build()
        assertTrue(shouldRequestScreenControl(linux))
        assertTrue(shouldEmbedScreenCursor(linux))
        assertEquals("waiting for approval on Linux host", screenConnectionPhase(linux))

        val macBeforePermission = linux.toBuilder().setPlatform("darwin").build()
        assertFalse(shouldRequestScreenControl(macBeforePermission))
        val macGranted = macBeforePermission.toBuilder()
            .setControlPermission("granted")
            .setCursorSupported(true)
            .build()
        assertTrue(shouldRequestScreenControl(macGranted))
        assertFalse(shouldEmbedScreenCursor(macGranted))
        assertEquals("connecting", screenConnectionPhase(macGranted))
    }
}
