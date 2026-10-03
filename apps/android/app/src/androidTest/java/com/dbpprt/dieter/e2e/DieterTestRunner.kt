package com.dbpprt.dieter.e2e

import android.os.Bundle
import android.app.UiAutomation
import androidx.test.runner.AndroidJUnitRunner
import org.json.JSONObject
import java.io.File

/** Credentials and flows arrive through the owned app's private files, never argv. */
class DieterTestRunner : AndroidJUnitRunner() {
    // A connected phone may have operator accessibility services enabled.
    // Keep one consistent automation connection without suppressing or cycling
    // those services when permission rules and screenshot helpers request it.
    override fun getUiAutomation(): UiAutomation = getUiAutomation(0)

    override fun getUiAutomation(flags: Int): UiAutomation =
        super.getUiAutomation(flags or UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)

    override fun onCreate(arguments: Bundle) {
        if (arguments.getString("e2ePlan") == "plan.json") {
            check(targetContext.packageName == "com.dbpprt.dieter.e2e") { "E2E plans require the isolated app" }
            val file = File(targetContext.filesDir, "plan.json")
            check(file.length() in 1..(1024 * 1024)) { "Missing or oversized E2E plan" }
            val plan = JSONObject(file.readText())
            check(plan.getInt("version") == 1) { "Unsupported E2E plan version" }
            val values = plan.getJSONObject("arguments")
            for (key in values.keys()) arguments.putString(key, values.getString(key))
        }
        super.onCreate(arguments)
    }
}
