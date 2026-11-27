package com.getdieter.mobile.store

import com.getdieter.api.v1.MemorySettings
import com.getdieter.api.v1.MemoryStatus
import com.getdieter.client.v1.*
import com.getdieter.core.client.ClientSubscription
import com.getdieter.core.memory.MemoryForm
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/** A project's memory as its settings show it: its state, and a dream started from there. */
data class ProjectMemory(
    /** The project's memory state on the machine that answered; null until it arrives. */
    val status: MemoryStatus? = null,
    /** Why the state could not be read, or the dream not started; empty otherwise. */
    val problem: String = "",
    val starting: Boolean = false,
    /** The dream started from here, running or failed. */
    val started: MemoryDreamState? = null,
)

/**
 * Agent memory: the account's memory setting, edited on one machine ([MemoryForm.machine]) whose
 * catalog the form's pickers show, and projects' memory state and dreams. The core reads, checks
 * and saves everything; this holder keeps what the views show while they show it.
 */
class MemoryModel internal constructor(private val context: StoreContext) {
    /**
     * The setting as last read or saved, with the daemon's defaults shown; null until it arrives.
     */
    val settings = MutableStateFlow<MemorySettings?>(null)

    /** The machine the form edits; null while none is available. */
    val daemonId = MutableStateFlow<String?>(null)

    /** Machine catalogs, for the form's agent pickers. */
    val metadata = MutableStateFlow<Map<String, MachineMetadata>>(emptyMap())

    /** Why the setting could not be read or saved; empty otherwise. */
    val problem = MutableStateFlow("")
    val saving = MutableStateFlow(false)

    /** Project ID → its memory state and the dream started for it. */
    val projects = MutableStateFlow<Map<String, ProjectMemory>>(emptyMap())
    private var viewers = 0
    private var subscription: ClientSubscription? = null

    /**
     * Reads the setting from [machines]' chosen machine and observes the catalogs while a view
     * shows the form; call the returned function when it leaves.
     */
    fun show(machines: List<MachineEntry>): () -> Unit {
        if (context.closed) return {}
        if (viewers++ == 0)
            subscription =
                context.observe(Slice.SLICE_METADATA, "") { update ->
                    update.metadata?.let { metadata.value = it.machines }
                }
        load(machines)
        var released = false
        return {
            if (!released) {
                released = true
                if (--viewers == 0) {
                    subscription?.close()
                    subscription = null
                }
            }
        }
    }

    /** Reads the setting again, e.g. after a machine came online. */
    fun load(machines: List<MachineEntry>) {
        val machine = MemoryForm.machine(machines)
        daemonId.value = machine
        if (machine == null) {
            problem.value = "No machine is online; the setting can change when one is."
            return
        }
        context.scope.launch {
            try {
                val read = context.serialized {
                    context.core.dispatch(
                        Command(memory = MemoryCommand(settings = MemoryMachine(machine)))
                    )
                }
                read.memory_settings?.let { settings.value = MemoryForm.withDefaults(it) }
                problem.value = ""
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                problem.value = failure.message ?: "The memory setting is unavailable."
            }
        }
    }

    /** Saves [draft] where it was read; [saved] runs once the machine kept it. */
    fun save(draft: MemorySettings, saved: () -> Unit = {}) {
        val machine = daemonId.value.orEmpty()
        saving.value = true
        context.action {
            try {
                val result =
                    context.core.dispatch(
                        Command(
                            memory =
                                MemoryCommand(
                                    update_settings = MemorySettingsUpdate(machine, draft)
                                )
                        )
                    )
                result.memory_settings?.let { settings.value = MemoryForm.withDefaults(it) }
                problem.value = ""
                saved()
            } catch (failure: Throwable) {
                if (failure is CancellationException) throw failure
                problem.value = failure.message ?: "The memory setting was not saved."
            } finally {
                saving.value = false
            }
        }
    }

    /** Reads [projectId]'s memory state, e.g. when its settings open. */
    fun loadProject(projectId: String) {
        if (context.closed || projectId.isEmpty()) return
        context.scope.launch {
            try {
                val read = context.serialized {
                    context.core.dispatch(
                        Command(memory = MemoryCommand(status = MemoryProjectRef(projectId)))
                    )
                }
                update(projectId) { it.copy(status = read.memory_status, problem = "") }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                update(projectId) {
                    it.copy(problem = failure.message ?: "The project's memory is unavailable.")
                }
            }
        }
    }

    /** Starts a dream of [projectId] now; its state is read again afterwards. */
    fun startDream(projectId: String) {
        if (projectId.isEmpty()) return
        update(projectId) { it.copy(starting = true, problem = "", started = null) }
        context.action {
            try {
                val result =
                    context.core.dispatch(
                        Command(memory = MemoryCommand(start_dream = MemoryProjectRef(projectId)))
                    )
                update(projectId) { it.copy(started = result.memory_dream) }
            } catch (failure: Throwable) {
                if (failure is CancellationException) throw failure
                update(projectId) {
                    it.copy(problem = failure.message ?: "The dream did not start.")
                }
            } finally {
                update(projectId) { it.copy(starting = false) }
            }
            loadProject(projectId)
        }
    }

    private fun update(projectId: String, change: (ProjectMemory) -> ProjectMemory) {
        val all = projects.value
        projects.value = all + (projectId to change(all[projectId] ?: ProjectMemory()))
    }
}
