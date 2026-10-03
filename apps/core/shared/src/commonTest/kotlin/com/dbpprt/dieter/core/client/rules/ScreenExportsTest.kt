package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.api.v1.RemoteDesktopCodecPreference
import com.dbpprt.dieter.api.v1.RemoteDesktopQuality
import com.dbpprt.dieter.client.v1.ScreenStreamOptions
import com.dbpprt.dieter.client.v1.ScreenToolbarKeys
import com.dbpprt.dieter.core.screens.Modifiers
import com.dbpprt.dieter.core.screens.ScreenPhase
import com.dbpprt.dieter.core.screens.ScreenView
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ScreenExportsTest {
    @Test
    fun toolbarKeysArmTheFourModifiersAndListTheSpecialKeysInOrder() {
        val keys = ScreenToolbarKeys.ADAPTER.decode(ScreenToolbarKeys.ADAPTER.encode(ScreenExports.toolbarKeys()))
        assertEquals(listOf("Ctrl", "Alt", "Shift", "⌘"), keys.modifiers.map { it.label })
        assertEquals(listOf(Modifiers.CONTROL, Modifiers.OPTION, Modifiers.SHIFT, Modifiers.COMMAND), keys.modifiers.map { it.modifier })
        assertEquals(listOf(224, 226, 225, 227), keys.modifiers.map { it.hid })
        assertEquals(listOf("Esc", "Tab", "←", "↑", "↓", "→", "Enter", "Backspace", "Delete", "Home", "End", "PgUp", "PgDn"), keys.special.take(13).map { it.label })
        assertEquals((1..12).map { "F$it" }, keys.special.drop(13).map { it.label })
        assertEquals((58..69).toList(), keys.special.drop(13).map { it.hid })
        assertEquals(41, keys.special.first().hid)
        assertTrue(keys.special.all { it.modifier == 0 }, "special keys arm nothing")
    }

    @Test
    fun streamOptionsNameEveryQualityAndCodecInMenuOrder() {
        val options = ScreenStreamOptions.ADAPTER.decode(ScreenStreamOptions.ADAPTER.encode(ScreenExports.streamOptions()))
        assertEquals(listOf("Automatic quality", "Sharp text", "Responsive motion"), options.qualities.map { it.label })
        assertEquals(
            listOf(RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_AUTO, RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_DETAIL, RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_MOTION),
            options.qualities.map { it.quality },
        )
        assertEquals(listOf("Automatic codec", "H.264 compatibility", "HEVC · up to 1080p60"), options.codecs.map { it.label })
        assertEquals(
            listOf(
                RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_AUTO, RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_H264,
                RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_HEVC,
            ),
            options.codecs.map { it.codec },
        )
        assertEquals("Up to 60 fps", ScreenExports.frameRate(60))
    }

    @Test
    fun theWaitingMessageSaysWhyNoSessionRunsThenWhyTheHostCannotShareThenThePhase() {
        assertEquals("Grant Screen Recording.", ScreenExports.waitingMessage("permission_required", "Grant Screen Recording.", hostReady = false, hostReason = "Off"))
        assertEquals("Connection reset", ScreenExports.waitingMessage("failed", "Connection reset", hostReady = true, hostReason = ""))
        assertEquals("Wayland only", ScreenExports.waitingMessage("unsupported", "", hostReady = false, hostReason = "Wayland only"), "a blank problem falls through")
        assertEquals("Screen sharing is unavailable on this machine.", ScreenExports.waitingMessage("idle", "", hostReady = false, hostReason = ""))
        assertEquals("Not connected", ScreenExports.waitingMessage("idle", "", hostReady = true, hostReason = ""))
        assertEquals("Reconnecting…", ScreenExports.waitingMessage("reconnecting", "ICE failed", hostReady = true, hostReason = ""), "a reconnect is not blocked")
        assertEquals("Waiting for approval on Linux host…", ScreenExports.waitingMessage("waiting_for_host_approval", "", hostReady = true, hostReason = ""))
        assertEquals("Not connected", ScreenExports.waitingMessage("something new", "", hostReady = true, hostReason = ""), "unknown phases are idle")
    }

    @Test
    fun phasesRoundTripThroughTheirWireNames() {
        val phases = listOf(
            ScreenPhase.Idle, ScreenPhase.Loading, ScreenPhase.PermissionRequired("p"), ScreenPhase.Unsupported("u"), ScreenPhase.Connecting,
            ScreenPhase.WaitingForHostApproval, ScreenPhase.Streaming, ScreenPhase.Reconnecting("r"), ScreenPhase.Failed("f"),
        )
        phases.forEach { phase ->
            val problem = phase.problem ?: (phase as? ScreenPhase.Reconnecting)?.reason.orEmpty()
            assertEquals(phase, ScreenPhase.of(phase.wire, problem))
        }
        assertEquals("Release Control", ScreenView(controlActive = true).controlAction)
        assertEquals("Take Control", ScreenView().controlAction)
        assertEquals("Release Control", ScreenExports.controlAction(controlActive = true))
    }
}
