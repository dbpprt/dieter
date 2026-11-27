package com.getdieter.mobile.store

import com.getdieter.api.v1.ReviewerSettings
import com.getdieter.client.v1.*
import com.getdieter.core.client.ClientSubscription
import com.getdieter.core.reviews.ReviewerForm
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/**
 * The account's code reviewer setting, edited on one machine ([ReviewerForm.machine]) whose catalog
 * the form's pickers show. The core reads, checks and saves it; this holder keeps what the form
 * shows while some view shows it ([show]).
 */
class CodeReviewModel internal constructor(private val context: StoreContext) {
    /** The setting as last read or saved; null until it arrives. */
    val settings = MutableStateFlow<ReviewerSettings?>(null)

    /** The machine the form edits; null while none is available. */
    val daemonId = MutableStateFlow<String?>(null)

    /** Machine catalogs, for the form's agent pickers. */
    val metadata = MutableStateFlow<Map<String, MachineMetadata>>(emptyMap())

    /** Why the setting could not be read or saved; empty otherwise. */
    val problem = MutableStateFlow("")
    val saving = MutableStateFlow(false)
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
        val machine = ReviewerForm.machine(machines)
        daemonId.value = machine
        if (machine == null) {
            problem.value = "No machine is online; the setting can change when one is."
            return
        }
        context.scope.launch {
            try {
                val read = context.serialized {
                    context.core.dispatch(
                        Command(
                            code_review = CodeReviewCommand(settings = CodeReviewMachine(machine))
                        )
                    )
                }
                read.reviewer_settings?.let { settings.value = it }
                problem.value = ""
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                problem.value = failure.message ?: "The reviewer setting is unavailable."
            }
        }
    }

    /** Saves [draft] where it was read; [saved] runs once the machine kept it. */
    fun save(draft: ReviewerSettings, saved: () -> Unit = {}) {
        val machine = daemonId.value.orEmpty()
        saving.value = true
        context.action {
            try {
                val result =
                    context.core.dispatch(
                        Command(
                            code_review =
                                CodeReviewCommand(
                                    update_settings = CodeReviewSettingsUpdate(machine, draft)
                                )
                        )
                    )
                result.reviewer_settings?.let { settings.value = it }
                problem.value = ""
                saved()
            } catch (failure: Throwable) {
                if (failure is CancellationException) throw failure
                problem.value = failure.message ?: "The reviewer setting was not saved."
            } finally {
                saving.value = false
            }
        }
    }
}
