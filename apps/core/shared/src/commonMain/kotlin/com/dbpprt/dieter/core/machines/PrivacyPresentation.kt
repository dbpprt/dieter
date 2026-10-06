package com.dbpprt.dieter.core.machines

import com.dbpprt.dieter.api.v1.MachinePrivacy

data class PrivacyPresentation(
    val label: String,
    val active: Boolean,
    val stale: Boolean,
    val warning: Boolean,
) {
    companion object {
        fun of(privacy: MachinePrivacy?, current: Boolean): PrivacyPresentation {
            if (privacy == null) return PrivacyPresentation("", false, false, false)
            val active = privacy.state == MachinePrivacy.State.STATE_ON
            val warning = privacy.state == MachinePrivacy.State.STATE_DEGRADED
            val label =
                when {
                    active -> "Privacy mode on — local displays and input blocked"
                    warning -> "Privacy protection is degraded: ${privacy.reason}"
                    else -> "Privacy mode off"
                }
            return PrivacyPresentation(
                if (current) label else "Last known: $label",
                active,
                !current,
                warning,
            )
        }
    }
}
