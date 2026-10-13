package com.getdieter.android.data

import com.getdieter.core.platform.DeviceTlsIdentity
import com.getdieter.core.platform.DirectTarget
import com.getdieter.core.platform.DirectTls
import com.getdieter.core.platform.DirectTlsProviders
import com.getdieter.core.platform.PinnedDaemonTrustManager
import com.getdieter.core.platform.SoftwareDeviceKeys
import com.getdieter.core.trust.DeviceCertificate
import com.getdieter.core.trust.Rosters
import java.io.ByteArrayInputStream
import java.io.IOException
import java.nio.file.Files
import java.security.InvalidKeyException
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Provider
import java.security.PublicKey
import java.security.Security
import java.security.Signature
import java.security.SignatureSpi
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.interfaces.ECKey
import java.security.interfaces.ECPrivateKey
import java.security.spec.ECParameterSpec
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager
import kotlin.concurrent.thread
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import okio.ByteString.Companion.toByteString
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.jsse.provider.BouncyCastleJsseProvider

/**
 * TLS 1.3 client authentication through BouncyCastle JSSE with a key BouncyCastle cannot read, as
 * the app authenticates to machines with its Android Keystore key. A test provider stands in for
 * the Android Keystore: its keys have no encoding and only it can sign with them, exactly what
 * makes BouncyCastle's own NONEwithECDSA refuse them.
 */
class KeyStoreTlsTest {
    private fun keys() =
        SoftwareDeviceKeys(Files.createTempDirectory("dieter-tls").resolve("key").toFile())

    private val device = keys()
    private val machine = keys()
    private val signatures = AtomicInteger()
    private val keyStore = HardwareKeys(signatures).also { Security.addProvider(it) }
    private val presented = AtomicReference<X509Certificate?>()
    private val listener = serverSocket()

    @AfterTest
    fun tearDown() {
        listener.close()
        Security.removeProvider(keyStore.name)
    }

    @Test
    fun theKeyStoreSignsTheClientCertificateVerify() {
        handshake(KeyStoreTls.providers(BouncyCastleProvider()))
        val certificate = checkNotNull(presented.get()) { "no client certificate" }
        assertContentEquals(device.publicKey(), certificate.publicKey.encoded)
        assertEquals(1, signatures.get(), "the key's own provider signed the handshake")
    }

    @Test
    fun bouncyCastleAloneCannotSignWithAKeyStoreKey() {
        val crypto = BouncyCastleProvider()
        val failure =
            assertFailsWith<IOException> {
                handshake(DirectTlsProviders(crypto, BouncyCastleJsseProvider(crypto)))
            }
        assertTrue(
            generateSequence<Throwable>(failure) { it.cause }.any { it is InvalidKeyException }
        )
        assertEquals(0, signatures.get())
    }

    private fun certificate(keys: SoftwareDeviceKeys) =
        DeviceCertificate.selfSigned(
            keys.publicKey(),
            Rosters.deviceId(keys.publicKey()),
            keys::sign,
        )

    private fun handshake(providers: DirectTlsProviders) {
        val accepted = thread {
            runCatching {
                (listener.accept() as SSLSocket).use { socket ->
                    socket.startHandshake()
                    socket.outputStream.write(1)
                    socket.outputStream.flush()
                }
            }
        }
        val pinned = machine.publicKey()
        val target =
            DirectTarget(
                "d_studio",
                "127.0.0.1",
                listener.localPort,
                pinned.toByteString(),
                certificate(device),
                "0.0.0-dev.0",
            )
        val identity = DeviceTlsIdentity { HardwareKey(device.privateKey() as ECPrivateKey) }
        val context =
            DirectTls.context(target, identity, PinnedDaemonTrustManager(pinned), providers)
        try {
            (context.socketFactory.createSocket("127.0.0.1", listener.localPort) as SSLSocket).use {
                it.startHandshake()
                it.inputStream.read()
            }
        } finally {
            accepted.join(5_000)
        }
    }

    /** A TLS 1.3 server that requires a client certificate and records it, like the daemon. */
    private fun serverSocket(): SSLServerSocket {
        val certificate =
            CertificateFactory.getInstance("X.509")
                .generateCertificate(ByteArrayInputStream(certificate(machine).toByteArray()))
        val store =
            KeyStore.getInstance("PKCS12").apply {
                load(null)
                setKeyEntry("machine", machine.privateKey(), CharArray(0), arrayOf(certificate))
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

    /** Like an Android Keystore key: an EC key without an encoding. */
    class HardwareKey(val inner: ECPrivateKey) : PrivateKey, ECKey {
        override fun getAlgorithm() = "EC"

        override fun getFormat(): String? = null

        override fun getEncoded(): ByteArray? = null

        override fun getParams(): ECParameterSpec = inner.params
    }

    /** Signs with [HardwareKey]s only, as the Android Keystore's provider does. */
    // Android's Provider has only the numeric-version constructor.
    @Suppress("DEPRECATION")
    private class HardwareKeys(signatures: AtomicInteger) :
        Provider("DieterTestKeyStore", 1.0, "Signs with keys that have no encoding") {
        init {
            putService(
                object :
                    Service(
                        this,
                        "Signature",
                        "NONEwithECDSA",
                        "com.getdieter.android.data.HardwareSignature",
                        null,
                        mapOf("SupportedKeyClasses" to HardwareKey::class.java.name),
                    ) {
                    override fun newInstance(constructorParameter: Any?): Any =
                        HardwareSignature(signatures)
                }
            )
        }
    }

    private class HardwareSignature(private val signatures: AtomicInteger) : SignatureSpi() {
        private var signer: Signature? = null

        override fun engineInitSign(privateKey: PrivateKey) {
            val key = privateKey as? HardwareKey ?: throw InvalidKeyException("not a hardware key")
            signer = Signature.getInstance("NONEwithECDSA", "SunEC").apply { initSign(key.inner) }
        }

        override fun engineInitVerify(publicKey: PublicKey) = throw InvalidKeyException("sign only")

        override fun engineUpdate(b: Byte) = checkNotNull(signer).update(b)

        override fun engineUpdate(b: ByteArray, off: Int, len: Int) =
            checkNotNull(signer).update(b, off, len)

        override fun engineSign(): ByteArray =
            checkNotNull(signer).sign().also { signatures.incrementAndGet() }

        override fun engineVerify(sigBytes: ByteArray): Boolean =
            throw UnsupportedOperationException()

        @Deprecated("JCA parameters")
        override fun engineSetParameter(param: String?, value: Any?) =
            throw UnsupportedOperationException()

        @Deprecated("JCA parameters")
        override fun engineGetParameter(param: String?): Any = throw UnsupportedOperationException()
    }
}
