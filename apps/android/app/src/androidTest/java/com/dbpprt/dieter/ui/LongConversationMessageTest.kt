package com.dbpprt.dieter.ui

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.connection.DieterConnectionManager
import com.dbpprt.dieter.data.DIETER_ENDPOINTS
import com.dbpprt.dieter.data.DieterEndpoint
import com.dbpprt.dieter.data.DieterRepository
import com.dbpprt.dieter.settings.AppPreferences
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.v1.UiMessage
import java.io.File
import java.lang.reflect.Proxy
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test

/** Native rendering with disposable app identity; no operator conversation is opened. */
class LongConversationMessageTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val lifecycle = ViewModelStore()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var model: DieterViewModel

    @Before fun setup() {
        assumeTrue("Use the isolated screen fixture app", context.packageName.endsWith(".screenfixture"))
        var endpoints = DIETER_ENDPOINTS
        val repository = Proxy.newProxyInstance(DieterRepository::class.java.classLoader, arrayOf(DieterRepository::class.java)) { _, method, args ->
            when (method.name) {
                "getEndpoints" -> endpoints
                "getActiveEndpoint" -> endpoints.first()
                "replaceEndpoints" -> { @Suppress("UNCHECKED_CAST") val values = args!![0] as List<DieterEndpoint>; endpoints = values; Unit }
                "close", "reconnect" -> Unit
                else -> error("Unexpected RPC during message rendering: ${method.name}")
            }
        } as DieterRepository
        compose.runOnUiThread {
            model = DieterViewModel(DieterConnectionManager(context, repository, scope), AppPreferences(context))
            lifecycle.put("long-message", model)
        }
    }

    @After fun cleanup() {
        compose.runOnUiThread { lifecycle.clear() }
        scope.cancel()
    }

    @Test fun largeTurnShowsLatestAndRevealsEarlierProseWithNativeInput() {
        val message = UiMessage.newBuilder().setId("long").setRole("assistant")
            .addAllParts((0 until 340).flatMap { index -> listOf(
                MessagePart.newBuilder().setType("text").setText("Step $index").build(),
                MessagePart.newBuilder().setType("dynamic-tool").setToolName("exec").setToolCallId("tool-$index")
                    .setState("output-available").build(),
            ) }).build()
        var presentedMessage by mutableStateOf(message)
        compose.setContent {
            DieterTheme {
                Surface(Modifier.fillMaxSize()) {
                    Column(Modifier.safeDrawingPadding().verticalScroll(rememberScrollState()).padding(16.dp)) {
                        MessageParts(presentedMessage, model, showReasoningTraces = false)
                    }
                }
            }
        }
        compose.onNodeWithText("Step 0").assertDoesNotExist()
        compose.onNodeWithText("Step 339").performScrollTo().assertIsDisplayed()
        capture("long-message-tail.png")
        compose.onAllNodesWithContentDescription("Expand tool activity")[5].performScrollTo().performClick()
        compose.onNodeWithContentDescription("Collapse tool activity").assertExists()
        compose.onNodeWithTag("message-earlier-long").performScrollTo().performClick()
        compose.onNodeWithText("Step 328").performScrollTo().assertIsDisplayed()
        compose.onNodeWithContentDescription("Collapse tool activity").assertExists()
        compose.onNodeWithText("Step 0").assertDoesNotExist()
        capture("long-message-earlier.png")
        compose.runOnUiThread {
            presentedMessage = message.toBuilder().clearParts()
                .addParts(MessagePart.newBuilder().setType("text").setText("Refreshed shorter message"))
                .build()
        }
        compose.onNodeWithText("Refreshed shorter message").performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag("message-earlier-long").assertDoesNotExist()
    }

    private fun capture(name: String) {
        val file = File(context.getExternalFilesDir(null), name)
        file.outputStream().use { output ->
            assertTrue(compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, output))
        }
    }
}
