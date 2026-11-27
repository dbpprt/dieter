package com.getdieter.core.providers

/**
 * Oh My Pi on Dieter's provider accounts, as the daemons apply it: its model selectors name their
 * provider ("anthropic/…" runs on a Claude account, "openai-codex/…" on a ChatGPT account), Claude
 * logins need the user's explicit Oh My Pi access, and ChatGPT models run on ChatGPT logins only (a
 * Codex sign-in or a machine's own login). Its advisor runs on its own account only when it uses
 * the other provider; with the same provider it shares the implementation account.
 */
object OmpAccounts {
    /** Oh My Pi's harness ID. */
    const val HARNESS = "omp"

    /** The advisor model option; [ADVISOR_OFF] turns the advisor off. */
    const val ADVISOR_MODEL = "advisor_model"

    /** The account the advisor runs on when it uses the other provider; empty for the default. */
    const val ADVISOR_ACCOUNT = "advisor_account"

    const val ADVISOR_OFF = "off"

    private const val ANTHROPIC_PREFIX = "anthropic/"
    private const val CODEX_PREFIX = "openai-codex/"

    /** The provider whose accounts an Oh My Pi [model] runs on; null for any other model. */
    fun provider(model: String): String? {
        val selector = model.trim()
        return when {
            selector.startsWith(ANTHROPIC_PREFIX) -> ProviderKinds.CLAUDE
            selector.startsWith(CODEX_PREFIX) -> ProviderKinds.CHATGPT
            else -> null
        }
    }

    /** The advisor's provider for an [advisorModel] option value; null while the advisor is off. */
    fun advisorProvider(advisorModel: String): String? =
        advisorModel.takeIf { it != ADVISOR_OFF }?.let(::provider)

    /** Oh My Pi may run on [account] of [provider]. */
    fun usable(provider: String, account: AccountChoice): Boolean =
        when (provider) {
            ProviderKinds.CLAUDE -> account.ompAccess
            ProviderKinds.CHATGPT ->
                account.method == ProviderKinds.METHOD_CODEX ||
                    account.method == ProviderKinds.METHOD_HOST
            else -> false
        }

    /**
     * Why Oh My Pi has no account of [provider] to run on, given whether the provider has any
     * account at all ([hasAccounts]).
     */
    fun missing(provider: String, hasAccounts: Boolean): String =
        when {
            provider == ProviderKinds.CHATGPT ->
                "Oh My Pi runs ChatGPT models on a Codex sign-in or a machine's ChatGPT login. " +
                    "Add one in Settings › Providers."
            hasAccounts -> "Allow Oh My Pi to use a Claude login in Settings › Providers."
            else -> "Add a Claude account in Settings › Providers and allow Oh My Pi to use it."
        }

    /** The switch on a Claude account in Settings › Providers. */
    const val ACCESS_LABEL = "Allow Oh My Pi to use this login"

    const val ACCESS_DETAIL = "Oh My Pi conversations may run on it"

    /** The confirmation before Oh My Pi may use a Claude login. */
    const val ACCESS_TITLE = "Allow Oh My Pi to use this Claude login?"

    const val ACCESS_MESSAGE =
        "Anthropic does not permit Claude.ai logins in third-party tools. Oh My Pi presents " +
            "itself as Claude Code, and Anthropic may block or suspend accounts used this way. " +
            "Dieter only passes Oh My Pi short-lived access tokens; Claude Code keeps refreshing " +
            "the login."

    const val ACCESS_CONFIRM = "Allow"
}
