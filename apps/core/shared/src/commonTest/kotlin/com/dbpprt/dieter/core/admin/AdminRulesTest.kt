package com.dbpprt.dieter.core.admin

import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.MachineInformation
import com.dbpprt.dieter.api.v1.MachineOperationAction
import com.dbpprt.dieter.api.v1.MachineOperationCapability
import com.dbpprt.dieter.api.v1.PeerSyncDiagnostic
import com.dbpprt.dieter.api.v1.PeerVersion
import com.dbpprt.dieter.core.outbox.MachineOutboxSummary
import com.dbpprt.dieter.core.outbox.OutboxView
import com.dbpprt.dieter.core.testing.MemoryDeviceSettings
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Instant
import okio.ByteString.Companion.encodeUtf8

class AdminRulesTest {
    @Test
    fun labelsUseThePaletteAndValidateHex() {
        assertEquals(10, Labels.PALETTE.size)
        repeat(50) { assertTrue(Labels.randomColor("#d95c68", Random(it)) != "#d95c68") }
        assertNull(Labels.validate("urgent", "#6558df"))
        assertNull(Labels.validate("urgent", ""))
        assertEquals("label color must be a hex color such as #6558df", Labels.validate("urgent", "#zzzzzz"))
        assertEquals("label name is required", Labels.validate(" ", ""))
    }

    @Test
    fun paletteMatchesTheWebLabelsAndResolvesColorsStably() {
        assertEquals(listOf("#d95c68", "#df7650", "#c9952f", "#7d9e45", "#3e9970", "#379799", "#478dc5", "#626fd0", "#8a62c3", "#c65f98"), Labels.PALETTE)
        assertEquals(listOf("Ruby", "Coral", "Amber", "Lime", "Emerald", "Teal", "Sky", "Indigo", "Violet", "Rose"), Labels.COLORS.map { it.name })
        repeat(100) { seed ->
            val previous = Labels.PALETTE[seed % Labels.PALETTE.size]
            val color = Labels.randomColor(previous, Random(seed))
            assertTrue(color in Labels.PALETTE)
            assertTrue(color != previous)
        }
        assertEquals("Teal", Labels.named("#379799").name)
        assertEquals("Teal", Labels.named("#379799".uppercase()).name)
        assertEquals("Ruby", Labels.named("#123456").name)
        assertEquals(Labels.stable("board-1"), Labels.stable("board-1"))
        assertTrue(Labels.stable("anything") in Labels.PALETTE)
        assertEquals(Labels.PALETTE["abc".hashCode().mod(10)], Labels.stable("abc"))
    }

    @Test
    fun conflictVersionsReadAsValuesAndSharedRecordsRouteToTheProjectReplica() {
        assertEquals("Release train", ConflictVersions.versionText(PeerVersion(value_json = "\"Release train\"".encodeUtf8())))
        assertEquals("{\"name\":\"x\",\"n\":1}", ConflictVersions.versionText(PeerVersion(value_json = "{ \"name\": \"x\", \"n\": 1 }".encodeUtf8())))
        assertEquals("not json", ConflictVersions.versionText(PeerVersion(value_json = "not json".encodeUtf8())))
        assertEquals("Deleted", ConflictVersions.versionText(PeerVersion(deleted = true)))
        assertEquals("Keep deletion", ConflictVersions.keepLabel(PeerVersion(deleted = true)))
        assertEquals("Keep this value", ConflictVersions.keepLabel(PeerVersion()))

        assertEquals(AdminRoute.Replica("p1"), AdminRoute.shared("p1"))
        assertEquals(AdminRoute.Attached, AdminRoute.shared(""))
        assertEquals(AdminRoute.Attached, AdminRoute.shared(null))
        assertEquals("After 7 days", Administration.archivePolicyTitle("after_7_days"))
        assertEquals("Never", Administration.archivePolicyTitle("never"))
        assertEquals(listOf("Manual", "Pull request", "Push base"), Administration.PUBLISH_MODES.map(Administration::publishModeTitle))
    }

    @Test
    fun hostnamesNormalizeLikeTheDaemon() {
        assertEquals(listOf("[::1]:4018", "example.com", "localhost:3000"), Hostnames.normalize(listOf("Example.COM.", "localhost:3000", "[::1]:4018", "example.com", " ")).getOrThrow())
        assertTrue(Hostnames.normalize(listOf("https://example.com/path")).isFailure)
        assertTrue(Hostnames.normalize(listOf("*.example.com")).isFailure)
        assertTrue(Hostnames.normalize(listOf("host:70000")).isFailure)
        assertTrue(Hostnames.normalize(List(65) { "h$it" }).isFailure)
    }

    @Test
    fun promptTemplatesAreCheckedWhileEditing() {
        val valid = "{{project.instructions_block}}\n{{ labels.instructions_block }}\n{{card.title}}"
        assertNull(PromptTemplates.validate(valid, context = true))
        assertEquals("template is required", PromptTemplates.validate(" "))
        assertEquals("unknown template variable {{card.secret}}", PromptTemplates.validate("{{card.secret}}"))
        assertEquals("template contains a malformed variable", PromptTemplates.validate("{{card.title} }"))
        assertEquals("template must contain {{project.instructions_block}} exactly once", PromptTemplates.validate("{{labels.instructions_block}}", context = true))
        assertEquals("template exceeds 32 KiB", PromptTemplates.validate("x".repeat(33 * 1024)))
        assertEquals(3, PromptTemplates.estimatedTokens("123456789"))
    }

    @Test
    fun machineOperationsPreferExplicitCapabilities() {
        val legacy = MachineInformation(supports_restart = true)
        assertTrue(MachineOperations.available(legacy, MachineOperationAction.MACHINE_OPERATION_ACTION_RESTART))
        assertFalse(MachineOperations.available(legacy, MachineOperationAction.MACHINE_OPERATION_ACTION_UPDATE_DAEMON))
        val explicit = legacy.copy(operation_capabilities = listOf(MachineOperationCapability(action = MachineOperationAction.MACHINE_OPERATION_ACTION_RESTART, supported = true, authorized = false, unavailable_reason = "interactive PolicyKit authorization is required")))
        assertFalse(MachineOperations.available(explicit, MachineOperationAction.MACHINE_OPERATION_ACTION_RESTART))
        assertEquals("interactive PolicyKit authorization is required", MachineOperations.unavailableReason(explicit, MachineOperationAction.MACHINE_OPERATION_ACTION_RESTART))
        assertFalse(MachineOperations.available(null, MachineOperationAction.MACHINE_OPERATION_ACTION_RESTART))
        assertEquals("SHUT DOWN", MachineOperations.confirmation(MachineOperationAction.MACHINE_OPERATION_ACTION_SHUTDOWN))
        val authorized = legacy.copy(operation_capabilities = listOf(MachineOperationCapability(action = MachineOperationAction.MACHINE_OPERATION_ACTION_UPDATE_DAEMON, supported = true, authorized = true)))
        assertTrue(MachineOperations.available(authorized, MachineOperationAction.MACHINE_OPERATION_ACTION_UPDATE_DAEMON))
        assertFalse(MachineOperations.available(MachineInformation(supports_restart = true, supports_shutdown = false), MachineOperationAction.MACHINE_OPERATION_ACTION_SHUTDOWN))
    }

    @Test
    fun backgroundModesFollowTheRunPolicy() {
        assertEquals("Live", BackgroundMode.LIVE.title)
        assertTrue(BackgroundMode.LIVE.detail.contains("highest battery"))
        assertEquals("Smart", BackgroundMode.PERIODIC.title)
        assertTrue(BackgroundMode.PERIODIC.detail.contains("about every minute"))
        assertEquals("App only", BackgroundMode.APP_ONLY.title)
        assertEquals(BackgroundMode.LIVE, BackgroundMode.parse(null))
        assertEquals(BackgroundMode.LIVE, BackgroundMode.parse("future"))
        assertTrue(BackgroundPolicy.shouldRun(desired = true, BackgroundMode.APP_ONLY, foreground = true, serviceActive = false, periodicWindow = false))
        assertFalse(BackgroundPolicy.shouldRun(desired = true, BackgroundMode.APP_ONLY, foreground = false, serviceActive = true, periodicWindow = true))
        assertTrue(BackgroundPolicy.shouldRun(desired = true, BackgroundMode.LIVE, foreground = false, serviceActive = true, periodicWindow = false))
        assertFalse(BackgroundPolicy.shouldRun(desired = true, BackgroundMode.PERIODIC, foreground = false, serviceActive = true, periodicWindow = false))
        assertTrue(BackgroundPolicy.shouldRun(desired = true, BackgroundMode.PERIODIC, foreground = false, serviceActive = true, periodicWindow = true))
        assertFalse(BackgroundPolicy.shouldRun(desired = false, BackgroundMode.LIVE, foreground = true, serviceActive = true, periodicWindow = true))
        assertTrue(BackgroundPolicy.shouldRun(desired = true, BackgroundMode.APP_ONLY, foreground = false, serviceActive = false, periodicWindow = false, widgetRefresh = true))
        assertEquals(60_000, BackgroundPolicy.POLL_INTERVAL.inWholeMilliseconds)
        assertEquals(30_000, BackgroundPolicy.WINDOW_TIMEOUT.inWholeMilliseconds)

        assertTrue(BackgroundPolicy.hasActiveWork(listOf(Card(runtime = "Working")), OutboxView()))
        assertTrue(BackgroundPolicy.hasActiveWork(emptyList(), OutboxView(machines = mapOf("d" to MachineOutboxSummary(1, 0, retrying = false, failed = false)))))
        assertFalse(BackgroundPolicy.hasActiveWork(listOf(Card(runtime = "idle")), OutboxView()))

        val settings = MemoryDeviceSettings()
        assertTrue(BackgroundPolicy.shouldAutostart(settings))
        settings.putString(BackgroundPolicy.MODE_KEY, "app_only")
        assertFalse(BackgroundPolicy.shouldAutostart(settings))
        settings.putString(BackgroundPolicy.MODE_KEY, "periodic")
        settings.putString(BackgroundPolicy.DESIRED_KEY, "false")
        assertFalse(BackgroundPolicy.shouldAutostart(settings))
    }

    @Test
    fun peerSyncWarningsIgnoreExpiredAndOfflineTransportFailures() {
        val now = Instant.parse("2026-09-30T12:00:00Z")
        val recent = PeerSyncDiagnostic(peer_id = "p", failure_code = "Unavailable", last_attempt_at = (now - 1.minutes).toString())
        assertTrue(PeerSyncHealth.isCurrent(recent, peerOnline = true, now = now))
        assertFalse(PeerSyncHealth.isCurrent(recent, peerOnline = false, now = now), "an offline laptop is not a problem")
        assertFalse(PeerSyncHealth.isCurrent(recent.copy(last_attempt_at = (now - 6.minutes).toString()), true, now))
        assertFalse(PeerSyncHealth.isCurrent(recent.copy(failure_code = "Canceled"), true, now))
        assertTrue(PeerSyncHealth.isCurrent(recent.copy(record_id = "b_1"), false, now), "a rejected record stays visible")
        assertFalse(PeerSyncHealth.isCurrent(PeerSyncDiagnostic(), true, now))
        val peers = mapOf("p" to ("laptop" to true))
        assertEquals(listOf("Shared updates between studio and laptop are delayed."), PeerSyncHealth.warnings("studio", true, true, listOf(recent), peers, now))
        assertEquals(listOf("Shared updates between studio and laptop are blocked by a rejected record."), PeerSyncHealth.warnings("studio", true, true, listOf(recent.copy(record_kind = "board")), peers, now))
        assertTrue(PeerSyncHealth.warnings("studio", true, connected = false, listOf(recent), peers, now).isEmpty())
    }
}
