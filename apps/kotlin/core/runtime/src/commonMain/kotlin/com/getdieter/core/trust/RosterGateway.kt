package com.getdieter.core.trust

import com.getdieter.api.gateway.v1.AppendDeviceRosterRequest
import com.getdieter.api.gateway.v1.ConfirmPairingRequestRequest
import com.getdieter.api.gateway.v1.DeviceDescriptor
import com.getdieter.api.gateway.v1.DeviceRoster
import com.getdieter.api.gateway.v1.DeviceRosterEntry
import com.getdieter.api.gateway.v1.GatewayServiceClient
import com.getdieter.api.gateway.v1.GetDeviceRosterRequest
import com.getdieter.api.gateway.v1.PairingRequest
import com.getdieter.api.gateway.v1.PairingRequestRef
import com.getdieter.api.gateway.v1.PostPairingRequestRequest
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import okio.ByteString

/**
 * The gateway as the roster's mailbox: it stores and serves entries and pairing notes but cannot
 * extend the roster. Every answer is verified by [DeviceTrust].
 */
interface RosterGateway {
    suspend fun roster(fromSequence: Long = 0): DeviceRoster

    /** The roster from [fromSequence], then one message per appended entry or entries. */
    fun watch(fromSequence: Long = 0): Flow<DeviceRoster>

    /** Compare-and-swap append; a concurrent append fails with gRPC ABORTED. */
    suspend fun append(entry: DeviceRosterEntry): DeviceRoster

    /** Idempotent per device ID: re-posting returns the same request. */
    suspend fun post(device: DeviceDescriptor, proof: ByteString): PairingRequest

    suspend fun list(): List<PairingRequest>

    suspend fun confirm(id: String, confirmation: ByteString): PairingRequest

    suspend fun delete(id: String)
}

/** [RosterGateway] over the gateway's gRPC service. */
class GrpcRosterGateway(private val client: GatewayServiceClient) : RosterGateway {
    override suspend fun roster(fromSequence: Long): DeviceRoster =
        client.GetDeviceRoster().execute(GetDeviceRosterRequest(from_sequence = fromSequence))

    override fun watch(fromSequence: Long): Flow<DeviceRoster> = flow {
        coroutineScope {
            val call = client.WatchDeviceRoster()
            val updates = call.executeIn(this, GetDeviceRosterRequest(from_sequence = fromSequence))
            try {
                for (update in updates) emit(update)
            } finally {
                call.cancel()
            }
        }
    }

    override suspend fun append(entry: DeviceRosterEntry): DeviceRoster =
        client.AppendDeviceRoster().execute(AppendDeviceRosterRequest(entry = entry))

    override suspend fun post(device: DeviceDescriptor, proof: ByteString): PairingRequest =
        client
            .PostPairingRequest()
            .execute(PostPairingRequestRequest(device = device, proof = proof))

    override suspend fun list(): List<PairingRequest> =
        client.ListPairingRequests().execute(Unit).requests

    override suspend fun confirm(id: String, confirmation: ByteString): PairingRequest =
        client
            .ConfirmPairingRequest()
            .execute(ConfirmPairingRequestRequest(id = id, confirmation = confirmation))

    override suspend fun delete(id: String) {
        client.DeletePairingRequest().execute(PairingRequestRef(id = id))
    }
}
