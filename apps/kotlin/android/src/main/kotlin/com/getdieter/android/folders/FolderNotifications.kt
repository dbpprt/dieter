package com.getdieter.android.folders

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.getdieter.android.MainActivity
import com.getdieter.android.R
import com.getdieter.core.CoreRuntime
import com.getdieter.core.folders.FolderLocalView
import com.getdieter.core.folders.FolderNotice
import com.getdieter.core.folders.FolderNotices
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Folder sync's notifications: conflicts and what needs attention (a held deletion, a lost
 * location, a reached limit) and, when turned on, a finished sync, as the core's [FolderNotices]
 * decide; plus the progress notification of long runs. Nothing posts without the person's
 * permission (Android 13+), which Settings › Folder sync asks for when a notification is turned on.
 */
object FolderNotifications {
    const val CHANNEL = "folders"
    const val PROGRESS_CHANNEL = "folder-transfers"
    const val PROGRESS_ID = 0x0F01
    /** The folder a tapped notification opens. */
    const val EXTRA_FOLDER = "com.getdieter.android.extra.FOLDER"

    private fun manager(context: Context) =
        context.getSystemService(NotificationManager::class.java)

    fun channels(context: Context) {
        val manager = manager(context) ?: return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Synced folders", NotificationManager.IMPORTANCE_DEFAULT)
                .apply { description = "Conflicts and folders that need you" }
        )
        manager.createNotificationChannel(
            NotificationChannel(
                    PROGRESS_CHANNEL,
                    "Folder transfers",
                    NotificationManager.IMPORTANCE_LOW,
                )
                .apply { description = "Progress of long folder syncs" }
        )
    }

    private fun allowed(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED

    /** The ongoing notification of a long run. */
    fun progress(context: Context): Notification {
        channels(context)
        return NotificationCompat.Builder(context, PROGRESS_CHANNEL)
            .setSmallIcon(R.drawable.ic_dieter_foreground_monochrome)
            .setContentTitle("Syncing folders")
            .setContentText("Dieter is moving files between this device and your machines.")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(0, 0, true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    fun post(context: Context, notice: FolderNotice) {
        if (!allowed(context)) return
        channels(context)
        val open =
            PendingIntent.getActivity(
                context,
                notice.key.hashCode(),
                Intent(context, MainActivity::class.java)
                    .putExtra(EXTRA_FOLDER, notice.folderId)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        val notification =
            NotificationCompat.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_dieter_foreground_monochrome)
                .setContentTitle(notice.title)
                .setContentText(notice.text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(notice.text))
                .setContentIntent(open)
                .setAutoCancel(true)
                .build()
        runCatching { manager(context)?.notify(notice.key, 0, notification) }
    }

    fun cancel(context: Context, key: String) {
        manager(context)?.cancel(key, 0)
    }
}

/**
 * Watches this device's folders while the runtime lives (Dieter open or a background window) and
 * posts or removes notifications as [FolderNotices] decide from each change. The first state is the
 * baseline, so starting the process never repeats an old notification.
 */
internal class FolderNotifier(private val context: Context, private val runtime: CoreRuntime) {
    fun start(scope: CoroutineScope): Job = scope.launch {
        var previous: List<FolderLocalView>? = null
        runtime.folders.revision.collect {
            try {
                val views = runtime.folders.views()
                val names = runtime.accountSync.snapshot.value.folders.mapValues { it.value.name }
                val before = previous
                previous = views
                if (before != null) {
                    val changes = FolderNotices.diff(before, views, names, runtime.folders.device())
                    changes.cancel.forEach { FolderNotifications.cancel(context, it) }
                    changes.post.forEach { FolderNotifications.post(context, it) }
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                runtime.platform.logger.warn("FolderNotifier", "folder notifications failed", error)
            }
            // Bursts of changes (a scan) settle into one check a second.
            delay(1.seconds)
        }
    }
}
