package com.dbpprt.dieter.settings

import io.grpc.Status
import org.junit.Assert.*
import org.junit.Test

class NavigationSyncHealthTest {
    @Test fun shortTransportInterruptionsGetTimeToRecover() {
        val error = Status.UNAVAILABLE.withDescription("private transport details").asRuntimeException()
        assertNull(navigationSyncFailure(error, 9_999))
        assertEquals("Folder and order sync is reconnecting.", navigationSyncFailure(error, 10_000))
    }

    @Test fun actionableErrorsExplainNextStepWithoutLeakingTransportDetails() {
        val error = Status.UNAUTHENTICATED.withDescription("secret token").asRuntimeException()
        assertEquals("Sign in again to sync folders and order.", navigationSyncFailure(error, 0))
        assertFalse(navigationSyncFailure(IllegalStateException("secret token"), 0)!!.contains("secret"))
    }
}
