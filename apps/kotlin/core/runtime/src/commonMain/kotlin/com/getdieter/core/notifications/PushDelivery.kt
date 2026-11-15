package com.getdieter.core.notifications

import okio.ByteString

/** OS adapters decrypt; account binding, pending taps and presentation rules are shared. */
class PushDelivery(private val decrypt: (String, ByteString) -> String?) {
    private var account: String? = null
    private var pending: ByteString? = null
    private var pendingLocal: Pair<String, String>? = null
    val accountKey: String?
        get() = account

    private var visible: String? = null
    private val presented = linkedSetOf<ByteString>()
    var available: Boolean = false
        private set

    fun registered(value: Boolean) {
        available = value
    }

    fun visible(cardId: String?) {
        visible = cardId
    }

    fun reset() {
        account = null
        visible = null
        available = false
        presented.clear()
        // Keep one encrypted cold tap through sign-in. It can open only under its key.
    }

    fun bind(accountKey: String): String? {
        if (account != accountKey) {
            reset()
            account = accountKey
        }
        return openPending()
    }

    fun cardId(sealed: ByteString): String? {
        if (sealed.size !in 60..2048) return null
        return account?.let { decrypt(it, sealed) }?.takeIf { it.isNotBlank() && it.length <= 256 }
    }

    fun tap(sealed: ByteString): String? {
        if (sealed.size !in 60..2048) return null
        pendingLocal = null
        pending = sealed
        return openPending()
    }

    fun tapLocal(accountKey: String, cardId: String): String? {
        if (
            accountKey.isBlank() ||
                accountKey.length > 2048 ||
                cardId.isBlank() ||
                cardId.length > 256
        )
            return null
        pending = null
        pendingLocal = accountKey to cardId
        return openPending()
    }

    private fun openPending(): String? {
        val local = pendingLocal
        val id =
            if (local != null) local.second.takeIf { local.first == account }
            else pending?.let(::cardId)
        if (id == null) return null
        pendingLocal = null
        pending = null
        return id
    }

    /** Unknown/account-mismatched destinations never produce a foreground banner. */
    fun present(sealed: ByteString): Boolean {
        val id = cardId(sealed) ?: return false
        val receipt = sealed.sha256()
        if (!presented.add(receipt)) return false
        while (presented.size > 64) presented.remove(presented.first())
        return id != visible
    }
}
