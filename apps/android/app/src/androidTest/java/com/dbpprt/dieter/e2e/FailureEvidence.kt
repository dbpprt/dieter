package com.dbpprt.dieter.e2e

import org.junit.rules.TestWatcher
import org.junit.runner.Description

/** Place inside the Activity rule so the failed UI is captured before teardown. */
class FailureEvidence : TestWatcher() {
    override fun failed(error: Throwable, description: Description) {
        runCatching { Evidence.display("failure-${description.methodName}.png") }
    }
}
