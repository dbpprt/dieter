package com.getdieter.core.trust

import com.getdieter.api.gateway.v1.DeviceRoster
import com.getdieter.api.gateway.v1.GetDeviceRosterRequest
import com.getdieter.api.v1.ApproveDeviceRequest
import com.getdieter.api.v1.InitializeDeviceRosterRequest
import com.getdieter.api.v1.InitializeDeviceRosterResponse
import com.getdieter.api.v1.ListPairingRequestsResponse
import com.getdieter.api.v1.RecoverDeviceTrustRequest
import com.getdieter.api.v1.RevokeDeviceRequest
import com.getdieter.api.v1.SyncDeviceRosterRequest
import com.getdieter.api.v1.TrustServiceClient
import com.getdieter.api.v1.TrustState as DaemonTrustState
import com.getdieter.api.v1.TrustStatus
import com.getdieter.core.storage.CoreStorage
import com.getdieter.core.testing.JcaSignatureVerifier
import com.getdieter.core.testing.PrintLogger
import com.squareup.wire.GrpcCall
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.time.Clock
import kotlin.time.Duration.Companion.milliseconds
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

/** Roster heads compared with a machine over its authenticated connection. */
class TrustGossipTest {
    private val gateway = FakeRosterGateway()
    private val machine = Signer.machine("d_studio")
    private val trust =
        DeviceTrust(
            softwareKeys("Test phone"),
            JcaSignatureVerifier,
            CoreStorage(FakeFileSystem(), "/state".toPath()).scope("trust"),
            Clock.System,
            PrintLogger,
            TrustConfig(pairingPoll = 100.milliseconds),
        )

    /** A machine's TrustService holding [roster]. */
    private class Daemon(var roster: Roster) : TrustServiceClient {
        val synced = mutableListOf<SyncDeviceRosterRequest>()

        private fun status() =
            TrustStatus(
                state = DaemonTrustState.TRUST_STATE_TRUSTED,
                root_hash = Rosters.encodeHash(roster.root),
                head_sequence = roster.headSequence,
                head_hash = Rosters.encodeHash(roster.headHash),
            )

        override fun GetTrustStatus(): GrpcCall<Unit, TrustStatus> = GrpcCall { status() }

        override fun GetDeviceRoster(): GrpcCall<GetDeviceRosterRequest, DeviceRoster> =
            GrpcCall { request ->
                DeviceRoster(entries = roster.entriesFrom(request.from_sequence))
            }

        override fun SyncDeviceRoster(): GrpcCall<SyncDeviceRosterRequest, TrustStatus> =
            GrpcCall { request ->
                synced += request
                roster = roster.extend(request.entries, JcaSignatureVerifier)
                status()
            }

        override fun InitializeDeviceRoster():
            GrpcCall<InitializeDeviceRosterRequest, InitializeDeviceRosterResponse> =
            error("unused")

        override fun ListPairingRequests(): GrpcCall<Unit, ListPairingRequestsResponse> =
            error("unused")

        override fun ApproveDevice(): GrpcCall<ApproveDeviceRequest, TrustStatus> = error("unused")

        override fun RevokeDevice(): GrpcCall<RevokeDeviceRequest, TrustStatus> = error("unused")

        override fun RecoverDeviceTrust(): GrpcCall<RecoverDeviceTrustRequest, TrustStatus> =
            error("unused")
    }

    private fun TestScope.paired(): Roster {
        gateway.serve(roster(genesis(machine)))
        backgroundScope.launch { trust.run("https://gateway.test:443", 42, gateway) }
        repeat(100) {
            if (gateway.requests.isNotEmpty() && trust.view.value.pairingCode != null) {
                gateway.approve(trust.view.value.pairingCode!!, machine)
                repeat(100) {
                    trust.view.value.roster?.let {
                        return it
                    }
                    advanceTimeBy(50.milliseconds)
                    runCurrent()
                }
            }
            advanceTimeBy(50.milliseconds)
            runCurrent()
        }
        error("not paired")
    }

    @Test
    fun aMachineBehindReceivesTheEntriesItLacks() = runTest {
        val pinned = paired()
        val daemon = Daemon(roster(pinned.entries.first()))
        trust.gossip("d_studio", daemon)
        assertEquals(pinned.entries.drop(1), daemon.synced.single().entries)
        assertEquals(pinned.headHash, daemon.roster.headHash)
    }

    @Test
    fun entriesTheGatewayWithholdsAreTakenFromTheMachine() = runTest {
        val pinned = paired()
        val tablet = Signer.app("Tablet")
        val daemon = Daemon(pinned.add(tablet.descriptor, machine))
        trust.gossip("d_studio", daemon)
        assertNotNull(trust.view.value.roster?.member(tablet.id))
        assertEquals(TrustState.TRUSTED, trust.view.value.state)
    }

    @Test
    fun aMachineWithAnotherHistoryIsAConflict() = runTest {
        val pinned = paired()
        val daemon =
            Daemon(roster(pinned.entries.first()).add(Signer.app("Intruder").descriptor, machine))
        trust.gossip("d_studio", daemon)
        assertEquals(TrustState.CONFLICT, trust.view.value.state)
        assertEquals(
            "Studio trusts devices that contradict the ones this device pinned.",
            trust.view.value.conflict,
        )
    }
}
