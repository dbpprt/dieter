package com.getdieter.mobile.store

import com.getdieter.client.v1.*
import com.getdieter.core.client.ClientSubscription

/** Records dispatched commands and lets a test publish updates to each slice and scope. */
class FakeMobileCore(private val reply: (Command) -> Result = { Result(done = Done()) }) :
    MobileCore {
    val sent = mutableListOf<Command>()
    private val observers = mutableMapOf<Pair<Slice, String>, MutableList<(Update) -> Unit>>()

    override suspend fun dispatch(command: Command): Result {
        sent += command
        return reply(command)
    }

    override fun observe(
        slice: Slice,
        scope: String,
        receive: (Update) -> Unit,
    ): ClientSubscription {
        val key = slice to scope
        observers.getOrPut(key) { mutableListOf() } += receive
        return ClientSubscription { observers[key]?.remove(receive) }
    }

    fun observing(slice: Slice, scope: String = "") =
        observers[slice to scope].orEmpty().isNotEmpty()

    fun publish(slice: Slice, scope: String = "", update: Update) {
        observers[slice to scope].orEmpty().toList().forEach { it(update) }
    }

    /** The sent commands of one kind, e.g. `sentOf { it.files }`. */
    fun <T : Any> sentOf(select: (Command) -> T?): List<T> = sent.mapNotNull(select)
}
