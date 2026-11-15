package com.getdieter.core.selection

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.EffortOption
import com.getdieter.api.v1.Harness
import com.getdieter.api.v1.HarnessModel
import com.getdieter.api.v1.HarnessSelection
import com.getdieter.api.v1.ProviderOption
import com.getdieter.core.composition.Creation
import com.getdieter.core.providers.AccountChoice
import com.getdieter.core.providers.AgentAccounts
import com.getdieter.core.providers.ProviderKinds

/**
 * The agent pickers of a composer or a new-conversation editor: what is selected, what may change,
 * and the next selection for each choice.
 */
data class AgentControls(
    val selection: HarnessSelection,
    val harnesses: List<Harness>,
    /** A started conversation fixes its provider; model and effort follow the harness's rules. */
    val locked: Boolean = false,
    val enabled: Boolean = true,
    /** Provider accounts judged on the machine that runs the agent. */
    val accounts: AgentAccounts = AgentAccounts(),
) {
    val harness: Harness?
        get() = Selections.harness(harnesses, selection.provider)

    val model: HarnessModel?
        get() = harness?.let { Selections.model(it, selection.model) }

    val providerEnabled: Boolean
        get() = enabled && !locked

    val modelEnabled: Boolean
        get() = enabled && Selections.canChange(harness, Selections.MODEL_SELECTION, locked)

    val effortEnabled: Boolean
        get() = enabled && Selections.canChange(harness, Selections.EFFORT_SELECTION, locked)

    val providerLabel: String
        get() = harness?.name?.ifEmpty { null } ?: selection.provider.ifEmpty { "Agent" }

    val modelLabel: String
        get() = model?.name?.ifEmpty { null } ?: selection.model.ifEmpty { "Default model" }

    /**
     * Efforts the selected model accepts ([Selections.efforts]), named by the harness, else by
     * their capitalized ID.
     */
    val efforts: List<EffortOption>
        get() {
            val harness = harness ?: return emptyList()
            val named = harness.effort?.options.orEmpty()
            return Selections.efforts(harness, model).map { id ->
                named.firstOrNull { it.id == id } ?: EffortOption(id = id, name = capitalized(id))
            }
        }

    /**
     * The effort picker's entries: "Default" (the provider's own, [Selections.DEFAULT_EFFORT])
     * first, then [efforts].
     */
    val effortChoices: List<EffortOption>
        get() = listOf(EffortOption(id = Selections.DEFAULT_EFFORT, name = "Default")) + efforts

    /** The effort picker's selected entry: the chosen effort, else [Selections.DEFAULT_EFFORT]. */
    val effortValue: String
        get() = selection.effort.ifEmpty { Selections.DEFAULT_EFFORT }

    /** The provider's fast-mode toggle, when the selected model has one. */
    val fastOptionId: String?
        get() = options.firstOrNull { it.id == Creation.FAST_MODE }?.id

    /** The provider's fast mode option applies and is on. */
    val fastMode: Boolean
        get() = fastOptionId != null && Selections.isOn(optionValues[Creation.FAST_MODE].orEmpty())

    /**
     * "Default" for the explicit default, else the effort's name, else the model's default effort.
     */
    val effortLabel: String
        get() {
            if (selection.effort == Selections.DEFAULT_EFFORT) return "Default"
            val shown = selection.effort.ifEmpty { model?.default_effort.orEmpty() }
            return efforts.firstOrNull { it.id == shown }?.name
                ?: capitalized(shown).ifEmpty { "Default" }
        }

    /** Options that apply to the selected model. */
    val options: List<ProviderOption>
        get() = Selections.options(harness, selection.model)

    fun optionEnabled(option: ProviderOption): Boolean =
        enabled && Selections.optionEnabled(option, locked)

    fun optionValue(option: ProviderOption): String =
        selection.provider_options[option.id] ?: option.default_value

    /** Every applicable option's value: the chosen one, else its default. */
    val optionValues: Map<String, String>
        get() = options.associate { it.id to optionValue(it) }

    /** The selected agent's provider accounts; none for agents without accounts. */
    val accountOptions: List<AccountChoice>
        get() =
            ProviderKinds.forHarness(selection.provider)?.let { accounts.byProvider[it] }.orEmpty()

    /** A chosen account that is no longer listed; sending with it would fail. */
    val missingAccount: String?
        get() =
            selection.account_id.takeIf { id ->
                id.isNotEmpty() &&
                    accountOptions.isNotEmpty() &&
                    accountOptions.none { it.id == id }
            }

    /**
     * The account a send uses, as the daemon resolves it: the chosen one, else the conversation's
     * last, else the provider default, else the only one signed in on the machine.
     */
    val account: AccountChoice?
        get() {
            val options = accountOptions
            if (options.isEmpty() || missingAccount != null) return null
            return options.firstOrNull { it.id == selection.account_id }
                ?: options.firstOrNull { it.id == accounts.last }
                ?: options.firstOrNull { it.isDefault }
                ?: options.filter { it.ready }.singleOrNull()
        }

    /** Accounts may change between turns, so only agents without any disable the picker. */
    val accountEnabled: Boolean
        get() = enabled && accountOptions.isNotEmpty()

    val accountLabel: String
        get() = account?.label ?: "Default account"

    /** The account a send uses cannot run on the machine; the composer blocks sending. */
    val accountBlocked: Boolean
        get() = missingAccount != null || account?.ready == false

    fun choosingAccount(id: String): HarnessSelection = selection.copy(account_id = id)

    fun choosingProvider(next: Harness): HarnessSelection = Selections.selectingProvider(next)

    /** Another model: its default effort, unless the effort may not change now. */
    fun choosingModel(id: String): HarnessSelection =
        Selections.selectingModel(
            selection,
            harness,
            id,
            keepEffort = !Selections.canChange(harness, Selections.EFFORT_SELECTION, locked),
        )

    fun choosingEffort(id: String): HarnessSelection = selection.copy(effort = id)

    fun settingOption(id: String, value: String): HarnessSelection =
        selection.copy(provider_options = selection.provider_options + (id to value))

    companion object {
        /**
         * A conversation's composer: the draft's choice, else the card's agent; locked once the
         * conversation started.
         */
        fun forConversation(
            draft: HarnessSelection?,
            card: Card?,
            harnesses: List<Harness>,
            enabled: Boolean = true,
            accounts: AgentAccounts = AgentAccounts(),
        ): AgentControls =
            AgentControls(
                Selections.filled(draft, card, harnesses),
                harnesses,
                locked = card != null && Selections.locked(card),
                enabled = enabled,
                accounts = accounts,
            )

        /**
         * The composer of [card] as the client contract shows it: [draft] while it differs from the
         * card's agent ([Selections.pending]), else the card's agent; locked once the conversation
         * started or has [hasMessages].
         */
        fun forComposer(
            draft: HarnessSelection?,
            card: Card,
            harnesses: List<Harness>,
            hasMessages: Boolean = false,
            accounts: AgentAccounts = AgentAccounts(),
        ): AgentControls =
            AgentControls(
                Selections.filled(Selections.pending(draft, card, harnesses), card, harnesses),
                harnesses,
                locked = Selections.locked(card, hasMessages),
                accounts = accounts,
            )

        private fun capitalized(id: String): String = id.replaceFirstChar { it.uppercaseChar() }
    }
}
