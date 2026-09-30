package com.dbpprt.dieter.core.legacy

import com.dbpprt.dieter.core.identity.Gateway
import com.dbpprt.dieter.core.navigation.KvActive

/** The macOS and iOS apps' raw legacy values from UserDefaults, files, and the Keychain. */
class AppleLegacyInput(
    /** macOS `DieterEndpoints` and `DieterActiveEndpoint` (JSON). */
    val endpointsJson: String?,
    val activeEndpointJson: String?,
    /** macOS `gateway-sessions.json`. */
    val tokensJson: String?,
    /** iOS `DieterIOSGateway`, its Keychain token, and `DieterIOSUtilityMachine:<origin>`. */
    val iosGateway: String?,
    val iosToken: String?,
    val iosPreferredMachine: String?,
    /** macOS `Application Support/Dieter/pending-commands.json`. */
    val pendingCommandsJson: String?,
    /** macOS `DieterSharedKV.activeAccount`/`.activeDaemon` and that account's `shared-kv/<hash>.json`. */
    val sharedKvAccount: String?,
    val sharedKvDaemon: String?,
    val sharedKvJson: String?,
    /** macOS `DieterConversationDraftTexts`, `quickTask.lastChoices`, `DieterConversationCreationWorkspaceMode`. */
    val draftsJson: String?,
    val quickTaskChoicesJson: String?,
    val creationWorkspaceMode: String?,
    /** macOS `DieterSelectedTerminalsByTarget`. */
    val terminalSelections: Map<String, String>,
    /** macOS `DieterNotifications`; null when never set. iOS has no setting. */
    val notificationsEnabled: Boolean?,
    val isIos: Boolean,
)

object LegacyInputs {
    fun apple(input: AppleLegacyInput): LegacyState {
        if (input.isIos) {
            val gateway = input.iosGateway?.let { Gateway.parse(it, "Gateway") }?.migrated()?.takeIf { it.secure }
                ?: return LegacyState()
            val tokenOrigin = input.iosGateway.let { Gateway.parse(it)?.origin }
            return LegacyState(
                gateways = listOf(gateway), activeOrigin = gateway.origin,
                preferredMachines = listOfNotNull(input.iosPreferredMachine?.takeIf { it.isNotBlank() }?.let { gateway.origin to it }).toMap(),
                // A relocated gateway needs a new sign-in; its old token is not carried over.
                tokens = listOfNotNull(input.iosToken?.takeIf { it.isNotBlank() && tokenOrigin == gateway.origin }?.let { gateway.origin to it }).toMap(),
            )
        }
        val (gateways, active, machine) = LegacyFormats.appleEndpoints(input.endpointsJson, input.activeEndpointJson)
        val account = input.sharedKvAccount?.takeIf { it.isNotEmpty() }
        val cache = account?.let { LegacyFormats.macSharedKv(input.sharedKvJson, it, input.sharedKvDaemon.orEmpty()) }
        return LegacyState(
            gateways = gateways, activeOrigin = active,
            preferredMachines = if (active != null && machine != null) mapOf(active to machine) else emptyMap(),
            tokens = LegacyFormats.macTokens(input.tokensJson),
            outbox = LegacyFormats.macOutbox(input.pendingCommandsJson, active),
            navigation = if (active != null && cache != null) listOf(ForGateway(active, cache)) else emptyList(),
            activeNavigation = if (active != null && account != null) ForGateway(active, KvActive(account, input.sharedKvDaemon.orEmpty())) else null,
            drafts = LegacyFormats.macDrafts(input.draftsJson),
            terminalSelections = LegacyFormats.macTerminalSelections(input.terminalSelections),
            notifications = LegacyFormats.macNotifications(input.notificationsEnabled),
            creation = LegacyFormats.macCreation(input.quickTaskChoicesJson, input.creationWorkspaceMode),
        )
    }
}
