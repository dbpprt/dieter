package com.getdieter.core.folders

import com.getdieter.core.v1.FolderBackgroundSync
import com.getdieter.core.v1.FolderDeviceSettings
import com.getdieter.core.v1.FolderDirection
import com.getdieter.core.v1.FolderLocalSettings
import com.getdieter.core.v1.FolderNetworkPolicy
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Instant

class FolderSyncPolicyTest {
    private val defaults = FolderSettings.DEFAULTS
    private val wifi =
        FolderConditions(network = FolderNetwork.UNMETERED, charging = false, batteryPercent = 80)
    private val cellular = wifi.copy(network = FolderNetwork.METERED)

    private fun decide(
        device: FolderDeviceSettings = defaults,
        folder: FolderLocalSettings? = null,
        conditions: FolderConditions = wifi,
        trigger: FolderTrigger = FolderTrigger.BACKGROUND,
        platform: String = "android",
    ) = FolderSyncPolicy.decide(device, folder, conditions, trigger, platform)

    private fun skip(decision: FolderRunDecision): FolderSkip? =
        (decision as? FolderRunDecision.Skip)?.skip

    @Test
    fun theDefaultsSyncOnWiFiAndWaitOnCellular() {
        assertEquals(FolderRunDecision.RunAll, decide())
        val waiting = assertIs<FolderRunDecision.Skip>(decide(conditions = cellular))
        assertEquals(FolderSkip.WAITING_FOR_WIFI, waiting.skip)
        assertEquals("Waiting for Wi-Fi", waiting.reason)
        assertEquals(
            FolderSkip.NO_NETWORK,
            skip(decide(conditions = wifi.copy(network = FolderNetwork.NONE))),
        )
    }

    @Test
    fun largeFilesWaitForWiFiOnCellular() {
        val device =
            defaults.copy(
                network = FolderNetworkPolicy.FOLDER_NETWORK_POLICY_ANY_LARGE_ON_UNMETERED
            )
        val small = assertIs<FolderRunDecision.SmallOnly>(decide(device, conditions = cellular))
        assertEquals(25 * FolderSettings.MB, small.maxBytes)
        assertEquals("Files over 25 MB wait for Wi-Fi", small.reason)
        assertEquals(FolderRunDecision.RunAll, decide(device))
    }

    @Test
    fun roamingDataSaverAndLowDataModeHoldBack() {
        val any = defaults.copy(network = FolderNetworkPolicy.FOLDER_NETWORK_POLICY_ANY)
        assertEquals(
            FolderSkip.ROAMING,
            skip(decide(any, conditions = cellular.copy(roaming = true))),
        )
        assertEquals(
            FolderRunDecision.RunAll,
            decide(any.copy(never_roaming = false), conditions = cellular.copy(roaming = true)),
        )
        // iOS has no roaming signal; the cellular choice covers it.
        assertEquals(
            FolderRunDecision.RunAll,
            decide(any, conditions = cellular.copy(roaming = true), platform = "ios"),
        )
        val saver =
            assertIs<FolderRunDecision.Skip>(
                decide(any, conditions = cellular.copy(dataSaver = true))
            )
        assertEquals("Paused: Data Saver", saver.reason)
        val lowData =
            assertIs<FolderRunDecision.Skip>(
                decide(any, conditions = wifi.copy(constrained = true), platform = "ios")
            )
        assertEquals("Paused: Low Data Mode", lowData.reason)
        assertEquals(
            FolderRunDecision.RunAll,
            decide(
                any.copy(respect_data_saver = false),
                conditions = cellular.copy(dataSaver = true),
            ),
        )
    }

    @Test
    fun powerRulesHoldBackAutomaticRunsButNotSyncNow() {
        val charging = defaults.copy(only_while_charging = true)
        assertEquals(FolderSkip.WAITING_FOR_CHARGING, skip(decide(charging)))
        assertEquals(
            FolderRunDecision.RunAll,
            decide(charging, conditions = wifi.copy(charging = true)),
        )
        assertEquals(FolderRunDecision.RunAll, decide(charging, trigger = FolderTrigger.MANUAL))
        val saver =
            assertIs<FolderRunDecision.Skip>(
                decide(conditions = wifi.copy(powerSaver = true), platform = "ios")
            )
        assertEquals("Paused: Low Power Mode", saver.reason)
        val low =
            assertIs<FolderRunDecision.Skip>(decide(conditions = wifi.copy(batteryPercent = 15)))
        assertEquals("Paused: battery below 20%", low.reason)
        assertEquals(
            FolderRunDecision.RunAll,
            decide(conditions = wifi.copy(batteryPercent = 15, charging = true)),
        )
        assertEquals(
            FolderRunDecision.RunAll,
            decide(
                defaults.copy(pause_below_percent = 0),
                conditions = wifi.copy(batteryPercent = 5),
            ),
        )
        assertEquals(FolderRunDecision.RunAll, decide(conditions = wifi.copy(batteryPercent = -1)))
    }

    @Test
    fun triggersFollowTheScheduleSettings() {
        val whileOpen =
            defaults.copy(background = FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_WHILE_OPEN)
        assertEquals(FolderSkip.NOT_SCHEDULED, skip(decide(whileOpen)))
        assertEquals(FolderRunDecision.RunAll, decide(whileOpen, trigger = FolderTrigger.OPENED))
        val manual = defaults.copy(background = FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_MANUAL)
        for (trigger in FolderTrigger.entries.filter { it != FolderTrigger.MANUAL }) assertEquals(
            FolderSkip.NOT_SCHEDULED,
            skip(decide(manual, trigger = trigger)),
            trigger.name,
        )
        assertEquals(FolderRunDecision.RunAll, decide(manual, trigger = FolderTrigger.MANUAL))
        assertEquals(
            FolderSkip.NOT_SCHEDULED,
            skip(decide(defaults.copy(live_sync = false), trigger = FolderTrigger.LIVE)),
        )
        assertEquals(
            FolderSkip.NOT_SCHEDULED,
            skip(
                decide(
                    defaults.copy(upload_right_away = false),
                    trigger = FolderTrigger.LOCAL_CHANGE,
                )
            ),
        )
        assertEquals(
            FolderSkip.NOT_SCHEDULED,
            skip(decide(defaults.copy(sync_when_opened = false), trigger = FolderTrigger.OPENED)),
        )
    }

    @Test
    fun folderOverridesWin() {
        val any =
            FolderLocalSettings(
                folder_id = "f",
                network = FolderNetworkPolicy.FOLDER_NETWORK_POLICY_ANY,
            )
        assertEquals(FolderRunDecision.RunAll, decide(folder = any, conditions = cellular))
        val paused =
            FolderLocalSettings(
                folder_id = "f",
                direction = FolderDirection.FOLDER_DIRECTION_PAUSED,
            )
        assertEquals(
            FolderSkip.PAUSED,
            skip(decide(folder = paused, trigger = FolderTrigger.MANUAL)),
        )
        assertEquals(
            FolderSkip.SYNC_OFF,
            skip(decide(defaults.copy(enabled = false), trigger = FolderTrigger.MANUAL)),
        )
    }

    /** Every combination of the settings and conditions keeps the rules' invariants. */
    @Test
    fun theFullMatrixKeepsItsInvariants() {
        var cases = 0
        for (enabled in listOf(true, false)) for (background in
            FolderBackgroundSync.entries.drop(1)) for (network in
            FolderNetworkPolicy.entries.drop(1)) for (charging in
            listOf(true, false)) for (onlyCharging in listOf(true, false)) for (saver in
            listOf(true, false)) for (pauseInSaver in listOf(true, false)) for (battery in
            listOf(5, 25, 90)) for (pauseBelow in listOf(0, 20)) for (kind in
            FolderNetwork.entries) for (roaming in listOf(true, false)) for (dataSaver in
            listOf(true, false)) for (trigger in FolderTrigger.entries) {
            val device =
                defaults.copy(
                    enabled = enabled,
                    background = background,
                    network = network,
                    only_while_charging = onlyCharging,
                    pause_in_power_saver = pauseInSaver,
                    pause_below_percent = pauseBelow,
                )
            val conditions =
                FolderConditions(kind, roaming, false, dataSaver, charging, battery, saver)
            val decision = decide(device, conditions = conditions, trigger = trigger)
            cases++
            val label = "$device $conditions $trigger"
            if (!enabled) assertEquals(FolderSkip.SYNC_OFF, skip(decision), label)
            if (kind == FolderNetwork.NONE && enabled && skip(decision) != FolderSkip.NOT_SCHEDULED)
                assertEquals(FolderSkip.NO_NETWORK, skip(decision), label)
            if (decision !is FolderRunDecision.Skip) {
                assertTrue(enabled, label)
                assertTrue(kind != FolderNetwork.NONE, label)
                if (kind == FolderNetwork.METERED) {
                    assertTrue(
                        network != FolderNetworkPolicy.FOLDER_NETWORK_POLICY_UNMETERED,
                        label,
                    )
                    assertTrue(!roaming && !dataSaver, label)
                }
                if (trigger != FolderTrigger.MANUAL) {
                    assertTrue(!onlyCharging || charging, label)
                    assertTrue(!(pauseInSaver && saver), label)
                    assertTrue(pauseBelow == 0 || charging || battery >= pauseBelow, label)
                }
                if (trigger == FolderTrigger.BACKGROUND)
                    assertEquals(
                        FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_INTERVAL,
                        background,
                        label,
                    )
                if (background == FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_MANUAL)
                    assertEquals(FolderTrigger.MANUAL, trigger, label)
            }
            if (decision is FolderRunDecision.SmallOnly) {
                assertEquals(FolderNetwork.METERED, kind, label)
                assertEquals(
                    FolderNetworkPolicy.FOLDER_NETWORK_POLICY_ANY_LARGE_ON_UNMETERED,
                    network,
                    label,
                )
            }
            if (decision is FolderRunDecision.Skip) assertTrue(decision.reason.isNotBlank(), label)
        }
        assertTrue(cases > 10_000)
    }

    @Test
    fun storageLimitsDownloadsButNotTaps() {
        val device = defaults.copy(storage_limit_bytes = 1000, keep_free_bytes = 100)
        assertTrue(FolderSyncPolicy.fitsStorage(device, 500, 10_000, 400))
        assertTrue(!FolderSyncPolicy.fitsStorage(device, 900, 10_000, 200))
        assertTrue(FolderSyncPolicy.fitsStorage(device, 900, 10_000, 200, onDemand = true))
        assertTrue(!FolderSyncPolicy.fitsStorage(device, 0, 250, 200, onDemand = true))
        assertTrue(
            FolderSyncPolicy.fitsStorage(
                defaults.copy(storage_limit_bytes = 0, keep_free_bytes = 0),
                Long.MAX_VALUE / 4,
                0,
                10,
            )
        )
    }

    @Test
    fun theScheduleUsesTheShortestActiveInterval() {
        val folders =
            listOf(
                FolderLocalSettings(folder_id = "inbox", interval_minutes = 15),
                FolderLocalSettings(folder_id = "archive", interval_minutes = 1440),
                FolderLocalSettings(
                    folder_id = "paused",
                    interval_minutes = 1,
                    direction = FolderDirection.FOLDER_DIRECTION_PAUSED,
                ),
            )
        val request = FolderSyncPolicy.schedule(defaults, folders)!!
        assertEquals(15.minutes, request.interval)
        assertTrue(request.unmeteredOnly)
        assertTrue(request.notRoaming)
        assertTrue(request.batteryNotLow)
        assertTrue(request.storageNotLow)
        assertNull(FolderSyncPolicy.schedule(defaults, emptyList()))
        assertNull(FolderSyncPolicy.schedule(defaults.copy(enabled = false), folders))
        assertNull(
            FolderSyncPolicy.schedule(
                defaults.copy(background = FolderBackgroundSync.FOLDER_BACKGROUND_SYNC_WHILE_OPEN),
                folders,
            )
        )
        val anyNetwork =
            listOf(
                FolderLocalSettings(
                    folder_id = "a",
                    network = FolderNetworkPolicy.FOLDER_NETWORK_POLICY_ANY,
                )
            )
        assertTrue(!FolderSyncPolicy.schedule(defaults, anyNetwork)!!.unmeteredOnly)
        val last = Instant.parse("2026-11-13T10:00:00Z")
        assertEquals(
            Instant.parse("2026-11-13T11:00:00Z"),
            FolderSyncPolicy.nextSync(
                defaults,
                listOf(FolderLocalSettings(folder_id = "a")),
                last,
                last,
            ),
        )
    }
}
