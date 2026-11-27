package com.getdieter.core.providers

import com.getdieter.api.v1.ProviderLoginChallenge
import com.getdieter.api.v1.ProviderLoginInput
import com.getdieter.client.v1.ProviderSeverity
import com.getdieter.core.providers.ProviderFixtures.CHATGPT_TEAM
import com.getdieter.core.providers.ProviderFixtures.CLAUDE_HOME
import com.getdieter.core.providers.ProviderFixtures.CLAUDE_WORK
import com.getdieter.core.providers.ProviderFixtures.account
import com.getdieter.core.providers.ProviderFixtures.default
import com.getdieter.core.providers.ProviderFixtures.login
import com.getdieter.core.providers.ProviderFixtures.usage
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Instant

class ProvidersPresenterTest {
    private val now = Instant.parse("2026-11-14T12:00:00Z")

    private val view =
        ProviderFixtures.view(
            account(CLAUDE_WORK, "claude", "Work", email = "alice@corp.com"),
            account(CLAUDE_HOME, "claude", "Home", included = false),
            account(CHATGPT_TEAM, "chatgpt", "Team", method = "codex"),
            default("claude", CLAUDE_WORK),
            login(
                CLAUDE_WORK,
                "mac",
                usage = usage("2026-11-14T11:50:00Z", "five_hour" to 92.5, "weekly" to 12.0),
                email = "alice@corp.com",
            ),
            login(
                CLAUDE_WORK,
                "box",
                state = ProviderKinds.EXPIRED,
                error = "The sign-in expired",
            ),
            login(
                CHATGPT_TEAM,
                "box",
                usage = usage("2026-11-14T11:00:00Z", plan = "plus", resetCredits = 1),
            ),
        )

    @Test
    fun groupsListClaudeThenChatGPTWithTheirAccounts() {
        val slice = ProvidersPresenter.slice(view, now)
        assertEquals(listOf("claude", "chatgpt"), slice.groups.map { it.provider })
        val claude = slice.groups[0]
        assertEquals("Claude", claude.provider_name)
        assertEquals("2 accounts · 1 excluded", claude.summary)
        assertEquals(CLAUDE_WORK, claude.default_account_id)
        assertEquals(listOf("Home", "Work"), claude.accounts.map { it.label })
        assertEquals(
            "No accounts",
            ProvidersPresenter.group(ProvidersView(), "chatgpt", now).summary,
        )

        val work = claude.accounts.single { it.id == CLAUDE_WORK }
        assertEquals("alice@corp.com", work.identity)
        assertEquals("Max · Claude Code sign-in", work.subtitle)
        assertTrue(work.is_default)
        assertTrue(work.included)
        assertEquals(7, work.remaining)
        assertEquals(ProviderSeverity.PROVIDER_SEVERITY_CRITICAL, work.severity)
        assertEquals("Claude · Work · 7% left", work.summary_line)
        assertEquals(listOf("five_hour", "weekly"), work.windows.map { it.id })
        assertEquals(listOf("5 hour", "Weekly"), work.windows.map { it.name })
        assertEquals(listOf(7, 88), work.windows.map { it.remaining })
        assertEquals("2026-11-14T11:50:00Z", work.usage_observed_at)
        assertEquals("https://claude.ai/settings/usage", work.manage_usage_url)
        assertFalse(work.can_reset, "Claude has no reset credits")
        assertTrue(work.can_sign_in_all, "box lacks a working sign-in")
        assertFalse(work.managed)
        assertEquals("", work.status)

        val (mac, box) = work.machines
        assertEquals("mac", mac.daemon_id)
        assertEquals("signed_in", mac.state)
        assertEquals("Signed in", mac.state_label)
        assertEquals("alice@corp.com · verified 2m ago", mac.detail)
        assertFalse(mac.can_sign_in)
        assertTrue(mac.can_sign_out)
        assertTrue(mac.can_check)
        assertEquals("expired", box.state)
        assertEquals("Sign-in expired", box.state_label)
        assertEquals("The sign-in expired", box.detail)
        assertTrue(box.can_sign_in)
        assertFalse(box.can_sign_out)

        val home = claude.accounts.single { it.id == CLAUDE_HOME }
        assertEquals("Not signed in yet", home.identity)
        assertEquals("Claude Code sign-in", home.subtitle)
        assertEquals(-1, home.remaining)
        assertEquals("Usage not reported", home.status)
        assertEquals("Claude · Home · Not signed in", home.summary_line)
        assertEquals(listOf("not_signed_in", "not_signed_in"), home.machines.map { it.state })
        assertEquals(listOf(false, false), home.machines.map { it.can_check })

        val team = slice.groups[1].accounts.single()
        assertEquals("Plus · Codex sign-in", team.subtitle)
        assertTrue(team.can_reset)
        assertEquals("Reset usage limits (1 credit)", team.reset_label)
        assertEquals("https://chatgpt.com/settings/usage", team.manage_usage_url)
    }

    @Test
    fun theSummaryCountsIncludedAccountsOnly() {
        val slice = ProvidersPresenter.slice(view.copy(mutating = setOf(CLAUDE_HOME)), now)
        assertEquals("7% left", slice.summary!!.text)
        assertEquals(ProviderSeverity.PROVIDER_SEVERITY_CRITICAL, slice.summary!!.severity)
        assertEquals(listOf(CLAUDE_HOME), slice.mutating)
    }

    @Test
    fun claudeAccountsOfferOhMyPiAccessOffByDefault() {
        val access =
            ProviderFixtures.view(
                account(CLAUDE_WORK, "claude", "Work", omp = true),
                account(CLAUDE_HOME, "claude", "Home"),
                // ChatGPT records never carry it; a stray flag reads as off.
                ProviderFixtures.entry(
                    ProviderRecords.ACCOUNTS,
                    CHATGPT_TEAM,
                    """{"provider":"chatgpt","label":"Team","ompAccess":true}""",
                ),
            )
        val slice = ProvidersPresenter.slice(access, now)
        val (home, work) = slice.groups[0].accounts
        assertTrue(work.omp_access)
        assertTrue(work.offers_omp_access)
        assertFalse(home.omp_access, "off by default")
        assertTrue(home.offers_omp_access)
        val team = slice.groups[1].accounts.single()
        assertFalse(team.omp_access)
        assertFalse(team.offers_omp_access, "ChatGPT logins need no access")
        assertEquals("Allow Oh My Pi to use this login", OmpAccounts.ACCESS_LABEL)
        assertTrue("Anthropic may block or suspend accounts" in OmpAccounts.ACCESS_MESSAGE)
        assertTrue("presents itself as Claude Code" in OmpAccounts.ACCESS_MESSAGE)
        assertTrue("short-lived access tokens" in OmpAccounts.ACCESS_MESSAGE)
    }

    @Test
    fun hostAccountsFollowTheMachine() {
        val host =
            ProviderFixtures.view(
                account(CLAUDE_HOME, "claude", "This Mac", method = "host"),
                login(CLAUDE_HOME, "mac"),
            )
        val row = ProvidersPresenter.slice(host, now).groups[0].accounts.single()
        assertTrue(row.managed)
        assertFalse(row.can_sign_in_all)
        assertEquals("Machine login", row.subtitle)
        assertTrue(row.machines.none { it.can_sign_in || it.can_sign_out })
    }

    @Test
    fun sessionsReadAsTheSheetShowsThem() {
        fun shown(session: SignInSession) =
            ProvidersPresenter.slice(view.copy(sessions = listOf(session)), now).sessions.single()

        val claude =
            shown(
                SignInSession(
                    id = "s1",
                    accountId = CLAUDE_WORK,
                    daemonId = "box",
                    loginId = "l1",
                    phase = SignInPhases.WAITING,
                    challenge =
                        ProviderLoginChallenge(
                            open_url = "https://claude.ai/oauth",
                            local_url = "http://localhost:5555/callback",
                            callback_port = 5555,
                            expects = ProviderLoginInput.PROVIDER_LOGIN_INPUT_CODE,
                        ),
                    remaining = listOf("mac"),
                )
            )
        assertEquals("Sign in to Claude Code on box", claude.title)
        assertEquals("Work", claude.account_label)
        assertEquals("box", claude.machine)
        assertEquals("waiting", claude.phase)
        assertEquals("https://claude.ai/oauth", claude.open_url)
        assertEquals(5555, claude.callback_port)
        assertFalse(claude.same_host, "box is not this device's machine")
        assertEquals("code", claude.expects)
        assertEquals("Paste the code Anthropic shows you", claude.instructions)
        assertEquals(1, claude.remaining_machines)

        val codex =
            shown(
                SignInSession(
                    id = "s2",
                    accountId = CHATGPT_TEAM,
                    daemonId = "mac",
                    phase = SignInPhases.WAITING,
                    challenge =
                        ProviderLoginChallenge(
                            open_url = "https://auth.openai.com/codex/device",
                            user_code = "ABCD-1234",
                            expires_at = "2026-11-14T12:15:00Z",
                            expects = ProviderLoginInput.PROVIDER_LOGIN_INPUT_NONE,
                        ),
                )
            )
        assertEquals("Sign in to Codex on mac", codex.title)
        assertTrue(codex.same_host)
        assertEquals("ABCD-1234", codex.user_code)
        assertEquals("none", codex.expects)
        assertEquals("Open the page and enter this code", codex.instructions)

        val callback =
            shown(
                SignInSession(
                    id = "s3",
                    accountId = CHATGPT_TEAM,
                    daemonId = "box",
                    phase = SignInPhases.WAITING,
                    challenge =
                        ProviderLoginChallenge(
                            expects = ProviderLoginInput.PROVIDER_LOGIN_INPUT_CALLBACK
                        ),
                )
            )
        assertEquals(
            "Sign in, then paste the address your browser couldn't open",
            callback.instructions,
        )
        val done =
            shown(
                SignInSession(
                    "s4",
                    CLAUDE_WORK,
                    "box",
                    phase = SignInPhases.SUCCEEDED,
                    email = "alice@corp.com",
                )
            )
        assertEquals("Signed in as alice@corp.com on box", done.instructions)
        val siwc =
            ProvidersPresenter.title(
                ProviderAccountView(AccountRecord("pa_s", "chatgpt", "Team", "siwc")),
                "box",
            )
        assertEquals("Sign in with ChatGPT on box", siwc)
    }
}
