package com.getdieter.core.client.rules

import com.getdieter.core.trust.Codes
import com.getdieter.core.trust.Pairing

/** The "Add a device" code field: what it shows while typing, and when it can approve. */
object DeviceExports {
    /**
     * [typed] as the field shows it: uppercase alphabet characters (O read as 0, I and L as 1) in
     * groups of four, at most 16, e.g. "ABCD-EFGH-JK".
     */
    fun pairingCodeInput(typed: String): String =
        Codes.group(Codes.normalize(typed).filter { it.isLetterOrDigit() }.take(16), 4)

    /** [typed] is a complete pairing code, so Approve can be enabled. */
    fun pairingCodeComplete(typed: String): Boolean = Pairing.parse(typed) != null
}
