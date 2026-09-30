package com.dbpprt.dieter.core.testing

import com.dbpprt.dieter.core.platform.AuthHttp
import com.dbpprt.dieter.core.platform.DeviceSettings
import com.dbpprt.dieter.core.platform.HttpResponse
import com.dbpprt.dieter.core.platform.SecureStore
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeout

class MemorySecureStore : SecureStore {
    val values = LinkedHashMap<String, String>()
    override fun read(key: String): String? = values[key]
    override fun write(key: String, value: String) { values[key] = value }
    override fun delete(key: String) { values.remove(key) }
}

class MemoryDeviceSettings : DeviceSettings {
    val values = LinkedHashMap<String, String>()
    override fun string(key: String): String? = values[key]
    override fun putString(key: String, value: String?) {
        if (value == null) values.remove(key) else values[key] = value
    }
}

/** Answers the OAuth exchange from a script and records each request. */
class ScriptedAuthHttp(private val respond: (url: String, body: String) -> HttpResponse) : AuthHttp {
    val requests = mutableListOf<Pair<String, String>>()
    override suspend fun postJson(url: String, body: String): HttpResponse {
        requests += url to body
        return respond(url, body)
    }
}

/** A wall clock tests move by hand. */
class ManualClock(var current: Instant = Instant.parse("2026-09-30T12:00:00Z")) : Clock {
    override fun now(): Instant = current
    fun advance(by: Duration) { current += by }
}

/** Waits in real time for [flow] to satisfy [predicate]; end-to-end tests use a live fixture. */
suspend fun <T> Flow<T>.await(timeout: Duration = 20.seconds, describe: () -> String = { "condition" }, predicate: (T) -> Boolean): T =
    try {
        withTimeout(timeout) { first(predicate) }
    } catch (error: kotlinx.coroutines.TimeoutCancellationException) {
        throw AssertionError("timed out after $timeout waiting for ${describe()}", error)
    }
