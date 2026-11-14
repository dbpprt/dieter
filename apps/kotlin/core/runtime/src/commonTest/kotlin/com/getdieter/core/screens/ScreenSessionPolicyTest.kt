package com.getdieter.core.screens

import com.getdieter.api.v1.RemoteDesktopAvailability
import com.getdieter.api.v1.RemoteDesktopCapabilities
import com.getdieter.api.v1.RemoteDesktopCodecMode
import com.getdieter.api.v1.RemoteDesktopCodecPreference
import com.getdieter.api.v1.RemoteDesktopICECandidate
import com.getdieter.api.v1.RemoteDesktopQuality
import com.getdieter.api.v1.RemoteDesktopReceiverFeedback
import com.getdieter.api.v1.RemoteDesktopSessionBinding
import com.getdieter.api.v1.RemoteDesktopSessionState
import com.getdieter.api.v1.RemoteDesktopStreamConfiguration
import com.getdieter.api.v1.RemoteDesktopVirtualDisplay
import com.getdieter.api.v1.SetRemoteDesktopVirtualDisplayRequest
import com.getdieter.core.screens.ScreenSessionPolicy.Outcome
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

/** The decisions a screen session makes, without a session: [ScreenSessionPolicy]. */
class ScreenSessionPolicyTest {
    private val hevcHost =
        RemoteDesktopCapabilities(
            codec_modes =
                listOf(
                    RemoteDesktopCodecMode(
                        codec = "H265",
                        profile = "main",
                        max_width = 1920,
                        max_height = 1080,
                        max_fps = 60,
                    )
                )
        )
    private val media =
        ScreenMediaCapabilities(
            receiveCodecs = listOf(RtpCodec("H264", "640c1f"), RtpCodec("H265")),
            hevcDecoder = true,
            referenceDependencies = true,
            millisecondTimestamps = false,
        )
    private val auto =
        ScreenPreferences(codec = RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_AUTO)

    @Test
    fun aHostThatCannotShareIsBlockedByPermissionOrUnsupported() {
        assertEquals(
            ScreenPhase.PermissionRequired("Grant Screen Recording"),
            ScreenSessionPolicy.unavailable(
                RemoteDesktopCapabilities(
                    availability =
                        RemoteDesktopAvailability.REMOTE_DESKTOP_AVAILABILITY_PERMISSION_REQUIRED,
                    unavailable_reason = "Grant Screen Recording",
                )
            ),
        )
        assertEquals(
            ScreenPhase.Unsupported("Screen sharing is unavailable on this machine."),
            ScreenSessionPolicy.unavailable(RemoteDesktopCapabilities()),
        )
    }

    @Test
    fun aLinuxHostGetsTimeForItsUserToApprove() {
        assertEquals(20.seconds, ScreenSessionPolicy.watchdog(RemoteDesktopCapabilities()))
        assertEquals(
            170.seconds,
            ScreenSessionPolicy.watchdog(RemoteDesktopCapabilities(platform = "linux")),
        )
        assertEquals(
            ScreenPhase.WaitingForHostApproval,
            ScreenSessionPolicy.negotiating(
                RemoteDesktopCapabilities(platform = "linux", capture_permission = "not_requested")
            ),
        )
        assertEquals(
            ScreenPhase.Connecting,
            ScreenSessionPolicy.negotiating(RemoteDesktopCapabilities(platform = "macos")),
        )
        val connecting =
            listOf(
                ScreenPhase.Loading,
                ScreenPhase.Connecting,
                ScreenPhase.WaitingForHostApproval,
                ScreenPhase.Reconnecting("x"),
            )
        assertTrue(connecting.all(ScreenSessionPolicy::connecting))
        val settled =
            listOf(
                ScreenPhase.Idle,
                ScreenPhase.Streaming,
                ScreenPhase.Failed("x"),
                ScreenPhase.Unsupported("x"),
                ScreenPhase.PermissionRequired("x"),
            )
        assertTrue(settled.none(ScreenSessionPolicy::connecting))
    }

    @Test
    fun channelsCarryLossyPointerMovesAndClipboardOnlyWhereSupported() {
        val plain = ScreenSessionPolicy.channels(RemoteDesktopCapabilities())
        assertEquals(
            listOf(ScreenChannels.POINTER, ScreenChannels.INPUT, ScreenChannels.SESSION),
            plain.map { it.label },
        )
        assertEquals(ScreenChannelSpec(ScreenChannels.POINTER, false, 0), plain.first())
        assertTrue(plain.drop(1).all { it.ordered && it.maxRetransmits == null })
        assertEquals(
            ScreenChannelSpec(ScreenChannels.CLIPBOARD, ordered = true),
            ScreenSessionPolicy.channels(RemoteDesktopCapabilities(clipboard_supported = true))
                .last(),
        )
    }

    @Test
    fun offersPreferHevcUntilItFailedOrTheModeExceedsTheHost() {
        val offer = ScreenSessionPolicy.offer(media, hevcHost, auto, hevcFailed = false, 120)
        assertEquals(
            RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_AUTO,
            offer.effective,
        )
        assertEquals(listOf("H265", "H264"), offer.codecs.map { it.name })

        val failed = ScreenSessionPolicy.offer(media, hevcHost, auto, hevcFailed = true, 120)
        assertEquals(
            RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_H264,
            failed.effective,
        )
        assertEquals(listOf("H264"), failed.codecs.map { it.name })

        val tooLarge =
            ScreenSessionPolicy.offer(
                media,
                hevcHost,
                auto.copy(width = 3840, height = 2160),
                hevcFailed = false,
                120,
            )
        assertEquals(listOf("H264"), tooLarge.codecs.map { it.name })

        val hevcOnly =
            ScreenSessionPolicy.offer(
                media.copy(hevcDecoder = false),
                hevcHost,
                ScreenPreferences(
                    codec = RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_HEVC
                ),
                hevcFailed = false,
                120,
            )
        assertTrue(hevcOnly.codecs.isEmpty(), "an unmet selection offers nothing")
    }

    @Test
    fun referenceRecoveryNeedsDependenciesAndTheNegotiatedDescriptor() {
        val sdp = "a=extmap:9 ${ScreenSessionPolicy.GENERIC_FRAME_DESCRIPTOR}"
        assertTrue(ScreenSessionPolicy.referenceRecovery(media, sdp))
        assertFalse(ScreenSessionPolicy.referenceRecovery(media, "v=0"))
        assertFalse(
            ScreenSessionPolicy.referenceRecovery(media.copy(referenceDependencies = false), sdp)
        )
    }

    @Test
    fun streamSizesFollowTheViewportOrTheVirtualDisplaysExactPixels() {
        assertEquals(
            2880 to 1800,
            ScreenSessionPolicy.streamSize(
                ScreenPreferences(),
                ViewportPolicy.Desktop,
                1440.0,
                900.0,
                2.0,
            ),
        )
        assertEquals(
            1920 to 1080,
            ScreenSessionPolicy.streamSize(
                ScreenPreferences(),
                ViewportPolicy.Fixed,
                1280.0,
                720.0,
                2.0,
            ),
        )
        val virtual = ScreenPreferences(virtualDisplay = true)
        assertEquals(
            2560 to 1440,
            ScreenSessionPolicy.streamSize(virtual, ViewportPolicy.Fixed, 1280.0, 720.0, 2.0),
        )
        assertEquals(
            1920 to 1080,
            ScreenSessionPolicy.streamSize(
                virtual.copy(
                    codec = RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_HEVC
                ),
                ViewportPolicy.Fixed,
                1280.0,
                720.0,
                2.0,
            ),
            "HEVC keeps a virtual display within 1080p",
        )
        assertNull(
            ScreenSessionPolicy.streamSize(
                ScreenPreferences(),
                ViewportPolicy.Desktop,
                0.0,
                0.0,
                2.0,
            )
        )
    }

    @Test
    fun anHevcStreamBeyond1080p60NeedsANewSession() {
        val hevc = RemoteDesktopSessionState(codec = ScreenCodecs.H265)
        val fullHd = ScreenPreferences()
        assertFalse(ScreenSessionPolicy.needsNewSession(hevc, fullHd, 60))
        assertTrue(ScreenSessionPolicy.needsNewSession(hevc, fullHd, 90))
        assertTrue(ScreenSessionPolicy.needsNewSession(hevc, fullHd.copy(width = 2560), 60))
        assertTrue(ScreenSessionPolicy.needsNewSession(hevc, fullHd.copy(height = 1440), 60))
        assertFalse(
            ScreenSessionPolicy.needsNewSession(
                RemoteDesktopSessionState(codec = ScreenCodecs.H264),
                fullHd,
                120,
            )
        )
        assertFalse(ScreenSessionPolicy.needsNewSession(null, fullHd, 120))
    }

    @Test
    fun theConfigurationTargetsTheVirtualDisplayAtUpTo60Fps() {
        val preferences =
            ScreenPreferences(
                width = 2560,
                height = 1440,
                quality = RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_DETAIL,
            )
        assertEquals(
            RemoteDesktopStreamConfiguration(
                display_id = "primary",
                max_width = 2560,
                max_height = 1440,
                max_fps = 120,
                max_bitrate_kbps = ScreenRequests.MAX_BITRATE_KBPS,
                quality = RemoteDesktopQuality.REMOTE_DESKTOP_QUALITY_DETAIL,
                embedded_cursor = true,
            ),
            ScreenSessionPolicy.configuration(
                preferences,
                RemoteDesktopCapabilities(),
                virtual = null,
                control = false,
                fps = 120,
            ),
        )
        val virtual =
            ScreenSessionPolicy.configuration(
                preferences.copy(displayId = "external"),
                RemoteDesktopCapabilities(cursor_supported = true),
                virtual = RemoteDesktopVirtualDisplay(active = true, display_id = "virtual-1"),
                control = true,
                fps = 120,
            )
        assertEquals("virtual-1", virtual.display_id)
        assertEquals(60, virtual.max_fps)
        assertFalse(virtual.embedded_cursor)
        assertEquals(
            "external",
            ScreenSessionPolicy.configuration(
                    preferences.copy(displayId = "external"),
                    RemoteDesktopCapabilities(),
                    virtual = null,
                    control = false,
                    fps = 60,
                )
                .display_id,
        )
    }

    @Test
    fun aVirtualDisplayIsHeldOnlyUnderControlAndWhereTheHostQualifiesIt() {
        val wanted = ScreenPreferences(virtualDisplay = true, width = 2560, height = 1440)
        val controlling = RemoteDesktopSessionState(control_active = true)
        assertNull(
            ScreenSessionPolicy.virtualDisplay(
                ScreenPreferences(),
                controlling,
                "rd_1",
                supported = true,
                disableSupported = true,
            )
        )
        assertNull(
            ScreenSessionPolicy.virtualDisplay(
                wanted,
                RemoteDesktopSessionState(),
                "rd_1",
                supported = true,
                disableSupported = true,
            )
        )
        assertNull(ScreenSessionPolicy.virtualDisplay(wanted, null, "rd_1", true, true))
        assertEquals(
            SetRemoteDesktopVirtualDisplayRequest(
                session_id = "rd_1",
                pixel_width = 2560,
                pixel_height = 1440,
                scale = 2,
                disable_physical = false,
            ),
            ScreenSessionPolicy.virtualDisplay(wanted, controlling, "rd_1", true, false),
        )
        assertEquals(
            "Experimental virtual displays are unavailable on this host",
            assertFailsWith<IllegalStateException> {
                    ScreenSessionPolicy.virtualDisplay(wanted, controlling, "rd_1", false, true)
                }
                .message,
        )
        assertEquals(
            "Physical display disabling is not qualified on this host",
            assertFailsWith<IllegalStateException> {
                    ScreenSessionPolicy.virtualDisplay(
                        wanted.copy(disablePhysical = true),
                        controlling,
                        "rd_1",
                        supported = true,
                        disableSupported = false,
                    )
                }
                .message,
        )
    }

    @Test
    fun onlyTheHostRestoringUnderANewerGrantDropsTheVirtualDisplay() {
        val virtual =
            RemoteDesktopSessionState(
                control_generation = 3,
                virtual_display = RemoteDesktopVirtualDisplay(active = true, display_id = "v"),
            )
        val restored = RemoteDesktopSessionState(control_generation = 4)
        assertTrue(ScreenSessionPolicy.hostRestoredVirtualDisplay(virtual, restored, false))
        assertFalse(
            ScreenSessionPolicy.hostRestoredVirtualDisplay(virtual, restored, restoring = true),
            "this client's own restore keeps the preference",
        )
        assertFalse(
            ScreenSessionPolicy.hostRestoredVirtualDisplay(
                virtual,
                restored.copy(control_generation = 3),
                false,
            )
        )
        assertFalse(ScreenSessionPolicy.hostRestoredVirtualDisplay(virtual, virtual, false))
        assertFalse(ScreenSessionPolicy.hostRestoredVirtualDisplay(null, restored, false))
    }

    @Test
    fun controlNeedsAPresentedCurrentDisplayOpenChannelsAGrantAndFocus() {
        val state =
            RemoteDesktopSessionState(
                display_generation = 2,
                display_id = "d",
                control_active = true,
            )
        val granted = RemoteDesktopSessionBinding(control_granted = true)
        fun readiness(
            authorized: Boolean = true,
            peerConnected: Boolean = true,
            presented: Long = 2,
            current: RemoteDesktopSessionState? = state,
            binding: RemoteDesktopSessionBinding? = granted,
            displayId: String? = null,
            channels: Boolean = true,
            focused: Boolean = true,
        ) =
            ScreenSessionPolicy.readiness(
                authorized,
                peerConnected,
                presented,
                current,
                binding,
                displayId,
                channels,
                focused,
            )
        val full = ScreenSessionPolicy.Readiness(true, true, true)
        assertEquals(full, readiness())
        assertEquals(full, readiness(displayId = "d"))
        val notReady = ScreenSessionPolicy.Readiness(false, false, true)
        assertEquals(notReady, readiness(authorized = false))
        assertEquals(notReady, readiness(peerConnected = false))
        assertEquals(notReady, readiness(presented = 0))
        assertEquals(notReady, readiness(presented = 1), "an older display's frame")
        assertEquals(notReady, readiness(current = null))
        assertEquals(notReady, readiness(displayId = "other"))
        val viewOnly = ScreenSessionPolicy.Readiness(true, false, true)
        assertEquals(viewOnly, readiness(channels = false))
        assertEquals(viewOnly, readiness(focused = false))
        assertEquals(viewOnly, readiness(current = state.copy(control_active = false)))
        assertEquals(ScreenSessionPolicy.Readiness(true, false, false), readiness(binding = null))
    }

    @Test
    fun inputNeedsThePointerInputAndSessionChannels() {
        val engine = OpenChannels()
        assertFalse(ScreenSessionPolicy.inputChannelsOpen(null))
        engine.open += listOf(ScreenChannels.POINTER, ScreenChannels.INPUT)
        assertFalse(ScreenSessionPolicy.inputChannelsOpen(engine))
        engine.open += ScreenChannels.SESSION
        assertTrue(ScreenSessionPolicy.inputChannelsOpen(engine))
    }

    @Test
    fun failuresRecoverFallBackFromHevcOrEndTheSession() {
        assertEquals(Outcome.HevcFallback, ScreenSessionPolicy.closure("HEVC encoder unavailable"))
        assertEquals(
            Outcome.Recover("daemon shutdown"),
            ScreenSessionPolicy.closure("daemon shutdown"),
        )
        assertEquals(Outcome.Fail("The screen session closed"), ScreenSessionPolicy.closure(""))
        assertEquals(Outcome.Fail("denied"), ScreenSessionPolicy.closure("denied"))

        assertEquals(
            Outcome.HevcFallback,
            ScreenSessionPolicy.hostError("hevc_unavailable", "", false),
        )
        assertEquals(
            Outcome.Recover("The screen session was interrupted"),
            ScreenSessionPolicy.hostError("lease", "", recoverable = true),
        )
        assertEquals(
            Outcome.Recover("peer lost"),
            ScreenSessionPolicy.hostError("peer_failed", "peer lost", false),
        )
        assertEquals(
            Outcome.Recover("daemon shutdown"),
            ScreenSessionPolicy.hostError("capture_failed", "daemon shutdown", false),
        )
        assertEquals(
            Outcome.Fail("The screen session failed"),
            ScreenSessionPolicy.hostError("capture_failed", "", false),
        )
        assertEquals(Outcome.Fail("No"), ScreenSessionPolicy.hostError("denied", "No", false))

        assertTrue(ScreenSessionPolicy.canFallBackFromHevc(auto, hevcFailed = false))
        assertFalse(ScreenSessionPolicy.canFallBackFromHevc(auto, hevcFailed = true))
        assertFalse(
            ScreenSessionPolicy.canFallBackFromHevc(
                ScreenPreferences(
                    codec = RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_HEVC
                ),
                hevcFailed = false,
            ),
            "a chosen HEVC fails instead of silently switching",
        )
    }

    @Test
    fun missingVideoIsRefreshedFirstAndReplacedLater() {
        val watch = ScreenFrameWatch()
        val nothing = ScreenFrameWatch.Tick(refresh = false, replace = false)
        repeat(ScreenSessionPolicy.NO_FRAME_REFRESH_TICKS - 1) {
            assertEquals(nothing, watch.tick(false))
        }
        assertEquals(ScreenFrameWatch.Tick(refresh = true, replace = false), watch.tick(false))
        repeat(ScreenSessionPolicy.NO_FRAME_GIVE_UP_TICKS - 1) {
            assertEquals(nothing, watch.tick(false), "one refresh per stall")
        }
        assertEquals(ScreenFrameWatch.Tick(refresh = false, replace = true), watch.tick(false))

        // Frozen video after frames were shown waits longer before refreshing.
        watch.reset()
        repeat(ScreenSessionPolicy.STALLED_FRAME_REFRESH_TICKS - 1) {
            assertEquals(nothing, watch.tick(true))
        }
        assertEquals(ScreenFrameWatch.Tick(refresh = true, replace = false), watch.tick(true))
        watch.reset()
        assertEquals(nothing, watch.tick(true), "a new frame starts counting again")
    }

    @Test
    fun onlyAConnectedPeerThatShouldPresentIsWatched() {
        val watch = ScreenFrameWatch()
        assertTrue(watch.watching(true, focused = true, presentedAny = true, ScreenPhase.Streaming))
        assertTrue(
            watch.watching(true, focused = false, presentedAny = false, ScreenPhase.Connecting),
            "the first frame is awaited even in the background",
        )
        assertFalse(
            watch.watching(true, focused = false, presentedAny = true, ScreenPhase.Streaming)
        )
        assertFalse(
            watch.watching(false, focused = true, presentedAny = true, ScreenPhase.Streaming)
        )
        assertFalse(
            watch.watching(
                true,
                focused = true,
                presentedAny = false,
                ScreenPhase.WaitingForHostApproval,
            )
        )
    }

    /** An engine that only reports which channels are open. */
    private class OpenChannels : ScreenMediaEngine {
        val open = mutableSetOf<String>()

        override suspend fun createOffer() = ""

        override suspend fun applyAnswer(sdp: String) = Unit

        override suspend fun addRemoteCandidate(candidate: RemoteDesktopICECandidate) = Unit

        override fun send(label: String, bytes: ByteArray) = false

        override fun isOpen(label: String) = label in open

        override fun bufferedAmount(label: String) = 0L

        override suspend fun statistics(): RemoteDesktopReceiverFeedback? = null

        override fun updateFrameGate(
            token: Long,
            displayGeneration: Long,
            mediaGeneration: Long,
            mediaTimestamp: UInt,
        ) = Unit

        override fun resetVideo() = Unit

        override fun close() = Unit
    }
}
