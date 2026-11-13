package com.getdieter.android.folders

import android.app.Notification
import android.app.job.JobParameters
import android.app.job.JobService
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.SystemClock
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import com.getdieter.android.DieterRuntime
import com.getdieter.core.CoreRuntime
import com.getdieter.core.folders.FolderTrigger
import kotlin.time.Duration
import kotlin.time.Duration.Companion.hours
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/** Folder windows the background hosts run. */
internal object FolderRuns {
    /** A periodic window: WorkManager stops a worker after ten minutes. */
    val PERIODIC_WINDOW = 8.minutes

    /** One window of a long run; the run starts the next while work remains. */
    val LONG_WINDOW = 10.minutes

    /**
     * Windows until nothing is left, the host stops the coroutine, or [budget] has passed. Every
     * durable step is persisted, so a stop at any point resumes in the next window.
     */
    suspend fun long(runtime: CoreRuntime, budget: Duration, trigger: FolderTrigger) {
        val until = SystemClock.elapsedRealtime() + budget.inWholeMilliseconds
        while (currentCoroutineContext().isActive) {
            val left = until - SystemClock.elapsedRealtime()
            if (left <= 0) return
            val window = minOf(LONG_WINDOW.inWholeMilliseconds, left)
            val result = runtime.folderSyncWindow(window.milliseconds, null, trigger)
            if (!result.workRemains || result.ran == 0) return
        }
    }
}

/**
 * The periodic window WorkManager runs at the interval and with the constraints of the settings.
 */
class FolderSyncWorker(context: Context, parameters: WorkerParameters) :
    CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val runtime = DieterRuntime.acquire(applicationContext)
        try {
            runtime.folderSyncWindow(FolderRuns.PERIODIC_WINDOW, null, FolderTrigger.BACKGROUND)
        } finally {
            DieterRuntime.release()
        }
        return Result.success()
    }
}

/**
 * A long run without a user-initiated job: expedited work that shows its progress as a `dataSync`
 * foreground service where the system lets it start one (always before Android 12; on later
 * releases only while Dieter is visible). Android 15 allows `dataSync` services six hours a day;
 * [DataSyncBudget] keeps runs inside that and the system's timeout stops a run cleanly.
 */
class FolderTransferWorker(context: Context, parameters: WorkerParameters) :
    CoroutineWorker(context, parameters) {
    override suspend fun getForegroundInfo(): ForegroundInfo =
        foregroundInfo(FolderNotifications.progress(applicationContext))

    override suspend fun doWork(): Result {
        if (!FolderLongRuns.active.compareAndSet(false, true)) return Result.success()
        val started = SystemClock.elapsedRealtime()
        var foreground = false
        try {
            if (DataSyncBudget.available(applicationContext))
                foreground = runCatching { setForeground(getForegroundInfo()) }.isSuccess
            val runtime = DieterRuntime.acquire(applicationContext)
            try {
                FolderRuns.long(
                    runtime,
                    if (foreground) minOf(1.hours, DataSyncBudget.left(applicationContext))
                    else FolderRuns.LONG_WINDOW,
                    FolderTrigger.BACKGROUND,
                )
            } finally {
                DieterRuntime.release()
            }
        } finally {
            if (foreground)
                DataSyncBudget.spend(applicationContext, SystemClock.elapsedRealtime() - started)
            FolderLongRuns.active.set(false)
        }
        return Result.success()
    }

    private fun foregroundInfo(notification: Notification): ForegroundInfo =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
            ForegroundInfo(
                FolderNotifications.PROGRESS_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        else ForegroundInfo(FolderNotifications.PROGRESS_ID, notification)
}

/**
 * The user-initiated data transfer job of Android 14+ (after Sync now): runs windows until nothing
 * is left, with a progress notification the system shows while it runs.
 */
class FolderTransferJobService : JobService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var run: Job? = null

    override fun onStartJob(params: JobParameters): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
            setNotification(
                params,
                FolderNotifications.PROGRESS_ID,
                FolderNotifications.progress(this),
                JOB_END_NOTIFICATION_POLICY_REMOVE,
            )
        if (!FolderLongRuns.active.compareAndSet(false, true)) return false
        run = scope.launch {
            var finished = false
            try {
                val runtime = DieterRuntime.acquire(applicationContext)
                try {
                    FolderRuns.long(runtime, 3.hours, FolderTrigger.MANUAL)
                    finished = true
                } finally {
                    DieterRuntime.release()
                }
            } finally {
                FolderLongRuns.active.set(false)
                if (finished) jobFinished(params, false)
            }
        }
        return true
    }

    /** Stopped by the system (network lost, the person stopped it): the journal resumes it. */
    override fun onStopJob(params: JobParameters): Boolean {
        run?.cancel()
        return false
    }

    override fun onDestroy() {
        run?.cancel()
        super.onDestroy()
    }
}

/**
 * Android 15 gives `dataSync` foreground services six hours in 24; long runs keep a little below
 * that and record what they used.
 */
internal object DataSyncBudget {
    private const val PREFERENCES = "folder_sync"
    private const val WINDOW_START = "data_sync_window_start"
    private const val USED = "data_sync_used"
    private val DAY = 24.hours.inWholeMilliseconds
    private val LIMIT = (5.hours + 30.minutes).inWholeMilliseconds

    private fun used(context: Context): Long {
        if (Build.VERSION.SDK_INT < 35) return 0
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val start = preferences.getLong(WINDOW_START, 0)
        return if (System.currentTimeMillis() - start > DAY) 0 else preferences.getLong(USED, 0)
    }

    fun left(context: Context): Duration = (LIMIT - used(context)).coerceAtLeast(0).milliseconds

    fun available(context: Context): Boolean = used(context) < LIMIT

    fun spend(context: Context, millis: Long) {
        if (Build.VERSION.SDK_INT < 35) return
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val now = System.currentTimeMillis()
        val start = preferences.getLong(WINDOW_START, 0)
        val fresh = now - start > DAY
        preferences
            .edit()
            .putLong(WINDOW_START, if (fresh) now else start)
            .putLong(USED, (if (fresh) 0 else preferences.getLong(USED, 0)) + millis)
            .apply()
    }
}
