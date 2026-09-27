package com.dbpprt.dieter.ui

import android.graphics.Bitmap
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.gateway.v1.*
import com.dbpprt.dieter.ui.theme.DieterTheme
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.time.Instant

class ProviderQuotaUiTest {
    @get:Rule val compose = createComposeRule()
    private val provider = ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX
    private val account = ProviderQuotaSnapshot.newBuilder().setAccountKey("personal").setProvider(provider)
        .setDisplayEmail("alex@example.com").setPlan("pro")
        .setAvailability(ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_AVAILABLE)
        .setResetCredits(ProviderResetCredits.newBuilder().setAvailableCount(2))
        .addWindows(ProviderQuotaWindow.newBuilder().setLabel("5-hour").setRemainingPercent(76)
            .setResetsAt(Instant.now().plusSeconds(8100).toString()))
        .addWindows(ProviderQuotaWindow.newBuilder().setLabel("Weekly").setRemainingPercent(42)
            .setResetsAt(Instant.now().plusSeconds(183600).toString())).build()
    private fun state(accounts: List<ProviderQuotaSnapshot> = listOf(account)): DieterUiState {
        val included = accounts.filter { !it.hasIncludedInSummary() || it.includedInSummary }
        val summary = ProviderQuotaSummary.newBuilder().setIncludedAccountCount(included.size)
            .setExcludedAccountCount(accounts.size - included.size)
        included.flatMap { it.windowsList }.filter { it.hasRemainingPercent() }.minOfOrNull { it.remainingPercent }
            ?.let { summary.remainingPercent = it }
        return DieterUiState(providerQuotaGroups = listOf(ProviderQuotaGroup.newBuilder().setProvider(provider)
            .addAllAccounts(accounts).setSummary(summary).build()))
    }

    @Test fun compactAccountsExpandAndKeepMutationsAccountScoped() {
        val current = mutableStateOf(state())
        val inclusions = mutableListOf<Triple<ProviderQuotaProvider, String, Boolean>>()
        val resets = mutableListOf<String>()
        var refreshes = 0
        compose.setContent { DieterTheme(darkTheme = true) {
            Surface {
                ProviderQuotaDetails(current.value, { refreshes++ }, { provider, key, included ->
                    inclusions += Triple(provider, key, included)
                    current.value = state(listOf(account.toBuilder().setIncludedInSummary(included).build()))
                }, { resets += it }, Modifier.fillMaxSize().padding(20.dp))
            }
        } }
        compose.onNodeWithTag("provider-quotas-refresh").performClick()
        compose.runOnIdle { assertEquals(1, refreshes) }
        compose.onNodeWithTag("provider-quotas-include-personal").assertDoesNotExist()
        compose.onNodeWithText("76%").assertIsDisplayed()
        compose.onNodeWithText("42%").assertIsDisplayed()
        val compactBounds = compose.onNodeWithTag("provider-quotas-account-personal").getUnclippedBoundsInRoot()
        val compactHeight = compactBounds.bottom - compactBounds.top
        assertTrue("Two windows should fit in a compact account card", compactHeight < 220.dp)
        compose.onNodeWithTag("provider-quotas-details-personal").performClick()
        compose.onNodeWithTag("provider-quotas-include-personal").performClick()
        compose.runOnIdle { assertEquals(listOf(Triple(provider, "personal", false)), inclusions) }
        compose.onNodeWithText("Pro · Excluded from summary").assertIsDisplayed()
        compose.onNodeWithTag("provider-quotas-reset-personal").performClick()
        compose.onNodeWithText("Cancel").performClick()
        compose.runOnIdle { assertTrue(resets.isEmpty()) }
        compose.onNodeWithTag("provider-quotas-reset-personal").performClick()
        compose.onNodeWithText("Use reset credit", substring = false).performClick()
        compose.runOnIdle {
            assertEquals(listOf("personal"), resets)
            current.value = current.value.copy(providerQuotaMutatingAccounts = setOf("personal"))
        }
        compose.onNodeWithTag("provider-quotas-include-personal").assertIsNotEnabled()
        compose.onNodeWithTag("provider-quotas-reset-personal").assertIsNotEnabled()
    }

    @Test fun phoneLightLargeTextAndTabletKeepEveryAccountReachable() {
        val dark = mutableStateOf(true)
        val scale = mutableStateOf(1f)
        val tablet = mutableStateOf(false)
        val accounts = listOf(account,
            account.toBuilder().setAccountKey("work").setDisplayEmail("alex@studio.design").setPlan("team")
                .clearWindows()
                .addWindows(ProviderQuotaWindow.newBuilder().setLabel("5-hour").setRemainingPercent(93))
                .addWindows(ProviderQuotaWindow.newBuilder().setLabel("Weekly").setRemainingPercent(8)).build(),
            account.toBuilder().setAccountKey("long").setDisplayEmail("a.very.long.account.name@a-long-example-domain.com")
                .setIncludedInSummary(false).clearWindows()
                .setAvailability(ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_SIGNED_OUT).build())
        val claude = ProviderQuotaGroup.newBuilder().setProvider(ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE)
            .addAccounts(account.toBuilder().setAccountKey("claude").setDisplayEmail("").setPlan("max")
                .clearWindows().clearResetCredits()
                .addWindows(ProviderQuotaWindow.newBuilder().setLabel("Session").setRemainingPercent(65))
                .addWindows(ProviderQuotaWindow.newBuilder().setLabel("Weekly · All models"))).build()
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(if (tablet.value) 1f else density.density, scale.value)) {
                DieterTheme(darkTheme = dark.value) { Surface {
                    ProviderQuotaDetails(state(accounts).copy(providerQuotaGroups = state(accounts).providerQuotaGroups + claude),
                        {}, { _, _, _ -> }, {}, Modifier.fillMaxSize().padding(20.dp))
                } }
            }
        }
        capture("usage-phone-dark.png")
        compose.onNodeWithTag("provider-quotas-account-work").assertIsDisplayed()
        compose.runOnIdle { dark.value = false }
        capture("usage-phone-light.png")
        compose.runOnIdle { scale.value = 1.6f }
        compose.onNodeWithTag("provider-quotas-list").performScrollToNode(hasTestTag("provider-quotas-details-long"))
        compose.onNodeWithTag("provider-quotas-details-long").performClick()
        compose.onNodeWithText("a.very.long.account.name@a-long-example-domain.com").assertIsDisplayed()
        capture("usage-large-text.png")
        compose.onNodeWithTag("provider-quotas-list").performScrollToNode(hasText("Not reported"))
        compose.onNodeWithText("Not reported").assertIsDisplayed()
        compose.onNodeWithText("0%").assertDoesNotExist()
        compose.runOnIdle { dark.value = true; scale.value = 1f; tablet.value = true }
        compose.onNodeWithTag("provider-quotas-list").performScrollToIndex(0)
        val first = compose.onNodeWithTag("provider-quotas-account-personal").getUnclippedBoundsInRoot()
        val second = compose.onNodeWithTag("provider-quotas-account-work").getUnclippedBoundsInRoot()
        assertEquals("Tablet accounts share a row", first.top.value, second.top.value, 1f)
        assertTrue("Tablet uses additional columns", second.left > first.left)
        capture("usage-tablet.png")
    }

    @Test fun loadingAndFailedRefreshNeverBecomeZeroUsage() {
        val current = mutableStateOf(DieterUiState(providerQuotasLoading = true))
        compose.setContent { DieterTheme { Surface {
            ProviderQuotaDetails(current.value, {}, { _, _, _ -> }, {}, Modifier.fillMaxSize().padding(20.dp))
        } } }
        compose.onNodeWithText("Loading usage…").assertIsDisplayed()
        compose.onNodeWithTag("provider-quotas-refresh").assertIsNotEnabled()
        compose.onNodeWithText("No provider accounts").assertDoesNotExist()
        compose.runOnIdle { current.value = state().copy(providerQuotaError = "Unable to refresh usage") }
        compose.onNodeWithText("Unable to refresh usage").assertIsDisplayed()
        compose.onNodeWithText("76%").assertIsDisplayed()
        compose.onNodeWithTag("provider-quotas-refresh").assertIsEnabled()
        compose.runOnIdle { current.value = DieterUiState() }
        compose.onNodeWithText("No provider accounts").assertIsDisplayed()
        compose.onNodeWithText("0%").assertDoesNotExist()
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        val directory = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "usage-evidence").apply { mkdirs() }
        File(directory, name).outputStream().use {
            compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it)
        }
    }
}
