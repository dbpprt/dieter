package com.dbpprt.dieter.ui

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import com.dbpprt.dieter.connection.EndpointConnection
import com.dbpprt.dieter.connection.EndpointPhase
import com.dbpprt.dieter.data.DIETER_API_VERSION
import com.dbpprt.dieter.ui.theme.DieterTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class ProjectHostPickerTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun pickerSelectsOnlyOnlineCompatibleDaemonHosts() {
        var selected = "machine-a"
        val machines = listOf(
            EndpointConnection(
                id = "machine-a",
                label = "Studio",
                address = "https://gateway.test",
                phase = EndpointPhase.CONNECTED,
                online = true,
                daemonId = "daemon-a",
                apiVersion = DIETER_API_VERSION,
            ),
            EndpointConnection(
                id = "machine-b",
                label = "Laptop",
                address = "https://gateway.test",
                online = true,
                daemonId = "daemon-b",
                apiVersion = DIETER_API_VERSION,
            ),
            EndpointConnection(
                id = "machine-old",
                label = "Old machine",
                address = "https://gateway.test",
                online = true,
                daemonId = "daemon-old",
                apiVersion = "1",
            ),
        )

        composeRule.setContent {
            DieterTheme { ProjectHostPicker(machines, selectedId = selected, onSelected = { selected = it }) }
        }

        composeRule.onNodeWithText("Studio").assertIsDisplayed()
        composeRule.onNodeWithTag("new-project-machine").performClick()
        composeRule.onNodeWithTag("new-project-machine-machine-old").assertIsNotEnabled()
        composeRule.onNodeWithTag("new-project-machine-machine-b").performClick()
        assertEquals("machine-b", selected)
    }
}
