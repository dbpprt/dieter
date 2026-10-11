package com.dbpprt.dieter.core.connection

import com.dbpprt.dieter.client.v1.MachineEntry
import com.dbpprt.dieter.client.v1.MachineOutbox
import com.dbpprt.dieter.core.runtime.Failures

data class StorageWarning(val machineId: String, val title: String, val detail: String)

/** A failed write is local to its daemon; other machines and reads keep working. */
object StorageWarnings {
    fun of(machines: List<MachineEntry>, outboxes: List<MachineOutbox>): List<StorageWarning> {
        val queued =
            outboxes
                .filter { it.phase == MachineOutbox.Phase.PHASE_WAITING_FOR_STORAGE }
                .associate { it.daemon_id to StorageWarning(it.daemon_id, it.title, it.detail) }
        val streams =
            machines
                .filter { Failures.isInsufficientStorage(it.detail) }
                .associate {
                    val name = it.display_name.ifBlank { it.name.ifBlank { it.id } }
                    it.id to
                        StorageWarning(
                            it.id,
                            "Low disk space on $name",
                            "Free disk space on $name. Dieter will keep trying to receive updates.",
                        )
                }
        return (streams + queued).values.sortedBy { it.machineId }
    }
}
