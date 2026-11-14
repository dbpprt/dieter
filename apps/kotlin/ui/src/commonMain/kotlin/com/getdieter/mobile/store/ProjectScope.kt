package com.getdieter.mobile.store

import com.getdieter.api.v1.Checkout
import com.getdieter.api.v1.Project

/**
 * The checkout a project tool shows: [checkoutId] when the route names one, else the checkout the
 * core remembers for the project ([remembered]), the only attached one, the first attached one on
 * an [available] machine, and finally any checkout. Tools never fall back to another project.
 */
internal fun Project.toolCheckout(
    checkoutId: String,
    remembered: String,
    available: (daemonId: String) -> Boolean,
): Checkout? {
    checkouts
        .firstOrNull { it.id == checkoutId }
        ?.let {
            return it
        }
    val attached = checkouts.filterNot { it.detached }
    return attached.firstOrNull { it.id == remembered }
        ?: attached.singleOrNull()
        ?: attached.firstOrNull { available(it.daemon_id) }
        ?: attached.firstOrNull()
        ?: checkouts.firstOrNull()
}
