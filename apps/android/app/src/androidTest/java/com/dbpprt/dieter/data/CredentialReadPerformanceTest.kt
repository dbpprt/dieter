package com.dbpprt.dieter.data

import android.os.StrictMode
import com.dbpprt.dieter.settings.SharedKV
import com.dbpprt.dieter.settings.SharedNavigation
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
    fun navigationPersistenceNeverCommitsOnMainAndPreservesCommandOrder() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val name = "navigation-performance-${UUID.randomUUID()}"
        val preferences = withContext(Dispatchers.IO) {
            context.getSharedPreferences(name, 0).also {
                it.edit().putString("activeAccount", "fixture-account").commit()
            }
        }
        val violations = AtomicInteger()
        var store: SharedKV? = null
        try {
            withContext(Dispatchers.Main) {
                val previous = StrictMode.getThreadPolicy()
                StrictMode.setThreadPolicy(StrictMode.ThreadPolicy.Builder().detectDiskReads().detectDiskWrites()
                    .penaltyListener({ it.run() }) { violations.incrementAndGet() }.build())
                try {
                    store = SharedKV(preferences).also { navigation ->
                        navigation.put("fixture", "one")
                        navigation.put("fixture", "two")
                    }
                } finally { StrictMode.setThreadPolicy(previous) }
            }
            val navigation = requireNotNull(store)
            navigation.awaitPendingWrites()
            assertEquals("\"two\"", navigation.values.value["fixture"])
            val restored = SharedKV(preferences)
            try {
                restored.awaitPendingWrites()
                assertEquals(2, restored.status.value.pending)
                assertEquals("\"two\"", restored.values.value["fixture"])
            } finally { restored.close() }
            val firstOrder = listOf("a", "b", "c")
            for (next in listOf(firstOrder, firstOrder.reversed(), firstOrder)) {
                navigation.edit { values ->
                    SharedNavigation.order(this, SharedNavigation.ordered(values, "test-order"), next, "test-order")
                }
            }
            navigation.awaitPendingWrites()
            assertEquals(firstOrder, SharedNavigation.ordered(navigation.values.value, "test-order"))
            withContext(Dispatchers.Main) { navigation.clearAccount() }
            navigation.awaitPendingWrites()
            assertEquals(emptyMap<String, String>(), navigation.values.value)
            assertNull(preferences.getString("activeAccount", null))
            instrumentation.waitForIdleSync()
            assertEquals(0, violations.get())
        } finally {
            store?.close()
            context.deleteSharedPreferences(name)
        }
    }

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
