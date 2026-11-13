package com.getdieter.android.folders

import com.getdieter.core.folders.FolderConditions
import com.getdieter.core.folders.FolderNetwork
import com.getdieter.core.folders.FolderScheduleRequest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.minutes

/** The core's schedule request as WorkManager constraints, and the platform's readings. */
class FolderSchedulingTest {
    private val request =
        FolderScheduleRequest(
            interval = 1.hours,
            unmeteredOnly = true,
            notRoaming = true,
            requiresCharging = false,
            batteryNotLow = true,
            storageNotLow = true,
        )

    @Test
    fun theRequestMapsToWorkManagersPeriodAndConstraints() {
        assertEquals(
            FolderWorkSpec(60, 15, FolderWorkSpec.Network.UNMETERED, false, true, true),
            FolderWorkSpec.of(request),
        )
        // Any network but never roaming; WorkManager's 15 minute floor.
        assertEquals(
            FolderWorkSpec(15, 5, FolderWorkSpec.Network.NOT_ROAMING, true, false, false),
            FolderWorkSpec.of(
                request.copy(
                    interval = 5.minutes,
                    unmeteredOnly = false,
                    requiresCharging = true,
                    batteryNotLow = false,
                    storageNotLow = false,
                )
            ),
        )
        assertEquals(
            FolderWorkSpec.Network.CONNECTED,
            FolderWorkSpec.of(request.copy(unmeteredOnly = false, notRoaming = false)).network,
        )
        assertEquals(360, FolderWorkSpec.of(request.copy(interval = 24.hours)).flexMinutes)
    }

    private val wifi =
        NetworkState(internet = true, notMetered = true, notRoaming = true, dataSaver = false)
    private val battery = PowerState(plugged = false, level = 41, scale = 50, saver = false)

    @Test
    fun readingsMapToTheCoresConditions() {
        assertEquals(
            FolderConditions(
                network = FolderNetwork.UNMETERED,
                roaming = false,
                dataSaver = false,
                charging = false,
                batteryPercent = 82,
                powerSaver = false,
            ),
            FolderConditionsMapping.map(wifi, battery),
        )
        val roamingCellular =
            FolderConditionsMapping.map(
                wifi.copy(notMetered = false, notRoaming = false, dataSaver = true),
                battery.copy(plugged = true, saver = true),
            )
        assertEquals(FolderNetwork.METERED, roamingCellular.network)
        assertEquals(true, roamingCellular.roaming)
        assertEquals(true, roamingCellular.dataSaver)
        assertEquals(true, roamingCellular.charging)
        assertEquals(true, roamingCellular.powerSaver)
        // Roaming on Wi-Fi costs nothing; no internet is no network.
        assertEquals(
            false,
            FolderConditionsMapping.map(wifi.copy(notRoaming = false), battery).roaming,
        )
        assertEquals(
            FolderNetwork.NONE,
            FolderConditionsMapping.map(wifi.copy(internet = false), battery).network,
        )
        assertEquals(-1, FolderConditionsMapping.map(wifi, battery.copy(level = -1)).batteryPercent)
    }
}
