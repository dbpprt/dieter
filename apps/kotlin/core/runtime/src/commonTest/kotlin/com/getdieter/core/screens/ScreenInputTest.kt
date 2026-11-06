package com.getdieter.core.screens

import com.getdieter.api.v1.RemoteDesktopCapabilities
import com.getdieter.api.v1.RemoteDesktopCursor
import com.getdieter.api.v1.RemoteDesktopICECandidate
import com.getdieter.api.v1.RemoteDesktopInput
import com.getdieter.api.v1.RemoteDesktopReceiverFeedback
import com.getdieter.api.v1.RemoteDesktopSessionState
import com.getdieter.client.v1.ScreenCommand
import com.getdieter.client.v1.ScreenKey
import com.getdieter.client.v1.ScreenPointer
import com.getdieter.client.v1.ScreenText
import com.getdieter.client.v1.Step
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Clock
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Instant
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import okio.ByteString.Companion.toByteString

/** [ScreenInput] on its own: routing, clipboard shortcuts, backpressure, and the host cursor. */
class ScreenInputTest {
    private class Engine : ScreenMediaEngine {
        val open =
            mutableSetOf(ScreenChannels.POINTER, ScreenChannels.INPUT, ScreenChannels.SESSION)
        val sent = mutableListOf<Pair<String, RemoteDesktopInput>>()
        var buffered = 0L

        override suspend fun createOffer() = ""

        override suspend fun applyAnswer(sdp: String) = Unit

        override suspend fun addRemoteCandidate(candidate: RemoteDesktopICECandidate) = Unit

        override fun send(label: String, bytes: ByteArray): Boolean {
            if (label !in open) return false
            sent += label to RemoteDesktopInput.ADAPTER.decode(bytes)
            return true
        }

        override fun isOpen(label: String) = label in open

        override fun bufferedAmount(label: String) = buffered

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

    /** A controlled session's input on the test scheduler. */
    private class Session(scope: TestScope) {
        private val start = Instant.fromEpochSeconds(1_800_000_000)
        val view =
            MutableStateFlow(
                ScreenView(
                    controlActive = true,
                    clipboardEnabled = true,
                    capabilities = RemoteDesktopCapabilities(clipboard_supported = true),
                )
            )
        val engine = Engine()
        var state: RemoteDesktopSessionState? =
            RemoteDesktopSessionState(display_generation = 3, control_generation = 2)
        val recovered = mutableListOf<String>()
        val clipboard = mutableListOf<String>()
        val input =
            ScreenInput(
                    scope.backgroundScope,
                    object : Clock {
                        override fun now() = start + scope.testScheduler.currentTime.milliseconds
                    },
                    view,
                    engine = { engine },
                    state = { state },
                    recover = { recovered += it },
                    clipboard = { clipboard += it },
                )
                .apply { encoder = ScreenInputEncoder(ByteArray(16) { 7 }.toByteString()) }

        fun sent(label: String) = engine.sent.filter { it.first == label }.map { it.second }
    }

    @Test
    fun commandsRouteTheirInputToItsChannelInOrder() = runTest {
        val session = Session(this)
        listOf(
                ScreenCommand(pointer = ScreenPointer(x = 0.5, y = 0.25)),
                ScreenCommand(key = ScreenKey(hid = 4, down = true)),
                ScreenCommand(text = ScreenText(text = "hi")),
                ScreenCommand(release_input = Step()),
                ScreenCommand(refresh = Step()),
            )
            .forEach(session.input::apply)
        val move = session.sent(ScreenChannels.POINTER).single()
        assertEquals(500_000, move.pointer_move?.normalized_x)
        assertEquals(3L, move.display_generation)
        assertEquals(2L, move.control_generation)
        val reliable = session.sent(ScreenChannels.INPUT)
        assertEquals(4, reliable[0].key?.physical_key)
        assertEquals("hi", reliable[1].text?.text)
        assertTrue(reliable[2].release_all != null)
        assertEquals(listOf(1L, 2L, 3L), reliable.map { it.sequence }, "no input for other members")
    }

    @Test
    fun pointerMovesWithinFourMillisecondsCoalesce() = runTest {
        val session = Session(this)
        session.input.pointer(0.1, 0.1)
        session.input.pointer(0.2, 0.2)
        session.input.pointer(0.3, 0.3)
        assertEquals(1, session.sent(ScreenChannels.POINTER).size, "the first move goes at once")
        advanceTimeBy(ScreenSessionPolicy.POINTER_INTERVAL)
        runCurrent()
        assertEquals(
            listOf(100_000, 300_000),
            session.sent(ScreenChannels.POINTER).map { it.pointer_move?.normalized_x },
            "the latest pending move wins",
        )
    }

    @Test
    fun commandCXAndVAreClipboardOperationsWhileSharingIsOn() = runTest {
        val session = Session(this)
        session.input.key(6, down = true, repeat = false, modifiers = Modifiers.COMMAND)
        session.input.key(27, down = true, repeat = false, modifiers = Modifiers.COMMAND)
        session.input.key(25, down = true, repeat = false, modifiers = Modifiers.COMMAND)
        assertEquals(listOf("copy", "cut", "paste"), session.clipboard)
        assertTrue(session.sent(ScreenChannels.INPUT).isEmpty())

        // Key-ups and repeats, or a host without sharing, type the key instead.
        session.input.key(6, down = false, repeat = false, modifiers = Modifiers.COMMAND)
        session.input.key(6, down = true, repeat = true, modifiers = Modifiers.COMMAND)
        session.view.value = session.view.value.copy(clipboardEnabled = false)
        session.input.key(6, down = true, repeat = false, modifiers = Modifiers.COMMAND)
        assertEquals(3, session.clipboard.size)
        assertEquals(
            listOf(6, 6, 6),
            session.sent(ScreenChannels.INPUT).map { it.key?.physical_key },
        )
    }

    @Test
    fun inputNeedsControlAndAStalledChannelRecovers() = runTest {
        val session = Session(this)
        session.view.value = session.view.value.copy(controlActive = false)
        session.input.key(4, down = true, repeat = false, modifiers = 0)
        session.input.pointer(0.5, 0.5)
        session.input.release()
        assertTrue(session.engine.sent.isEmpty(), "without control nothing is sent")

        session.view.value = session.view.value.copy(controlActive = true)
        session.engine.buffered = ScreenChannels.BACKPRESSURE_BYTES
        session.input.key(4, down = true, repeat = false, modifiers = 0)
        assertEquals(listOf("Remote input stalled"), session.recovered)

        session.engine.buffered = 0
        session.engine.open -= ScreenChannels.INPUT
        session.input.release()
        assertEquals(1, session.recovered.size, "releasing never recovers the session")
    }

    @Test
    fun textBeyondEightKilobytesIsRefused() = runTest {
        val session = Session(this)
        session.input.text("x".repeat(ScreenInputEncoder.MAX_TEXT_BYTES + 1), 0)
        assertTrue(session.engine.sent.isEmpty())
        assertEquals(
            "Text input is limited to 8 KB per insertion",
            session.view.value.clipboardError,
        )
        session.input.text("a", Modifiers.CONTROL)
        assertEquals(
            listOf(true, false),
            session.sent(ScreenChannels.INPUT).map { it.key?.down },
            "a shortcut character is a key stroke",
        )
    }

    @Test
    fun theHostCursorMovesUnlessLocalInputOrAFingerHoldsIt() = runTest {
        val session = Session(this)
        val png = ByteArray(4) { 1 }.toByteString()
        fun cursor(x: Int, generation: Long = 3, ordinal: Long = 0) =
            RemoteDesktopCursor(
                shape_id = "arrow",
                png = png,
                width = 16.0,
                height = 16.0,
                normalized_x = x,
                normalized_y = 500_000,
                visible = true,
                display_generation = generation,
                last_input_ordinal = ordinal,
            )
        session.input.cursor(cursor(250_000))
        assertEquals(0.25, session.view.value.cursorX)
        assertEquals(png, session.view.value.cursorImage)

        session.input.cursor(cursor(750_000, generation = 2))
        assertEquals(0.25, session.view.value.cursorX, "a cursor of an older display is ignored")

        session.input.pointer(0.9, 0.9)
        session.input.cursor(cursor(100_000, ordinal = 1))
        assertEquals(0.25, session.view.value.cursorX, "the local move is newer")
        advanceTimeBy(200)
        session.input.cursor(cursor(100_000, ordinal = 1))
        assertEquals(0.1, session.view.value.cursorX, "the host saw the local move")

        session.input.holdingCursor = true
        session.input.cursor(cursor(600_000, ordinal = 1))
        assertEquals(0.1, session.view.value.cursorX, "a held cursor stays")

        session.input.forgetCursors()
        session.input.cursor(cursor(600_000, ordinal = 1).copy(png = okio.ByteString.EMPTY))
        assertNull(session.view.value.cursorImage, "shapes of the old display are forgotten")
    }
}
