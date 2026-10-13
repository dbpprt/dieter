package com.getdieter.core.trust

import com.getdieter.api.gateway.v1.DeviceDescriptor
import com.getdieter.api.gateway.v1.DeviceKeyAlgorithm
import com.getdieter.api.gateway.v1.DeviceKind
import com.getdieter.api.gateway.v1.DeviceRosterEntry
import com.getdieter.api.gateway.v1.GetDeviceRosterRequest
import com.getdieter.api.gateway.v1.PairingRequest
import com.getdieter.api.v1.SyncDeviceRosterRequest
import com.getdieter.api.v1.TrustServiceClient
import com.getdieter.api.v1.TrustState as DaemonTrustState
import com.getdieter.core.platform.DeviceKeys
import com.getdieter.core.platform.SignatureVerifier
import com.getdieter.core.runtime.Backoff
import com.getdieter.core.runtime.CoreException
import com.getdieter.core.runtime.CoreLogger
import com.getdieter.core.runtime.FailureKind
import com.getdieter.core.runtime.Failures
import com.getdieter.core.runtime.Timestamps
import com.getdieter.core.storage.CoreStorage
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Clock
import kotlin.time.Duration
import kotlin.time.Duration.Companion.minutes
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import okio.ByteString
import okio.ByteString.Companion.decodeBase64
import okio.ByteString.Companion.toByteString

/** This device's place in the active account's device roster. */
enum class TrustState {
    /** Signed out, or the gateway's roster has not been read yet. */
    UNKNOWN,

    /** The account has no roster: a machine must start it (`dieter device init`). */
    NO_ROSTER,

    /** This device asked to join and shows its pairing code until another device approves it. */
    PENDING,
    TRUSTED,

    /** This device was removed from the roster. */
    REVOKED,

    /** The gateway or a machine presented a roster that contradicts the pinned one. */
    CONFLICT,
}

/** What the core knows of this device's trust in the active account. */
data class TrustView(
    val state: TrustState = TrustState.UNKNOWN,
    /** This device's roster ID, derived from its key. */
    val deviceId: String = "",
    /** The pinned, verified roster while trusted, revoked, or in conflict. */
    val roster: Roster? = null,
    /** The one-time code to type on a trusted device while [state] is PENDING. */
    val pairingCode: String? = null,
    /** Devices waiting to join, newest first; read while trusted and observed. */
    val requests: List<PairingRequest> = emptyList(),
    /** Why the roster is in conflict. */
    val conflict: String? = null,
    /** The last failure to read or update the roster; cleared by the next success. */
    val problem: String? = null,
    /** The roster or the waiting devices are being read. */
    val loading: Boolean = false,
)

/** What a route needs: the target machine's pinned key and this device's TLS credentials. */
class RoutePin(
    /** The machine's DER SubjectPublicKeyInfo from the pinned roster. */
    val daemonPublicKey: ByteString,
    /** This device's roster ID, which daemon tokens are bound to. */
    val deviceId: String,
    /** This device's self-signed DER certificate. */
    val clientCertificate: ByteString,
)

/** The trust a route selection needs; throws when this device or the machine is not trusted. */
fun interface RouteTrust {
    fun pin(daemonId: String): RoutePin
}

data class TrustConfig(
    /** How often a pending device asks whether it was approved. */
    val pairingPoll: Duration = 2.seconds,
    /** A pending request is posted again before the gateway's 15-minute expiry. */
    val repost: Duration = 5.minutes,
    /** How often a trusted device rereads waiting devices while they are shown. */
    val requestsPoll: Duration = 5.seconds,
    /** Approvals and revocations that lose a concurrent append retry this often. */
    val appendAttempts: Int = 5,
)

/**
 * This device's membership in the account device roster, per gateway account: the pinned roster
 * (verified locally; the gateway can withhold entries but not add a device or rewrite what is
 * pinned), pairing while not a member, approvals, revocations and roster gossip with machines.
 *
 * State lives in [storage] (outside each account's synchronized data, so signing out keeps it): one
 * directory per gateway origin and GitHub account holds `roster.pb` (the pinned roster, an encoded
 * `DeviceRoster`), `conflict` (why the roster conflicts) and, while pending, the pairing secret and
 * request ID. Confined to the core dispatcher.
 */
class DeviceTrust(
    private val keys: DeviceKeys,
    private val verifier: SignatureVerifier,
    private val storage: CoreStorage,
    private val clock: Clock,
    private val logger: CoreLogger,
    private val config: TrustConfig = TrustConfig(),
) : RouteTrust {
    private val mutableView = MutableStateFlow(TrustView())
    val view: StateFlow<TrustView> = mutableView.asStateFlow()

    /** The bound account's directory and the gateway while its session runs. */
    private var bound: String? = null
    private var directory: CoreStorage? = null
    private var gateway: RosterGateway? = null

    /** The gateway's roster as the current watch served it. */
    private var served: List<DeviceRosterEntry>? = null
    private var fixtureSecret: ByteArray? = null
    private var credentials: Credentials? = null
    private val requestObservers = MutableStateFlow(0)

    /** Advances whenever the pairing secret or key changes, restarting a pending request. */
    private val pairingEpoch = MutableStateFlow(0)

    private class Credentials(
        val publicKey: ByteArray,
        val deviceId: String,
        val certificate: ByteString,
    )

    /** This device's key, ID and certificate, created on first use. */
    private fun credentials(): Credentials {
        credentials?.let {
            return it
        }
        val publicKey = keys.publicKey()
        val deviceId = Rosters.deviceId(publicKey)
        return Credentials(
                publicKey,
                deviceId,
                DeviceCertificate.selfSigned(publicKey, deviceId, keys::sign),
            )
            .also { credentials = it }
    }

    /** This device's roster ID. */
    val deviceId: String
        get() = credentials().deviceId

    /**
     * Isolated fixtures only: pair with the secret of [code], which the fixture's machine approves,
     * instead of a random one.
     */
    fun usePairingCode(code: String) {
        val secret = Pairing.parse(code) ?: throw CoreException(FailureKind.PERMANENT, INVALID_CODE)
        fixtureSecret = secret
        directory?.let { saveSecret(it, secret) }
        pairingEpoch.update { it + 1 }
    }

    /** Forgets the bound account in memory, e.g. after sign-out or a gateway switch. */
    fun forget() {
        bound = null
        directory = null
        served = null
        mutableView.value = TrustView()
    }

    /**
     * Binds the account of [origin] and [githubId] and keeps its roster current through [gateway]
     * until cancelled: watches the gateway's roster, pairs while this device is not a member, and
     * reads waiting devices while they are observed.
     */
    suspend fun run(origin: String, githubId: Long, gateway: RosterGateway) {
        bind("$origin|github:$githubId")
        this.gateway = gateway
        try {
            coroutineScope {
                launch { watch(gateway) }
                launch {
                    combine(view.map { it.state == TrustState.PENDING }, pairingEpoch) {
                            pending,
                            epoch ->
                            pending to epoch
                        }
                        .distinctUntilChanged()
                        .collectLatest { (pending, _) -> if (pending) pair(gateway) }
                }
                launch {
                    combine(view.map { it.state == TrustState.TRUSTED }, requestObservers) {
                            trusted,
                            observers ->
                            trusted && observers > 0
                        }
                        .distinctUntilChanged()
                        .collectLatest { shown ->
                            if (!shown) return@collectLatest
                            while (true) {
                                readRequests(gateway)
                                delay(config.requestsPoll)
                            }
                        }
                }
            }
        } finally {
            if (this.gateway === gateway) this.gateway = null
            served = null
            mutableView.update { it.copy(loading = false) }
        }
    }

    /** Waiting devices are read while at least one view shows them; call the result to stop. */
    fun observeRequests(): () -> Unit {
        requestObservers.update { it + 1 }
        var released = false
        return {
            if (!released) {
                released = true
                requestObservers.update { it - 1 }
            }
        }
    }

    private fun bind(key: String) {
        if (bound == key) return
        bound = key
        served = null
        val scoped = storage.scope(key)
        directory = scoped
        fixtureSecret?.let { saveSecret(scoped, it) }
        val pinned =
            scoped.read(ROSTER)?.let { bytes ->
                try {
                    Roster.decode(bytes, verifier)
                } catch (error: Throwable) {
                    logger.warn(
                        TAG,
                        "the pinned device roster does not verify; pairing again",
                        error,
                    )
                    scoped.delete(ROSTER)
                    null
                }
            }
        val conflict = scoped.read(CONFLICT)?.decodeToString()
        val ownId = deviceId
        mutableView.value =
            when {
                conflict != null ->
                    TrustView(TrustState.CONFLICT, ownId, roster = pinned, conflict = conflict)
                pinned != null && pinned.member(ownId) != null -> pinnedView(pinned)
                else -> {
                    // A key the pinned roster never listed (e.g. a restored backup) pairs again.
                    if (pinned != null) scoped.delete(ROSTER)
                    TrustView(TrustState.UNKNOWN, ownId)
                }
            }
    }

    private fun pinnedView(roster: Roster): TrustView {
        val ownId = deviceId
        val revoked = roster.member(ownId)?.active != true
        return mutableView.value.copy(
            state = if (revoked) TrustState.REVOKED else TrustState.TRUSTED,
            deviceId = ownId,
            roster = roster,
            pairingCode = null,
            conflict = null,
            requests = if (revoked) emptyList() else mutableView.value.requests,
        )
    }

    /** Pins [roster] and persists it. */
    private fun pin(roster: Roster) {
        val scoped = directory ?: return
        val previous = mutableView.value.roster
        if (previous == null || roster.length > previous.length)
            scoped.write(ROSTER, roster.encode())
        mutableView.value = pinnedView(roster)
    }

    private fun enterConflict(reason: String) {
        logger.warn(TAG, "device roster conflict: $reason")
        directory?.write(CONFLICT, reason.encodeToByteArray())
        mutableView.update {
            it.copy(
                state = TrustState.CONFLICT,
                conflict = reason,
                pairingCode = null,
                requests = emptyList(),
            )
        }
    }

    // --- Gateway roster ----------------------------------------------------------------

    private suspend fun watch(gateway: RosterGateway) {
        var attempt = 0
        while (true) {
            mutableView.update { it.copy(loading = true) }
            try {
                val entries = mutableListOf<DeviceRosterEntry>()
                gateway.watch(0).collect { message ->
                    attempt = 0
                    // A replaced roster is sent again from its genesis.
                    for (entry in message.entries) {
                        val sequence = entry.sequence
                        if (sequence < 0 || sequence > entries.size) continue
                        while (entries.size > sequence) entries.removeAt(entries.lastIndex)
                        entries += entry
                    }
                    served = entries.toList()
                    evaluate(entries.toList())
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                logger.info(TAG, "device roster watch ended: ${Failures.message(error)}")
                mutableView.update {
                    it.copy(loading = false, problem = readProblem(error))
                }
            }
            delay(Backoff.STREAM.delay(attempt++))
        }
    }

    /** Applies the gateway's roster [entries] (from sequence 0) to this device's state. */
    private fun evaluate(entries: List<DeviceRosterEntry>) {
        val current = mutableView.value
        mutableView.update { it.copy(loading = false) }
        when (current.state) {
            TrustState.CONFLICT -> return
            TrustState.TRUSTED,
            TrustState.REVOKED -> {
                val pinned = current.roster ?: return
                try {
                    val next = pinned.extend(entries, verifier)
                    if (next.length > pinned.length) pin(next)
                    mutableView.update { it.copy(problem = null) }
                } catch (rejected: RosterException) {
                    if (rejected.conflict) enterConflict(CONFLICT_GATEWAY)
                    else {
                        logger.warn(
                            TAG,
                            "the gateway served an invalid roster: ${rejected.message}",
                        )
                        mutableView.update { it.copy(problem = INVALID_ROSTER) }
                    }
                }
            }
            TrustState.UNKNOWN,
            TrustState.NO_ROSTER,
            TrustState.PENDING -> {
                // A roster that merely lists this device is never enough to trust it: only the
                // approver's confirmation pins one (see pair).
                val next = if (entries.isEmpty()) TrustState.NO_ROSTER else TrustState.PENDING
                if (next != current.state)
                    mutableView.update {
                        it.copy(
                            state = next,
                            pairingCode = if (next == TrustState.PENDING) it.pairingCode else null,
                            problem = null,
                        )
                    }
            }
        }
    }

    /** Rereads the gateway's roster into the pinned one; a conflict throws. */
    private suspend fun refreshPinned(gateway: RosterGateway): Roster {
        val pinned =
            mutableView.value.roster ?: throw CoreException(FailureKind.PERMANENT, NOT_TRUSTED)
        val served = gateway.roster(0)
        return try {
            pinned.extend(served.entries, verifier).also { if (it.length > pinned.length) pin(it) }
        } catch (rejected: RosterException) {
            if (rejected.conflict) {
                enterConflict(CONFLICT_GATEWAY)
                throw CoreException(FailureKind.PERMANENT, CONFLICT_GATEWAY)
            }
            throw CoreException(FailureKind.TRANSIENT, INVALID_ROSTER)
        }
    }

    // --- Pairing (this device) ----------------------------------------------------------

    /** Asks to join until a trusted device approves this device, or the state changes. */
    private suspend fun pair(gateway: RosterGateway) {
        val scoped = directory ?: return
        val secret =
            fixtureSecret
                ?: scoped.read(SECRET)?.takeIf { it.size == Pairing.SECRET_BYTES }
                ?: Pairing.newSecret().also { saveSecret(scoped, it) }
        mutableView.update { it.copy(pairingCode = Pairing.code(secret)) }
        val device = descriptor()
        val proof = Pairing.proof(secret, device)
        var requestId = scoped.read(REQUEST)?.decodeToString()
        var repostAt = Instant.DISTANT_PAST
        while (true) {
            try {
                if (requestId == null || clock.now() >= repostAt) {
                    val posted = gateway.post(device, proof)
                    requestId = posted.id
                    scoped.write(REQUEST, posted.id.encodeToByteArray())
                    val expiry = Timestamps.parse(posted.expires_at)
                    repostAt =
                        minOf(
                            clock.now() + config.repost,
                            expiry?.minus(2.minutes) ?: (clock.now() + config.repost),
                        )
                }
                val mine = gateway.list().firstOrNull { it.id == requestId }
                when {
                    mine == null -> requestId = null
                    mine.confirmation.size > 0 -> if (confirm(gateway, secret, mine)) return
                }
                mutableView.update { it.copy(problem = null) }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                logger.info(TAG, "pairing request failed: ${Failures.message(error)}")
                mutableView.update { it.copy(problem = readProblem(error)) }
            }
            delay(config.pairingPoll)
        }
    }

    /**
     * Pins the gateway's roster if [request]'s confirmation proves the approver added this device
     * to exactly that roster.
     */
    private suspend fun confirm(
        gateway: RosterGateway,
        secret: ByteArray,
        request: PairingRequest,
    ): Boolean {
        val served = gateway.roster(0)
        val roster =
            try {
                Roster.verify(served.entries, verifier)
            } catch (rejected: RosterException) {
                logger.warn(TAG, "the approved roster does not verify: ${rejected.message}")
                return false
            }
        val ownId = deviceId
        val addition = roster.addition(ownId) ?: return false
        if (
            !Pairing.verifyConfirmation(
                secret,
                roster.root,
                Rosters.hash(addition),
                request.confirmation,
            )
        ) {
            logger.warn(TAG, "the pairing confirmation does not match the gateway's roster")
            return false
        }
        directory?.let {
            it.delete(SECRET)
            it.delete(REQUEST)
        }
        mutableView.update { it.copy(roster = null) }
        pin(roster)
        try {
            gateway.delete(request.id)
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            logger.info(
                TAG,
                "the pairing request stays until it expires: ${Failures.message(error)}",
            )
        }
        return true
    }

    /** This device as it asks to join. */
    private fun descriptor(): DeviceDescriptor {
        val own = credentials()
        return DeviceDescriptor(
            device_id = own.deviceId,
            kind = DeviceKind.DEVICE_KIND_CLIENT,
            platform = platformLabel(keys.platform),
            name = deviceName(keys.deviceName),
            algorithm = DeviceKeyAlgorithm.DEVICE_KEY_ALGORITHM_ECDSA_P256_SHA256,
            public_key = own.publicKey.toByteString(),
        )
    }

    private fun saveSecret(scoped: CoreStorage, secret: ByteArray) {
        if (scoped.read(SECRET)?.contentEquals(secret) == true) return
        scoped.write(SECRET, secret)
        // A request posted with another secret carries the wrong proof.
        scoped.delete(REQUEST)
    }

    // --- Approving, revoking and resetting ------------------------------------------------

    /** Rereads the roster and, when shown, the waiting devices. */
    suspend fun refresh() {
        val gateway = connected()
        when (mutableView.value.state) {
            TrustState.TRUSTED,
            TrustState.REVOKED -> {
                refreshPinned(gateway)
                if (mutableView.value.state == TrustState.TRUSTED) readRequests(gateway)
            }
            TrustState.CONFLICT -> {}
            else -> {
                val roster = gateway.roster(0)
                served = roster.entries
                evaluate(roster.entries)
            }
        }
    }

    /**
     * Signs the device that shows [code] into the roster and confirms it to that device. The
     * request whose proof verifies with the code's secret is the one the new device posted, so the
     * gateway cannot substitute another key.
     */
    suspend fun approve(code: String) {
        val secret =
            Pairing.parse(code.trim()) ?: throw CoreException(FailureKind.PERMANENT, INVALID_CODE)
        val gateway = connected()
        requireTrusted()
        val request =
            gateway.list().firstOrNull { request ->
                request.device?.let { Pairing.verifyProof(secret, it, request.proof) } == true
            } ?: throw CoreException(FailureKind.PERMANENT, NO_SUCH_REQUEST)
        val device = request.device!!
        Rosters.descriptorProblem(device)?.let {
            throw CoreException(FailureKind.PERMANENT, "This device cannot join: $it.")
        }
        repeat(config.appendAttempts) {
            val roster = refreshPinned(gateway)
            requireTrusted()
            val existing = roster.member(device.device_id)
            val addition =
                if (existing != null) {
                    // An earlier approval whose confirmation did not arrive: confirm it again.
                    if (!existing.active)
                        throw CoreException(
                            FailureKind.PERMANENT,
                            "This device was removed from your account. Reset trust on it to pair it again.",
                        )
                    roster.addition(device.device_id)!!
                } else {
                    val entry = Roster.signed(roster.addition(device, deviceId, now()), keys::sign)
                    val next =
                        try {
                            roster.extend(listOf(entry), verifier)
                        } catch (rejected: RosterException) {
                            throw CoreException(
                                FailureKind.PERMANENT,
                                "This device cannot join: ${rejected.message}.",
                            )
                        }
                    if (!append(gateway, entry)) return@repeat
                    pin(next)
                    entry
                }
            gateway.confirm(
                request.id,
                Pairing.confirmation(secret, roster.root, Rosters.hash(addition)),
            )
            readRequests(gateway)
            return
        }
        throw CoreException(FailureKind.TRANSIENT, BUSY)
    }

    /** Removes [deviceId] from the roster; removing this device revokes it. */
    suspend fun revoke(deviceId: String) {
        val gateway = connected()
        requireTrusted()
        repeat(config.appendAttempts) {
            val roster = refreshPinned(gateway)
            requireTrusted()
            val member =
                roster.member(deviceId)
                    ?: throw CoreException(
                        FailureKind.PERMANENT,
                        "This device is not in your account.",
                    )
            if (!member.active) return
            if (member.kind == DeviceKind.DEVICE_KIND_RECOVERY)
                throw CoreException(FailureKind.PERMANENT, "A recovery key cannot be removed here.")
            if (member.connects && roster.connectingCount == 1)
                throw CoreException(
                    FailureKind.PERMANENT,
                    "This is the last device that can connect, so it cannot be removed.",
                )
            val entry = Roster.signed(roster.revocation(deviceId, this.deviceId, now()), keys::sign)
            val next =
                try {
                    roster.extend(listOf(entry), verifier)
                } catch (rejected: RosterException) {
                    throw CoreException(
                        FailureKind.PERMANENT,
                        "The device cannot be removed: ${rejected.message}.",
                    )
                }
            if (!append(gateway, entry)) return@repeat
            pin(next)
            return
        }
        throw CoreException(FailureKind.TRANSIENT, BUSY)
    }

    /** Appends [entry]; false when another device appended first. */
    private suspend fun append(gateway: RosterGateway, entry: DeviceRosterEntry): Boolean =
        try {
            gateway.append(entry)
            true
        } catch (error: GrpcException) {
            if (error.grpcStatus == GrpcStatus.ABORTED) false else throw error
        }

    /**
     * Forgets every pinned roster, this device's key and pairing secret, then asks to join again
     * with a new key and code. Used after a conflict or a revocation.
     */
    fun reset() {
        storage.clear()
        keys.reset()
        credentials = null
        val key = bound
        val last = served
        bound = null
        directory = null
        mutableView.value = TrustView()
        pairingEpoch.update { it + 1 }
        if (key != null) {
            bind(key)
            served = last
            last?.let { evaluate(it) }
        }
    }

    private suspend fun readRequests(gateway: RosterGateway) {
        try {
            val roster = mutableView.value.roster ?: return
            val ownId = deviceId
            val waiting =
                gateway
                    .list()
                    .filter { request ->
                        val id = request.device?.device_id ?: return@filter false
                        id != ownId && roster.member(id)?.active != true
                    }
                    .sortedByDescending {
                        Timestamps.parse(it.requested_at) ?: Instant.DISTANT_PAST
                    }
            mutableView.update { it.copy(requests = waiting) }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            logger.info(TAG, "waiting devices unavailable: ${Failures.message(error)}")
        }
    }

    // --- Machines -----------------------------------------------------------------------

    override fun pin(daemonId: String): RoutePin {
        val current = mutableView.value
        if (current.state != TrustState.TRUSTED)
            throw CoreException(FailureKind.TRANSIENT, NOT_TRUSTED)
        val member =
            current.roster?.daemon(daemonId)
                ?: throw CoreException(FailureKind.TRANSIENT, MACHINE_NOT_TRUSTED)
        val own = credentials()
        return RoutePin(member.descriptor.public_key, own.deviceId, own.certificate)
    }

    /** The pinned key of [daemonId]'s machine while trusted, else null. */
    fun daemonKey(daemonId: String): ByteString? =
        mutableView.value
            .takeIf { it.state == TrustState.TRUSTED }
            ?.roster
            ?.daemon(daemonId)
            ?.descriptor
            ?.public_key

    /**
     * Compares roster heads with a machine over its authenticated connection: hands it entries it
     * lacks, adopts entries it has that the gateway withheld, and enters CONFLICT when the two
     * histories differ.
     */
    suspend fun gossip(daemonId: String, client: TrustServiceClient) {
        val pinned = mutableView.value.roster ?: return
        if (mutableView.value.state != TrustState.TRUSTED) return
        val status = client.GetTrustStatus().execute(Unit)
        if (status.state != DaemonTrustState.TRUST_STATE_TRUSTED) return
        val root = status.root_hash.decodeBase64()?.takeIf { it.size == 32 }
        val head = status.head_hash.decodeBase64()?.takeIf { it.size == 32 }
        if (root == null || head == null) {
            logger.info(TAG, "$daemonId reported no roster head")
            return
        }
        val machine = pinned.daemon(daemonId)?.descriptor?.name ?: daemonId
        val conflict = "$machine trusts devices that contradict the ones this device pinned."
        if (root != pinned.root) return enterConflict(conflict)
        val sequence = status.head_sequence
        when {
            sequence == pinned.headSequence -> if (head != pinned.headHash) enterConflict(conflict)
            sequence < pinned.headSequence -> {
                if (head != pinned.hashAt(sequence)) return enterConflict(conflict)
                client
                    .SyncDeviceRoster()
                    .execute(SyncDeviceRosterRequest(entries = pinned.entriesFrom(sequence + 1)))
            }
            else -> {
                var roster = gateway?.let { refreshPinned(it) } ?: pinned
                if (roster.headSequence < sequence) {
                    val missing =
                        client
                            .GetDeviceRoster()
                            .execute(GetDeviceRosterRequest(from_sequence = roster.length.toLong()))
                    roster =
                        try {
                            roster.extend(missing.entries, verifier)
                        } catch (rejected: RosterException) {
                            if (rejected.conflict) return enterConflict(conflict)
                            logger.warn(
                                TAG,
                                "$daemonId served an invalid roster: ${rejected.message}",
                            )
                            return
                        }
                    if (roster.length > pinned.length) pin(roster)
                }
                if (roster.hashAt(sequence)?.let { it != head } == true) enterConflict(conflict)
            }
        }
    }

    private fun connected(): RosterGateway =
        gateway ?: throw CoreException(FailureKind.TRANSIENT, "Connect to your gateway first.")

    private fun requireTrusted() {
        when (mutableView.value.state) {
            TrustState.TRUSTED -> {}
            TrustState.CONFLICT -> throw CoreException(FailureKind.PERMANENT, CONFLICT_GATEWAY)
            TrustState.REVOKED ->
                throw CoreException(
                    FailureKind.PERMANENT,
                    "This device was removed from your account.",
                )
            else -> throw CoreException(FailureKind.PERMANENT, NOT_TRUSTED)
        }
    }

    /** Now in RFC 3339 UTC without fractions, as roster entries record it. */
    private fun now(): String = Instant.fromEpochSeconds(clock.now().epochSeconds).toString()

    private fun readProblem(error: Throwable): String =
        if (error is CoreException) error.message.orEmpty()
        else "Trusted devices could not be read: ${Failures.message(error)}"

    companion object {
        private const val TAG = "DeviceTrust"
        private const val ROSTER = "roster.pb"
        private const val CONFLICT = "conflict"
        private const val SECRET = "pairing.secret"
        private const val REQUEST = "pairing.request"

        const val NOT_TRUSTED = "This device is not trusted yet."
        const val MACHINE_NOT_TRUSTED = "This machine is not in your trusted devices."
        const val NO_SUCH_REQUEST = "No device is waiting with this code."
        const val INVALID_CODE =
            "That is not a pairing code. It has 16 characters, like ABCD-EFGH-JKMN-PQRS."
        const val CONFLICT_GATEWAY =
            "Your gateway served trusted devices that contradict the ones this device pinned."
        const val INVALID_ROSTER = "Your gateway served trusted devices that do not verify."
        const val BUSY = "Other devices kept changing your trusted devices. Try again."

        /** A roster platform label: 1..16 characters of [a-z0-9]. */
        fun platformLabel(value: String): String =
            value.lowercase().filter { it in 'a'..'z' || it in '0'..'9' }.take(16).ifEmpty { "app" }

        /** A roster display name: no control characters, at most 64 UTF-8 bytes. */
        fun deviceName(value: String): String {
            var name = value.filterNot { it.isISOControl() }.trim()
            while (name.encodeToByteArray().size > Rosters.MAX_NAME_BYTES) {
                name =
                    name.dropLast(
                        if (name.length >= 2 && name[name.length - 1].isLowSurrogate()) 2 else 1
                    )
            }
            return name.trim().ifEmpty { "Dieter app" }
        }
    }
}
