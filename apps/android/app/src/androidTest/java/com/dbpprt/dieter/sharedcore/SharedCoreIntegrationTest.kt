package com.dbpprt.dieter.sharedcore

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.DieterContainer
import com.dbpprt.dieter.data.DieterCredentialStore
import com.dbpprt.dieter.e2e.IsolatedCore
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The shared core on a real device: Android's OkHttp/BouncyCastle transport,
 * keystore-backed credentials, and private file storage against the isolated
 * gateway. Protocol behavior (sync, the outbox, shared navigation) is covered
 * by the core's JVM end-to-end tests; this proves the Android bindings carry it.
 */
@RunWith(AndroidJUnit4::class)
class SharedCoreIntegrationTest {
    private val container: DieterContainer
        get() = (InstrumentationRegistry.getInstrumentation().targetContext.applicationContext as DieterApplication).container

    @After fun disconnect() = IsolatedCore.disconnect(container)

    @Test
    fun relaySignInSyncsTheFixtureAndReachesItsMachine() = runBlocking {
        val workspace = IsolatedCore.connect(container)
        assertTrue(workspace.projects.isNotEmpty())
        val daemonId = IsolatedCore.machineId
        val information = container.core.onMachine(daemonId) { it.GetMachineInformation().execute(Unit) }
        assertTrue(information.hostname.isNotBlank())
        // The session token is kept in the keystore-backed store, keyed by the gateway's origin.
        val stored = DieterCredentialStore(InstrumentationRegistry.getInstrumentation().targetContext).get(IsolatedCore.gateway.origin)
        assertEquals(IsolatedCore.token, stored)
    }
}
