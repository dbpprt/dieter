package com.dbpprt.dieter.coreharness

import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.RuntimeConfig
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.identity.Gateway
import com.dbpprt.dieter.core.outbox.OutboxPolicy
import com.dbpprt.dieter.core.platform.DeviceSettings
import com.dbpprt.dieter.core.platform.OkHttpAuthHttp
import com.dbpprt.dieter.core.platform.OkHttpRpcTransport
import com.dbpprt.dieter.core.platform.Platform
import com.dbpprt.dieter.core.platform.SecureStore
import java.io.File
import java.nio.file.Files
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okio.FileSystem
import okio.Path.Companion.toOkioPath
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test

/** The core's Android variant on the host JVM, against the real Go fixture. */
class AndroidVariantEndToEndTest {
    private class Memory : SecureStore, DeviceSettings {
        private val values = ConcurrentHashMap<String, String>()
        override fun read(key: String) = values[key]
        override fun write(key: String, value: String) { values[key] = value }
        override fun delete(key: String) { values.remove(key) }
        override fun string(key: String) = values[key]
        override fun putString(key: String, value: String?) { if (value == null) values.remove(key) else values[key] = value }
    }

    @Test
    fun androidVariantSyncsAndCreates() = runBlocking {
        val binary = System.getProperty("dieter.isolatedGateway").orEmpty()
        assumeTrue("set -Pdieter.isolatedGateway", binary.isNotEmpty())
        val home = Files.createTempDirectory("core-android").toFile()
        val fixture = ProcessBuilder(binary, "-addr", "127.0.0.1:0", "-home", File(home, "fixture").path)
            .redirectError(File(home, "fixture.log")).start()
        try {
            val values = fixture.inputStream.bufferedReader().lineSequence().takeWhile { it != "READY" }
                .map { it.split("=", limit = 2) }.filter { it.size == 2 }.associate { it[0] to it[1] }
            val memory = Memory()
            val runtime = CoreRuntime(
                Platform(OkHttpRpcTransport(), memory, memory, OkHttpAuthHttp(), FileSystem.SYSTEM, File(home, "state").toOkioPath()),
                RuntimeConfig("0.0.0-dev.0", "dieter-android://oauth/callback", includeLoopbackRoutes = false, clientIdPrefix = "android"),
            )
            runtime.start()
            runtime.setActive(true)
            runtime.adoptSession(requireNotNull(Gateway.parse("http://${values.getValue("DIETER_ISOLATED_ADDR")}")), values.getValue("DIETER_ISOLATED_TOKEN"))
            withTimeout(30.seconds) { runtime.connection.state.first { it.phase == ConnectionPhase.CONNECTED } }
            runtime.createConversation(
                CreateConversationRequest(
                    project_id = values.getValue("DIETER_ISOLATED_PROJECT"), board_id = values.getValue("DIETER_ISOLATED_BOARD"),
                    lane = "todo", title = "From the Android variant", prompt = "hello", defer_start = true, workspace_mode = "project",
                ),
                chat = false,
            )
            val view = withTimeout(30.seconds) {
                runtime.workspace.state.first { view -> view.allItems.any { OutboxPolicy.isServerBacked(it.id) && it.title == "From the Android variant" } }
            }
            // The authoritative card replaces its optimistic row.
            val created = view.allItems.filter { it.title == "From the Android variant" }
            assertEquals(1, created.size)
            assertEquals(values.getValue("DIETER_ISOLATED_BOARD"), created.single().board_id)
            assertEquals(values.getValue("DIETER_ISOLATED_BOARD"), view.board(values.getValue("DIETER_ISOLATED_BOARD"))!!.id)
            runtime.shutdown()
        } finally {
            fixture.destroy()
            if (!fixture.waitFor(20, TimeUnit.SECONDS)) fixture.destroyForcibly()
            home.deleteRecursively()
        }
    }
}
