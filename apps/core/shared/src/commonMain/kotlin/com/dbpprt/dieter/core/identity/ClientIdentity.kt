package com.dbpprt.dieter.core.identity

import com.dbpprt.dieter.core.journal.ClientIdentityRecord
import com.dbpprt.dieter.core.storage.CoreStorage
import kotlin.uuid.Uuid

/**
 * This install's sync client ID. Daemons deduplicate commands by
 * (client_id, command_id), so the value must survive restarts and upgrades:
 * an install that already has a legacy ID keeps it.
 */
object ClientIdentity {
    private const val FILE = "client.pb"

    fun load(storage: CoreStorage, prefix: String, legacy: () -> String? = { null }): String {
        storage.read(FILE)?.let { bytes ->
            runCatching { ClientIdentityRecord.ADAPTER.decode(bytes).client_id }.getOrNull()?.takeIf { it.isNotBlank() }?.let { return it }
        }
        val value = legacy()?.takeIf { it.isNotBlank() } ?: "${prefix}_${Uuid.random()}"
        storage.write(FILE, ClientIdentityRecord.ADAPTER.encode(ClientIdentityRecord(client_id = value)))
        return value
    }
}
