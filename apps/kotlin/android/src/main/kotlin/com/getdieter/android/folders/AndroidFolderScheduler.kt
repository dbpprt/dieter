package com.getdieter.android.folders

import android.app.job.JobInfo
import android.app.job.JobScheduler
import android.content.ComponentName
import android.content.Context
import android.os.Build
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import com.getdieter.core.folders.FolderScheduleRequest
import com.getdieter.core.folders.FolderScheduler
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** How a periodic window's request reads as WorkManager constraints; pure, so tests cover it. */
data class FolderWorkSpec(
    val periodMinutes: Long,
    val flexMinutes: Long,
    val network: Network,
    val requiresCharging: Boolean,
    val batteryNotLow: Boolean,
    val storageNotLow: Boolean,
) {
    enum class Network {
        CONNECTED,
        UNMETERED,
        NOT_ROAMING,
    }

    companion object {
        /** WorkManager's shortest period. */
        const val MINIMUM_MINUTES = 15L

        fun of(request: FolderScheduleRequest): FolderWorkSpec {
            val period = request.interval.inWholeMinutes.coerceAtLeast(MINIMUM_MINUTES)
            return FolderWorkSpec(
                periodMinutes = period,
                // Let the system batch the run within the last quarter of the period.
                flexMinutes = (period / 4).coerceIn(5, period),
                network =
                    when {
                        request.unmeteredOnly -> Network.UNMETERED
                        request.notRoaming -> Network.NOT_ROAMING
                        else -> Network.CONNECTED
                    },
                requiresCharging = request.requiresCharging,
                batteryNotLow = request.batteryNotLow,
                storageNotLow = request.storageNotLow,
            )
        }
    }
}

/**
 * Folder sync's background hosts on Android. The periodic window is unique WorkManager periodic
 * work at the requested interval (15 minutes or more) with the request's constraints, updated in
 * place when settings change and cancelled when no folder is on this device. A longer run is a
 * user-initiated data transfer job on Android 14+ after Sync now, and otherwise expedited work that
 * promotes itself to a `dataSync` foreground service where the system allows it.
 */
class AndroidFolderScheduler(context: Context) : FolderScheduler {
    private val context = context.applicationContext
    @Volatile private var scheduled: FolderWorkSpec? = null

    private val work: WorkManager
        get() = WorkManager.getInstance(context)

    override fun schedule(request: FolderScheduleRequest) {
        val spec = FolderWorkSpec.of(request)
        // Every window reschedules; only a change touches WorkManager.
        if (spec == scheduled) return
        scheduled = spec
        FolderLongRuns.unmeteredOnly = spec.network == FolderWorkSpec.Network.UNMETERED
        work.enqueueUniquePeriodicWork(
            PERIODIC,
            ExistingPeriodicWorkPolicy.UPDATE,
            PeriodicWorkRequestBuilder<FolderSyncWorker>(
                    spec.periodMinutes,
                    TimeUnit.MINUTES,
                    spec.flexMinutes,
                    TimeUnit.MINUTES,
                )
                .setConstraints(spec.constraints())
                .build(),
        )
    }

    override fun requestLongRun(userInitiated: Boolean) =
        FolderLongRuns.request(context, userInitiated)

    override fun cancel() {
        scheduled = null
        work.cancelUniqueWork(PERIODIC)
        work.cancelUniqueWork(FolderLongRuns.WORK)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
            context.getSystemService(JobScheduler::class.java)?.cancel(FolderLongRuns.JOB_ID)
    }

    companion object {
        const val PERIODIC = "folder-sync"
    }
}

internal fun FolderWorkSpec.constraints(): Constraints =
    Constraints.Builder()
        .setRequiredNetworkType(
            when (network) {
                FolderWorkSpec.Network.UNMETERED -> NetworkType.UNMETERED
                FolderWorkSpec.Network.NOT_ROAMING -> NetworkType.NOT_ROAMING
                FolderWorkSpec.Network.CONNECTED -> NetworkType.CONNECTED
            }
        )
        .setRequiresCharging(requiresCharging)
        .setRequiresBatteryNotLow(batteryNotLow)
        .setRequiresStorageNotLow(storageNotLow)
        .build()

/** Longer runs: one at a time, started after Sync now or when a window left work. */
object FolderLongRuns {
    const val WORK = "folder-transfer"
    /** Negative, so it never meets the IDs WorkManager gives its own jobs (0 and up). */
    const val JOB_ID = -0x0F01DE

    /** A long run is going; the windows it runs ask for more and must not replace it. */
    val active = AtomicBoolean(false)

    /** The periodic window's network constraint, which a long run keeps. */
    @Volatile var unmeteredOnly = true

    fun request(context: Context, userInitiated: Boolean) {
        if (active.get()) return
        if (userInitiated && Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val scheduler = context.getSystemService(JobScheduler::class.java)
            val job =
                JobInfo.Builder(
                        JOB_ID,
                        ComponentName(context, FolderTransferJobService::class.java),
                    )
                    .setUserInitiated(true)
                    .setRequiredNetworkType(
                        if (unmeteredOnly) JobInfo.NETWORK_TYPE_UNMETERED
                        else JobInfo.NETWORK_TYPE_ANY
                    )
                    .build()
            // Only possible while Dieter is visible; otherwise the worker below takes it.
            val scheduled = runCatching {
                scheduler?.schedule(job) == JobScheduler.RESULT_SUCCESS
            }
                .getOrDefault(false)
            if (scheduled) return
        }
        WorkManager.getInstance(context)
            .enqueueUniqueWork(
                WORK,
                ExistingWorkPolicy.KEEP,
                OneTimeWorkRequestBuilder<FolderTransferWorker>()
                    .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                    .setConstraints(
                        Constraints.Builder()
                            .setRequiredNetworkType(
                                if (unmeteredOnly) NetworkType.UNMETERED else NetworkType.CONNECTED
                            )
                            .build()
                    )
                    .build(),
            )
    }
}
