package com.getdieter.android.folders

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import com.getdieter.core.folders.DeviceConditions
import com.getdieter.core.folders.FolderConditions
import com.getdieter.core.folders.FolderNetwork

/**
 * The network and power state folder sync's policy reads: ConnectivityManager's capabilities of the
 * active network (internet, not metered, not roaming), Data Saver, BatteryManager and Battery
 * Saver.
 */
class AndroidDeviceConditions(private val context: Context) : DeviceConditions {
    override fun current(): FolderConditions {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val capabilities = connectivity?.let { manager ->
            runCatching { manager.getNetworkCapabilities(manager.activeNetwork) }.getOrNull()
        }
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val plugged = battery?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        val status = battery?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        return FolderConditionsMapping.map(
            NetworkState(
                internet =
                    capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) ==
                        true,
                notMetered =
                    capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) ==
                        true ||
                        (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                            capabilities?.hasCapability(
                                NetworkCapabilities.NET_CAPABILITY_TEMPORARILY_NOT_METERED
                            ) == true),
                notRoaming =
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
                        capabilities?.hasCapability(
                            NetworkCapabilities.NET_CAPABILITY_NOT_ROAMING
                        ) != false
                    else
                        @Suppress("DEPRECATION") connectivity?.activeNetworkInfo?.isRoaming != true,
                dataSaver =
                    connectivity?.restrictBackgroundStatus ==
                        ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED,
            ),
            PowerState(
                plugged = plugged != 0 || status == BatteryManager.BATTERY_STATUS_FULL,
                level = level,
                scale = scale,
                saver = context.getSystemService(PowerManager::class.java)?.isPowerSaveMode == true,
            ),
        )
    }
}

/** What ConnectivityManager reports about the active network. */
data class NetworkState(
    val internet: Boolean,
    val notMetered: Boolean,
    val notRoaming: Boolean,
    val dataSaver: Boolean,
)

/** What BatteryManager and PowerManager report. */
data class PowerState(val plugged: Boolean, val level: Int, val scale: Int, val saver: Boolean)

/** The platform readings as the core's conditions; pure, so the shell's tests cover it. */
object FolderConditionsMapping {
    fun map(network: NetworkState, power: PowerState): FolderConditions =
        FolderConditions(
            network =
                when {
                    !network.internet -> FolderNetwork.NONE
                    network.notMetered -> FolderNetwork.UNMETERED
                    else -> FolderNetwork.METERED
                },
            // Roaming only costs on a metered network.
            roaming = network.internet && !network.notMetered && !network.notRoaming,
            dataSaver = network.dataSaver,
            charging = power.plugged,
            batteryPercent =
                if (power.level < 0 || power.scale <= 0) -1
                else (power.level * 100 / power.scale).coerceIn(0, 100),
            powerSaver = power.saver,
        )
}
