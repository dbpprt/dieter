package com.dbpprt.dieter.widget

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.api.v1.State
import com.dbpprt.dieter.core.sync.DirectoryPoller
import com.dbpprt.dieter.sharedcore.SharedCore
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.runner.RunWith
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId

/**
 * Not a regression test: dev tooling that seeds a realistic offline
 * projection so home-screen widgets can be exercised end to end on an
 * emulator without a live gateway, plus a helper that asks the launcher to
 * pin the widget.
 */
@RunWith(AndroidJUnit4::class)
class WidgetDemoSeeder {
    private val daemonId = "d_demo"

    @Test
    fun seed() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val now = Instant.now()
        val zone = ZoneId.systemDefault()
        val yesterday = LocalDate.now(zone).minusDays(1)

        val projects = listOf(
            Project(id = "p1", name = "Agent workspace"),
            Project(id = "p2", name = "kannacli"),
        )
        val boards = listOf(
            Board(id = "b1", project_id = "p1", name = "Main"),
        )
        val cards = listOf(
            card("w1", "p1", "Lets understand the code", lane = "running", runtime = "waiting_for_user", runtimeAt = now.minus(Duration.ofHours(18)), activityAt = now.minus(Duration.ofHours(18))),
            card("r1", "p1", "Migrate schedule store", lane = "running", runtime = "running", runtimeAt = now.minus(Duration.ofMinutes(12)), activityAt = now.minus(Duration.ofMinutes(1)), summary = "7 files touched"),
            card("d1", "p1", "Subagents", lane = "done", runtime = "completed", phaseAt = now.minus(Duration.ofMinutes(19)), summary = "start 3 sub agents for testing"),
            card("d2", "p1", "Hi", lane = "done", runtime = "completed", phaseAt = yesterday.atTime(LocalTime.of(17, 38)).atZone(zone).toInstant()),
        )
        val chats = listOf(
            card("c1", "p2", "we dont need kanna cli anylonger", scope = "chat", runtime = "completed", runtimeAt = now.minus(Duration.ofMinutes(48))),
            card("c2", "p2", "hi", scope = "chat", runtime = "completed", runtimeAt = yesterday.atTime(LocalTime.of(14, 5)).atZone(zone).toInstant()),
        )
        val state = State(projects = projects.toList(), boards = boards.toList(), cards = cards.toList(), chats = chats.toList())

        // The app's own core state, seeded as one machine's cached view. The
        // app is not running in this process; it restores the view on launch.
        val core = SharedCore.create(context, null)
        core.storageFor(core.accounts.state.value.active).write(DirectoryPoller.cacheName(daemonId), State.ADAPTER.encode(state))
        runBlocking { core.setConnected(false) }
        context.getSharedPreferences("dieter_widget", Context.MODE_PRIVATE).edit()
            .putLong("last_sync_at", now.toEpochMilli())
            .commit()
    }

    @Test
    fun requestPin() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val manager = AppWidgetManager.getInstance(context)
        check(manager.isRequestPinAppWidgetSupported) { "Launcher does not support pinning widgets" }
        manager.requestPinAppWidget(
            ComponentName(context, DieterActivityWidgetProvider::class.java),
            null,
            null,
        )
        // Leave time for the launcher's confirmation dialog to appear before
        // the instrumentation process exits.
        Thread.sleep(4_000)
    }

    private fun card(
        id: String,
        projectId: String,
        title: String,
        lane: String = "",
        runtime: String = "",
        scope: String = "board",
        summary: String = "",
        runtimeAt: Instant? = null,
        phaseAt: Instant? = null,
        activityAt: Instant? = null,
    ): Card {
        val activity = (activityAt ?: runtimeAt ?: phaseAt)?.toString().orEmpty()
        return Card(
            id = id, scope = scope, project_id = projectId, board_id = if (scope == "board") "b1" else "", lane = lane, title = title,
            runtime = runtime, summary = summary, owner_daemon_id = daemonId,
            runtime_updated_at = runtimeAt?.toString().orEmpty(), phase_changed_at = phaseAt?.toString().orEmpty(),
            last_activity_at = activity, updated_at = activity,
        )
    }
}
