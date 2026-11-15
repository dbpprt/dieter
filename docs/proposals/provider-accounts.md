# Proposal: managed Claude and ChatGPT accounts

Status: spike, plan and Phase 0 live checks, 2026-11-13/14 · scope: daemon
(store, engine, harness runtime, API, CLI), replication schema, Kotlin core,
Mac, iOS and Android apps, docs

## TL;DR

The goal: sign in to Claude and ChatGPT subscriptions from the Mac, iOS or
Android app, keep several accounts per provider, choose the account per chat,
and see the same accounts and login state on every machine and client.

Two facts shape the design:

- **Anthropic forbids storing or relaying Claude.ai credentials.** Its terms
  say third-party developers "may not collect, store, or intermediate
  Claude.ai credentials or session tokens — sign-in to a Claude account must
  complete through Anthropic's own flow". They explicitly allow an end user to
  sign in to the unmodified Claude Code binary, including where a platform
  hosts it.
- **Both providers rotate refresh tokens.** Two machines holding a copy of
  one login race at refresh, and the loser's login dies: Claude wipes it,
  Codex reports `refresh_token_reused`. OpenAI says "Do not share the same
  file across concurrent jobs or multiple machines".

So **accounts synchronize, credentials do not.** The design:

- **Account registry.** Accounts, their labels and identities, which machines
  are signed in to each, and which account each chat uses are replicated
  records, so every client and machine sees the same picture.
- **Logins stay per machine.** Each login belongs to one machine and is held
  by the provider's own tool:
  - Claude Code in a per-account config directory.
  - For ChatGPT, a per-account Codex auth home, and later optionally a
    per-machine Sign in with ChatGPT session.
- **Sign-in from any app.** For any machine, the daemon runs the official
  login there (`claude auth login`, Codex `account/login/start`). The app shows
  the URL, the device code or a field for the pasted code. **Sign in on all
  machines** repeats this in one sheet, with one approval per machine.
- **Switchable per chat.** The account can change between turns. Spike S2
  showed a Claude session resumes from another account's config directory when
  the session store is shared. Codex keeps one `CODEX_HOME` and gets its token
  per turn.

The spike also found **a problem in today's code that is worth fixing on its
own**:

- **The adapter handles Claude tokens itself.** The bundled
  `@ai-sdk/harness-claude-code` adapter reads Claude Code's OAuth credential,
  refreshes it outside Claude Code, and passes an access-only token into the
  turn.
- **That is the likely cause of the 401s at the 8-hour boundary.** A turn
  that outlives that token cannot refresh it, which explains the "HTTP 401 at
  the 8-hour boundary" failures that `claude-resilience.mjs` works around.
- **The quota probe is affected too.** It reads the same token, from the
  wrong Keychain item for any non-default config directory.
- **It conflicts with Anthropic's terms.** Card `c_7152335f4a2ee3c3e65872ae`
  fixes it on its own, ahead of the account work.

For ChatGPT, Phase 1 uses Codex's own login: device code, or browser with a
forwarded callback. OpenAI's **Sign in with ChatGPT** program for open-source
and locally hosted apps is the endorsed long-term path, and Phase 3 adopts it
where its preview limits allow.

**Phase 0 ran on real accounts on 2026-11-14** (§4.1). It confirmed every
assumption the design rests on:

- **Every sign-in route works.** Claude by pasted code and by a forwarded
  callback; Codex by device code and by a forwarded browser callback; SIWC
  registration with plan usage granted.
- **Claude Code refreshes its own token inside a turn** when Dieter passes
  `auth: {}`, so the 8-hour boundary no longer breaks turns.
- **One chat can switch accounts between turns.** A Claude session continued
  A → B → A, and a Codex thread continued across two logins.
- **Usage needs no tokens.** Claude Code reports plan usage through the SDK
  without a prompt.

It also changed two details:

- **Codex needs the provider declared globally.** The shared `CODEX_HOME`
  must declare the injected-token provider in its `config.toml`. Otherwise
  `turn/start` fails with "This chat uses agent_bridge_openai, but your current
  provider is openai".
- **A production bug surfaced.** The same mismatch silently breaks Dieter's
  Codex quick titles in production today: every card since late October keeps
  its fallback title.

Phases 1–3 take roughly 4 weeks.

## 1. Goal

| #   | Requirement                                                                                                                                               |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| R1  | Sign in to Claude (Pro, Max, Team, Enterprise) and ChatGPT (Plus, Pro, Business) from the Mac, iOS or Android app, for any machine of the Dieter account. |
| R2  | Several accounts per provider (work and personal, two Max seats, …).                                                                                      |
| R3  | Choose the account per card, chat and schedule, with a per-provider default. Changeable between turns.                                                    |
| R4  | Synchronized: every client and machine sees the same accounts, which machines are signed in to each, and which account a conversation uses.               |
| R5  | CLI parity over the local route, verified direct TLS and the relay ([AGENTS.md](../../AGENTS.md#adding-or-changing-an-operation-cli-parity)).             |

Out of scope:

- API-key accounts. They would sync through the vault (§9).
- Switching accounts automatically when a usage limit is reached. Switching
  between turns makes that a small follow-up.
- Accounts for Pi, OMP and DSH.

## 2. Where we are

| Area               | Today                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Login              | Done by hand on each host (`claude auth login`, `codex login`). [harnesses.md](../../site/content/docs/harnesses.md) says "Authenticate or configure the provider on that machine first." No provider login appears anywhere in `internal/` or the apps.                                                                                                                                                                                         |
| Worker environment | `harnessEnvironment` (`internal/harness/harness.go:719`) passes `CLAUDE_CONFIG_DIR`, `CLAUDE_CODE_OAUTH_TOKEN`, `CODEX_HOME` and the API-key variables through from the daemon environment. Every turn on a machine uses the same login.                                                                                                                                                                                                         |
| Claude credentials | `runner.mjs:335` creates the adapter without `auth`. The adapter's `readClaudeCodeSubscription` reads `~/.claude/.credentials.json` or the Keychain item `Claude Code-credentials`. Within 5 minutes of expiry it refreshes against `platform.claude.com/v1/oauth/token` with Claude Code's client ID and writes the rotated tokens back. It then injects `CLAUDE_CODE_OAUTH_TOKEN`, an 8-hour access token with no refresh token, into the CLI. |
| Codex credentials  | The adapter's `readCodexSubscription` reads `$CODEX_HOME/auth.json` or the keyring, refreshes in the same way, and passes the access token as `CODEX_API_KEY` to a custom `agent_bridge_openai` provider at `chatgpt.com/backend-api/codex` (bridge `index.ts:129-178`). Codex-native access tokens live 240 h (measured from the JWT claims), so they rarely expire mid-turn.                                                                   |
| 401 handling       | `claude-resilience.mjs:67-108` holds the first auth error, waits 2 s and resumes once. Its comment records 26 of 30 failures followed by a working turn. The second failure says "Run `claude auth login` on the host".                                                                                                                                                                                                                          |
| Session data       | Claude transcripts live in `<config dir>/projects/<slug>/<session>.jsonl`. Codex rollouts and the thread index (`state_5.sqlite`, …) live in `CODEX_HOME`. The resume handle stored per conversation contains no account (`turn_execution.go:199`).                                                                                                                                                                                              |
| Selection          | `HarnessSelection{provider, model, effort, provider_options}` (`common.proto:382`), per turn and per queued message. `resolveTurnSelection` locks the harness after the first prompt; the model and effort can change between turns (`turn_selection.go:25`).                                                                                                                                                                                    |
| Quota              | `internal/providerquota` probes the active profile plus `DIETER_{CODEX,CLAUDE}_ACCOUNT_HOMES`. `quota-claude.mjs:32-52` reads the OAuth token, and on macOS that is always the default Keychain item, whatever the config dir. It calls the undocumented `/api/oauth/usage`. `quota-openai.mjs` reads `auth.json` and calls `wham/usage`. The gateway stores normalized snapshots keyed by an HMAC account key, each with a `machines[]` list.   |
| Per-card account   | `Card.provider_account_key` (`common.proto:196`) records the quota HMAC of the latest turn's account. The core's `Quotas.forConversation` matches it, but no slice calls it.                                                                                                                                                                                                                                                                     |
| Vault              | End-to-end encrypted items replicated to every member daemon (`internal/security/vault`). The only item type is password-style, and no app UI exists. Not used for provider logins, and must not be for Claude (§3.1).                                                                                                                                                                                                                           |
| Apps               | Pickers render `AgentControlsState` and report `AgentChoice` (`client.proto:611-695`). GitHub sign-in opens the system browser and returns through a custom-scheme callback (`core/identity/SignIn.kt`). Device pairing already has a typed-code field. The Mac Settings › Agents page is read-only (`SettingsPages.swift:254`).                                                                                                                 |

## 3. Constraints

### 3.1 Anthropic's terms

Read on 2026-11-13 from
[Legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)
(the page shows no revision date):

> Anthropic does not permit third-party developers to offer Claude.ai login
> into their own applications, or to route requests through Free, Pro, Max, or
> Ultra plan credentials on behalf of their users. Moreover, developers may not
> collect, store, or intermediate Claude.ai credentials or session tokens —
> sign-in to a Claude account must complete through Anthropic's own flow.

> Nor does it prevent an end user from signing in to the unmodified Claude Code
> binary with their own Claude subscription, including where a platform hosts
> Claude Code […].

> The Claude Code binary must not be modified. […] customers may not remove,
> disable, or restrict any authentication method built into it.

The [Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview)
repeats: "Unless previously approved, Anthropic does not allow third party
developers to offer claude.ai login or rate limits for their products,
including agents built on the Claude Agent SDK." Anthropic's support article
nevertheless counts "Claude Agent SDK, `claude -p`, and third-party app usage"
against the plan
([support](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)).

What follows for Dieter:

- **No Claude credentials in Dieter.** Dieter never reads, refreshes,
  stores, replicates or injects Claude OAuth tokens. That rules out the vault,
  a token custodian, `setup-token` distribution, and today's adapter-side
  refresh.
- **Claude Code owns the login.** It signs in through its own `claude auth
login`, against Anthropic's pages, into its own credential store.
  - Dieter only starts that process on the user's machine and relays its
    prompt and the user's keystrokes, exactly as a Dieter terminal running the
    same command would.
  - The relayed authorization code is useless without the PKCE verifier,
    which never leaves the Claude Code process (§5.9).
- **UI wording.**
  - The app must not present a Dieter-branded "Sign in with Claude". The
    action reads **Sign in to Claude Code on ‹machine›**, and the page the
    user signs in on is Anthropic's.
  - Whether relaying a pasted code counts as "intermediating" is not settled
    by the text. §8 lists this as a risk; the authoritative answer is
    Anthropic sales.

### 3.2 OpenAI's terms

- **Codex app-server authentication.** The
  [app-server docs](https://learn.chatgpt.com/docs/app-server) say: "If you've
  built a local or open-source application using Codex app-server
  authentication, you can continue using it, though we recommend migrating to
  Sign in with ChatGPT… App-server authentication has never been permitted for
  commercial or hosted services." Dieter is MIT-licensed and self-hosted.
- **Sign in with ChatGPT (SIWC).**
  [Plan usage](https://developers.openai.com/siwc/token-sharing-open-source)
  "is available to all open-source partners and selected private clients" for
  Plus and Pro. Business is not mentioned.
  - **Registration.** It registers dynamically on first sign-in
    (`client_id=dynamic_agent_client`), with no secret or partner key. The
    issued `client_id` is "bound to the authenticated user and the workspace".
  - **Several machines.** "A single client can have multiple hosts for the
    same user and workspace"; each host has its own `ext_agent_host_id`.
    Moving a login to another host "transfers an existing credential session",
    and that host must "own later refreshes".
  - **Tokens.** Access tokens last 1 h. Refresh tokens last 30 days and
    rotate. Apps must "serialize refreshes for the same session".
  - **Preview limits.** No hosted tools (image generation, file search, Code
    Interpreter, hosted MCP) and no Responses `tool_search`. "Configurations
    that emit Responses `tool_search` will fail."
  - **Branding.** The sign-in button reads "Continue with ChatGPT", and
    "Using ChatGPT plan" with a "Manage usage" link appears near the composer
    ([UI guidelines](https://developers.openai.com/siwc/ui-ux-guidelines)).
- **Not usable.** The app-server's `chatgptAuthTokens` login (host-supplied
  tokens with a refresh callback) is marked "[UNSTABLE] FOR OPENAI INTERNAL
  USE ONLY - DO NOT USE" in the pinned 0.166 schema (spike S4).

### 3.3 Rotating refresh tokens

- **Claude.** Refresh tokens are single-use. When two processes refresh at
  once, the loser gets `invalid_grant` and Claude Code wipes the login
  ([claude-code#103325](https://github.com/anthropics/claude-code/issues/103325)).
- **Codex.** It refreshes at 8 days and on 401. A reused refresh token fails
  with `refresh_token_reused`. The CI guide says "one `auth.json` per runner"
  ([CI/CD auth](https://learn.chatgpt.com/docs/auth/ci-cd-auth)).
- **SIWC.** Rotation per refresh; refreshes must be serialized (above).

So a login must have **exactly one refresher**. Within a machine, that is the
provider's tool, or Dieter's token broker under the central lock. Across
machines, each machine has its own login.

### 3.4 Dieter's invariants

Nothing here needs an exception ([invariants.md](../invariants.md)):

- **The gateway learns nothing new.** It "stores … normalized,
  credential-free provider quota snapshots" and never provider credentials.
  The new records replicate between daemons inside mutual TLS. Login traffic
  is ordinary daemon API calls inside the tunnel.
- **Ownership.** Conversations keep one owner daemon, so the login is
  resolved on the machine that runs the turn.
- **Agents cannot sign in.** Agent turns already "never change device trust".
  Login mutations refuse a turn token the same way (`internal/api/trust.go:38`).
- **Bounded records.** Replicated records stay within the CRDT limits:
  32 KiB values and at most 16 siblings.

### 3.5 Options considered

| Option                                                              | Verdict                                                                                                                                                                                                                                                                                                                                                                                |
| ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A. Sync OAuth credentials through the vault                         | **Rejected.** Claude: forbidden ("store, or intermediate"). Both providers: rotation races kill the copies (§3.3).                                                                                                                                                                                                                                                                     |
| B. One `claude setup-token` per account, synced in the vault        | **Rejected by default.** It is a one-year, inference-only (`user:inference`) token that cannot be revoked ([#106670](https://github.com/anthropics/claude-code/issues/106670)). It is documented as something to "set … wherever you want to authenticate", but Dieter storing and distributing it falls under "store". It also breaks quota: `/api/oauth/usage` needs `user:profile`. |
| C. A custodian daemon refreshes and hands out access tokens         | **Rejected.** Claude: intermediating. ChatGPT: a single point of failure, and it defeats per-host attribution and revocation. SIWC wants one session per host.                                                                                                                                                                                                                         |
| D. One official login per machine and account, driven from the apps | **Chosen.** It complies for both providers, has no refresh races across machines, and a "Sign in on all machines" sheet keeps the extra approvals cheap.                                                                                                                                                                                                                               |
| E. ChatGPT through SIWC, one session per host                       | **Candidate (Phase 3).** It is OpenAI's endorsed path, but it has preview limits and needs real-account testing first (§6).                                                                                                                                                                                                                                                            |

## 4. Spike results

The script and its redacted output are in
[tools/spikes/provider-accounts](../../tools/spikes/provider-accounts/):
`probe.mjs` and `results/2026-11-13-darwin-arm64.json`.

- **Setup.** The probes ran Claude Code 2.1.317 and Codex 0.166.0 from the
  pinned runtime, in throwaway homes, with `$BROWSER` pointed at a logging
  hook.
- **Safety.** No probe completed a sign-in or touched the operator's
  `~/.claude`, `~/.codex` or Keychain. The only exception was S7, which read
  two JWT claims, described there.

**S1. Claude login can be driven without a TTY.**
`claude auth login --claudeai` with plain pipes:

1. It hands `$BROWSER` an authorize URL whose
   `redirect_uri=http://localhost:<random port>/callback`.
2. It prints `If the browser didn't open, visit: <url>`. That second URL uses
   `redirect_uri=https://platform.claude.com/oauth/code/callback`, the manual
   flow, with the same PKCE challenge and state.
3. It waits at `Paste code here if prompted >`, reading the code from stdin.

So the daemon gets both URLs, from its own `$BROWSER` hook and from stdout,
and can complete the login by writing one line. When the client runs on the
daemon's host, the localhost URL finishes without any paste.

- **Scopes.** `claude auth login` requests `user:profile user:inference
user:sessions:claude_code …`. `claude setup-token` needs a TTY (Ink UI) and
  requests only `user:inference`.
- **Identity after login.** `claude auth status --json` reports `loggedIn`,
  `authMethod`, `configDirectory` and `projectsDirectory`, which is what
  Dieter needs to verify a login.

**S2. Claude sessions resume across config directories when `projects/` is
shared.**

- **Setup.** A session was created in config dir A (the transcript is written
  even though the request failed with 401). It was then resumed:
  - from dir B, whose `projects/` is a symlink to the same directory as A's;
  - from dir C, an isolated config dir.
- **Result.** From B, the resume got past session lookup and failed only at
  authentication (bogus token). From C it failed with `No conversation found
with session ID`.
- **Conclusion.** Per-account config directories that share the session store
  let a conversation change account between turns.

**S3. What a Claude config directory holds.** A fresh directory gets
`.claude.json` (`userID`, `machineID`, migration flags and later
`oauthAccount`), `backups/`, `plugins/` and `sessions/`. The operator's
`~/.claude` also has `settings.json`, `skills/`, `projects/`, `session-env/`,
`shell-snapshots/`, `history.jsonl`, `policy-limits*` and `remote-settings*`,
and `~/.claude.json` holds `oauthAccount`, `mcpServers`, `projects` and many
account-scoped caches. The split for a managed account directory:

- **Share by symlink:** `projects/`, `settings.json`, `CLAUDE.md`, `skills/`,
  `agents/`, `commands/`, `plugins/`, `todos/`, `file-history/`, `plans/`,
  `shell-snapshots/`, `session-env/`.
- **Keep per account:** `.claude.json`, credentials, `policy-limits*`,
  `remote-settings*` and caches.
- **Not shared:** user-scope MCP servers live in `.claude.json`. Phase 0
  decides whether to mirror them.

**S4. The Codex app-server has both login flows Dieter needs.**

- **Browser login.** `account/login/start {type: "chatgpt"}` returns
  `{loginId, authUrl}`:
  - Codex's client `app_EMoamEEZ73f0CkXaXp7hrann`, with
    `redirect_uri=http://127.0.0.1:1455/auth/callback`.
  - The port is fixed, so only one login can run per host at a time.
  - `originator` is the `clientInfo.name`.
  - The app-server does not open a browser itself.
- **Device code.** `{type: "chatgptDeviceCode"}` returns `{loginId,
verificationUrl: "https://auth.openai.com/codex/device", userCode:
"XXXX-XXXXX"}`. The account owner must enable device codes in ChatGPT
  settings (Business: an admin).
- **Status and cancel.** `account/login/cancel` works.
  `account/read` returns `{account, requiresOpenaiAuth}`.
- **Other variants in 0.166:** `apiKey`, `chatgptAuthTokens` (internal only)
  and two Bedrock variants. The server request
  `account/chatgptAuthTokens/refresh` exists.
- **`CODEX_HOME` cannot be split per account.** A fresh one immediately gets
  `state_5.sqlite`, `goals_1.sqlite`, `memories_1.sqlite`, `queue_1.sqlite`
  and `logs_2.sqlite`; the thread index and rollouts live there. Per-account
  homes would split thread state. Codex therefore keeps one `CODEX_HOME`, and
  the account only changes the token.

**S5. The adapters accept a per-turn credential without patches.**

- **Disabling credential discovery.** Passing `auth` as a flat environment
  object stops native-subscription discovery. Empty `{}` is accepted
  (`isHarnessAuthenticationEnvironment`).
  - Claude: with `auth: {}`, the adapter neither reads nor refreshes
    credentials, and the CLI uses its own store in `CLAUDE_CONFIG_DIR`.
  - Codex: `auth: {CODEX_API_KEY, OPENAI_BASE_URL}` goes straight to the
    bridge's custom provider.
- **The bridge already matches SIWC.** Its custom provider (`base_url`,
  `env_key`, `wire_api: "responses"`, `supports_websockets: false`) has the
  shape SIWC requires for app-server.
- **Command-backed provider tokens.** The Codex 0.166 binary contains
  `ModelProviderAuthInfo {command, args, timeout_ms, refresh_interval_ms,
cwd}`, which looks like command-backed bearer tokens for custom providers.
  That would renew 1-hour SIWC tokens inside a long turn without restarting
  app-server. Verified only from strings: Phase 0 checks it.

**S6. Quota is available without touching tokens.**

- **Claude, through the SDK.** The Agent SDK exposes `accountInfo()` (email,
  organization, subscription type, token source) and
  `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET()`, which returns
  the plan's 5-hour and 7-day utilization as the official binary sees it.
  It also streams `rate_limit_event` messages during turns.
- **Codex, through app-server.** It has `account/rateLimits/read`.
- **Conclusion.** Quota can come from the official tools instead of Dieter
  reading credentials.

**S7. Token lifetimes.**

- **Codex native: 240 h.** Measured from the `iat` and `exp` claims of the
  operator's existing Codex access token, without copying it. Codex refreshes
  at 8 days.
- **Claude: about 8 h.** This is consistent with the comment in
  `claude-resilience.mjs` and with
  [claude-code#101649](https://github.com/anthropics/claude-code/issues/101649).
- **Consequence.** An injected Claude access token can expire inside a long
  turn, and the CLI cannot refresh it because it has no refresh token. Letting
  Claude Code use its own store removes that failure mode.

### 4.1 Phase 0: live checks on real accounts (2026-11-14)

- **Setup.** The operator approved signing in to their own Claude Max and
  ChatGPT Pro accounts. Each login ran in a throwaway directory on mini-home
  under a holder process (`tools/spikes/provider-accounts/live/holder.mjs`),
  and the operator completed it from a browser on another device.
- **Turns.** They ran through the same adapters, local sandbox and
  `HarnessAgent` as `runner.mjs` (`live/turn.mjs`).
- **Evidence.** Redacted results are in `results/2026-11-14-phase0.json`.
- **Cleanup.** Every login was signed out afterwards: `claude auth logout`
  removed the Keychain items, and Codex `account/logout` removed `auth.json`.

| #    | Check                                | Result                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ---- | ------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P0.1 | Claude login by pasted code          | **Pass.** `claude auth login` over plain pipes accepted the pasted value (format `code#state`), and `auth status` reported `claude.ai` / `max`. The macOS Keychain item is `Claude Code-credentials-<sha256(CLAUDE_CONFIG_DIR)[:8]>`, computed over the path string as given (not its realpath). The access token lives about 480 minutes.                                                                                                                                                                |
| P0.7 | Claude callback forwarding           | **Pass.** The browser on another device redirected to `http://localhost:<port>/callback?code&state`. Replaying that request on the daemon host (HTTP 302) completed the login.                                                                                                                                                                                                                                                                                                                            |
| P0.8 | Usage without a prompt               | **Pass.** A prompt-less SDK query in the account directory returned `accountInfo()` and `usage_EXPERIMENTAL…()` in 827 ms: plan, 5-hour and weekly windows, per-model limits, spend. No token was touched.                                                                                                                                                                                                                                                                                                |
| P0.2 | Claude refresh with `auth: {}`       | **Pass.** The baseline turn works, with the CLI using its own store. With expiry set 3 minutes out, the CLI refreshed at the first request of the turn. With expiry 6.5 minutes out and a 5-minute turn, it refreshed in-process once inside its roughly 5-minute buffer, mid-turn, with no error.                                                                                                                                                                                                        |
| P0.2 | Claude: server-rejected access token | **Heals on the next request.** With a corrupted access token and a valid refresh token, the in-flight turn failed once (`HTTP 401: authentication_failed`). The CLI then refreshed its store itself, and the next turn worked. So the runner's resume-once retry stays: it turns that case into a same-turn recovery.                                                                                                                                                                                     |
| P0.3 | Shadow config parity                 | **Pass with one gap.** Linking `settings.json`, `skills/` and `plugins/` gave the same 71 commands and skills and 6 agents as `~/.claude`; a plain directory lacked the user's skills. User-scope MCP servers live in `~/.claude.json` and must be mirrored. An account's own claude.ai connectors show up, which is correct per account.                                                                                                                                                                 |
| P0.3 | Claude account switch                | **Pass.** One session (same `claudeSessionId`) ran turns on A, then B, then A, with B and A seeing the earlier turns. Both accounts' `projects/` symlinked to one directory, and one sandbox root.                                                                                                                                                                                                                                                                                                        |
| P0.4 | Codex device code                    | **Pass.** It was enabled for the operator's Pro account. The code expires after exactly 15 minutes ("device auth timed out after 15 minutes"), so the sheet must restart it.                                                                                                                                                                                                                                                                                                                              |
| P0.4 | Codex browser login, forwarded       | **Pass, with one subtlety.** The replayed callback (302) saved the tokens, but the login reported completion only after the loopback `/success` page was fetched. So forwarding must follow redirects that stay on loopback.                                                                                                                                                                                                                                                                              |
| P0.4 | Codex injected-token turn            | **Fails unless the provider is global.** In fresh and default homes alike, `turn/start` failed: "This chat uses agent_bridge_openai, but your current provider is openai". This happened even on today's credential path; the bridge sets `model_provider` per thread only. Declaring `model_provider = "agent_bridge_openai"` and its `[model_providers…]` block in the shared `CODEX_HOME/config.toml` fixed it.                                                                                        |
| P0.4 | Codex account switch                 | **Pass.** With that config, a thread started on one login's token and resumed on another login's token (`NOTED` → `PAPAYA-7`) in one shared `CODEX_HOME`.                                                                                                                                                                                                                                                                                                                                                 |
| P0.4 | Codex refresh on request             | **Pass.** `account/read {refreshToken: true}` on an account home rotated both tokens and updated `last_refresh`. The broker can ask Codex to refresh; Dieter needs no OAuth code.                                                                                                                                                                                                                                                                                                                         |
| P0.4 | Business workspace header            | **Not tested.** The operator has a personal Pro account, with `workspaceName` null.                                                                                                                                                                                                                                                                                                                                                                                                                       |
| P0.5 | SIWC registration                    | **Pass.** `dynamic_agent_client` with `agent_name_hint=Dieter` returned an issued `oaiapp_…` client ID in the callback. The token response included `chatgpt.tokens.use.direct` (plan usage), `expires_in` 3600 and `earliest_refresh_at`, and the ID token's `nonce` and `aud` checked out. `/v1/models` listed 8 models.                                                                                                                                                                                |
| P0.5 | SIWC turns                           | **Pass, except web search.** A plain turn worked, and a turn with a shell call plus a Dieter host tool (`present_content`) worked on Codex 0.166: Dieter's tool shape triggered no `tool_search` failure. Web search returned "authorization error": standalone web search is not available on the plan route.                                                                                                                                                                                            |
| P0.5 | SIWC second host                     | **Pass.** A second host ID re-authorized with the issued `client_id` and the first host's `id_token_hint`. The operator opened the link and returned the callback. The docs say `id_token_hint` skips the account picker and consent; whether any prompt appeared was not recorded. The callback carried no `client_id` (as documented), and the token response granted plan usage for an independent session. Both sessions were revoked afterwards (`/oauth/revoke` 200; refresh then `invalid_grant`). |
| P0.6 | Codex provider `auth` command        | **Pass.** `[model_providers.<id>.auth] command/args/refresh_interval_ms` printed a plain bearer token on stdout. Codex called it at start and again after each interval: 5 calls in a 50-second turn at 10 s. A 1-hour SIWC token can renew inside a long turn without restarting app-server.                                                                                                                                                                                                             |
| P0.7 | Mobile loopback listener             | **Not tested.** It needs app code; it moves to Phase 3. The forwarding protocol itself is proven by the two rows above.                                                                                                                                                                                                                                                                                                                                                                                   |

**Production bug found on the way.** Dieter's Codex quick titles
(`conversation_creation.go`, `gpt-5.3-codex-spark`) go through the same
injected-token provider.

- **Matching evidence.** The operator's `~/.codex` thread index has one
  `agent_bridge_openai` thread with 0 tokens at each creation time of the
  recent cards: 2026-11-13 10:34, 11:10, 11:56 and 12:57, and 2026-11-14
  10:52.
- **Visible symptom.** Every card since late October kept its 80-rune
  fallback title, because `scheduleQuickTaskTitle` drops the error silently.
- **Fix.** Declare the provider globally: a `--config` override at app-server
  launch, or a Dieter-owned `CODEX_HOME` config (§5.4).
- **Scope.** New interactive Codex conversations use the same path and are
  probably affected too, but that was not verified separately.

## 5. Design

### 5.1 Concepts

- **Provider account.** One Claude or ChatGPT identity the user wants agents
  to use: provider, label, identity (email, organization or workspace, plan).
  It is account-wide and the same object on every machine.
- **Machine login.** The login of one account on one machine. Its state is
  signed in, signed out, expired or failed. The credential stays on that
  machine, inside the provider's tool (or Dieter's per-host token file for
  SIWC).
- **Selection.** The account a turn uses, carried in `HarnessSelection` next
  to provider, model and effort.

### 5.2 Records and storage

| Record                      | Where                                               | Writer                                                   | Contents                                                                                                                                                                                                                                                             |
| --------------------------- | --------------------------------------------------- | -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `provider-accounts`         | KV namespace, key `<accountId>` (`pa_…`)            | Any daemon, compare-and-set                              | `{provider: claude\|chatgpt, label, identity{email, organization, workspaceId, plan}, quotaAccountKey, createdAt, createdBy}`. A tombstone deletes it.                                                                                                               |
| `provider-logins`           | KV namespace, key `<accountId>.<daemonId>`          | Only that daemon (key convention, like `channel-claims`) | `{state, method: claude-code\|codex\|siwc\|host, identity, verifiedAt, error}`. Never a token.                                                                                                                                                                       |
| `provider-account-defaults` | KV namespace, key `<provider>`                      | Any daemon                                               | `{accountId}`                                                                                                                                                                                                                                                        |
| Login directory             | `DIETER_HOME/provider-accounts/<accountId>/`, local | The daemon, under `fsx.LockHome`                         | `claude/`: a Claude Code config directory (the CLI's own credentials: a Keychain item keyed to this path on macOS, `.credentials.json` on Linux), with the shared entries symlinked (S3). `codex/`: a Codex home used only for `auth.json`. `siwc.json` for Phase 3. |

- **Schemas.** The namespaces get strict validators in
  `internal/replication/schema/provider_accounts.go`, like `channel.go`.
  `internal/api/kv.go` refuses public KV writes to them, so they change only
  through `ProviderAccountService`.
- **Quota key.** `quotaAccountKey` is the HMAC the quota pipeline already
  uses (`providerquota/manager.go:393`). The daemon that verifies a login
  computes it from the identity, so clients can join quota rows to accounts
  without the correlation key.
- **Identity binding.**
  - The first verified login sets the account's identity.
  - Any later login whose identity differs, for example
    `signed in as bob@…, expected alice@…`, is signed out again, and the
    error is reported.
  - `claude auth login --email` pre-fills the expected address.
- **Adopting existing logins.** On upgrade, each daemon checks its existing
  host logins (`~/.claude` with `claude auth status --json`, `~/.codex` with
  `account/read`). It links each to the account record with the same identity,
  or creates one, and writes a `method: host` login record. That is a pointer
  to the CLI's default store, not a copy. Existing machines and chats keep
  working, and the user sees every machine's login on day one. This is a net
  new feature, not a migration: nothing old is read or converted.

### 5.3 Signing in

The daemon on the target machine runs the official flow. `ProviderLoginSession`
(in `internal/engine/accounts/`) allows at most one active login per account
and machine, and one Codex browser login per host (port 1455). A session is
cancelled when its watch ends.

- **Claude.** Claude Code waits for the code indefinitely, so Dieter holds the
  process for up to 30 minutes.
- **Codex device code.** It expires after 15 minutes on OpenAI's side (P0.4),
  and the sheet starts a new one automatically.

**Claude Code** (no Dieter code touches a token):

```text
CLAUDE_CONFIG_DIR=DIETER_HOME/provider-accounts/<id>/claude \
BROWSER=<dieter> provider-account browser-hook <loginId> \
  claude auth login --claudeai [--email <expected>]
```

1. The `$BROWSER` hook reports the localhost-redirect URL. The daemon parses
   the manual URL from stdout (S1).
2. The challenge sent to the client is `{manualUrl, localUrl, callbackPort,
expects: code}`.
3. `SubmitProviderLoginCode` writes the pasted value and a newline to the
   process's stdin. The page shows it as `code#state`, and Claude Code expects
   it verbatim. It is never logged or stored.
4. When the process exits 0, the daemon runs `claude auth status --json` and
   `accountInfo()` to read the identity, binds it, and writes the login
   record.
5. Sign-out runs `claude auth logout` with the same config directory, which
   removes the Keychain item (P0.1 cleanup), and then removes the directory.
   It unlinks symlinks first and never recurses through them: a test guards
   that the shared `~/.claude` entries survive.
6. **The path must be canonical.** `CLAUDE_CONFIG_DIR` must be the identical
   string on every run. On macOS the Keychain item is named after
   `sha256(CLAUDE_CONFIG_DIR)[:8]` of the path as given, so `/tmp/x` and
   `/private/tmp/x` are two different, separately signed-in accounts.
   `internal/store/accounts` hands out one cleaned absolute path per account.

**Codex** (Phase 1):

- **Device code.** The daemon runs `codex app-server` with
  `CODEX_HOME=…/<id>/codex` and `cli_auth_credentials_store="file"`, then
  calls `account/login/start {type: "chatgptDeviceCode"}`. The challenge is
  `{verificationUrl, userCode}`. Completion is the
  `account/login/completed` notification, followed by `account/read` for the
  identity.
- **Browser.** `{type: "chatgpt"}` returns an `authUrl` with a fixed
  `127.0.0.1:1455` callback. This works directly when the client runs on the
  daemon's host; otherwise it needs callback forwarding (below).
  - Codex saves the tokens on the callback, but reports
    `account/login/completed` only after its loopback `/success` page is
    fetched (P0.4).
  - So the daemon's replay follows redirects that stay on `127.0.0.1` or
    `localhost`, and only those.
- **Default.** The app offers the device code first and falls back to the
  browser when device codes are disabled.

**Callback forwarding** handles a browser that runs on a different device
from the daemon.

- **Phase 1: paste the address.** The sheet offers "Paste the address your
  browser couldn't open". The daemon replays the pasted
  `http://localhost:…/callback?…` or `http://127.0.0.1:1455/auth/callback?…`
  locally. Phase 0 completed both Claude and Codex logins exactly this way
  (P0.7, P0.4).
- **Phase 3: automatic.** The client catches the redirect itself and no paste
  is needed:

1. The client listens on its own loopback at the callback port: the Mac app
   with a `127.0.0.1` socket, the mobile apps inside the sign-in sheet.
2. It opens the localhost-redirect URL.
3. When the provider redirects to `localhost:<port>/callback?code&state`, the
   client relays the path and query through `DeliverProviderLoginCallback`.
4. The daemon replays that request to the CLI's own loopback listener on its
   host.

This is the same mechanism as `ssh -L` port forwarding: the code still reaches
the unmodified CLI through its own redirect. Phase 3 starts by checking that
iOS and Android can serve a loopback socket while the in-app browser sheet is
open; Phase 0 did not cover that.

**Sign in on all machines.** The sheet lists every online machine that lacks
a login for the account and walks through them one by one. Each machine needs
one approval in the browser:

- **Claude:** one Authorize click plus a paste, unless the callback is
  forwarded.
- **Codex:** the device code.
- **SIWC:** a redirect with no prompt, because re-authorization with
  `id_token_hint` skips account selection and consent.

A machine that comes online later, or joins the roster, shows a "Sign in"
action on every account it lacks.

```text
Claude · Work (alice@corp.com · Max)
  Studio        ● Signed in   (verified 2 min ago)
  mbp-office    ○ Not signed in              [Sign in]
  box           ○ Not signed in              [Sign in]
                               [Sign in on 2 machines]

Sign in to Claude Code on mbp-office
  1. Open Anthropic's sign-in page            [Open]
  2. Paste the code it shows                  [__________] [Continue]
```

### 5.4 Running a turn on an account

Admission (`turn_admission.go`) resolves `selection.account_id` on the owner
daemon:

- An empty `account_id` means the provider's default.
- The account must exist, its provider must match the harness, and this
  machine's login must be signed in.
- Otherwise admission fails with
  `fault.FailedPrecondition{reason: provider_login_required, account_id,
daemon_id}`. The clients render that as a **Sign in** action in the chat
  instead of an error text.

Schedules record the same failure in occurrence history.

| Harness     | Worker environment and runner request                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Claude Code | `CLAUDE_CONFIG_DIR` is the account directory's canonical path (unset for a `host` login). `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_API_KEY` are removed from the environment. `runner.mjs` passes `auth: {}`, so the adapter does no credential work and Claude Code refreshes in-process (P0.2). The account directory is a shadow of `~/.claude`: `projects/`, `settings.json`, `CLAUDE.md`, `skills/`, `agents/`, `commands/` and `plugins/` are symlinked, and the user-scope `mcpServers` from `~/.claude.json` are mirrored into the account's own `.claude.json` before each turn (P0.3). The resume handle is unchanged and valid in any account directory (P0.3 switch).                                                            |
| Codex       | A Dieter-owned shared home, `DIETER_HOME/codex`, is the `CODEX_HOME` of every Dieter Codex turn, whatever the account. Dieter renders its `config.toml` from the user's `~/.codex/config.toml` (MCP servers, features, trust) plus a global `model_provider = "agent_bridge_openai"` block. Without that block `turn/start` fails (P0.4). The broker returns the account's access token under a per-account lock, first asking Codex to refresh with `account/read {refreshToken: true}` on the account's auth home when the token is due (P0.4). `runner.mjs` passes `auth: {CODEX_API_KEY, OPENAI_BASE_URL}`. For SIWC (Phase 3), the provider gets an `auth.command` that asks the daemon for the current token, so 1-hour tokens renew inside long turns (P0.6). |

The `auth: {}` change also applies to `host` logins. It fixes today's mid-turn
401s and the adapter's token handling before any account exists, and ships
separately (card `c_7152335f4a2ee3c3e65872ae`). The resume-once auth retry in
`claude-resilience.mjs` stays: when the server rejects an access token, the
CLI refreshes only after the failed request (P0.2), and the retry recovers
within the same turn. The second-failure text in `claude-resilience.mjs` changes from "Run
`claude auth login`" to the machine-login state. The login record turns
`expired`, and the app offers **Sign in again**.

### 5.5 Choosing an account per chat

- **Selection fields.** `HarnessSelection` gains `account_id`. It travels
  wherever the selection does:
  - `CreateConversationRequest`, `SendMessageRequest` and
    `DraftAgentSettings`;
  - queued messages, turn records and schedules.
- **Card field.** `Card.provider_account_id` replaces `provider_account_key`
  (clean break; the quota key now comes from the account record).
- **Changing accounts.** The catalog adds an `account-selection` capability
  at level `between-turns` for `claude-code` and `codex`.
  `resolveTurnSelection` then allows a change between turns, like model and
  effort, and keeps the harness lock.
- **Defaults.** Resolution order:
  1. the explicit choice;
  2. the conversation's last account;
  3. the provider default;
  4. the only account that is signed in on the owner machine.
     The clients' `CreationPreferences` remembers the last choice per provider.
- **Agent-created cards.** They inherit the creating conversation's account
  when the provider matches. Agents may pass `--account`, because accounts are
  not secrets and agents can already list them. Agents may not sign in, sign
  out, create, rename or delete accounts.

### 5.6 Quota and status

- **Claude probe.** It runs inside the official binary, with no token
  handling. It is a short Agent SDK session in the account's config directory
  that calls `accountInfo()` and the SDK usage call, and never sends a prompt
  (P0.8: 827 ms, with 5-hour, weekly, per-model and spend data). If that call
  is unavailable, the fallback is the last `rate_limit_event`
  from that account's turns. `quota-claude.mjs` stops reading Keychain and
  credential files.
- **Codex probe.** `account/rateLimits/read` through app-server on the
  account home, or `wham/usage` with the broker's token as today.
- **Login status checks.** A cheap check runs for every login at most every
  15 minutes and after each turn's auth error: `claude auth status --json`, or
  Codex `account/read`. Its result is written to the login record.
- **What stays the same.** The gateway pipeline, the normalized snapshots,
  their HMAC keys and `machines[]` are unchanged. The profile list comes from
  the login records instead of `DIETER_{CODEX,CLAUDE}_ACCOUNT_HOMES`, and
  those variables are deleted.
- **In the apps.** The composer shows the chosen account with its tightest
  window ("Work · 62% left"), using the existing `Quotas.forConversation`
  join.

### 5.7 API and CLI

New service in `api/proto/dieter/v1/provider_accounts.proto`:

```proto
service ProviderAccountService {
  rpc ListProviderAccounts(...)        // accounts + every machine's login state
  rpc CreateProviderAccount(...)       // provider, label
  rpc UpdateProviderAccount(...)       // label
  rpc DeleteProviderAccount(...)       // tombstone; each daemon signs out locally
  rpc SetDefaultProviderAccount(...)
  rpc StartProviderLogin(...)          // on the target machine: method → challenge
  rpc WatchProviderLogin(...)          // stream: challenge, waiting, succeeded{identity}, failed
  rpc SubmitProviderLoginCode(...)     // Claude pasted code → CLI stdin
  rpc DeliverProviderLoginCallback(...)// forwarded loopback redirect (Phase 3)
  rpc CancelProviderLogin(...)
  rpc SignOutProviderAccount(...)      // on the target machine
  rpc CheckProviderLogin(...)          // re-verify now
}
```

- **Turn tokens.** Every mutation refuses a turn token by presence, like
  `trustAPI.admit`. Reads are open.
- **Routes.** Login RPCs work over every route, and `--machine` targets the
  machine that should sign in.
- **CLI.** `internal/cli/rpc_provider_accounts.go` adds `dieter
provider-account list|add|rename|remove|default|login|logout|check`.
  - `login` is interactive: it prints the URL or device code and reads the
    pasted code from stdin.
  - `dieter card create|send` and `dieter chat …` get `--account ID|LABEL`.
- **Same-change updates.** The help contract and `rpcCommand` mapping, the
  CLI reference, `.agents/skills/dieter-cli/SKILL.md` and an end-to-end CLI
  test over local, direct TLS and relay (`internal/testkit/topology`). The
  test uses fixture CLIs, never a provider (§7).

### 5.8 Kotlin core and apps

**Core** (`apps/kotlin/core`, all rules):

- **Accounts package.** A new `accounts` package projects the
  `provider-accounts`, `provider-logins` and defaults namespaces from
  `AccountSnapshot` into rows: account, identity, plan, per-machine state with
  online state from presence, and quota via `quotaAccountKey`.
- **Commands.** `ProviderAccountsCommand` covers create, rename, remove,
  set default, sign in (account, machine), submit code, cancel and sign out.
  Account-wide mutations go to any reachable machine; logins go to the target
  machine (`MachineChoice`).
- **Sign-in state machine.** It tracks challenge, waiting, success and
  failure for each login session, with the same sheet used for "all machines".
- **Pickers.** `AgentChoice` gains an `account` arm. `AgentControlsState`
  gains the accounts for the chosen provider, each with readiness on the
  target machine (signed in, needs sign-in, offline). Every picker on all
  three apps picks it up.
- **Opening URLs.** The host's existing `openUrl` lambda opens the system
  browser (Mac `NSWorkspace`, iOS `openURL`, Android `ACTION_VIEW`). The code
  field reuses the pairing-code text field pattern.

**Apps** (presentation only):

- **Mac.**
  - A new Settings › Accounts page with the account list, the machine matrix,
    sign-in sheets and a default per provider.
  - The composer gets an Account menu next to Provider
    (`AgentComposerMenus`), and the conversation header gets an account chip.
  - An inline "Not signed in on ‹machine› · Sign in" row appears in the chat
    when admission reports `provider_login_required`.
- **iOS and Android** (shared Compose UI):
  - More › Accounts, with an account detail screen and its machine list.
  - An Account row in `AgentSettings` (creation screen and composer agent
    sheet).
  - The same inline sign-in row and sign-in sheet.

### 5.9 Security and threat model

- **Credentials never leave the machine.**
  - Claude credentials stay in Claude Code's own store, under a Dieter-chosen
    directory. Dieter code never reads them.
  - Codex and SIWC tokens stay in user-only files under `DIETER_HOME`,
    written atomically under the lock.
  - Nothing is replicated or reaches the gateway. Clients see URLs, device
    codes and the code a user pastes, never tokens: the threat model's
    "clients never hold … provider credentials" still holds.
- **Relayed codes.** The pasted Claude code and a forwarded callback travel
  client → daemon inside mutual TLS. A PKCE authorization code is useless
  without the verifier, which only the CLI process on the daemon holds. Codes
  are not logged, and audit entries record the event, not the value.
- **Agents.** Login mutations refuse turn tokens. An agent that reads
  `DIETER_HOME` directly can still read the Codex and SIWC token files and run
  `claude` with an account directory. That is the same residual risk as
  today's `~/.claude` and `~/.codex`.
- **Peers.** KV records carry no provenance today: `validatePeerDomainMerge`
  checks only domain kinds (`internal/store/replica/provenance.go:144`). A malicious peer
  could forge another machine's login record and show a wrong state, but it
  cannot obtain a credential. That is within "machines of one account trust
  each other".
- **Revocation.** Removing a machine from the roster leaves its provider
  logins in place on that host. The Devices removal flow should offer **Sign
  out of provider accounts** while the machine is still reachable. The
  threat model's stolen-host advice ("rotate provider credentials") gains the
  per-account sign-out path.
- **ADR 0006.** It records the rule: "Dieter never reads, stores, refreshes
  or replicates Claude.ai credentials; provider logins are per machine; login
  state replicates, credentials never do." It adds one line to the
  invariants' "Network and identity" section and updates the threat model's
  asset table.

### 5.10 What gets deleted

All in the same change, with no compatibility paths:

- Adapter-side Claude credential discovery and refresh, plus token reading
  in `quota-claude.mjs`. Both go in card `c_7152335f4a2ee3c3e65872ae`, ahead
  of this work.
- `~/.codex` as the `CODEX_HOME` of Dieter turns, replaced by the
  Dieter-owned `DIETER_HOME/codex` (§5.4).
  - Existing Dieter Codex conversations cannot resume their threads after the
    switch. That is a clean break, with no import of old rollouts.
  - The operator's own Codex and ChatGPT app history stays in `~/.codex`,
    untouched.
- `DIETER_CODEX_ACCOUNT_HOMES`, `DIETER_CLAUDE_ACCOUNT_HOMES` and their
  config fields, docs and tests.
- `providerquota.ActiveAccountKey` and `Card.provider_account_key`. The field
  number is reserved.
- Not deleted: `claude-resilience.mjs`'s auth-resume retry. P0.2 showed it
  still recovers the case where the server rejects an access token within
  the same turn.

## 6. ChatGPT: Codex login now, Sign in with ChatGPT later

|                 | Codex login (Phase 1)                                                             | SIWC (Phase 3)                                                                                                                                                                                             |
| --------------- | --------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Standing        | Tolerated for local and open-source apps; OpenAI recommends migrating             | Endorsed for open-source and locally hosted apps; dynamic registration, no partner key                                                                                                                     |
| Plans           | Every plan Codex supports; Pro verified live                                      | Plus and Pro per docs; Pro verified live; Business unknown                                                                                                                                                 |
| Remote sign-in  | Device code (verified; 15-minute expiry) or forwarded `127.0.0.1:1455` (verified) | Loopback redirect with PKCE only; forwarded redirect verified                                                                                                                                              |
| Multi-machine   | One Codex login per machine                                                       | One host ID per daemon (`urn:ietf:params:oauth:jwk-thumbprint:…` of its roster key), one session per host, one issued `client_id` per account; extra hosts re-authorize with `id_token_hint` and no prompt |
| Token lifetime  | 240 h access, refresh at 8 days; Codex refreshes on request (`account/read`)      | 1 h access, 30-day rotating refresh; renewed inside a turn by the provider `auth.command` (verified, P0.6)                                                                                                 |
| Inference route | `chatgpt.com/backend-api/codex` (today's path)                                    | `api.openai.com/v1` Responses                                                                                                                                                                              |
| Verified tools  | Shell, Dieter host tools, web search                                              | Shell and Dieter host tools work; **web search fails with an authorization error**; no hosted tools, `store: false`                                                                                        |
| UI duties       | None beyond "Sign in to Codex on ‹machine›"                                       | "Continue with ChatGPT" button, first-use modal, "Using ChatGPT plan" + "Manage usage" near the composer                                                                                                   |

The account model, records, UI and turn wiring are the same for both. Only the
login method and the token broker's source change. Recommendation after
Phase 0:

1. Ship Codex login in Phase 1 as the default ChatGPT method.
2. In Phase 3, add SIWC as a second sign-in method per account. It is the
   endorsed route and works for Dieter's normal tool use, but chats on a SIWC
   account lose web search.
3. Revisit the default when OpenAI lifts the web-search limit on the plan
   route.

## 7. Plan

### Phase 0: live checks with real accounts (done 2026-11-14)

All eight checks ran on the operator's own Claude Max and ChatGPT Pro
accounts, in throwaway directories, and everything was signed out afterwards.
Results are in §4.1 and `tools/spikes/provider-accounts/results/2026-11-14-phase0.json`.

| #    | Check                                                                  | Outcome                                                                       |
| ---- | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| P0.1 | Claude login by pasted code; identity; Keychain naming                 | Pass                                                                          |
| P0.2 | Turns with `auth: {}`; expiry at start and mid-turn; rejected token    | Pass; the resume-once retry stays for rejected tokens                         |
| P0.3 | Shadow config parity; one session across accounts A → B → A            | Pass; mirror user-scope MCP servers                                           |
| P0.4 | Codex device code and forwarded browser login; injected token; refresh | Pass once the provider is declared globally in `CODEX_HOME/config.toml`       |
| P0.5 | SIWC registration, models, turns with Dieter's tools, web search       | Pass except web search; second-host re-authorization documented, not run live |
| P0.6 | Codex provider `auth.command`                                          | Pass                                                                          |
| P0.7 | Callback forwarding                                                    | Pass for the replay; the mobile loopback listener moves to Phase 3            |
| P0.8 | SDK usage without a prompt                                             | Pass                                                                          |

### Phase 1: daemon (about 8 days)

1. **Schema and storage.** `internal/replication/schema/provider_accounts.go`,
   KV refusal for the namespaces, `internal/store/accounts` for the local
   login directories (atomic writes, the lock, symlink-safe removal).
2. **Engine.** `internal/engine/accounts` holds:
   - the login sessions (Claude CLI, Codex app-server), including the "paste
     the address" replay that follows loopback redirects;
   - identity binding, host-login adoption and status checks;
   - the Codex token broker with per-account locks and `account/read
{refreshToken: true}`;
   - the shadow Claude account directories, with the `mcpServers` mirror;
   - the Dieter-owned `DIETER_HOME/codex`, with its rendered `config.toml`.
     Ship that last piece first: it also fixes the broken quick titles.
3. **Turns.**
   - Thread `account_id` through the selection, queue, schedules and
     `resolveTurnSelection` (the `account-selection` capability).
   - Admission resolves the account and fails with `provider_login_required`.
   - The runner always passes `auth`; the Claude environment is cleaned.
4. **API.** `api/proto/dieter/v1/provider_accounts.proto` (`just generate`),
   `internal/api/provider_accounts.go`, mounted in `service.go`, refusing turn
   tokens on mutations.
5. **CLI.** `dieter provider-account …`, `--account` on card and chat
   commands, the help contract, the CLI reference and the skill doc.
6. **Quota.** Profiles from login records, the Claude probe through the SDK,
   and deletion of the env-var profiles.
7. **Docs.** ADR 0006, the invariants line, the threat model, and
   `docs/reference/environment.md`.

Exit: `just test` and `just test-e2e` green, with a topology test that signs
in through a fixture CLI on machine B from a client attached to machine A,
over local, direct TLS and relay.

### Phase 2: core and apps (about 8 days)

1. **Core.** The `accounts` projection and rules, `client.proto` commands and
   slices, the sign-in state machine, `AgentChoice.account`, readiness in
   `AgentControlsState`, the quota join, and `provider_login_required`
   rendering data.
2. **Mac.** Settings › Accounts, the sign-in sheet, the composer Account menu,
   the header chip and the inline sign-in row.
3. **Compose (iOS and Android).** More › Accounts, account detail, the Account
   row in agent settings, the sign-in sheet and the inline row.
4. **Flows.** Maestro flows on the fixture gateway with fixture CLIs:
   - add an account;
   - sign in on two machines (paste and device code);
   - choose an account in the composer;
   - switch between turns;
   - a not-signed-in recovery.

Exit: `just kotlin` core tests, the Mac tests and `just e2e <platform>
tags:smoke` green, plus screenshots on the fixture.

### Phase 3: forwarding, SIWC, polish (about 6 days)

- **Automatic callback forwarding** in all three apps. It starts by checking
  the iOS and Android loopback listener while the in-app browser sheet is
  open.
- **SIWC as a second ChatGPT method per account**, with the required branding
  and usage UI, `auth.command` token renewal, and a clear "no web search on
  this account" note in the composer.
- The "Sign in on all machines" batch flow and the new-machine prompt.
- Sign-out on device removal.
- User guide `site/content/docs/accounts.md`, and updates to
  `harnesses.md`, `security.md` and the CLI reference.

### Tests without providers

- **Fixture `claude`.** A fixture executable in `tools/fixtures/provider-cli`
  implements `auth login` (prints both URLs, honours `$BROWSER`, reads a code
  from stdin and accepts `FIXTURE-CODE`), `auth status --json` and
  `auth logout` against a state file in `CLAUDE_CONFIG_DIR`. Plain-pipe I/O is
  enough (S1).
- **Fixture `codex app-server`.** It answers `initialize`, `account/read`,
  `account/login/start` (both types, completing after a fixture approval),
  `account/login/cancel` and `account/rateLimits/read`.
- **Wiring.** The daemon resolves the CLI paths through the harness runtime,
  so tests point it at the fixtures. The topology end-to-end test, the CLI
  end-to-end tests and the Maestro flows all use them.
- **Runner tests.** Unit tests in the style of `runner-auth-retry.test.mjs`
  assert that the adapter receives `auth: {}` for Claude and the broker token
  for Codex, and that a Claude worker's environment contains no credential
  variables.

## 8. Risks

| Risk                                                                                       | Mitigation                                                                                                                                                                                                                  |
| ------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Anthropic reads relaying the login URL and pasted code as "intermediating"                 | The design is equivalent to a Dieter terminal running `claude auth login`; the UI names Claude Code and the machine; no token ever reaches Dieter. Ask Anthropic sales before a public release that advertises the feature. |
| Claude Code changes its login output or flags (2.1.267 once broke all logins)              | The CLI version is pinned in the runtime lockfile; parsing tolerates layout changes and falls back to the `$BROWSER` hook URL; the fixture contract test fails on drift during runtime bumps.                               |
| Shadow config dir misses user configuration (MCP servers in `.claude.json`)                | Confirmed by P0.3: Dieter mirrors the `mcpServers` key into each account's own `.claude.json` before a turn, and never edits `~/.claude.json`.                                                                              |
| The rendered `DIETER_HOME/codex/config.toml` drifts from the user's `~/.codex/config.toml` | It is re-rendered before each turn when the source changes; only `model_provider` and `[model_providers.agent_bridge_openai]` are Dieter's own keys.                                                                        |
| Codex device codes expire after 15 minutes                                                 | The sheet starts a new code automatically; the browser login is the fallback.                                                                                                                                               |
| Device codes are disabled for an account or workspace                                      | Browser login with forwarding; the error text explains the ChatGPT setting.                                                                                                                                                 |
| Port 1455 is busy (the operator's own `codex login`)                                       | One Codex browser login per host; a clear "port in use" failure.                                                                                                                                                            |
| SIWC preview limits: web search fails on the plan route (P0.5)                             | Codex login stays the default; SIWC accounts are labelled as having no web search.                                                                                                                                          |
| Business or Team workspaces route wrongly without the `ChatGPT-Account-ID` header          | Not testable in Phase 0 (no Business account). Test with the first Business user; pass the header through the bridge's `start.headers` if needed.                                                                           |
| A host login is also used by the operator's own interactive CLI and races it               | The same as today, minus the adapter as a third refresher. Managed accounts avoid it entirely.                                                                                                                              |

## 9. Later

- **API-key accounts.** An `api_key` kind whose key lives in the vault and
  syncs to every machine. Anthropic explicitly allows API keys in "a secrets
  manager", so this is the one fully synced option.
- **Automatic switching on limits.** Switch to another account of the same
  provider when a usage limit is reached; the between-turn switching makes
  this small.
- **Per-project default accounts.**

## 10. Decisions

Decided on 2026-11-14:

- Phase 0 runs on the operator's accounts.
- Claude sign-in happens once per machine and account.
- Codex login comes first, SIWC later.
- The adapter fix is its own card (`c_7152335f4a2ee3c3e65872ae`).
- The quick-title bug is fixed as part of the implementation, not as a
  separate card.
- Existing Dieter Codex conversations do not resume after the move to
  `DIETER_HOME/codex`, a clean break.
- Usage moves onto the account records and replaces the gateway quota
  pipeline completely.

The file-by-file build plan is
[provider-accounts-implementation.md](provider-accounts-implementation.md).
