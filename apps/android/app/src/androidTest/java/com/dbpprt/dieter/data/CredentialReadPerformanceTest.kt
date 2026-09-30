package com.dbpprt.dieter.data

import android.os.StrictMode
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

@RunWith(AndroidJUnit4::class)
class CredentialReadPerformanceTest {
    @Test
    fun warmCredentialReadsAvoidDiskAndObserveReplacementAndSignOut() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val endpoint = "credential-performance-${UUID.randomUUID()}"
        val (writer, reader) = withContext(Dispatchers.IO) {
            DieterCredentialStore(instrumentation.targetContext) to
                DieterCredentialStore(instrumentation.targetContext)
        }
        try {
            withContext(Dispatchers.IO) {
                writer.set(endpoint, "fixture-first")
                assertEquals("fixture-first", reader.get(endpoint))
            }
            val violations = AtomicInteger()
            withContext(Dispatchers.Main) {
                val previous = StrictMode.getThreadPolicy()
                StrictMode.setThreadPolicy(
                    StrictMode.ThreadPolicy.Builder().detectDiskReads().detectDiskWrites()
                        .penaltyListener({ it.run() }) { violations.incrementAndGet() }.build(),
                )
                try {
                    repeat(100) { assertEquals("fixture-first", reader.get(endpoint)) }
                } finally {
                    StrictMode.setThreadPolicy(previous)
                }
            }
            instrumentation.waitForIdleSync()
            assertEquals("Warm credential reads must not re-enter Keystore", 0, violations.get())
            withContext(Dispatchers.IO) {
                writer.set(endpoint, "fixture-replaced")
                assertEquals("fixture-replaced", reader.get(endpoint))
                writer.set(endpoint, null)
                assertNull(reader.get(endpoint))
            }
        } finally {
            withContext(Dispatchers.IO) { writer.set(endpoint, null) }
        }
    }
}
