package com.getdieter.android.data

import com.getdieter.core.platform.DirectTlsProviders
import java.security.Provider
import org.bouncycastle.jcajce.util.DefaultJcaJceHelper
import org.bouncycastle.jcajce.util.JcaJceHelper
import org.bouncycastle.jsse.provider.BouncyCastleJsseProvider
import org.bouncycastle.tls.crypto.impl.jcajce.JcaTlsCryptoProvider

/**
 * Machine TLS on Android. Conscrypt cannot verify the machines' Ed25519 certificates, so the app
 * speaks TLS through BouncyCastle JSSE, whose crypto comes from [crypto]. BouncyCastle cannot use
 * an Android Keystore key, so a private-key operation it rejects runs through the provider that
 * owns the key (JCA delayed provider selection): the TLS 1.3 client CertificateVerify is signed
 * with NONEwithECDSA by the Android Keystore.
 */
object KeyStoreTls {
    fun providers(crypto: Provider): DirectTlsProviders {
        val tlsCrypto =
            object : JcaTlsCryptoProvider() {
                    override fun getAltHelper(): JcaJceHelper = DefaultJcaJceHelper()
                }
                .setProvider(crypto)
        return DirectTlsProviders(crypto, BouncyCastleJsseProvider(false, tlsCrypto))
    }
}
