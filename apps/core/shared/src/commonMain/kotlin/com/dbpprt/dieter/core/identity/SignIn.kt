package com.dbpprt.dieter.core.identity

import com.dbpprt.dieter.core.platform.AuthHttp
import com.dbpprt.dieter.core.platform.SecureStore
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.base64Url
import com.dbpprt.dieter.core.runtime.randomUrlToken
import com.dbpprt.dieter.core.state.GatewayRecord
import com.dbpprt.dieter.core.state.PendingSignIn
import com.dbpprt.dieter.core.storage.CoreStorage
import kotlin.time.Clock
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Instant
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okio.ByteString.Companion.encodeUtf8

/**
 * GitHub OAuth with PKCE (RFC 7636) through the gateway. The platform opens
 * [begin]'s URL in a browser and hands the callback URL to [complete]. The
 * pending attempt is persisted, so a callback delivered after the app was
 * relaunched still completes within [EXPIRY].
 */
class SignIn(
    private val storage: CoreStorage,
    private val http: AuthHttp,
    private val credentials: Credentials,
    private val redirectUri: String,
    private val clock: Clock = Clock.System,
) {
    /** Starts an attempt for [gateway] and returns the URL to open. Replaces any previous attempt. */
    fun begin(gateway: Gateway): String {
        if (!gateway.secure) throw CoreException(FailureKind.PERMANENT, "Remote sign-in requires an HTTPS gateway.")
        val verifier = randomUrlToken(48)
        val challenge = verifier.encodeUtf8().sha256().toByteArray().base64Url()
        storage.write(
            PENDING,
            PendingSignIn.ADAPTER.encode(
                PendingSignIn(gateway = gateway.record(), verifier = verifier, created_at_millis = clock.now().toEpochMilliseconds()),
            ),
        )
        return "${gateway.httpBase}/auth/github/start?native_redirect_uri=${Urls.encode(redirectUri)}" +
            "&native_code_challenge=${Urls.encode(challenge)}"
    }

    /** Whether [url] is this client's OAuth callback. */
    fun isCallback(url: String): Boolean = url.substringBefore('?') == redirectUri

    /**
     * Exchanges the callback's code for a session token, stores it, and
     * returns the gateway that was signed in to.
     */
    suspend fun complete(callbackUrl: String): Gateway {
        if (!isCallback(callbackUrl)) throw CoreException(FailureKind.PERMANENT, "Not a Dieter sign-in callback.")
        val pending = storage.read(PENDING)?.let(PendingSignIn.ADAPTER::decode)
            ?: throw CoreException(FailureKind.PERMANENT, "No sign-in is in progress.")
        storage.delete(PENDING)
        if (clock.now() - Instant.fromEpochMilliseconds(pending.created_at_millis) > EXPIRY) {
            throw CoreException(FailureKind.PERMANENT, "Sign-in expired. Start sign-in again.")
        }
        val code = Urls.queryParameter(callbackUrl, "code")
            ?: throw CoreException(FailureKind.PERMANENT, "The sign-in callback did not contain a code.")
        val gateway = pending.gateway?.toGateway() ?: throw CoreException(FailureKind.PERMANENT, "No sign-in is in progress.")
        val body = buildJsonObject {
            put("code", code)
            put("verifier", pending.verifier)
        }.toString()
        val response = http.postJson("${gateway.httpBase}/auth/native/exchange", body)
        if (response.status != 200) {
            throw CoreException(FailureKind.PERMANENT, "Dieter rejected the sign-in exchange (${response.status}).")
        }
        val token = runCatching { Json.parseToJsonElement(response.body).jsonObject["accessToken"]?.jsonPrimitive?.contentOrNull }
            .getOrNull()?.takeIf { it.isNotBlank() }
            ?: throw CoreException(FailureKind.PERMANENT, "Dieter rejected the sign-in exchange.")
        credentials.save(gateway, token)
        return gateway
    }

    fun cancel() = storage.delete(PENDING)

    companion object {
        val EXPIRY = 5.minutes
        private const val PENDING = "pending-sign-in.pb"
    }
}

/** Gateway session tokens, keyed by gateway origin. */
class Credentials(private val store: SecureStore) {
    fun token(gateway: Gateway): String? = store.read(gateway.origin)?.takeIf { it.isNotBlank() }
    fun save(gateway: Gateway, token: String) = store.write(gateway.origin, token)
    fun remove(gateway: Gateway) = store.delete(gateway.origin)
}

fun Gateway.record() = GatewayRecord(name = name, host = host, port = port, secure = secure)

fun GatewayRecord.toGateway() = Gateway(name = name, host = host, port = port, secure = secure)

/** Minimal URL helpers; the core never needs a full URL parser. */
object Urls {
    private const val UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

    fun encode(value: String): String = buildString {
        for (byte in value.encodeToByteArray()) {
            val char = byte.toInt().toChar()
            if (byte >= 0 && char in UNRESERVED) append(char) else append('%').append(HEX[(byte.toInt() shr 4) and 0xf]).append(HEX[byte.toInt() and 0xf])
        }
    }

    /** Percent-decodes a URL path; unlike a query, `+` stays a plus. */
    fun decodePath(value: String): String = decode(value.replace("+", "%2B"))

    fun decode(value: String): String {
        val bytes = ArrayList<Byte>(value.length)
        var index = 0
        while (index < value.length) {
            val char = value[index]
            if (char == '%' && index + 2 < value.length) {
                val decoded = value.substring(index + 1, index + 3).toIntOrNull(16)
                if (decoded != null) {
                    bytes.add(decoded.toByte()); index += 3; continue
                }
            }
            if (char == '+') bytes.add(' '.code.toByte()) else char.toString().encodeToByteArray().forEach(bytes::add)
            index++
        }
        return bytes.toByteArray().decodeToString()
    }

    fun queryParameter(url: String, name: String): String? {
        val query = url.substringAfter('?', "").substringBefore('#')
        return query.split('&').firstNotNullOfOrNull { pair ->
            val key = pair.substringBefore('=')
            if (decode(key) == name) decode(pair.substringAfter('=', "")) else null
        }
    }

    private const val HEX = "0123456789ABCDEF"
}
