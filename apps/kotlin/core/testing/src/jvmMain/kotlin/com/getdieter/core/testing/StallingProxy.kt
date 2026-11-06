package com.getdieter.core.testing

import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.concurrent.thread

/**
 * A loopback TCP proxy whose open connections can go silent, as a Mac's do after it sleeps and
 * wakes: nothing fails or closes, bytes just stop arriving in either direction. Connections opened
 * afterwards work, like those a woken Mac opens on its network.
 */
class StallingProxy(private val target: String) : AutoCloseable {
    private val server = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
    private val links = CopyOnWriteArrayList<Link>()

    val url
        get() = "http://127.0.0.1:${server.localPort}"

    init {
        thread(isDaemon = true, name = "stalling-proxy") {
            while (!server.isClosed) {
                val client =
                    try {
                        server.accept()
                    } catch (_: IOException) {
                        return@thread
                    }
                val (host, port) = target.split(":", limit = 2)
                val upstream =
                    try {
                        Socket(host, port.toInt())
                    } catch (_: IOException) {
                        client.close()
                        continue
                    }
                links += Link(client, upstream).also(Link::start)
            }
        }
    }

    /** Every connection open now stops delivering bytes; none of them closes. */
    fun stall() = links.forEach { it.stalled = true }

    override fun close() {
        server.close()
        links.forEach(Link::close)
    }

    private class Link(private val client: Socket, private val upstream: Socket) {
        @Volatile var stalled = false

        fun start() {
            pump(client, upstream)
            pump(upstream, client)
        }

        // A stalled link keeps reading so neither peer sees back-pressure, and drops the bytes.
        private fun pump(from: Socket, to: Socket) =
            thread(isDaemon = true, name = "stalling-proxy-link") {
                val buffer = ByteArray(16 * 1024)
                try {
                    while (true) {
                        val read = from.getInputStream().read(buffer)
                        if (read < 0) break
                        if (!stalled) to.getOutputStream().write(buffer, 0, read)
                    }
                } catch (_: IOException) {}
                if (!stalled) close()
            }

        fun close() {
            client.close()
            upstream.close()
        }
    }
}
