package com.getdieter.mobile.store

import com.getdieter.client.v1.Command
import com.getdieter.client.v1.Result
import com.getdieter.client.v1.Slice
import com.getdieter.client.v1.Update
import com.getdieter.core.client.ClientApi
import com.getdieter.core.client.ClientSubscription

/** The same typed core contract on Android/JVM and through the Apple byte bridge. */
interface MobileCore {
    suspend fun dispatch(command: Command): Result

    fun observe(slice: Slice, scope: String, receive: (Update) -> Unit): ClientSubscription
}

class RuntimeMobileCore(private val api: ClientApi) : MobileCore {
    override suspend fun dispatch(command: Command) = api.dispatch(command)

    override fun observe(slice: Slice, scope: String, receive: (Update) -> Unit) =
        api.observe(slice, scope, receive)
}

class MobilePreferences(
    val read: (String) -> String? = { null },
    val write: (String, String) -> Unit = { _, _ -> },
)
