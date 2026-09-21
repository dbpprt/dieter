package com.dbpprt.dieter.ui

import android.Manifest
import android.graphics.Bitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import com.dbpprt.dieter.DieterApplication
import com.dbpprt.dieter.MainActivity
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.data.DieterEndpoint
import com.dbpprt.dieter.data.dieterEndpointFromAddress
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.RuleChain
import java.io.File

/** Visible Activity → authenticated isolated gateway → machine telemetry and safe operation coverage. */
class MachinesEndToEndTest {
    private val compose = createAndroidComposeRule<MainActivity>()
    @get:Rule val rules: RuleChain = RuleChain
        .outerRule(GrantPermissionRule.grant(Manifest.permission.POST_NOTIFICATIONS))
        .around(compose)

    @Test fun machineFleetOpensLiveTelemetryAndAcceptsFixtureUpdate() {
        val args = InstrumentationRegistry.getArguments()
        val token = args.getString("isolatedGatewayToken").orEmpty()
        val daemonId = args.getString("isolatedMachineId").orEmpty()
        assumeTrue("Requires the isolated machine fixture", token.isNotBlank() && daemonId.isNotBlank())
        val origin = DieterEndpoint(
            id = "machines_isolated_${args.getString("isolatedGatewayPort")}",
            label = "Machines test gateway",
            host = "127.0.0.1",
            port = args.getString("isolatedGatewayPort")!!.toInt(),
            secure = false,
        )
        val container = (compose.activity.application as DieterApplication).container
        val repository = container.repository
        val manager = container.connectionManager
        val previous = manager.state.value
        val endpoints = previous.configuredConnections.map {
            dieterEndpointFromAddress(it.id, it.label, it.address)
        }
        repository.setAccessToken(origin, token)
        try {
            manager.updateEndpoints(listOf(origin), selectedGatewayId = origin.id)
            manager.connect()
            manager.onAppForegrounded()
            val connected = runBlocking {
                withTimeout(30_000) {
                    manager.state.first { state ->
                        state.phase == ConnectionPhase.CONNECTED &&
                            state.endpointConnections.any { it.daemonId == daemonId && it.online }
                    }
                }
            }
            val endpoint = connected.endpointConnections.first { it.daemonId == daemonId }
            compose.onNodeWithTag("nav-tools").performClick()
            compose.onNodeWithTag("tool-machines").assertIsDisplayed().assertIsEnabled().performClick()
            compose.waitUntil(20_000) {
                compose.onAllNodesWithTag("machine-row-${endpoint.id}").fetchSemanticsNodes().isNotEmpty()
            }
            compose.waitUntil(20_000) {
                compose.onAllNodesWithText("1/2 reporting").fetchSemanticsNodes().isNotEmpty()
            }
            capture("machines-fleet-e2e.png")
            compose.onNodeWithTag("machine-row-${endpoint.id}").performClick()
            compose.waitUntil(30_000) {
                compose.onAllNodesWithTag("machine-cpu").fetchSemanticsNodes().isNotEmpty()
            }
            compose.onNodeWithTag("machine-cpu").assertIsDisplayed()
            compose.onNodeWithTag("machine-memory").assertIsDisplayed()
            capture("machine-telemetry-e2e.png")
            compose.onNodeWithTag("machine-detail").performScrollToNode(hasTestTag("machine-processes"))
            compose.onNodeWithTag("machine-processes").assertIsDisplayed()

            val information = runBlocking { repository.machineInformationOn(endpoint.id) }
            assertTrue("Fixture host identity must be present", information.hostname.isNotBlank() && information.osName.isNotBlank())
            assertTrue("Fixture telemetry must be complete", information.logicalCpuCount > 0 && information.memoryTotalBytes > 0)
            assertTrue("Fixture daemon process must be visible", information.processesList.any { it.kind == "daemon" })

            compose.onNodeWithTag("machine-detail").performScrollToNode(hasTestTag("machine-actions"))
            compose.onNodeWithTag("machine-actions").performClick()
            compose.onNodeWithTag("machine-action-update").assertIsEnabled().performClick()
            compose.onNodeWithTag("machine-operation-confirm").performClick()
            compose.waitUntil(15_000) {
                compose.onAllNodesWithTag("machine-operation-result").fetchSemanticsNodes().isNotEmpty()
            }
            capture("machine-operation-accepted-e2e.png")
            compose.onNodeWithTag("machine-operation-result").performClick()
        } finally {
            repository.setAccessToken(origin, null)
            manager.updateEndpoints(endpoints, selectedGatewayId = previous.activeGatewayId)
            if (previous.desiredConnected) manager.connect() else manager.disconnect()
        }
    }

    private fun capture(name: String) {
        val args = InstrumentationRegistry.getArguments()
        val directory = args.getString("additionalTestOutputDir")
            ?.takeIf(String::isNotBlank)
            ?.let(::File)
            ?: requireNotNull(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null))
        directory.mkdirs()
        File(directory, name).outputStream().use { stream ->
            compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, stream)
        }
    }
}
