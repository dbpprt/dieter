package com.getdieter.core.testing

import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * tools/fixtures/gateway: a disposable gateway plus enrolled daemons on random loopback ports.
 * Never touches the operator's gateway or DIETER_HOME.
 */
class IsolatedGateway(
    /** "live" advertises a pinned loopback TLS route, "dead" a refused one. */
    directRoute: String? = null,
    /** Enrolls a second, projectless daemon in the same account. */
    secondDaemon: Boolean = false,
    /**
     * Seeds the workspace the Maestro flows share (`-e2e-fixture`): labelled cards, chats, a
     * schedule, and the agent mail they read.
     */
    seeded: Boolean = false,
) : AutoCloseable {
    private val home = Files.createTempDirectory("dieter-core-e2e").toFile()
    private val offlineTrigger = File(home, "offline")
    private val restartTrigger = File(home, "restart-second")
    private val log = File(home, "fixture.log")
    private val process: Process
    val values: Map<String, String>

    init {
        val started = System.nanoTime()
        val binary =
            requireNotNull(System.getProperty("dieter.isolatedGateway")) {
                "run through ./gradlew jvmTest"
            }
        val command =
            mutableListOf(
                binary,
                "-addr",
                "127.0.0.1:0",
                "-home",
                File(home, "fixture").path,
                "-offline-trigger",
                offlineTrigger.path,
            )
        if (directRoute != null) command += listOf("-direct-route", directRoute)
        if (secondDaemon) command += listOf("-daemon-restart-trigger", restartTrigger.path)
        if (seeded) command += "-e2e-fixture"
        process = ProcessBuilder(command).redirectError(log).start()
        val lines = process.inputStream.bufferedReader()
        values = buildMap {
            while (true) {
                val line =
                    lines.readLine()
                        ?: error("isolated gateway exited: ${log.readText().takeLast(4000)}")
                if (line == "READY") break
                line
                    .split("=", limit = 2)
                    .takeIf { it.size == 2 }
                    ?.let { (key, value) -> put(key, value) }
            }
        }
        // Counted in the test reports, so a run shows how many fixtures it launched.
        println(
            "isolated gateway ${launches.incrementAndGet()} ready in ${(System.nanoTime() - started) / 1_000_000} ms"
        )
    }

    /** The gateway's loopback `host:port`. */
    val address
        get() = values.getValue("DIETER_ISOLATED_ADDR")

    val url
        get() = "http://$address"

    val token
        get() = values.getValue("DIETER_ISOLATED_TOKEN")

    /**
     * The one-time pairing code the fixture's machine approves: a runtime that pairs with it
     * becomes a trusted device without user interaction.
     */
    val pairingCode: String
        get() =
            values.getOrElse("DIETER_ISOLATED_PAIRING_CODE") {
                values.entries.firstOrNull { it.key.uppercase().endsWith("PAIRING_CODE") }?.value
                    ?: error("the fixture gateway printed no pairing code")
            }

    val daemonId
        get() = values.getValue("DIETER_ISOLATED_DAEMON")

    val incompatibleDaemonId
        get() = values.getValue("DIETER_ISOLATED_INCOMPATIBLE_DAEMON")

    val secondDaemonId
        get() = values.getValue("DIETER_ISOLATED_SECOND_DAEMON")

    val projectId
        get() = values.getValue("DIETER_ISOLATED_PROJECT")

    val boardId
        get() = values.getValue("DIETER_ISOLATED_BOARD")

    /** Disconnects the primary daemon's tunnel while the gateway stays up. */
    fun daemonOffline() = check(offlineTrigger.createNewFile())

    fun daemonOnline() = check(offlineTrigger.delete())

    /** Reconnects the primary daemon if a test left it offline; otherwise does nothing. */
    fun ensureOnline() {
        offlineTrigger.delete()
    }

    override fun close() {
        process.destroy()
        if (!process.waitFor(20, TimeUnit.SECONDS)) process.destroyForcibly().waitFor()
        home.deleteRecursively()
    }

    companion object {
        /** Fixtures launched by this test JVM. */
        val launches = AtomicInteger()
    }
}
