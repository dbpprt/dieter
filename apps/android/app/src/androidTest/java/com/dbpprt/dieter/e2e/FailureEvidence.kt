package com.dbpprt.dieter.e2e

import android.graphics.Bitmap
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.rules.TestWatcher
import org.junit.runner.Description
import java.io.File

/** Place inside the Activity rule so the failed UI is captured before teardown. */
class FailureEvidence : TestWatcher() {
    override fun failed(error: Throwable, description: Description) {
        runCatching {
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            val directory = requireNotNull(instrumentation.targetContext.getExternalFilesDir(null))
            File(directory, "failure-${description.methodName}.png").outputStream().use {
                instrumentation.uiAutomation.takeScreenshot()?.compress(Bitmap.CompressFormat.PNG, 100, it)
            }
        }
    }
}
