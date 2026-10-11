package com.getdieter.mobile.store

import com.getdieter.client.v1.Command
import com.getdieter.client.v1.Slice
import com.getdieter.client.v1.Update
import com.getdieter.core.client.ClientSubscription
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * The coordinator's plumbing that every state holder shares: one core, one scope, serialized
 * commands, the ordered input channel, and the shared busy and error state.
 */
internal class StoreContext(val core: MobileCore, val scope: CoroutineScope) {
    val busy = MutableStateFlow(false)
    val error = MutableStateFlow("")
    var closed = false
    private val commands = Mutex()
    private val inputCommands = Channel<Command>(64)
    private val subscriptions = mutableListOf<ClientSubscription>()

    /** Sends terminal and screen input in order, beside the serialized commands. */
    fun startInput() {
        scope.launch {
            for (input in inputCommands) {
                try {
                    core.dispatch(input)
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: Throwable) {
                    error.value = failure.message ?: "Could not send input."
                }
            }
        }
    }

    fun input(command: Command) {
        if (!closed && inputCommands.trySend(command).isFailure)
            error.value =
                "Input is arriving too quickly. Some input could not be sent; wait and try again."
    }

    fun action(block: suspend () -> Unit) {
        if (closed) return
        scope.launch {
            commands.withLock {
                busy.value = true
                error.value = ""
                try {
                    block()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: Throwable) {
                    error.value = failure.message ?: "The action failed."
                } finally {
                    busy.value = false
                }
            }
        }
    }

    fun command(command: Command) = action { core.dispatch(command) }

    /** Runs [block] in turn with the serialized commands, without showing the busy state. */
    suspend fun <T> serialized(block: suspend () -> T): T = commands.withLock { block() }

    fun observe(slice: Slice, key: String, receive: (Update) -> Unit): ClientSubscription =
        core.observe(slice, key) { update ->
            scope.launch {
                if (!closed) {
                    update.failure?.let { error.value = it.message }
                    receive(update)
                }
            }
        }

    /** Observes [slice] for the store's whole lifetime. */
    fun observeAlways(slice: Slice, key: String, receive: (Update) -> Unit) {
        subscriptions += observe(slice, key, receive)
    }

    /** Ends every lifetime observation, the input channel and pending work. */
    fun release() {
        subscriptions.forEach(ClientSubscription::close)
        inputCommands.close()
        scope.cancel()
    }
}
