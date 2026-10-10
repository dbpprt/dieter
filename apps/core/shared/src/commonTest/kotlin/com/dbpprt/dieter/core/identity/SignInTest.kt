package com.dbpprt.dieter.core.identity

import com.dbpprt.dieter.core.platform.AuthHttp
import com.dbpprt.dieter.core.platform.HttpResponse
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.storage.CoreStorage
import com.dbpprt.dieter.core.testing.ManualClock
import com.dbpprt.dieter.core.testing.MemorySecureStore
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.time.Duration.Companion.minutes
import kotlinx.coroutines.test.runTest
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

class SignInTest {
    private val redirect = "dieter-test://oauth/callback"
    private val gateway = Gateway.parse("https://gateway.example", "Example")!!
    private val clock = ManualClock()
    private val secrets = MemorySecureStore()
    private val exchanges = mutableListOf<String>()
    private val http =
        object : AuthHttp {
            override suspend fun postJson(url: String, body: String): HttpResponse {
                exchanges += body
                return if ("\"real\"" in body) HttpResponse(200, """{"accessToken":"session"}""")
                else HttpResponse(400, "invalid")
            }
        }
    private val signIn =
        SignIn(
            CoreStorage(FakeFileSystem(), "/state".toPath()),
            http,
            Credentials(secrets),
            redirect,
            clock,
        )

    @Test
    fun aForgedCallbackDoesNotCancelTheRealAttempt() = runTest {
        signIn.begin(gateway)
        assertFailsWith<CoreException> { signIn.complete("$redirect?code=forged") }
        assertFailsWith<CoreException> { signIn.complete(redirect) }
        assertEquals(gateway.origin, signIn.complete("$redirect?code=real").origin)
        assertEquals("session", Credentials(secrets).token(gateway))
        assertFailsWith<CoreException>("a completed attempt is single-use") {
            signIn.complete("$redirect?code=real")
        }
        assertEquals(2, exchanges.size)
    }

    @Test
    fun anExpiredAttemptEndsWithoutAnExchange() = runTest {
        signIn.begin(gateway)
        clock.current += SignIn.EXPIRY + 1.minutes
        assertFailsWith<CoreException> { signIn.complete("$redirect?code=real") }
        clock.current -= SignIn.EXPIRY + 1.minutes
        assertFailsWith<CoreException>("expiry removed the attempt") {
            signIn.complete("$redirect?code=real")
        }
        assertEquals(0, exchanges.size)
        assertNull(Credentials(secrets).token(gateway))
    }
}
