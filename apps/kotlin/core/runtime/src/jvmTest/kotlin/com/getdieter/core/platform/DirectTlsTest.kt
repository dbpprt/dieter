package com.getdieter.core.platform

import com.getdieter.core.trust.DeviceCertificate
import com.getdieter.core.trust.Rosters
import java.io.ByteArrayInputStream
import java.nio.file.Files
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLException
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager
import kotlin.concurrent.thread
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertFailsWith
import okio.ByteString.Companion.toByteString

/**
 * Mutual TLS as the transport dials a daemon: the server is accepted only by its pinned key, and
 * the client presents this device's certificate and key.
 */
class DirectTlsTest {
    private fun keys() =
        SoftwareDeviceKeys(Files.createTempDirectory("dieter-tls").resolve("key").toFile())

    private val device = keys()
    private val server = keys()
    private val presented = AtomicReference<X509Certificate?>()
    private val listener = serverSocket()

    private fun certificate(keys: SoftwareDeviceKeys) =
        DeviceCertificate.selfSigned(
            keys.publicKey(),
            Rosters.deviceId(keys.publicKey()),
            keys::sign,
        )

    /** A TLS 1.3 server that requires a client certificate and records it, like the daemon. */
    private fun serverSocket(): SSLServerSocket {
        val certificate =
            CertificateFactory.getInstance("X.509")
                .generateCertificate(ByteArrayInputStream(certificate(server).toByteArray()))
        val store =
            KeyStore.getInstance("PKCS12").apply {
                load(null)
                setKeyEntry("server", server.privateKey(), CharArray(0), arrayOf(certificate))
            }
        val keyManagers =
            KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
                .apply { init(store, CharArray(0)) }
                .keyManagers
        val anyClient =
            object : X509TrustManager {
                override fun checkClientTrusted(
                    chain: Array<out X509Certificate>,
                    authType: String,
                ) {
                    presented.set(chain.first())
                }

                override fun checkServerTrusted(
                    chain: Array<out X509Certificate>,
                    authType: String,
                ) = Unit

                override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            }
        val context =
            SSLContext.getInstance("TLSv1.3").apply { init(keyManagers, arrayOf(anyClient), null) }
        return (context.serverSocketFactory.createServerSocket(0) as SSLServerSocket).apply {
            needClientAuth = true
            enabledProtocols = arrayOf("TLSv1.3")
        }
    }

    @AfterTest fun tearDown() = listener.close()

    private fun handshake(pinned: ByteArray) {
        val accepted = thread {
            runCatching {
                (listener.accept() as SSLSocket).use { socket ->
                    socket.startHandshake()
                    socket.outputStream.write(1)
                    socket.outputStream.flush()
                }
            }
        }
        val target =
            DirectTarget(
                "d_studio",
                "127.0.0.1",
                listener.localPort,
                pinned.toByteString(),
                certificate(device),
                "0.0.0-dev.0",
            )
        val context = DirectTls.context(target, device, PinnedDaemonTrustManager(pinned))
        try {
            (context.socketFactory.createSocket("127.0.0.1", listener.localPort) as SSLSocket).use {
                it.startHandshake()
                it.inputStream.read()
            }
        } finally {
            accepted.join(5_000)
        }
    }

    @Test
    fun theDaemonIsAcceptedByItsRosterKeyAndSeesTheDeviceKey() {
        handshake(server.publicKey())
        val certificate = checkNotNull(presented.get()) { "no client certificate" }
        assertContentEquals(device.publicKey(), certificate.publicKey.encoded)
    }

    @Test
    fun anotherKeyIsRefusedWhateverItsCertificateSays() {
        assertFailsWith<SSLException> { handshake(keys().publicKey()) }
    }
}
