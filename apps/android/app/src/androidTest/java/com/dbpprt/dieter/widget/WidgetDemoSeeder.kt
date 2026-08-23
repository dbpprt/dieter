package com.dbpprt.dieter.widget

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.data.CachedProjectHost
import com.dbpprt.dieter.data.DieterSyncStore
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.GlobalSnapshot
import com.dbpprt.dieter.v1.Project
import com.dbpprt.dieter.v1.State
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
    private val endpointId = "gateway#demo"

    @Test
    fun seed() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val now = Instant.now()
        val zone = ZoneId.systemDefault()
        val yesterday = LocalDate.now(zone).minusDays(1)

        val projects = listOf(
            Project.newBuilder().setId("p1").setName("Agent workspace").build(),
            Project.newBuilder().setId("p2").setName("kannacli").build(),
        )
        val boards = listOf(
            Board.newBuilder().setId("b1").setProjectId("p1").setName("Main").build(),
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
        val state = State.newBuilder()
            .addAllProjects(projects)
            .addAllBoards(boards)
            .addAllCards(cards)
            .addAllChats(chats)
            .build()
        val snapshot = GlobalSnapshot.newBuilder().setState(state).build()

        val store = DieterSyncStore(context)
        store.saveProjection(endpointId, snapshot, null)
        store.saveMachineDirectory(
            "gateway",
            state,
            mapOf(
                "p1" to CachedProjectHost(endpointId, "demo", "mac-mini"),
                "p2" to CachedProjectHost(endpointId, "demo", "mac-mini"),
            ),
        )

        context.getSharedPreferences("dieter_connection", Context.MODE_PRIVATE).edit()
            .putString("preferred_endpoint", endpointId)
            .putBoolean("desired_connected", false)
            .commit()
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
        val builder = Card.newBuilder()
            .setId(id)
            .setScope(scope)
            .setProjectId(projectId)
            .setBoardId(if (scope == "board") "b1" else "")
            .setLane(lane)
            .setTitle(title)
            .setRuntime(runtime)
            .setSummary(summary)
        runtimeAt?.let { builder.setRuntimeUpdatedAt(it.toString()) }
        phaseAt?.let { builder.setPhaseChangedAt(it.toString()) }
        val activity = activityAt ?: runtimeAt ?: phaseAt
        activity?.let {
            builder.setLastActivityAt(it.toString())
            builder.setUpdatedAt(it.toString())
        }
        return builder.build()
    }
}
