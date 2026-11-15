package com.getdieter.android.notifications

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/** Play services owns background display; no daemon connection or keepalive service. */
class DieterMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        applicationContext
            .getSharedPreferences("dieter_push", MODE_PRIVATE)
            .edit()
            .putString("token", token)
            .apply()
        receiver?.setToken(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        if (
            message.data["dieter_badge"] == "0" && message.data[AndroidNotifications.SEALED] == null
        ) {
            AndroidNotifications.clear(applicationContext)
        }
        receiver?.receive(message.data)
    }

    companion object {
        @Volatile var receiver: AndroidNotifications? = null
    }
}
