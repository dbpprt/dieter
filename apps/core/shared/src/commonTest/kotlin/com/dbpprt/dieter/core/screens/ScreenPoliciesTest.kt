package com.dbpprt.dieter.core.screens

import com.dbpprt.dieter.api.v1.RemoteDesktopCapabilities
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardItem
import com.dbpprt.dieter.api.v1.RemoteDesktopCodecMode
import com.dbpprt.dieter.api.v1.RemoteDesktopCodecPreference
import com.dbpprt.dieter.api.v1.RemoteDesktopCursor
import com.dbpprt.dieter.api.v1.RemoteDesktopPointerButton
import com.dbpprt.dieter.api.v1.RemoteDesktopReference
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionBinding
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionState
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import okio.ByteString
import okio.ByteString.Companion.decodeBase64
import okio.ByteString.Companion.encodeUtf8
import okio.ByteString.Companion.toByteString

class ScreenPoliciesTest {
    private val t0 = Instant.fromEpochSeconds(1_800_000_000)
    private val epoch = ByteArray(16) { 7 }.toByteString()

    @Test
    fun softKeyboardReturnAndTabsBecomeKeysWithoutSplittingUnicodeText() {
        assertEquals(listOf(Typed.Key(40)), ScreenKeyboard.committed("\n", 0))
        assertEquals(listOf(Typed.Text("é世界🙂"), Typed.Key(40), Typed.Text("next"), Typed.Key(43), Typed.Key(40)),
            ScreenKeyboard.committed("é世界🙂\r\nnext\t\r", 0))
        assertEquals(listOf(Typed.Key(4), Typed.Key(40)), ScreenKeyboard.committed("a\n", Modifiers.CONTROL))
        assertEquals(emptyList(), ScreenKeyboard.committed("", 0))
        assertEquals(40, AndroidKeys.hid(66))
        assertEquals(88, AndroidKeys.hid(160))
    }

    @Test
    fun trustMessageMatchesTheDaemonGolden() {
        val binding = RemoteDesktopSessionBinding(
            client_nonce = "nonce", helper_dtls_fingerprint = "sha-256 AA:BB", expires_at = "2026-08-25T08:00:00Z",
            offer_sha256 = byteArrayOf(0, 1, 2).toByteString(), control_granted = true, display_id = "primary",
            input_protocol_version = 3, input_epoch = epoch,
        )
        assertEquals(
            "dieter-remote-desktop-v3\nrd_one\nnonce\nsha-256 AA:BB\n2026-08-25T08:00:00Z\nAAEC\ntrue\nprimary\n3\nBwcHBwcHBwcHBwcHBwcHBw",
            ScreenTrust.message("rd_one", binding).utf8(),
        )
    }

    @Test
    fun publicKeyIsReadFromTheCertificatesSubjectKey() {
        val key = ByteArray(32) { it.toByte() }
        val spki = byteArrayOf(0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00) + key
        val pem = "-----BEGIN CERTIFICATE-----\n${(byteArrayOf(1, 2, 3) + spki + byteArrayOf(9)).toByteString().base64()}\n-----END CERTIFICATE-----\n"
        assertEquals(key.toByteString(), ScreenTrust.ed25519PublicKey(pem))
        assertNull(ScreenTrust.ed25519PublicKey("-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----"))
    }

    @Test
    fun recoveryBacksOffToFiveSecondsAndResetsAfterStableStreaming() {
        val recovery = ScreenRecovery()
        val delays = (0 until 7).map { recovery.nextDelay(t0).inWholeMilliseconds }
        assertEquals(listOf(250L, 500L, 1000L, 2000L, 4000L, 5000L, 5000L), delays)
        recovery.streaming(t0)
        recovery.interrupted(t0 + 5.seconds)
        assertEquals(5000L, recovery.nextDelay(t0 + 5.seconds).inWholeMilliseconds, "a short stream keeps the backoff")
        recovery.streaming(t0 + 6.seconds)
        assertEquals(250L, recovery.nextDelay(t0 + 17.seconds).inWholeMilliseconds, "ten stable seconds reset it")
    }

    @Test
    fun failuresSeparateRetryableFromFatal() {
        assertTrue(ScreenFailures.retryable(GrpcException(GrpcStatus.UNAVAILABLE, "down")))
        assertTrue(ScreenFailures.retryable(GrpcException(GrpcStatus.NOT_FOUND, "expired")))
        assertFalse(ScreenFailures.retryable(GrpcException(GrpcStatus.PERMISSION_DENIED, "no")))
        assertFalse(ScreenFailures.retryable(ScreenTrustException("forged")))
        assertTrue(ScreenFailures.retryableClosure("session lease expired"))
        assertFalse(ScreenFailures.retryableClosure("closed by host"))
        assertTrue(ScreenFailures.retryableError("peer_failed", "", recoverable = false))
        assertTrue(ScreenFailures.retryableError("capture_failed", "native capture helper stopped", recoverable = false))
        assertFalse(ScreenFailures.retryableError("capture_failed", "permission denied", recoverable = false))
    }

    @Test
    fun capabilitiesDecideControlCursorAndFrameRates() {
        val mac = RemoteDesktopCapabilities(platform = "darwin", control_supported = true, control_permission = "granted", cursor_supported = true, max_fps = 120)
        val linux = RemoteDesktopCapabilities(platform = "linux", control_supported = true, control_permission = "not_requested", capture_permission = "not_requested", max_fps = 0)
        assertTrue(ScreenCapabilities.shouldRequestControl(mac))
        assertTrue(ScreenCapabilities.shouldRequestControl(linux))
        assertFalse(ScreenCapabilities.shouldRequestControl(mac.copy(control_permission = "denied")))
        assertEquals("Accessibility permission is required on the host", ScreenCapabilities.controlUnavailableReason(mac.copy(control_permission = "denied")))
        assertTrue(ScreenCapabilities.needsHostApproval(linux))
        assertFalse(ScreenCapabilities.needsHostApproval(mac))
        assertFalse(ScreenCapabilities.embedCursor(mac, control = true))
        assertFalse(ScreenCapabilities.embedCursor(linux, control = true))
        assertTrue(ScreenCapabilities.embedCursor(linux, control = false))
        assertEquals(listOf(30, 60, 90, 120), ScreenCapabilities.frameRates(mac))
        assertEquals(listOf(30, 60), ScreenCapabilities.frameRates(linux), "an unknown host maximum means 60")
        assertEquals(60, ScreenCapabilities.maxFps(120, mac, ceiling = 60))
    }

    @Test
    fun codecsPreferHardwareHevcAndFallBackToH264() {
        val codecs = listOf(RtpCodec("H264", "42e01f"), RtpCodec("VP8"), RtpCodec("H265"), RtpCodec("H264", "640c1f"), RtpCodec("flexfec-03"))
        val caps = RemoteDesktopCapabilities(codec_modes = listOf(RemoteDesktopCodecMode(codec = "H265", profile = "main", max_width = 1920, max_height = 1080, max_fps = 60)))
        assertTrue(ScreenCodecs.canHevc(caps, 1920, 1080, 60, hardwareDecoder = true))
        assertFalse(ScreenCodecs.canHevc(caps, 3840, 2160, 60, hardwareDecoder = true))
        assertFalse(ScreenCodecs.canHevc(caps, 1920, 1080, 60, hardwareDecoder = false))
        val auto = ScreenCodecs.receiveCodecs(codecs, RtpCodec::name, RtpCodec::profile, RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_AUTO, canHevc = true)
        assertEquals(listOf("H265", "H264:640c1f", "H264:42e01f", "flexfec-03"), auto.map { listOfNotNull(it.name, it.profile).joinToString(":") })
        val h264 = ScreenCodecs.receiveCodecs(codecs, RtpCodec::name, RtpCodec::profile, RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_H264, canHevc = true)
        assertTrue(h264.none { it.name == "H265" })
        assertTrue(ScreenCodecs.receiveCodecs(codecs.filter { it.name != "H265" }, RtpCodec::name, RtpCodec::profile, RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_HEVC, true).isEmpty())
        assertEquals(RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_H264, ScreenCodecs.effective(RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_AUTO, hevcFailed = true))
        assertEquals(RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_HEVC, ScreenCodecs.effective(RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_HEVC, hevcFailed = true))
    }

    @Test
    fun viewportsFollowEachPlatformsGrid() {
        assertEquals(2880 to 1800, ViewportPolicy.Desktop.size(1440.0, 900.0, 2.0))
        assertEquals(640 to 360, ViewportPolicy.Desktop.size(100.0, 100.0, 1.0))
        assertEquals(1920 to 1080, ViewportPolicy.Tablet.size(1194.0, 834.0, 2.0))
        assertEquals(1120 to 450, ViewportPolicy.Tablet.size(1024.0, 400.0, 1.0))
        assertNull(ViewportPolicy.Tablet.size(0.0, 400.0, 1.0))
        assertEquals(1920 to 1080, ViewportPolicy.Fixed.size(1.0, 1.0, 1.0))
    }

    @Test
    fun stateMergeIsMonotonicPerGeneration() {
        val first = RemoteDesktopSessionState(display_generation = 2, media_generation = 3, media_timestamp = 900, control_generation = 4, control_active = true, clipboard_generation = 1)
        assertNull(ScreenStates.merge(first, first.copy(display_generation = 1)), "an older display is dropped")
        val staleMedia = ScreenStates.merge(first, first.copy(media_generation = 2, media_timestamp = 5, control_generation = 3, control_active = false))!!
        assertEquals(3, staleMedia.state.media_generation)
        assertEquals(900, staleMedia.state.media_timestamp)
        assertTrue(staleMedia.state.control_active, "older control state never regresses")
        assertFalse(staleMedia.displayChanged)
        val newDisplay = ScreenStates.merge(first, first.copy(display_generation = 3, media_generation = 1, clipboard_generation = 2))!!
        assertTrue(newDisplay.displayChanged)
        assertTrue(newDisplay.clipboardChanged)
        assertEquals(1, newDisplay.state.media_generation, "a new display restarts media generations")
    }

    @Test
    fun presentedFramesBelongToTheirGenerationAcrossWrap() {
        assertTrue(ScreenStates.belongsToGeneration(1000u, 900u, millisecondQuantized = false))
        assertFalse(ScreenStates.belongsToGeneration(800u, 900u, millisecondQuantized = false))
        assertTrue(ScreenStates.belongsToGeneration(10u, UInt.MAX_VALUE - 5u, millisecondQuantized = false), "the 90 kHz clock wraps")
        assertTrue(ScreenStates.belongsToGeneration(900u, 950u, millisecondQuantized = true), "Android timestamps are quantized to milliseconds")
        assertFalse(ScreenStates.belongsToGeneration(810u, 950u, millisecondQuantized = true))
    }

    @Test
    fun startRequestCarriesPreferencesAndProtocol() {
        val caps = RemoteDesktopCapabilities(platform = "darwin", control_supported = true, control_permission = "granted", clipboard_supported = true, max_fps = 60)
        val request = ScreenRequests.start(
            "n", com.dbpprt.dieter.api.gateway.v1.RTCConfiguration(), "v=0", caps, ScreenPreferences(maxFps = 120, displayId = "external"),
            RemoteDesktopCodecPreference.REMOTE_DESKTOP_CODEC_PREFERENCE_H264, "x".repeat(100), referenceRecovery = true,
        )
        assertEquals("offer", request.offer?.type)
        assertEquals("external", request.display_id)
        assertEquals(60, request.max_fps)
        assertEquals(64, request.client_name.length)
        assertEquals(SCREEN_INPUT_PROTOCOL, request.input_protocol_version)
        assertTrue(request.control && request.clipboard && request.reference_recovery)
    }

    @Test
    fun inputEnvelopesOrderReliableAndPointerEvents() {
        val encoder = ScreenInputEncoder(epoch)
        val move = encoder.move(0.5, 2.0, 3, 4)
        assertEquals(1, move.sequence)
        assertEquals(0, move.state_barrier)
        assertEquals(500_000, move.pointer_move?.normalized_x)
        assertEquals(1_000_000, move.pointer_move?.normalized_y, "coordinates clamp to the screen")
        val down = encoder.button(RemoteDesktopPointerButton.Button.BUTTON_LEFT, true, 5, 0.1, 0.1, 0xFF, 3, 4)
        assertEquals(1, down.sequence)
        assertEquals(1, down.state_barrier)
        assertEquals(3, down.pointer_button?.click_count, "clicks cap at three")
        assertEquals(0x3F, down.pointer_button?.modifiers)
        assertEquals(1, encoder.move(0.2, 0.2, 3, 4).state_barrier, "pointer moves follow the reliable input before them")
        assertEquals(down.event_ordinal + 1, encoder.lastPointerOrdinal)
        assertNull(encoder.key(3, true, false, 0, 3, 4), "HID usages below 4 are not keys")
        assertNotNull(encoder.releaseAll(3, 4).release_all)
        assertEquals(2, encoder.stateBarrier, "rejected keys do not advance the barrier")
    }

    @Test
    fun textChunksKeepSurrogatePairsAndLimitSize() {
        val emoji = "😀"
        val text = "a".repeat(511) + emoji + "b"
        val chunks = ScreenInputEncoder.textChunks(text)!!
        assertEquals(listOf(511, 3), chunks.map { it.length })
        assertEquals(text, chunks.joinToString(""))
        assertNull(ScreenInputEncoder.textChunks("x".repeat(8193)))
        assertEquals(4 to false, ScreenInputEncoder.stroke("a"))
        assertEquals(4 to true, ScreenInputEncoder.stroke("A"))
        assertEquals(39 to false, ScreenInputEncoder.stroke("0"))
        assertEquals(31 to true, ScreenInputEncoder.stroke("@"))
        assertNull(ScreenInputEncoder.stroke("é"))
        assertEquals("copy", ScreenInputEncoder.clipboardShortcut(6, Modifiers.COMMAND))
        assertEquals("paste", ScreenInputEncoder.clipboardShortcut(25, Modifiers.COMMAND or Modifiers.FUNCTION))
        assertNull(ScreenInputEncoder.clipboardShortcut(6, Modifiers.COMMAND or Modifiers.SHIFT))
    }

    @Test
    fun feedbackRenewsWithMeasurementsAndInputActivity() {
        val feedback = ScreenFeedback(epoch)
        feedback.start(t0)
        feedback.input(true, t0)
        val first = feedback.next(t0 + 200.milliseconds)
        assertEquals(1, first.sequence)
        assertEquals(1, first.measurement_sequence)
        assertEquals(200, first.measurement_age_ms)
        assertTrue(first.input_active)
        assertFalse(feedback.next(t0 + 1.seconds).input_active, "input goes stale after one second")
        feedback.acknowledge((1..10).map { RemoteDesktopReference(frame_id = it.toLong(), generation = 1) })
        assertEquals((3L..10L).toList(), feedback.next(t0).decoded_references.map { it.frame_id })
    }

    @Test
    fun referencesAckOnlyDecodedFramesWithinTheWindow() {
        val references = ScreenReferences(millisecondQuantized = false)
        val reference = RemoteDesktopReference(frame_id = 1, generation = 1, rtp_timestamp = 9000)
        assertEquals(emptyList(), references.expect(reference, t0))
        assertEquals(listOf(reference), references.decoded(9000u, t0 + 100.milliseconds))
        assertEquals(emptyList(), references.expect(reference.copy(frame_id = 2, rtp_timestamp = 18000), t0))
        assertEquals(emptyList(), references.decoded(18000u, t0 + 3.seconds), "late decodes are not acknowledged")
        assertEquals(emptyList(), references.expect(reference.copy(generation = 0), t0))
        val quantized = ScreenReferences(millisecondQuantized = true)
        quantized.decoded(9045u, t0)
        assertEquals(1, quantized.expect(reference, t0).size)
    }

    @Test
    fun referencesAckInEitherOrderAcrossTheRtpWrapAndStopWithThePeer() {
        val references = ScreenReferences(millisecondQuantized = false)
        fun reference(id: Long, timestamp: UInt, generation: Long = 1) =
            RemoteDesktopReference(frame_id = id, generation = generation, rtp_timestamp = timestamp.toInt())
        assertEquals(emptyList(), references.expect(reference(1, 90_025u), t0))
        assertEquals(emptyList(), references.decoded(90_024u, t0), "a neighbouring timestamp is not the frame")
        assertEquals(listOf(1L), references.decoded(90_025u, t0).map { it.frame_id })
        references.decoded(UInt.MAX_VALUE, t0)
        assertEquals(listOf(2L), references.expect(reference(2, UInt.MAX_VALUE), t0).map { it.frame_id }, "the decode came first")
        val later = t0 + 2001.milliseconds
        assertEquals(emptyList(), references.expect(reference(3, 90_025u), later), "decodes expire after two seconds")
        references.stop()
        references.decoded(90_025u, later)
        assertEquals(emptyList(), references.expect(reference(4, 90_025u), later), "a stopped peer acknowledges nothing")
    }

    @Test
    fun referenceChallengesAreBoundedAndScopedToTheNewestGeneration() {
        val references = ScreenReferences(millisecondQuantized = false)
        fun reference(id: Long, timestamp: UInt, generation: Long = 1) =
            RemoteDesktopReference(frame_id = id, generation = generation, rtp_timestamp = timestamp.toInt())
        references.expect(reference(1, 90u), t0)
        val later = t0 + 2001.milliseconds
        assertEquals(emptyList(), references.decoded(90u, later), "an expired challenge is not answered")
        for (id in 2..10) references.expect(reference(id.toLong(), (id * 90).toUInt(), generation = 2), later)
        assertEquals(emptyList(), references.decoded(180u, later), "at most eight challenges are pending")
        assertEquals(emptyList(), references.expect(reference(11, 180u, generation = 1), later), "an older generation is ignored")
        assertEquals(listOf(10L), references.decoded(900u, later).map { it.frame_id })
        references.expect(reference(12, 270u, generation = 3), later)
        assertEquals(listOf(12L), references.decoded(270u, later).map { it.frame_id }, "a newer generation drops the older challenges")
    }

    @Test
    fun clipboardFramesRoundTripAndRejectForeignOperations() {
        val payload = ByteArray(40_000) { (it % 251).toByte() }.toByteString()
        val frames = ClipboardFraming.frames("op", payload)
        assertEquals(3, frames.size)
        assertEquals(listOf(false, false, true), frames.map { it.end })
        val assembler = ClipboardFraming.Assembler("op")
        val results = frames.map { assembler.accept(it.encodeByteString()) }
        assertEquals(listOf(null, null, payload), results)
        assertEquals(1, ClipboardFraming.frames("op", ByteString.EMPTY).size)
        assertFailsWith<IllegalStateException> { ClipboardFraming.Assembler("other").accept(frames[0].encodeByteString()) }
    }

    @Test
    fun clipboardContentRulesMatchTheDaemon() {
        fun file(name: String, bytes: Int = 1) = RemoteDesktopClipboardItem(kind = RemoteDesktopClipboardItem.Kind.FILE, name = name, data_ = ByteArray(bytes).toByteString())
        assertNull(ClipboardContent.validate("hello", emptyList()))
        assertNull(ClipboardContent.validate("", listOf(file("a.txt"), file("b.txt"))))
        assertEquals("Invalid clipboard file or image", ClipboardContent.validate("", listOf(file("A.txt"), file("a.TXT"))))
        assertEquals("Invalid clipboard file or image", ClipboardContent.validate("", listOf(file("../x"))))
        assertEquals("Invalid clipboard file or image", ClipboardContent.validate("text", listOf(file("a"))))
        assertEquals("Clipboard limit: 1 MiB text or 8 MiB across 64 files", ClipboardContent.validate("", listOf(file("big", 8 * 1024 * 1024 + 1))))
        val image = RemoteDesktopClipboardItem(kind = RemoteDesktopClipboardItem.Kind.IMAGE, name = "i.png", mime_type = "image/png", data_ = "png".encodeUtf8())
        assertNull(ClipboardContent.validate("", listOf(image)))
        assertEquals("Invalid clipboard file or image", ClipboardContent.validate("", listOf(image, file("b"))))
    }

    @Test
    fun cursorShapesAreCachedPerId() {
        val cache = CursorCache()
        val png = "png".encodeUtf8()
        assertEquals(png, cache.accept(RemoteDesktopCursor(shape_id = "arrow", png = png, width = 16.0, height = 16.0)))
        assertEquals(png, cache.accept(RemoteDesktopCursor(shape_id = "arrow")), "later updates reuse the cached image")
        assertNull(cache.accept(RemoteDesktopCursor(shape_id = "beam")))
        assertNull(cache.accept(RemoteDesktopCursor(shape_id = "huge", png = png, width = 512.0, height = 16.0)))
        assertTrue(CursorCache.adoptHostPosition(false, false, false, 5, 5, 200.milliseconds))
        assertFalse(CursorCache.adoptHostPosition(false, false, false, 4, 5, 200.milliseconds), "the host has not seen the latest move")
        assertFalse(CursorCache.adoptHostPosition(false, true, false, 5, 5, 200.milliseconds))
        assertTrue(CursorCache.adoptHostPosition(true, true, true, 0, 5, 0.milliseconds))
    }

    @Test
    fun trackpadTapsDragsAndScrolls() {
        val events = mutableListOf<String>()
        val trackpad = TouchTrackpad(slop = 8.0, doubleTapSlop = 20.0, actions = object : TrackpadActions {
            override fun move(delta: Point) { events += "move ${delta.x.toInt()},${delta.y.toInt()}" }
            override fun button(down: Boolean, clicks: Int) { events += "button ${if (down) "down" else "up"} $clicks" }
            override fun clicked() { events += "clicked" }
            override fun scroll(delta: Point, phase: Int) { events += "scroll ${delta.y.toInt()} $phase" }
            override fun transform(factor: Double, oldCenter: Point, newCenter: Point) { events += "zoom $factor" }
        })
        trackpad.begin(1, Point(100.0, 100.0), canControl = true)
        trackpad.end(1, Point(101.0, 100.0), t0)
        trackpad.begin(1, Point(105.0, 100.0), canControl = true)
        trackpad.end(1, Point(105.0, 100.0), t0 + 200.milliseconds)
        assertEquals(listOf("button down 1", "button up 1", "clicked", "button down 2", "button up 2", "clicked"), events)
        events.clear()

        trackpad.begin(1, Point(0.0, 0.0), canControl = true)
        trackpad.move(mapOf(1 to Point(4.0, 0.0)))
        trackpad.move(mapOf(1 to Point(20.0, 0.0)))
        trackpad.move(mapOf(1 to Point(25.0, 5.0)))
        trackpad.end(1, Point(25.0, 5.0), t0 + 1.seconds)
        assertEquals(listOf("move 20,0", "move 5,5"), events)
        events.clear()

        trackpad.begin(1, Point(0.0, 0.0), canControl = true)
        assertTrue(trackpad.canLongPress)
        assertTrue(trackpad.longPress())
        assertFalse(trackpad.longPress(), "a drag starts once")
        trackpad.end(1, Point(0.0, 0.0), t0 + 2.seconds)
        assertEquals(listOf("button down 1", "button up 1"), events)
        events.clear()
        trackpad.begin(1, Point(0.0, 0.0), canControl = false)
        assertFalse(trackpad.longPress(), "no drag without control")
        trackpad.cancel()

        trackpad.begin(1, Point(0.0, 0.0), canControl = true)
        trackpad.fingers(mapOf(1 to Point(0.0, 0.0), 2 to Point(10.0, 0.0), 3 to Point(20.0, 0.0)))
        trackpad.move(mapOf(1 to Point(0.0, 30.0), 2 to Point(10.0, 30.0), 3 to Point(20.0, 30.0)))
        trackpad.cancel()
        assertEquals(listOf("scroll 0 1", "scroll 30 2", "scroll 0 4"), events)
    }

    @Test
    fun canvasZoomsAroundTheGestureAndKeepsTheCursorVisible() {
        val canvas = ScreenCanvas()
        canvas.resize(1000.0, 500.0, 1920.0, 1080.0)
        assertTrue(canvas.isFitted)
        assertEquals(500.0 / 1080.0, canvas.scale, 1e-9)
        canvas.transform(100.0, Point(500.0, 250.0), Point(500.0, 250.0))
        assertEquals(ScreenCanvas.MAX_ZOOM, canvas.zoom)
        val before = canvas.cursor
        canvas.move(canvas.scale * 1920 * 0.25, 0.0)
        assertEquals(before.x + 0.25, canvas.cursor.x, 1e-9)
        val cursorX = canvas.left + canvas.cursor.x * 1920 * canvas.scale
        assertTrue(cursorX in 0.0..1000.0, "the view pans to follow the cursor")
        canvas.reset()
        assertTrue(canvas.isFitted)
        canvas.setCursor(2.0, -1.0)
        assertEquals(Point(1.0, 0.0), canvas.cursor)
        assertTrue(canvas.contains(500.0, 250.0))
        assertFalse(canvas.contains(canvas.left - 1, 250.0), "the letterbox is outside the desktop")
        canvas.setView(2.0, 10_000.0, 0.0)
        assertEquals(2.0, canvas.zoom)
        assertTrue(canvas.panX < 10_000.0, "an animated view is clamped like a gesture")
        canvas.setView(Double.NaN, 0.0, 0.0)
        assertEquals(2.0, canvas.zoom, "a non-finite view is ignored")
    }

    @Test
    fun displayMatchingPrefersTheClosestMode() {
        val modes = listOf(
            com.dbpprt.dieter.api.v1.RemoteDesktopDisplayMode(logical_width = 1920, logical_height = 1080, pixel_width = 3840, pixel_height = 2160, refresh_rate = 60.0),
            com.dbpprt.dieter.api.v1.RemoteDesktopDisplayMode(logical_width = 1512, logical_height = 982, pixel_width = 3024, pixel_height = 1964, refresh_rate = 120.0),
        )
        val target = DisplayMatching.Target(1512.0, 982.0, 2.0, 120.0)
        assertEquals(1512, DisplayMatching.best(modes, target)?.logical_width)
        assertTrue(DisplayMatching.exact(modes[1], target))
        assertFalse(DisplayMatching.exact(modes[0], target))
    }

    @Test
    fun epochDecodesLikeTheFixture() {
        assertEquals(epoch, "BwcHBwcHBwcHBwcHBwcHBw==".decodeBase64())
    }
}
