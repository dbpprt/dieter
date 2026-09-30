package com.dbpprt.dieter.core.testing

import java.io.File
import java.nio.file.Files
import java.util.concurrent.TimeUnit

/**
 * scripts/isolated-gateway: a disposable gateway plus enrolled daemons on
 * random loopback ports. Never touches the operator's gateway or DIETER_HOME.
 */
class IsolatedGateway(
    /** "live" advertises a pinned loopback TLS route, "dead" a refused one. */
    directRoute: String? = null,
    /** Enrolls a second, projectless daemon in the same account. */
    secondDaemon: Boolean = false,
    inboxFixture: Boolean = false,
) : AutoCloseable {
    private val home = Files.createTempDirectory("dieter-core-e2e").toFile()
    private val offlineTrigger = File(home, "offline")
    private val restartTrigger = File(home, "restart-second")
    private val log = File(home, "fixture.log")
    private val process: Process
    val values: Map<String, String>

    init {
        val binary = requireNotNull(System.getProperty("dieter.isolatedGateway")) { "run through ./gradlew jvmTest" }
        val command = mutableListOf(binary, "-addr", "127.0.0.1:0", "-home", File(home, "fixture").path, "-offline-trigger", offlineTrigger.path)
        if (directRoute != null) command += listOf("-direct-route", directRoute)
        if (secondDaemon) command += listOf("-daemon-restart-trigger", restartTrigger.path)
        if (inboxFixture) command += "-inbox-fixture"
        process = ProcessBuilder(command).redirectError(log).start()
        val lines = process.inputStream.bufferedReader()
        values = buildMap {
            while (true) {
                val line = lines.readLine() ?: error("isolated gateway exited: ${log.readText().takeLast(4000)}")
                if (line == "READY") break
                line.split("=", limit = 2).takeIf { it.size == 2 }?.let { (key, value) -> put(key, value) }
            }
        }
    }

    val url get() = "http://${values.getValue("DIETER_ISOLATED_ADDR")}"
    val token get() = values.getValue("DIETER_ISOLATED_TOKEN")
    val daemonId get() = values.getValue("DIETER_ISOLATED_DAEMON")
    val incompatibleDaemonId get() = values.getValue("DIETER_ISOLATED_INCOMPATIBLE_DAEMON")
    val secondDaemonId get() = values.getValue("DIETER_ISOLATED_SECOND_DAEMON")
    val projectId get() = values.getValue("DIETER_ISOLATED_PROJECT")
    val boardId get() = values.getValue("DIETER_ISOLATED_BOARD")

    /** Disconnects the primary daemon's tunnel while the gateway stays up. */
    fun daemonOffline() = check(offlineTrigger.createNewFile())

    fun daemonOnline() = check(offlineTrigger.delete())

    /** Restarts the second daemon's API and tunnel once; returns when it reconnected. */
    fun restartSecondDaemon(timeoutMillis: Long = 15_000) {
        check(restartTrigger.createNewFile())
        val ready = File(restartTrigger.path + ".ready")
        val deadline = System.currentTimeMillis() + timeoutMillis
        while (!ready.exists()) {
            check(System.currentTimeMillis() < deadline) { "second daemon did not restart" }
            Thread.sleep(50)
        }
    }

    fun logTail(characters: Int = 4000): String = log.readText().takeLast(characters)

    override fun close() {
        process.destroy()
        if (!process.waitFor(20, TimeUnit.SECONDS)) process.destroyForcibly().waitFor()
        home.deleteRecursively()
    }
}
