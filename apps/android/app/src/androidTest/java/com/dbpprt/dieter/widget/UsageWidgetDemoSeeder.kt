package com.dbpprt.dieter.widget

import android.appwidget.AppWidgetHost
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.os.Bundle
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaAvailability
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaGroup
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaProvider
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaSnapshot
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaWindow
import org.junit.Test
import org.junit.runner.RunWith
import java.time.Instant

/**
 * Not a regression test: dev tooling that seeds the usage widget cache with
 * realistic provider accounts and pins both variants on the launcher, so the
 * home-screen rendering can be inspected without a live gateway.
 */
@RunWith(AndroidJUnit4::class)
class UsageWidgetDemoSeeder {
    @Test
    fun seedAndPin() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val now = Instant.now()
        fun window(label: String, remaining: Int, hours: Long) = ProviderQuotaWindow(
            label = label,
            remaining_percent = remaining,
            resets_at = now.plusSeconds(hours * 3600).toString(),
        )
        val snapshots = usageSnapshots(listOf(
            ProviderQuotaGroup(
                provider = ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE,
                accounts = listOf(
                    ProviderQuotaSnapshot(
                        provider = ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE,
                        account_key = "demo-claude",
                        display_email = "alex@example.com",
                        plan = "max",
                        availability = ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_AVAILABLE,
                        fresh_until = now.plusSeconds(3600).toString(),
                        windows = listOf(window("Session", 61, 3), window("Weekly · All models", 42, 96)),
                    ),
                    ProviderQuotaSnapshot(
                        provider = ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE,
                        account_key = "demo-claude-work",
                        display_email = "alex@work.example.com",
                        plan = "team",
                        availability = ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_SIGNED_OUT,
                        fresh_until = now.plusSeconds(3600).toString(),
                        windows = listOf(window("Weekly", 15, 96)),
                    ),
                ),
            ),
            ProviderQuotaGroup(
                provider = ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX,
                accounts = listOf(
                    ProviderQuotaSnapshot(
                        provider = ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX,
                        account_key = "demo-codex",
                        display_email = "alex@example.com",
                        plan = "plus",
                        availability = ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_AVAILABLE,
                        fresh_until = now.plusSeconds(3600).toString(),
                        windows = listOf(window("Daily", 8, 12), window("Weekly", 55, 96)),
                    ),
                ),
            ),
        ))
        WidgetUsagePrefs.saveCache(context, snapshots, now.minusSeconds(120).toEpochMilli())
        val manager = AppWidgetManager.getInstance(context)
        // Bind through a host so verification does not depend on the
        // launcher's pin-confirmation dialog timing.
        val host = AppWidgetHost(context, 261011)
        val largeId = host.allocateAppWidgetId()
        val smallId = host.allocateAppWidgetId()
        check(manager.bindAppWidgetIdIfAllowed(largeId,
            ComponentName(context, DieterUsageWidgetProvider::class.java))) { "Bind large usage widget" }
        check(manager.bindAppWidgetIdIfAllowed(smallId,
            ComponentName(context, DieterUsageSmallWidgetProvider::class.java))) { "Bind small usage widget" }
        host.startListening()
        manager.updateAppWidgetOptions(largeId, Bundle().apply {
            putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 360)
            putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 320)
        })
        manager.updateAppWidgetOptions(smallId, Bundle().apply {
            putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 140)
            putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 140)
        })
        DieterUsageWidgetProvider.render(context, manager, largeId)
        DieterUsageWidgetProvider.render(context, manager, smallId, pinnedSmall = true)
        Thread.sleep(2_000)
        host.stopListening()
    }
}
