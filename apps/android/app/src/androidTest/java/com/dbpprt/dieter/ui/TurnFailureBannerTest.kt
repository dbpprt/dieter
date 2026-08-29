package com.dbpprt.dieter.ui

import android.os.ParcelFileDescriptor
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.ui.theme.DieterBackground
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class TurnFailureBannerTest {
    @get:Rule
    val compose = createComposeRule()

    @Test
    fun completeLogOpensAndRetryActionIsAvailable() {
        var retries = 0
        val failure = ConversationTurnFailure(
            summary = "codex exited 1 (context overflow).",
            log = "codex exited 1\nprovider stderr: context window exceeded",
            retryParts = listOf(MessagePart.newBuilder().setType("text").setText("Try again").build()),
        )
        compose.setContent {
            DieterTheme(darkTheme = true) {
                var showingLog by remember { mutableStateOf(false) }
                Box(
                    Modifier.fillMaxSize().background(DieterBackground)
                        .safeDrawingPadding().padding(16.dp),
                ) {
                    TurnFailureBanner(
                        failure = failure,
                        retrying = false,
                        onViewLog = { showingLog = true },
                        onRetry = { retries += 1 },
                    )
                }
                if (showingLog) TurnFailureLogDialog(failure.log) { showingLog = false }
            }
        }

        compose.onNodeWithTag("turn-failure").assertIsDisplayed()
        capture("turn-failure-banner.png")
        compose.onNodeWithTag("turn-failure-view-log").performClick()
        compose.onNodeWithTag("turn-failure-log-dialog").assertIsDisplayed()
        compose.onNodeWithText("provider stderr: context window exceeded", substring = true).assertIsDisplayed()
        capture("turn-failure-log.png")
        compose.onNodeWithText("Done").performClick()
        compose.onNodeWithTag("turn-failure-retry").performClick()
        compose.runOnIdle { assertEquals(1, retries) }
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        val descriptor = InstrumentationRegistry.getInstrumentation().uiAutomation
            .executeShellCommand("screencap -p /sdcard/Download/$name")
        ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
            while (input.read() != -1) {}
        }
    }
}
