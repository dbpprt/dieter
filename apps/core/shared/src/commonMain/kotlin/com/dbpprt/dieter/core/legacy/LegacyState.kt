package com.dbpprt.dieter.core.legacy

import com.dbpprt.dieter.core.identity.Gateway
import com.dbpprt.dieter.core.journal.OutboxEntry
import com.dbpprt.dieter.core.navigation.KvActive
import com.dbpprt.dieter.core.navigation.KvCache
import com.dbpprt.dieter.core.notifications.NotificationSettings
import com.dbpprt.dieter.core.state.CreationPreferences
import com.dbpprt.dieter.core.state.DraftText

/**
 * Everything a legacy app kept on the device, parsed by [LegacyFormats].
 * [CoreRuntime.importLegacy] moves it into the core once, before the first
 * start; the legacy stores are left untouched for a rollback.
 */
data class LegacyState(
    val gateways: List<Gateway> = emptyList(),
    val activeOrigin: String? = null,
    /** Origin → the machine whose feed the app attached to. */
    val preferredMachines: Map<String, String> = emptyMap(),
    /** Origin → gateway session token. */
    val tokens: Map<String, String> = emptyMap(),
    val outbox: List<ForGateway<OutboxEntry>> = emptyList(),
    val navigation: List<ForGateway<KvCache>> = emptyList(),
    val activeNavigation: ForGateway<KvActive>? = null,
    val drafts: List<ForGateway<DraftText>> = emptyList(),
    /** `<daemon>|<project>|<card>` → terminal ID, oldest first. */
    val terminalSelections: List<ForGateway<Pair<String, String>>> = emptyList(),
    val notifications: NotificationSettings? = null,
    val creation: CreationPreferences? = null,
)

data class LegacyImportReport(
    val skipped: Boolean,
    val gateways: Int = 0,
    val tokens: Int = 0,
    val outboxEntries: Int = 0,
    val navigationCaches: Int = 0,
    val drafts: Int = 0,
    val terminalSelections: Int = 0,
)
