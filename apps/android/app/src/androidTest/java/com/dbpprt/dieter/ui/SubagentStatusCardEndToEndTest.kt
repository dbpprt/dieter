package com.dbpprt.dieter.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.e2e.Evidence
import com.dbpprt.dieter.api.v1.Subagent
import org.junit.Rule
import org.junit.Test

class SubagentStatusCardEndToEndTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun dedicatedCardShowsOverviewAndExpandsOperationalDetails() {
        val subagent = Subagent(id = "route-auditor", name = "task", agent_type = "task", agent_source = "delegate", provider = "omp", model = "tailscale/glm-5.3-flash-exl3", task = "Read the remaining routes", assignment = "Trace every remaining route and report the request flow back to the main agent.", description = "Inspect route registration, handlers, and their tests.", status = "running", activity = "Reading the remaining route handlers", current_tool = "functions.exec", current_tool_args = "{\"cmd\":\"rg -n 'route' internal\"}", tool_count = 7, requests = 3, tokens = 1_288_847, context_tokens = 128_953, context_window = 1_000_000, cost = 0.423, duration_ms = 85_000, recent_output = listOf("Found the route table in internal/server.", "Mapping handlers to the request flow now."), transcript_available = true)

        composeRule.setContent {
            DieterTheme(darkTheme = true) {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    LazyColumn(
                        Modifier.safeDrawingPadding().padding(18.dp),
                        verticalArrangement = Arrangement.spacedBy(14.dp),
                    ) {
                        item { Text("Subagent details", style = MaterialTheme.typography.titleLarge) }
                        item { SubagentStatusCard(subagent) }
                    }
                }
            }
        }

        composeRule.onNodeWithText("Read the remaining routes").assertIsDisplayed()
        composeRule.onNodeWithText("Trace every remaining route", substring = true).assertIsDisplayed()
        composeRule.onNodeWithText("Reading the remaining route handlers", substring = true).assertIsDisplayed()
        composeRule.onNodeWithText("7 tool calls", substring = true).assertIsDisplayed()
        composeRule.onNodeWithText("129k / 1.0M context (13%)", substring = true).assertIsDisplayed()
        capture("subagent-card-overview.png")

        composeRule.onNodeWithTag("subagent-details-route-auditor").performClick()
        composeRule.onNodeWithText("CURRENT TOOL").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithText("functions.exec", substring = true).assertIsDisplayed()
        composeRule.onNodeWithText("RECENT OUTPUT").performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithText("Mapping handlers to the request flow now.", substring = true).assertIsDisplayed()
        capture("subagent-card-expanded.png")
    }

    private fun capture(name: String) {
        composeRule.waitForIdle()
        Evidence.display(name)
    }
}
