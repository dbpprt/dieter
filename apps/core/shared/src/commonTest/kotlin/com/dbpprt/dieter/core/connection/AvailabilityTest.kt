package com.dbpprt.dieter.core.connection

import com.dbpprt.dieter.core.navigation.Destination
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant

class AvailabilityTest {
    private val start = Instant.fromEpochSeconds(1_800_000_000)

    @Test fun routineSyncDoesNotCoverCachedWorkspaceWhileUnavailableReadOnlyDestinationsMute() {
        listOf(ConnectionPhase.CONNECTING, ConnectionPhase.SYNCING, ConnectionPhase.CONNECTED).forEach { phase ->
            val refreshing = Availability.treatment(Destination.BOARD, hasCache = true, phase)
            assertEquals(SurfaceTreatment.CURRENT, refreshing)
            assertFalse(refreshing.showsNotice)
            assertFalse(refreshing.blocksInteraction)
        }
        val unavailable = Availability.treatment(Destination.FILES, hasCache = true, ConnectionPhase.RECONNECTING)
        assertEquals(SurfaceTreatment.UNAVAILABLE, unavailable)
        assertTrue(unavailable.showsNotice)
        assertTrue(Availability.blocksInteraction(Destination.FILES, hasCache = true, ConnectionPhase.RECONNECTING))
        // Chats and boards queue offline, so the notice shows but input stays open.
        assertEquals(SurfaceTreatment.UNAVAILABLE, Availability.treatment(Destination.CHATS, hasCache = true, ConnectionPhase.DISCONNECTED))
        assertFalse(Availability.blocksInteraction(Destination.CHATS, hasCache = true, ConnectionPhase.DISCONNECTED))
        assertEquals(SurfaceTreatment.CURRENT, Availability.treatment(Destination.BOARD, hasCache = false, ConnectionPhase.NO_MACHINE))
        assertEquals(SurfaceTreatment.CURRENT, Availability.treatment(Destination.MACHINES, hasCache = true, ConnectionPhase.NO_MACHINE))
    }

    @Test fun firstSyncReplacesTheEmptyWorkspaceUntilLiveDataArrives() {
        assertTrue(Availability.initialSync(Destination.ACTIVITY, hasCache = false, loading = true, desired = true, ConnectionPhase.SYNCING))
        assertTrue(Availability.initialSync(Destination.ACTIVITY, hasCache = false, loading = false, desired = true, ConnectionPhase.NO_MACHINE))
        assertFalse(Availability.initialSync(Destination.ACTIVITY, hasCache = true, loading = true, desired = true, ConnectionPhase.SYNCING))
        assertFalse(Availability.initialSync(Destination.ACTIVITY, hasCache = false, loading = false, desired = true, ConnectionPhase.CONNECTED))
        assertFalse(Availability.initialSync(Destination.ACTIVITY, hasCache = false, loading = true, desired = false, ConnectionPhase.DISCONNECTED))
        assertFalse(Availability.initialSync(Destination.TERMINALS, hasCache = false, loading = true, desired = true, ConnectionPhase.SYNCING))

        val syncing = Availability.firstSync(ConnectionPhase.SYNCING)
        assertEquals("Syncing your workspace", syncing.title)
        assertTrue(syncing.working)
        assertTrue(Availability.firstSync(ConnectionPhase.AUTH_REQUIRED).offline)
    }

    @Test fun loadingEndsWithTheFirstViewOrWhenNoMachineCanDeliverIt() {
        assertTrue(Availability.loading(desired = true, loaded = false, ConnectionPhase.SYNCING))
        assertFalse(Availability.loading(desired = true, loaded = true, ConnectionPhase.SYNCING))
        assertFalse(Availability.loading(desired = true, loaded = false, ConnectionPhase.NO_MACHINE))
        assertFalse(Availability.loading(desired = false, loaded = false, ConnectionPhase.DISCONNECTED))
    }

    @Test fun workspaceNoticeMatchesTheQuietMacPresentation() {
        val syncing = Availability.notice(ConnectionPhase.SYNCING, cached = true)
        assertEquals("Refreshing workspace", syncing.title)
        assertEquals("Your current workspace stays available while changes load.", syncing.detail)
        assertTrue(syncing.working)
        assertFalse(syncing.offline)

        val offline = Availability.notice(ConnectionPhase.NO_MACHINE, cached = true)
        assertEquals("Working from cached data", offline.title)
        assertFalse(offline.working)
        assertTrue(offline.offline)
        assertEquals("Dieter is unavailable", Availability.notice(ConnectionPhase.DISCONNECTED, cached = false).title)

        assertTrue(Availability.notice(ConnectionPhase.NO_MACHINE, cached = true, offlineOutbox = true).detail.contains("messages and new conversations queue"))
        assertEquals("Your workspace stays available while Dieter connects.", Availability.notice(ConnectionPhase.CONNECTING, cached = true, offlineOutbox = true).detail)
    }

    @Test fun updatedLabelsStayCompactInsideTheWorkspaceNotice() {
        val now = start
        assertEquals("Waiting for first update", Availability.updated(null, now))
        assertEquals("Updated just now", Availability.updated(now - 59.seconds, now))
        assertEquals("Updated 2m ago", Availability.updated(now - 2.minutes, now))
        assertEquals("Updated 2h ago", Availability.updated(now - 120.minutes, now))
        assertEquals("Updated 3d ago", Availability.updated(now - (3 * 24 * 60).minutes, now))
        assertEquals("Updated just now", Availability.updated(now + 5.seconds, now))
        assertEquals("Updated 6m ago", Availability.updated(now - 360.seconds, now))
    }

    @Test fun lastConnectedLabelsUseCompactRelativeAges() {
        val now = start
        assertEquals("Last connected unknown", Availability.lastConnected(null, now))
        assertEquals("Last connected just now", Availability.lastConnected(now - 59.seconds, now))
        assertEquals("Last connected 1m ago", Availability.lastConnected(now - 60.seconds, now))
        assertEquals("Last connected 1h ago", Availability.lastConnected(now - 3_600.seconds, now))
    }

    @Test fun cachedWorkspacesShowANoticeOnlyWhileUnavailable() {
        // Routine handoffs keep the cached workspace current without a banner.
        listOf(ConnectionPhase.CONNECTED, ConnectionPhase.SYNCING, ConnectionPhase.CONNECTING).forEach { phase ->
            assertNull(Availability.workspaceNotice(phase, hasCache = true), "$phase")
        }
        // Nothing cached: the first-sync screen explains the phase instead.
        assertNull(Availability.workspaceNotice(ConnectionPhase.DISCONNECTED, hasCache = false))

        val reconnecting = Availability.workspaceNotice(ConnectionPhase.RECONNECTING, hasCache = true)!!
        assertEquals("Reconnecting to Dieter", reconnecting.title)
        assertEquals("Cached conversations stay available; messages and new conversations queue until Dieter reconnects.", reconnecting.detail)
        assertTrue(reconnecting.working)
        assertFalse(reconnecting.offline)

        val offline = Availability.workspaceNotice(ConnectionPhase.DISCONNECTED, hasCache = true)!!
        assertEquals("Working from cached data", offline.title)
        assertTrue(offline.offline)
        assertFalse(offline.working)
        assertEquals("Sign in required", Availability.workspaceNotice(ConnectionPhase.AUTH_REQUIRED, hasCache = true)!!.title)
        assertEquals("Update required", Availability.workspaceNotice(ConnectionPhase.UPDATE_REQUIRED, hasCache = true)!!.title)
    }

    @Test fun theWorkspaceIsLiveOnlyWithATransportAndAnAppliedLiveFrame() {
        assertTrue(Availability.workspaceLive(ConnectionPhase.CONNECTED, feedLive = true, projectionPending = false))
        assertFalse(Availability.workspaceLive(ConnectionPhase.CONNECTED, feedLive = false, projectionPending = false))
        assertFalse(Availability.workspaceLive(ConnectionPhase.CONNECTED, feedLive = true, projectionPending = true))
        assertFalse(Availability.workspaceLive(ConnectionPhase.SYNCING, feedLive = true, projectionPending = false))
        assertFalse(Availability.workspaceLive(ConnectionPhase.RECONNECTING, feedLive = true, projectionPending = false))
    }

    @Test fun phasesDescribeRecoveryInsteadOfCollapsingToOffline() {
        assertEquals("Connecting", Availability.label(ConnectionPhase.CONNECTING))
        assertEquals("Syncing", Availability.label(ConnectionPhase.SYNCING))
        assertEquals("Reconnecting", Availability.label(ConnectionPhase.RECONNECTING))
        assertEquals("Disconnected", Availability.label(ConnectionPhase.DISCONNECTED))
        assertEquals("Update required", Availability.label(ConnectionPhase.UPDATE_REQUIRED))
        assertTrue(Availability.blocked(ConnectionPhase.NO_MACHINE))
        assertFalse(Availability.blocked(ConnectionPhase.RECONNECTING))
    }

    @Test fun projectScopedDestinationsStayMutedWhenEveryKnownProjectHostIsOffline() {
        assertFalse(Availability.projectScopedEnabled(listOf("p1", "p2")) { false })
        assertTrue(Availability.projectScopedEnabled(listOf("p1", "p2")) { if (it == "p2") true else false })
        // An unknown host is not known to be offline.
        assertTrue(Availability.projectScopedEnabled(listOf("p1")) { null })
        assertFalse(Availability.projectScopedEnabled(emptyList()) { true })
    }

    @Test fun statusNotificationDoesNotTurnRoutineSynchronizationIntoAModalSheet() {
        fun opens(desired: Boolean, phase: ConnectionPhase, hasCache: Boolean) = ConnectionPrompt().apply { showIfNeeded(desired, phase, hasCache) }.visible
        assertFalse(opens(true, ConnectionPhase.CONNECTING, false))
        assertFalse(opens(true, ConnectionPhase.SYNCING, true))
        assertFalse(opens(true, ConnectionPhase.RECONNECTING, true))
        assertFalse(opens(true, ConnectionPhase.NO_MACHINE, true))
        assertTrue(opens(true, ConnectionPhase.AUTH_REQUIRED, true))
        assertTrue(opens(true, ConnectionPhase.UPDATE_REQUIRED, true))
        assertTrue(opens(true, ConnectionPhase.NO_MACHINE, false))
        assertTrue(opens(false, ConnectionPhase.DISCONNECTED, true))
    }

    @Test fun connectedStartupAndRoutineRecoveryNeverOpenTheSheet() {
        val prompt = ConnectionPrompt()
        assertNull(prompt.reconcile(desired = true, ConnectionPhase.CONNECTED, hasCache = true, foreground = true, start))
        assertFalse(prompt.visible)
        prompt.phaseChanged(ConnectionPhase.CONNECTED, ConnectionPhase.RECONNECTING, start)
        assertNull(prompt.reconcile(desired = true, ConnectionPhase.RECONNECTING, hasCache = true, foreground = true, start + 70.seconds))
        assertNull(prompt.reconcile(desired = true, ConnectionPhase.NO_MACHINE, hasCache = true, foreground = true, start + 70.seconds))
        assertFalse(prompt.visible)
    }

    @Test fun userActionableFailureGetsGraceBeforeOpeningTheSheet() {
        val prompt = ConnectionPrompt()
        prompt.phaseChanged(ConnectionPhase.CONNECTED, ConnectionPhase.AUTH_REQUIRED, start)
        assertEquals(ConnectionPrompt.GRACE, prompt.reconcile(desired = true, ConnectionPhase.AUTH_REQUIRED, hasCache = true, foreground = true, start))
        assertEquals(20.seconds, prompt.reconcile(desired = true, ConnectionPhase.AUTH_REQUIRED, hasCache = true, foreground = true, start + 40.seconds))
        assertFalse(prompt.visible)
        // In the background, nothing opens and no timer runs.
        assertNull(prompt.reconcile(desired = true, ConnectionPhase.AUTH_REQUIRED, hasCache = true, foreground = false, start + 70.seconds))
        assertFalse(prompt.visible)
        assertNull(prompt.reconcile(desired = true, ConnectionPhase.AUTH_REQUIRED, hasCache = true, foreground = true, start + 60.seconds + 1.milliseconds))
        assertTrue(prompt.visible)

        // Without a working connection to lose, the first-sync screen explains the phase: no sheet, no timer.
        val launch = ConnectionPrompt()
        assertNull(launch.reconcile(desired = true, ConnectionPhase.NO_MACHINE, hasCache = false, foreground = true, start))
        assertNull(launch.reconcile(desired = true, ConnectionPhase.UPDATE_REQUIRED, hasCache = true, foreground = true, start + 5.minutes))
        assertFalse(launch.visible)
    }

    @Test fun aDismissedSheetStaysClosedUntilThePhaseChanges() {
        val prompt = ConnectionPrompt()
        prompt.phaseChanged(ConnectionPhase.CONNECTED, ConnectionPhase.AUTH_REQUIRED, start)
        prompt.reconcile(desired = true, ConnectionPhase.AUTH_REQUIRED, hasCache = true, foreground = true, start + 2.minutes)
        assertTrue(prompt.visible)
        prompt.dismiss(desired = true, ConnectionPhase.AUTH_REQUIRED)
        assertFalse(prompt.visible)
        assertNull(prompt.reconcile(desired = true, ConnectionPhase.AUTH_REQUIRED, hasCache = true, foreground = true, start + 5.minutes))
        assertFalse(prompt.visible)
        // A different blocking phase is news.
        assertNull(prompt.reconcile(desired = true, ConnectionPhase.UPDATE_REQUIRED, hasCache = true, foreground = true, start + 5.minutes))
        assertTrue(prompt.visible)

        // Leaving for settings counts as a dismissal of that phase too.
        val settings = ConnectionPrompt()
        settings.show()
        settings.leaveForSettings(ConnectionPhase.NO_MACHINE)
        assertFalse(settings.visible)
        assertNull(settings.reconcile(desired = true, ConnectionPhase.NO_MACHINE, hasCache = false, foreground = true, start + 5.minutes))
        assertFalse(settings.visible)
    }

    @Test fun aRequestedSheetStaysOpenWhileConnectedAndTurningOffKeepsItOpen() {
        val prompt = ConnectionPrompt()
        prompt.show()
        prompt.reconcile(desired = true, ConnectionPhase.CONNECTED, hasCache = true, foreground = true, start)
        assertTrue(prompt.visible)
        prompt.dismiss(desired = true, ConnectionPhase.CONNECTED)
        assertFalse(prompt.visible)
        // A connected dismissal is not remembered: a later failure still opens it.
        prompt.phaseChanged(ConnectionPhase.CONNECTED, ConnectionPhase.AUTH_REQUIRED, start)
        prompt.reconcile(desired = true, ConnectionPhase.AUTH_REQUIRED, hasCache = true, foreground = true, start + 2.minutes)
        assertTrue(prompt.visible)

        val off = ConnectionPrompt()
        off.disconnected()
        assertTrue(off.visible)
        off.reconcile(desired = false, ConnectionPhase.DISCONNECTED, hasCache = true, foreground = true, start)
        assertTrue(off.visible)
        // An automatically opened sheet closes once the connection works again.
        off.connecting()
        off.reconcile(desired = true, ConnectionPhase.CONNECTED, hasCache = true, foreground = true, start)
        assertFalse(off.visible)
    }
}
