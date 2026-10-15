package com.getdieter.core.trust

import com.getdieter.core.runtime.CoreException
import com.getdieter.core.storage.CoreStorage
import com.getdieter.core.testing.JcaSignatureVerifier
import com.getdieter.core.testing.PrintLogger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.fail
import kotlin.time.Clock
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.minutes
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

/** Pairing, approvals, revocations and conflicts against a gateway that verifies nothing. */
class DeviceTrustTest {
    private val fileSystem = FakeFileSystem()
    private val storage = CoreStorage(fileSystem, "/state".toPath())
    private val gateway = FakeRosterGateway()
    private val machine = Signer.machine("d_studio")
    private val keys = softwareKeys("Test phone")
    private val config =
        TrustConfig(
            pairingPoll = 100.milliseconds,
            repost = 1.minutes,
            requestsPoll = 100.milliseconds,
        )

    private fun trust(keys: com.getdieter.core.platform.SoftwareDeviceKeys = this.keys) =
        DeviceTrust(
            keys,
            JcaSignatureVerifier,
            storage.scope("trust"),
            Clock.System,
            PrintLogger,
            config,
        )

    private fun TestScope.run(
        trust: DeviceTrust,
        gateway: RosterGateway = this@DeviceTrustTest.gateway,
    ): Job = backgroundScope.launch { trust.run("https://gateway.test:443", 42, gateway) }

    private fun TestScope.settle(describe: String, predicate: () -> Boolean) {
        repeat(400) {
            if (predicate()) return
            advanceTimeBy(50.milliseconds)
            runCurrent()
        }
        if (!predicate()) fail("timed out waiting for $describe")
    }

    /** Runs [trust] until the machine approved it with the code it shows. */
    private fun TestScope.paired(trust: DeviceTrust): Job {
        gateway.entries.value.ifEmpty { gateway.serve(roster(genesis(machine))) }
        val job = run(trust)
        settle("pending") { trust.view.value.pairingCode != null && gateway.requests.isNotEmpty() }
        gateway.approve(trust.view.value.pairingCode!!, machine)
        settle("trusted") { trust.view.value.state == TrustState.TRUSTED }
        return job
    }

    @Test
    fun anEmptyRosterAsksForAMachineFirstThenTheDeviceAsksToJoin() = runTest {
        val trust = trust()
        run(trust)
        settle("no roster") { trust.view.value.state == TrustState.NO_ROSTER }
        assertNull(trust.view.value.pairingCode)
        assertTrue(gateway.requests.isEmpty())

        gateway.serve(roster(genesis(machine)))
        settle("pending") { gateway.requests.isNotEmpty() }
        val view = trust.view.value
        assertEquals(TrustState.PENDING, view.state)
        val code = assertNotNull(view.pairingCode)
        val request = gateway.requests.values.single()
        assertEquals(trust.deviceId, request.device?.device_id)
        assertEquals("jvm", request.device?.platform)
        assertEquals("Test phone", request.device?.name)
        assertTrue(Pairing.verifyProof(Pairing.parse(code)!!, request.device!!, request.proof))
        assertFailsWith<CoreException> { trust.pin("d_studio") }
            .also {
                assertEquals(DeviceTrust.NOT_TRUSTED, it.message)
            }
    }

    @Test
    fun theCodeSurvivesARestartUntilTheDeviceIsPaired() = runTest {
        gateway.serve(roster(genesis(machine)))
        val first = trust()
        val job = run(first)
        settle("pending") { gateway.requests.isNotEmpty() }
        val code = first.view.value.pairingCode
        job.cancel()
        val second = trust()
        run(second)
        settle("pending again") { second.view.value.pairingCode != null }
        assertEquals(code, second.view.value.pairingCode)
        assertEquals(1, gateway.requests.size)
    }

    @Test
    fun aConfirmedApprovalPinsTheApproversRosterAndSurvivesRestarts() = runTest {
        val trust = trust()
        val job = paired(trust)
        val roster = assertNotNull(trust.view.value.roster)
        assertEquals(machine.id, roster.member(trust.deviceId)?.addedBy)
        assertEquals(gateway.posted.first().id, gateway.deleted.single())
        assertNull(trust.view.value.pairingCode)
        val pin = trust.pin("d_studio")
        assertEquals(machine.descriptor.public_key, pin.daemonPublicKey)
        assertEquals(trust.deviceId, pin.deviceId)
        assertEquals(
            DeviceTrust.MACHINE_NOT_TRUSTED,
            assertFailsWith<CoreException> { trust.pin("d_unknown") }.message,
        )

        // A restart trusts the pinned roster before the gateway answers.
        job.cancel()
        val restarted = trust()
        run(restarted, FakeRosterGateway())
        settle("trusted after restart") { restarted.view.value.state == TrustState.TRUSTED }
        assertEquals(roster.headHash, restarted.view.value.roster?.headHash)
    }

    @Test
    fun aFixtureCodeReplacesTheRandomOne() = runTest {
        gateway.serve(roster(genesis(machine)))
        val trust = trust()
        trust.usePairingCode("21FZ-7S2E-CZ4E-DY4Q")
        run(trust)
        settle("pending") { gateway.requests.isNotEmpty() }
        assertEquals("21FZ-7S2E-CZ4E-DY4Q", trust.view.value.pairingCode)
        gateway.approve("21fz 7s2e cz4e dy4q", machine)
        settle("trusted") { trust.view.value.state == TrustState.TRUSTED }
    }

    @Test
    fun aRosterContainingThisDeviceWithoutAValidConfirmationIsNeverPinned() = runTest {
        gateway.serve(roster(genesis(machine)))
        val trust = trust()
        run(trust)
        settle("pending") { gateway.requests.isNotEmpty() }
        val request = gateway.requests.values.single()
        // The gateway lists this device (even with a member's valid signature) and confirms
        // without the secret.
        val listed = roster(*gateway.entries.value.toTypedArray()).add(request.device!!, machine)
        gateway.serve(listed)
        val guessed = Pairing.newSecret()
        gateway.requests[request.id] =
            request.copy(
                confirmation =
                    Pairing.confirmation(guessed, listed.root, Rosters.hash(listed.entries.last()))
            )
        advanceTimeBy(2_000.milliseconds)
        runCurrent()
        assertEquals(TrustState.PENDING, trust.view.value.state)
        assertNull(trust.view.value.roster)
        assertTrue(gateway.deleted.isEmpty())
    }

    @Test
    fun aRosterThatDoesNotExtendThePinnedOneIsAConflictUntilReset() = runTest {
        val trust = trust()
        val job = paired(trust)
        val pinned = trust.view.value.roster!!
        val oldId = trust.deviceId
        // Another history at a sequence this device pinned.
        val fork =
            roster(*pinned.entries.take(1).toTypedArray())
                .add(Signer.app("Intruder").descriptor, machine)
        gateway.serve(fork)
        settle("conflict") { trust.view.value.state == TrustState.CONFLICT }
        assertNotNull(trust.view.value.conflict)
        assertFailsWith<CoreException> { trust.pin("d_studio") }
        assertFailsWith<CoreException> { trust.approve("21FZ-7S2E-CZ4E-DY4Q") }

        // The conflict outlives a restart.
        job.cancel()
        val restarted = trust()
        val second = run(restarted)
        settle("conflict after restart") { restarted.view.value.state == TrustState.CONFLICT }

        // Reset forgets the roster and the key and asks to join again.
        restarted.reset()
        settle("pending after reset") {
            restarted.view.value.state == TrustState.PENDING &&
                restarted.view.value.pairingCode != null
        }
        assertNotEquals(oldId, restarted.deviceId)
        assertNull(restarted.view.value.roster)
        second.cancel()
    }

    @Test
    fun aTrustedDeviceApprovesTheDeviceThatShowsTheCode() = runTest {
        val trust = trust()
        paired(trust)
        val tablet = Signer.app("Tablet")
        val secret = Pairing.newSecret()
        gateway.post(tablet.descriptor, Pairing.proof(secret, tablet.descriptor))
        gateway.post(
            Signer.app("Other").descriptor,
            Pairing.proof(Pairing.newSecret(), tablet.descriptor),
        )

        assertEquals(
            DeviceTrust.NO_SUCH_REQUEST,
            assertFailsWith<CoreException> { trust.approve(Pairing.code(Pairing.newSecret())) }
                .message,
        )
        assertEquals(
            DeviceTrust.INVALID_CODE,
            assertFailsWith<CoreException> { trust.approve("ABCD") }.message,
        )
        trust.approve(Pairing.code(secret).lowercase())
        val roster = trust.view.value.roster!!
        assertEquals(trust.deviceId, roster.member(tablet.id)?.addedBy)
        assertEquals(roster.headHash, Rosters.hash(gateway.entries.value.last()))
        val request = gateway.requests.values.first { it.device?.device_id == tablet.id }
        assertTrue(
            Pairing.verifyConfirmation(
                secret,
                roster.root,
                Rosters.hash(roster.addition(tablet.id)!!),
                request.confirmation,
            )
        )
        // Approving again confirms the same entry instead of adding the device twice.
        trust.approve(Pairing.code(secret))
        assertEquals(roster.length, trust.view.value.roster!!.length)
        val presented = DevicesPresenter.present(trust.view.value)
        assertEquals("Tablet was added by Test phone", presented.notices.first().text)
    }

    @Test
    fun anApprovalThatLosesAConcurrentAppendRetriesOnTheNewHead() = runTest {
        val trust = trust()
        paired(trust)
        val tablet = Signer.app("Tablet")
        val secret = Pairing.newSecret()
        gateway.post(tablet.descriptor, Pairing.proof(secret, tablet.descriptor))
        val laptop = Signer.app("Laptop")
        gateway.beforeAppend = {
            gateway.serve(
                roster(*gateway.entries.value.toTypedArray()).add(laptop.descriptor, machine)
            )
        }
        trust.approve(Pairing.code(secret))
        val roster = trust.view.value.roster!!
        assertNotNull(roster.member(laptop.id))
        assertNotNull(roster.member(tablet.id))
        assertEquals(tablet.id, roster.entries.last().device?.device_id)
    }

    @Test
    fun revokingRemovesDevicesAndRevokingThisDeviceEndsItsTrust() = runTest {
        val trust = trust()
        paired(trust)
        val tablet = Signer.app("Tablet")
        gateway.serve(roster(*gateway.entries.value.toTypedArray()).add(tablet.descriptor, machine))
        settle("tablet listed") { trust.view.value.roster?.member(tablet.id) != null }
        trust.revoke(tablet.id)
        assertTrue(trust.view.value.roster!!.member(tablet.id)!!.revoked)
        val presented = DevicesPresenter.present(trust.view.value)
        assertEquals(listOf(true, true, false), presented.devices.map { it.revocable })
        assertTrue(presented.devices.first().thisDevice)
        assertEquals("Tablet", presented.devices.last().name)
        assertTrue(presented.devices.last().revoked)

        trust.revoke(trust.deviceId)
        assertEquals(TrustState.REVOKED, trust.view.value.state)
        assertFailsWith<CoreException> { trust.pin("d_studio") }
    }

    @Test
    fun theLastDeviceThatConnectsCannotBeRemoved() = runTest {
        val trust = trust()
        paired(trust)
        trust.revoke(machine.id)
        assertEquals(
            "This is the last device that can connect, so it cannot be removed.",
            assertFailsWith<CoreException> { trust.revoke(trust.deviceId) }.message,
        )
    }
}
