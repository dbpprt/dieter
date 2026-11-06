package com.getdieter.core.identity

import com.getdieter.core.storage.CoreStorage
import com.getdieter.core.v1.ClientIdentityRecord
import kotlin.uuid.Uuid

/**
 * This install's sync client ID. Daemons deduplicate commands by (client_id, command_id), so the
 * value must survive restarts and upgrades.
 */
object ClientIdentity {
    private const val FILE = "client.pb"

    fun load(storage: CoreStorage, prefix: String): String {
        storage.read(FILE)?.let { bytes ->
            runCatching { ClientIdentityRecord.ADAPTER.decode(bytes).client_id }
                .getOrNull()
                ?.takeIf { it.isNotBlank() }
                ?.let {
                    return it
                }
        }
        val value = "${prefix}_${Uuid.random()}"
        storage.write(
            FILE,
            ClientIdentityRecord.ADAPTER.encode(ClientIdentityRecord(client_id = value)),
        )
        return value
    }
}
