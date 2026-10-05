package com.dbpprt.dieter.widget

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.ChangesCursor
import com.dbpprt.dieter.api.v1.ChangesFrame
import com.dbpprt.dieter.api.v1.PeerRecord
import com.dbpprt.dieter.api.v1.PeerVersion
import com.dbpprt.dieter.core.sync.AccountSync
import com.dbpprt.dieter.sharedcore.SharedCore
import kotlinx.coroutines.runBlocking
import okio.ByteString.Companion.encodeUtf8
import org.json.JSONObject
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

        val records = project("p1", "Agent workspace") + project("p2", "kannacli") + board("b1", "p1", "Main") +
            item("w1", "p1", "Lets understand the code", lane = "running", runtime = "waiting_for_user", runtimeAt = now.minus(Duration.ofHours(18)), activityAt = now.minus(Duration.ofHours(18))) +
            item("r1", "p1", "Migrate schedule store", lane = "running", runtime = "running", runtimeAt = now.minus(Duration.ofMinutes(12)), activityAt = now.minus(Duration.ofMinutes(1))) +
            item("d1", "p1", "Subagents", lane = "done", runtime = "completed", phaseAt = now.minus(Duration.ofMinutes(19))) +
            item("d2", "p1", "Hi", lane = "done", runtime = "completed", phaseAt = yesterday.atTime(LocalTime.of(17, 38)).atZone(zone).toInstant()) +
            item("c1", "p2", "we dont need kanna cli anylonger", chat = true, runtime = "completed", runtimeAt = now.minus(Duration.ofMinutes(48))) +
            item("c2", "p2", "hi", chat = true, runtime = "completed", runtimeAt = yesterday.atTime(LocalTime.of(14, 5)).atZone(zone).toInstant())
        // What only the owner reports.
        val owned = listOf(Card(id = "r1", summary = "7 files touched"), Card(id = "d1", summary = "start 3 sub agents for testing"))

        // The app's own core state, seeded as one machine's cached view: the
        // records its stream delivers. The app is not running in this
        // process; it restores the view on launch.
        val view = ChangesFrame(
            daemon_id = daemonId, account = "demo", cursor = ChangesCursor(records_epoch = "demo", records_sequence = 1, local_epoch = "demo", local_sequence = 1),
            reset_records = true, reset_local = true, caught_up = true, records = records, owned_cards = owned,
        )
        val core = SharedCore.create(context, null)
        core.storageFor(core.accounts.state.value.active).write(AccountSync.cacheName(daemonId), ChangesFrame.ADAPTER.encode(view))
        runBlocking { core.setConnected(false) }
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

    /** One register as this machine wrote it once. */
    private fun field(kind: String, id: String, field: String, value: Any): PeerRecord {
        val json = if (value is String) JSONObject.quote(value) else value.toString()
        val version = PeerVersion(clock = mapOf(daemonId to 1L), rank = "$daemonId:$kind/$id.$field", value_json = json.encodeUtf8())
        val revision = "$kind/$id.$field=$json"
        return PeerRecord(kind = kind, id = "$id.$field", versions = listOf(version), revision = revision, value_revision = revision)
    }

    private fun project(id: String, name: String): List<PeerRecord> = listOf(
        field("project", id, "identity", JSONObject(mapOf("id" to id, "createdAt" to CREATED))),
        field("project", id, "name", name),
        field("project", id, "archived", false),
        field("checkout", "co_$id", "registration", JSONObject(mapOf("id" to "co_$id", "projectId" to id, "daemonId" to daemonId, "name" to name, "detached" to false))),
    )

    private fun board(id: String, projectId: String, name: String): List<PeerRecord> = listOf(
        field("board", id, "identity", JSONObject(mapOf("id" to id, "projectId" to projectId, "createdAt" to CREATED))),
        field("board", id, "name", name),
        field("board", id, "workflow", "review"),
    )

    private fun item(
        id: String,
        projectId: String,
        title: String,
        lane: String = "",
        runtime: String = "",
        chat: Boolean = false,
        runtimeAt: Instant? = null,
        phaseAt: Instant? = null,
        activityAt: Instant? = null,
    ): List<PeerRecord> {
        val activity = (activityAt ?: runtimeAt ?: phaseAt)?.toString().orEmpty()
        return listOf(
            field("item", id, "identity", JSONObject(mapOf("id" to id, "projectId" to projectId, "ownerDaemonId" to daemonId, "checkoutId" to "co_$projectId", "scope" to (if (chat) "chat" else "board"), "createdAt" to CREATED))),
            field("item", id, "title", title),
            field("item", id, "placement", JSONObject(mapOf("boardId" to (if (chat) "" else "b1"), "lane" to lane, "orderKey" to id, "phaseChangedAt" to phaseAt?.toString().orEmpty()))),
            field("item", id, "archived", false),
            field("item", id, "summary", JSONObject(mapOf("runtime" to runtime, "runtimeUpdatedAt" to runtimeAt?.toString().orEmpty(), "lastActivityAt" to activity, "responseSeq" to 0))),
        )
    }

    private companion object {
        const val CREATED = "2026-01-01T00:00:00Z"
    }
}
