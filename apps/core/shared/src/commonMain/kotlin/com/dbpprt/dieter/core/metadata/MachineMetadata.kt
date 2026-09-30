package com.dbpprt.dieter.core.metadata

import com.dbpprt.dieter.api.v1.HarnessCatalog
import com.dbpprt.dieter.api.v1.RuntimeStatus
import com.dbpprt.dieter.api.v1.SettingsOptions
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.session.MachineSessions
import kotlin.coroutines.cancellation.CancellationException
import kotlin.time.Clock
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/** What one machine offers: its agents, settings choices, and runtime readiness. */
data class MachineMetadata(
    val harnesses: HarnessCatalog? = null,
    val settingsOptions: SettingsOptions? = null,
    val runtime: RuntimeStatus? = null,
    val refreshedAt: Instant? = null,
    val error: String? = null,
) {
    val loaded: Boolean get() = harnesses != null
}

/**
 * Harness catalogs and runtime status per machine. A catalog belongs to the
 * machine that runs the conversation, so a stale catalog from another machine
 * is never used. Loads retry every 5 s until they succeed. Confined to the
 * core dispatcher.
 */
class MachineMetadataStore(
    private val sessions: MachineSessions,
    private val scope: CoroutineScope,
    private val clock: Clock,
    private val logger: CoreLogger,
) {
    private val mutableMachines = MutableStateFlow<Map<String, MachineMetadata>>(emptyMap())
    val machines: StateFlow<Map<String, MachineMetadata>> = mutableMachines.asStateFlow()
    private val loads = HashMap<String, Job>()

    /** Loads [daemonId]'s metadata once (retrying until it succeeds); [refresh] reloads it. */
    fun ensure(daemonId: String, refresh: Boolean = false) {
        if (!refresh && (mutableMachines.value[daemonId]?.loaded == true || loads[daemonId]?.isActive == true)) return
        loads[daemonId]?.cancel()
        loads[daemonId] = scope.launch {
            var attempt = 0
            while (true) {
                try {
                    val harnesses = sessions.call(daemonId) { it.GetHarnesses().execute(Unit) }
                    val options = runCatching { sessions.call(daemonId) { it.GetSettingsOptions().execute(Unit) } }
                        .onFailure { if (it is CancellationException) throw it }.getOrNull()
                    val runtime = runCatching { sessions.call(daemonId) { it.GetRuntimeStatus().execute(Unit) } }
                        .onFailure { if (it is CancellationException) throw it }.getOrNull()
                    mutableMachines.update { it + (daemonId to MachineMetadata(harnesses, options, runtime, clock.now())) }
                    return@launch
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    val message = Failures.message(error)
                    logger.debug(TAG, "metadata for $daemonId unavailable: $message")
                    mutableMachines.update { it + (daemonId to (it[daemonId] ?: MachineMetadata()).copy(error = message)) }
                    attempt++
                    delay(RETRY)
                }
            }
        }
    }

    fun forget() {
        loads.values.forEach(Job::cancel)
        loads.clear()
        mutableMachines.value = emptyMap()
    }

    private companion object {
        val RETRY = 5.seconds
        const val TAG = "Metadata"
    }
}
