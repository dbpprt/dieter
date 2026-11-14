package com.getdieter.android.data

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.getdieter.core.platform.DeviceKeys
import com.getdieter.core.platform.DeviceTlsIdentity
import java.security.GeneralSecurityException
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.ProviderException
import java.security.Signature
import java.security.spec.ECGenParameterSpec

/**
 * This install's device key: a non-exportable ECDSA P-256 key in the Android Keystore, in StrongBox
 * when the device has one. Roster entries are signed with SHA256withECDSA; TLS 1.3 client
 * authentication signs its CertificateVerify hash with NONEwithECDSA through [KeyStoreTls], so the
 * key authorizes both digests. Clearing the app's data deletes the key.
 */
class AndroidDeviceKeys(override val deviceName: String = Build.MODEL) :
    DeviceKeys, DeviceTlsIdentity {
    override val platform = "android"
    private val keyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }
    private var entry: KeyStore.PrivateKeyEntry? = null

    @Synchronized
    private fun entry(): KeyStore.PrivateKeyEntry {
        entry?.let {
            return it
        }
        val stored = keyStore.getEntry(ALIAS, null) as? KeyStore.PrivateKeyEntry
        return (stored ?: generate()).also { entry = it }
    }

    override fun publicKey(): ByteArray = entry().certificate.publicKey.encoded

    override fun sign(message: ByteArray): ByteArray =
        Signature.getInstance("SHA256withECDSA").run {
            initSign(entry().privateKey)
            update(message)
            sign()
        }

    override fun privateKey(): PrivateKey = entry().privateKey

    @Synchronized
    override fun reset() {
        entry = null
        keyStore.deleteEntry(ALIAS)
    }

    private fun generate(): KeyStore.PrivateKeyEntry {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
            try {
                return generate(strongBox = true).also(::signHash)
            } catch (unavailable: ProviderException) {
                // StrongBoxUnavailableException, or a StrongBox that refuses this key.
                keyStore.deleteEntry(ALIAS)
            } catch (unavailable: GeneralSecurityException) {
                keyStore.deleteEntry(ALIAS)
            }
        return generate(strongBox = false)
    }

    /** TLS signs a precomputed hash; a StrongBox key that cannot is not used. */
    private fun signHash(entry: KeyStore.PrivateKeyEntry) {
        Signature.getInstance("NONEwithECDSA").run {
            initSign(entry.privateKey)
            update(ByteArray(32))
            sign()
        }
    }

    private fun generate(strongBox: Boolean): KeyStore.PrivateKeyEntry {
        val spec =
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256)
                .apply {
                    if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
                        setIsStrongBoxBacked(true)
                }
                .build()
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, PROVIDER).run {
            initialize(spec)
            generateKeyPair()
        }
        return keyStore.getEntry(ALIAS, null) as KeyStore.PrivateKeyEntry
    }

    private companion object {
        const val PROVIDER = "AndroidKeyStore"
        const val ALIAS = "dieter-device-v1"
    }
}
