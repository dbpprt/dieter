package com.dbpprt.dieter.core

import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.time.Duration.Companion.seconds

/** QUOTA scenario against a real gateway. */
class QuotasEndToEndTest : EndToEnd() {
    @AfterTest
    fun tearDown() = tearDownRuntimes()

    @Test
    fun quotasAreWatchedFromTheGateway() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.quotas.view.await(20.seconds, describe = { "watching: ${runtime.quotas.view.value}" }) { it.live && it.error == null }
        runtime.onCore { runtime.quotas.load(refresh = true) }
        assertEquals(null, runtime.quotas.view.value.error)
    }
}
