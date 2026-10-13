package com.getdieter.core.platform

import java.io.File
import java.nio.ByteBuffer
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermissions
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.Provider
import java.security.PublicKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec

/**
 * A software ECDSA P-256 device key in a private file ([file], mode 0600): the JVM platform's key,
 * and a fallback for hosts whose key store cannot sign TLS handshakes. The file holds the PKCS#8
 * private key and the DER SubjectPublicKeyInfo, each length-prefixed. Thread-safe.
 */
class SoftwareDeviceKeys(
    private val file: File,
    override val platform: String = "jvm",
    override val deviceName: String = "Dieter on JVM",
    private val provider: Provider? = null,
) : DeviceKeys, DeviceTlsIdentity {
    private var pair: KeyPair? = null

    @Synchronized
    private fun pair(): KeyPair {
        pair?.let {
            return it
        }
        val loaded = runCatching { load() }.getOrNull()
        return (loaded ?: generate().also(::save)).also { pair = it }
    }

    override fun publicKey(): ByteArray = pair().public.encoded

    override fun sign(message: ByteArray): ByteArray =
        signature().run {
            initSign(pair().private)
            update(message)
            sign()
        }

    override fun privateKey(): PrivateKey = pair().private

    @Synchronized
    override fun reset() {
        pair = null
        file.delete()
    }

    private fun signature(): Signature =
        provider?.let { Signature.getInstance("SHA256withECDSA", it) }
            ?: Signature.getInstance("SHA256withECDSA")

    private fun keyFactory(): KeyFactory =
        provider?.let { KeyFactory.getInstance("EC", it) } ?: KeyFactory.getInstance("EC")

    private fun generate(): KeyPair =
        (provider?.let { KeyPairGenerator.getInstance("EC", it) }
                ?: KeyPairGenerator.getInstance("EC"))
            .apply { initialize(ECGenParameterSpec("secp256r1")) }
            .generateKeyPair()

    private fun load(): KeyPair? {
        if (!file.exists()) return null
        val buffer = ByteBuffer.wrap(file.readBytes())
        fun field(): ByteArray = ByteArray(buffer.getInt()).also { buffer.get(it) }
        val private = field()
        val public = field()
        val factory = keyFactory()
        val publicKey: PublicKey = factory.generatePublic(X509EncodedKeySpec(public))
        val privateKey: PrivateKey = factory.generatePrivate(PKCS8EncodedKeySpec(private))
        return KeyPair(publicKey, privateKey)
    }

    private fun save(pair: KeyPair) {
        val private = pair.private.encoded
        val public = pair.public.encoded
        val bytes =
            ByteBuffer.allocate(8 + private.size + public.size)
                .putInt(private.size)
                .put(private)
                .putInt(public.size)
                .put(public)
                .array()
        file.parentFile?.mkdirs()
        val temporary = File(file.parentFile, ".${file.name}.tmp")
        temporary.delete()
        temporary.createNewFile()
        runCatching {
            Files.setPosixFilePermissions(
                temporary.toPath(),
                PosixFilePermissions.fromString("rw-------"),
            )
        }
        temporary.writeBytes(bytes)
        Files.move(
            temporary.toPath(),
            file.toPath(),
            StandardCopyOption.REPLACE_EXISTING,
            StandardCopyOption.ATOMIC_MOVE,
        )
    }
}

/** ECDSA P-256 verification through JCA (any provider with `SHA256withECDSA`). */
object JcaEcdsa {
    fun verify(
        publicKey: ByteArray,
        message: ByteArray,
        signature: ByteArray,
        provider: Provider? = null,
    ): Boolean = runCatching {
        val factory =
            provider?.let { KeyFactory.getInstance("EC", it) } ?: KeyFactory.getInstance("EC")
        val key = factory.generatePublic(X509EncodedKeySpec(publicKey))
        (provider?.let { Signature.getInstance("SHA256withECDSA", it) }
                ?: Signature.getInstance("SHA256withECDSA"))
            .run {
                initVerify(key)
                update(message)
                verify(signature)
            }
    }
        .getOrDefault(false)
}
