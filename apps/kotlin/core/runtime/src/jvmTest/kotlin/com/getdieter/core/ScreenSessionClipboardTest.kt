package com.getdieter.core

import com.getdieter.api.v1.RemoteDesktopClipboardFrame
import com.getdieter.api.v1.RemoteDesktopClipboardItem
import com.getdieter.api.v1.RemoteDesktopClipboardRequest
import com.getdieter.api.v1.RemoteDesktopClipboardResponse
import com.getdieter.api.v1.RemoteDesktopSignal
import com.getdieter.core.screens.ClipboardFraming
import com.getdieter.core.screens.LocalClipboard
import com.getdieter.core.screens.ScreenChannels
import com.getdieter.core.screens.ScreenConfig
import com.getdieter.core.screens.ScreenPhase
import com.getdieter.core.screens.ScreenSession
import com.getdieter.core.screens.ScreenSessionPolicy
import com.getdieter.core.screens.ViewportPolicy
import com.getdieter.core.testing.JcaSignatureVerifier
import com.getdieter.core.testing.PrintLogger
import com.getdieter.core.testing.await
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Clock
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext

/**
 * Clipboard sharing in a screen session: the sharing switch, user operations, and the background
 * sync, none of which may hold the session or outlive it.
 */
class ScreenSessionClipboardTest : ScreenSessionHarness() {
    @Test
    fun clipboardSharingToggleIsConfiguredOnTheHost() = runBlocking {
        val engines = Engines()
        val daemon = FakeDaemon()
        daemon.caps = daemon.caps.copy(clipboard_supported = true)
        val session = session(engines)
        onCore { session.connect { daemon.route() } }
        session.view.await { it.sessionId == "rd_test" }
        val engine = engines.created.single()
        eventually { engine.answer != null }
        onCore {
            engine.open += ScreenChannels.CLIPBOARD
            engine.connect()
        }
        daemon.signals.send(
            RemoteDesktopSignal(
                session_id = "rd_test",
                state =
                    daemon.state(1, 1000).copy(clipboard_enabled = true, clipboard_generation = 1),
            )
        )
        onCore { engine.events.presented(1200u) }
        session.view.await { it.controlActive && it.clipboardEnabled }

        val toggle = scope.async { session.setClipboardEnabled(false) }
        eventually { engine.sent.any { it.first == ScreenChannels.CLIPBOARD } }
        val frame =
            RemoteDesktopClipboardFrame.ADAPTER.decode(
                engine.sent.first { it.first == ScreenChannels.CLIPBOARD }.second
            )
        val request = RemoteDesktopClipboardRequest.ADAPTER.decode(frame.data_)
        assertEquals(RemoteDesktopClipboardRequest.Action.CONFIGURE, request.action)
        assertEquals(false, request.enabled)
        assertEquals(daemon.epoch, request.input_epoch)
        val response =
            RemoteDesktopClipboardResponse.ADAPTER.encodeByteString(
                RemoteDesktopClipboardResponse(operation_id = request.operation_id, enabled = false)
            )
        ClipboardFraming.frames(request.operation_id, response).forEach { reply ->
            onCore {
                engine.events.channelMessage(
                    ScreenChannels.CLIPBOARD,
                    RemoteDesktopClipboardFrame.ADAPTER.encode(reply),
                )
            }
        }
        toggle.await()
        val off = session.view.await { !it.clipboardEnabled }
        assertEquals(null, off.clipboardError)
        assertEquals(false, onCore { session.preferences.clipboard })
        onCore { session.disconnect() }
    }

    @Test
    fun aUserPasteWaitsForTheBackgroundSyncAndASecondOperationIsRefused() = runBlocking {
        val engines = Engines()
        val daemon = FakeDaemon()
        daemon.caps = daemon.caps.copy(clipboard_supported = true)
        val local =
            object : LocalClipboard {
                override fun stamp() = 1L

                override fun read(binary: Boolean) =
                    "pasted text" to emptyList<RemoteDesktopClipboardItem>()

                override fun apply(text: String, items: List<RemoteDesktopClipboardItem>) = Unit
            }
        val session =
            ScreenSession(
                engines,
                JcaSignatureVerifier,
                ScreenConfig("Test", ViewportPolicy.Fixed),
                Clock.System,
                scope,
                PrintLogger,
                local,
            )
        onCore { session.connect { daemon.route() } }
        session.view.await { it.sessionId == "rd_test" }
        val engine = engines.created.single()
        eventually { engine.answer != null }
        onCore {
            engine.open += ScreenChannels.CLIPBOARD
            engine.connect()
        }
        daemon.signals.send(
            RemoteDesktopSignal(
                session_id = "rd_test",
                state =
                    daemon.state(1, 1000).copy(clipboard_enabled = true, clipboard_generation = 1),
            )
        )
        onCore { engine.events.presented(1200u) }
        session.view.await { it.controlActive && it.clipboardEnabled }
        fun requests() =
            engine.sent
                .filter { it.first == ScreenChannels.CLIPBOARD }
                .map {
                    RemoteDesktopClipboardRequest.ADAPTER.decode(
                        RemoteDesktopClipboardFrame.ADAPTER.decode(it.second).data_
                    )
                }
        suspend fun answer(request: RemoteDesktopClipboardRequest, revision: String) {
            val response =
                RemoteDesktopClipboardResponse.ADAPTER.encodeByteString(
                    RemoteDesktopClipboardResponse(
                        operation_id = request.operation_id,
                        revision = revision,
                    )
                )
            ClipboardFraming.frames(request.operation_id, response).forEach { reply ->
                onCore {
                    engine.events.channelMessage(
                        ScreenChannels.CLIPBOARD,
                        RemoteDesktopClipboardFrame.ADAPTER.encode(reply),
                    )
                }
            }
        }

        // The background sync's read is in flight and unanswered.
        eventually({ "a background read" }) { requests().isNotEmpty() }
        val read = requests().single()
        assertEquals(RemoteDesktopClipboardRequest.Action.READ, read.action)
        val paste = scope.async { session.performClipboard("paste") }
        session.view.await { it.clipboardBusy }
        onCore {}
        assertEquals(1, requests().size, "the paste waits for the exchange in flight")
        assertEquals(null, session.view.value.clipboardError)
        withContext(core) { session.performClipboard("copy") }
        assertEquals(
            "A clipboard operation is still in progress",
            session.view.value.clipboardError,
        )

        answer(read, "r1")
        eventually({ "the paste request" }) { requests().size == 2 }
        val pasted = requests()[1]
        assertEquals(RemoteDesktopClipboardRequest.Action.PASTE, pasted.action)
        assertEquals("pasted text", pasted.text)
        assertEquals("r1", pasted.known_revision)
        answer(pasted, "r2")
        paste.await()
        val done = session.view.await { !it.clipboardBusy && it.clipboardOperations == 1 }
        assertEquals(null, done.clipboardError)
        onCore { session.disconnect() }
    }

    @Test
    fun aClipboardExchangeThatTimesOutDoesNotEndTheSync() = runTest {
        val engines = Engines()
        val daemon = FakeDaemon()
        daemon.caps = daemon.caps.copy(clipboard_supported = true)
        val local =
            object : LocalClipboard {
                override fun stamp() = 1L

                override fun read(binary: Boolean) = "" to emptyList<RemoteDesktopClipboardItem>()

                override fun apply(text: String, items: List<RemoteDesktopClipboardItem>) = Unit
            }
        val session = virtualSession(engines, clipboard = local)
        val engine = streaming(session, daemon, engines, clipboard = true)
        fun reads() = engine.sent.count { it.first == ScreenChannels.CLIPBOARD }
        // The background sync reads the host's clipboard; the host never answers.
        advanceTimeBy(ScreenSessionPolicy.CLIPBOARD_POLL)
        runCurrent()
        assertEquals(1, reads())
        advanceTimeBy(ScreenSessionPolicy.CLIPBOARD_TIMEOUT + ScreenSessionPolicy.CLIPBOARD_POLL)
        runCurrent()
        assertEquals("Clipboard transfer timed out", session.view.value.clipboardError)
        assertEquals(2, reads(), "the next poll reads again")
        session.disconnect()
    }

    @Test
    fun admittedClipboardWorkDoesNotHoldDisconnectAndCannotOutliveItsSession() = runTest {
        for (toggle in listOf(false, true)) {
            val engines = Engines()
            val daemon = FakeDaemon()
            daemon.caps = daemon.caps.copy(clipboard_supported = true)
            val local =
                object : LocalClipboard {
                    override fun stamp() = 1L

                    override fun read(binary: Boolean) =
                        "owned clipboard" to emptyList<RemoteDesktopClipboardItem>()

                    override fun apply(text: String, items: List<RemoteDesktopClipboardItem>) = Unit
                }
            val session = virtualSession(engines, clipboard = local)
            val engine = streaming(session, daemon, engines, clipboard = true)
            if (toggle) session.requestClipboardEnabled(false)
            else session.requestClipboard("paste")
            runCurrent()
            assertTrue(
                session.view.value.clipboardBusy,
                "the admitted operation awaits the unanswered host",
            )
            assertTrue(engine.sent.any { it.first == ScreenChannels.CLIPBOARD })

            session.disconnect()
            runCurrent()
            assertEquals(ScreenPhase.Idle, session.view.value.phase)
            assertFalse(session.view.value.controlActive)
            assertFalse(session.view.value.clipboardBusy)
            assertTrue(engine.closed)
            assertEquals(0, session.heldJobs)
            val sent = engine.sent.size
            advanceTimeBy(
                ScreenSessionPolicy.CLIPBOARD_TIMEOUT + ScreenSessionPolicy.CLIPBOARD_POLL
            )
            runCurrent()
            assertEquals(sent, engine.sent.size, "cancelled work cannot send on the stopped peer")
            assertEquals(
                null,
                session.view.value.clipboardError,
                "the old timeout cannot alter the idle view",
            )
        }
    }
}
