# Proposal: Oh My Pi on Dieter's managed Claude and ChatGPT accounts

Status: spike 2026-11-27, against OMP 19.2.1 (the version `origin/main`
pins); decisions taken and implemented on the `omp-managed-accounts` branch,
recorded in [ADR 0007](../adr/0007-oh-my-pi-managed-accounts.md), which is
binding where it differs from this page · scope: harness runtime, engine
accounts, catalog, API and CLI, Kotlin core, Mac and mobile apps · builds on
[managed-oh-my-pi.md](managed-oh-my-pi.md) and
[provider-accounts.md](provider-accounts.md)

## TL;DR

The question: can the Oh My Pi (OMP) harness run its implementation model and
its advisor model on the Claude and ChatGPT logins Dieter already manages
(Settings › Providers)? Dieter, not OMP's own configuration, would choose the
models and accounts, and the apps would offer them.

**Technically, yes. Every piece was verified offline with the pinned OMP:**

- **Credentials.** OMP takes subscription credentials per process, without its
  own login:
  - Claude: `ANTHROPIC_OAUTH_TOKEN`, or a `models.yml` `apiKey`.
  - ChatGPT: `OPENAI_CODEX_OAUTH_TOKEN`, or a `models.yml` `apiKey`.
  - It derives the ChatGPT account header from the JWT itself.
- **Two credentials in one process.** The main role and the advisor role run
  on two different providers and credentials in the same process. Both
  directions passed, in print mode and in ACP mode with Dieter's real launch
  flags.
- **Dieter chooses the models.**
  - A per-turn `--config` overlay sets `modelRoles.advisor`, and it beats a
    `config.yml` that names another advisor.
  - The advisor effort rides along as `model:level`.
- **Mid-turn refresh works.**
  - With `apiKey: "!command"`, OMP runs the command for a token, reruns it
    after a 401 and retries.
  - That happened once per provider in one turn, for the main and the advisor
    role.
  - So Dieter's daemon can serve fresh access tokens and stay the coordinator.
    OMP never sees a refresh token and stores nothing.

**ChatGPT (Codex logins) needs no rule change.**

- Dieter already reads, refreshes (through Codex's app-server) and serves Codex
  access tokens to turns.
- `dieter provider token --turn` already serves a turn's own token on the
  local route.

**Claude needs a decision first, because it breaks a binding rule.**

- [invariants.md](../invariants.md) and
  [ADR 0006](../adr/0006-provider-accounts.md) say: "Dieter never reads,
  stores, refreshes, replicates or injects Claude.ai credentials."
- Anthropic's terms forbid third-party tools from routing requests through
  Pro/Max credentials. OMP also impersonates Claude Code on the wire: it sends
  Claude Code's user agent, its billing header and "You are Claude Code" as the
  system prompt.
- The user accepted this risk in the request. It is still an account-level risk
  (blocking or suspension, at any time, server-side) and a change to a binding
  invariant. So it should be an explicit, per-account opt-in, default off.

**Recommended shape**, about 20 agent-days:

- **Managed OMP home.** One machine-local home that holds no logins.
- **Per-turn files.** A Dieter-rendered `models.yml` whose `apiKey` for each
  provider is `!dieter provider token --turn --provider anthropic|openai-codex`
  (the daemon maps each provider to the turn's implementation or advisor
  account), plus one overlay per conversation that pins every OMP model role.
- **Two account selections per conversation:** implementation and advisor.
- **Apps.** OMP gets the existing account picker; its provider follows from the
  chosen model. The composer adds an Advisor picker (Off, or a model plus an
  account).

## 1. Question and constraints

- Use the 0.7 provider accounts, not OMP's `/login` and not the operator's
  `~/.omp`: one place to sign in, the same accounts the Claude Code and Codex
  harnesses use.
- The implementation model and the advisor model are chosen independently,
  possibly on different providers and accounts.
- Models are Dieter-managed (the accounts' subscription models), not OMP's
  `config.yml` / `models.yml`.
- Apps: pick both from the composer, on every client (Kotlin core rules, per
  [AGENTS.md](../../AGENTS.md)).

## 2. What was verified

Drivers are in `tools/spikes/omp-managed-auth/` (Appendix A). Every run used:

- a throwaway `HOME` and OMP agent dir;
- fake tokens;
- a loopback stand-in for `api.anthropic.com` and
  `chatgpt.com/backend-api`.

No real credential or account was used. The upstream records each request's
credential only as a fingerprint (scheme, prefix, length, SHA-256).

| #   | Scenario                                                                                                                               | Result                                                                                                                                                                   |
| --- | -------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| P1  | Print mode, main `anthropic/claude-sonnet-5-5`, advisor `openai-codex/gpt-6-sol`, tokens in env                                        | Main request: `/v1/messages` with the Anthropic token. Advisor request: `/backend-api/codex/responses` with the Codex token and `chatgpt-account-id: acct-dieter-spike`. |
| P2  | Print mode, reversed (Codex main, Claude advisor)                                                                                      | Same, mirrored.                                                                                                                                                          |
| P3  | ACP mode (`omp acp --config <overlay> --thinking=high --advisor --model=…`, Dieter's `ompACPArgs`), Claude main, Codex advisor         | `end_turn` with the main reply. The advisor ran on Codex.                                                                                                                |
| P4  | ACP mode, Codex main, Claude advisor                                                                                                   | Same, mirrored.                                                                                                                                                          |
| P5  | ACP mode with the agent dir's `config.yml` setting `modelRoles.advisor` (and `default`) to `openai-codex/gpt-6-astra`                  | Dieter's overlay won: the advisor ran on `claude-opus-5-5` and the main model was the `--model` value. `gpt-6-astra` was never called.                                   |
| P6  | ACP mode, all chat roles pinned to the main model, advisor `openai-codex/gpt-6-sol:low`                                                | Advisor request carried `reasoning.effort=low`; main kept `high`. The auxiliary requests (below) stayed on the main model and credential.                                |
| R1  | ACP mode, no env tokens: `models.yml` `apiKey: "!token-helper …"` per provider; the first token of each provider answers 401 (expired) | Helper called twice per provider. Requests went `token.1 → 401 → token.2 → 200` for Claude main and for Codex advisor. `end_turn` with the reply.                        |

**Side findings:**

- **ACP turns make auxiliary calls.** Each turn compresses skill descriptions
  into routing hints (`extensibility/skill-descriptions.ts`) with three
  `max_tokens: 1024` requests.
  - Without pinned roles they fell back to the **main model** (Opus in P3),
    which spends that quota.
  - With two providers' credentials present, an unpinned role resolves through
    OMP's built-in priority chains and may land on the _other_ account.
  - Dieter must pin every chat role (§6.2).
- **OMP model discovery.** OMP calls `GET /v1/models` with the Anthropic token
  for discovery.
- **Hang without stdin.** `omp -p` waits forever on an open, non-TTY stdin
  (`readPipedInput`). Always redirect stdin.

## 3. How OMP 19.2.1 handles credentials

Paths are relative to `node_modules/@oh-my-pi/`.

| Topic                 | Fact                                                                                                                                                                                                                                                                                                                                                   |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Claude env token      | `ANTHROPIC_OAUTH_TOKEN` (then `ANTHROPIC_API_KEY`) via the `anthropic-foundry` env hook (`pi-ai/src/registry/hooks/env.ts`). An `sk-ant-oat` prefix selects OAuth request shaping (`pi-ai/src/utils/anthropic-auth.ts` `isOAuthToken`).                                                                                                                |
| ChatGPT env token     | `OPENAI_CODEX_OAUTH_TOKEN` (`pi-catalog/src/compat/rules/providers/openai-codex.kdl`). The account id comes from the JWT claim `https://api.openai.com/auth.chatgpt_account_id` (`pi-catalog/src/wire/codex.ts` `getCodexAccountId`).                                                                                                                  |
| Precedence            | `--api-key` > `models.yml` `apiKey` > **stored OAuth in `agent.db`** > stored login key > env > stored API key (`pi-ai/src/auth/cascade.ts` `peek`/`get`). An env token loses to any login in the agent dir, so managed turns need an agent dir with no logins.                                                                                        |
| `!command` values     | `apiKey: "!cmd"` runs `/bin/sh -c cmd` with a 10 s timeout. stdout is cached per process; a failure backs off 30 s; a 401 invalidates the cache and reruns (`pi-coding-agent/src/config/resolve-config-value.ts`, proven by R1).                                                                                                                       |
| OMP's own logins      | `omp login anthropic` / `omp login openai-codex` use Claude Code's and Codex's public client ids. They store rotating refresh tokens in `agent.db` and refresh them themselves (`pi-catalog/src/compat/rules/auth/*.kdl`). They are scriptable (URL, loopback callback on 54545 / fixed 1455, paste fallback; `pi-coding-agent/src/cli/login-cli.ts`). |
| Auth broker           | `omp auth-broker` is an HTTP credential server. Clients get access tokens from a snapshot and `POST /v1/credential/:id/refresh` on expiry or a 401; "the broker holds OAuth refresh tokens" (`pi-ai/src/auth-broker/types.ts`). It is a large, OMP-versioned protocol (~5.7k lines).                                                                   |
| Claude Code imitation | Anthropic requests carry `user-agent: claude-cli/2.1.326 (external, cli)`, an `x-anthropic-billing-header: cc_version=…` system block and "You are Claude Code, Anthropic's official CLI for Claude." (observed; `pi-ai/src/providers/claude-code-fingerprint.ts`).                                                                                    |
| Advisor               | `advisor.enabled` defaults to off for ACP/RPC hosts; `--advisor` or an overlay turns it on (`pi-coding-agent/src/advisor/settings.ts`). Its model is `modelRoles.advisor`, then `slow`, never the primary (`config/model-resolver.ts` `resolveAdvisorRoleSelection`). Optional `model:level` suffix.                                                   |
| Roles to pin          | `default, smol, slow, vision, plan, commit, tiny, memory, task, advisor, widget` (chat), plus kind roles `image, web, speech, dictation, judge` (`pi-coding-agent/src/config/model-roles.ts`).                                                                                                                                                         |
| Overlays              | Each `--config` file is a strict settings layer above the agent dir's `config.yml`; a missing file is a hard error (`config/settings.ts`).                                                                                                                                                                                                             |
| ACP identity          | `@ai-sdk/harness-acp` 1.0.135 hashes the launch `args` and the forwarded env **names** into the lifecycle identity (`createACPAgentIdentity`). If the model, `--thinking` or `--advisor` changes between turns, resume fails with "ACP lifecycle state is incompatible with the configured agent." Env _values_ are not part of it.                    |

## 4. Policy and invariants

### 4.1 ChatGPT

- No Dieter rule changes.
- Codex turns already get their account's access token from the daemon
  (`internal/engine/accounts/broker.go` `codexToken`).
- The daemon refreshes through Codex's own app-server (`account/read
{refreshToken: true}`) under the account lock. That satisfies "exactly one
  refresher: the provider's own tool, or the daemon under that account's lock".
- The [threat model](../threat-model.md) needs one line: OMP turns hold their
  ChatGPT account's access token, as Codex turns do.
- The residual OpenAI policy risk is as described in
  [managed-oh-my-pi.md §3.2](managed-oh-my-pi.md): OMP reuses Codex's client
  id, and its requests say `omp/19.2.1`.

### 4.2 Claude

- **Anthropic's terms.** Third-party developers may not "route requests
  through Free, Pro, or Max plan credentials on behalf of their users" or
  "collect, store, or intermediate Claude.ai credentials"
  ([legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)).
- **OMP impersonates Claude Code.** Its fingerprint is what makes subscription
  tokens work for it. Anthropic can detect or block that at any time, and
  accounts that use it are at risk.
- **This breaks a binding invariant.** Using a managed Claude login in OMP
  means one of these:
  - the daemon reads Claude Code's access token (options A–C below);
  - Dieter signs in to Claude through a non-Claude-Code client (option D).

  Either breaks the invariant _"Dieter never reads, stores, refreshes,
  replicates or injects Claude.ai credentials"_
  ([invariants.md](../invariants.md), [ADR 0006](../adr/0006-provider-accounts.md)).
  Per [AGENTS.md](../../AGENTS.md) this needs an explicit decision (D1) and an
  ADR that supersedes that part of 0006 before any implementation.

- **Option D is no way around it.** It avoids Dieter _reading_ the token, but
  it is still the same terms issue. It adds a second sign-in per account and
  machine, and a second rotating grant that can be revoked or race.
- **What can stay true:**
  - Claude Code stays the only refresher of the login.
  - Only access tokens (hours) reach OMP, never refresh tokens.
  - Nothing is stored outside Claude Code's store or replicated.
  - Everything stays local, behind an opt-in per account.

## 5. Credential delivery options

| Option                                 | How                                                                                                                                                                                                                           | Mid-turn refresh                                               | Claude refresher                   | Verdict                                                                                                                         |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- | ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| A. Static env                          | Runner sets `ANTHROPIC_OAUTH_TOKEN` / `OPENAI_CODEX_OAUTH_TOKEN` per turn                                                                                                                                                     | No: a token that expires mid-turn fails the turn (Claude: 8 h) | Claude Code                        | Works (P1–P6). Simplest fallback. The token sits in the worker env.                                                             |
| **B. `!command` helper (recommended)** | Rendered `models.yml`: `apiKey: "!'<dieter>' provider token --turn --provider anthropic"` (and `openai-codex`). The daemon maps the provider to the turn's implementation or advisor account and returns a fresh access token | Yes: 401 → rerun → retry (R1)                                  | Claude Code (daemon asks it, §6.3) | Reuses `GetProviderTurnToken` (turn token, local route only). No token in any file or env. Beats any stored login (precedence). |
| C. Dieter as OMP auth broker           | Daemon implements `/v1/snapshot` + `/v1/credential/:id/refresh`                                                                                                                                                               | Yes                                                            | Claude Code                        | Same outcome as B for far more code, tied to an internal OMP protocol. Not worth it.                                            |
| D. OMP-owned logins                    | Per-account `omp login` driven by Settings › Providers; grant in a per-account OMP `agent.db`                                                                                                                                 | Yes (OMP refreshes)                                            | OMP (separate grant)               | Second sign-in per account and machine. One agent dir can't hold "Claude account X + ChatGPT account Y" per role. Rejected.     |

## 6. Design

### 6.1 Managed OMP home

- **Clean break.** Every Dieter OMP process uses
  `PI_CODING_AGENT_DIR=DIETER_HOME/omp/agent`: machine-local, never replicated,
  **no `agent.db` logins**. This is the managed home from
  [managed-oh-my-pi.md §4.1](managed-oh-my-pi.md) and a clean break: OMP
  conversations from `~/.omp` don't resume, and they continue from the Dieter
  transcript through the existing fork-seed path.
- **Forwarding.**
  - Stop forwarding `OMP_PROFILE`.
  - Blank the inherited `ANTHROPIC_*`, `OPENAI_*` and `CLAUDE_CODE_OAUTH_TOKEN`,
    as Claude turns already do.
  - Do not forward `CLAUDE_CONFIG_DIR`: it turns OMP's foreign Claude sources
    back on.
- **Shared configuration.** The user's skills, rules and `WATCHDOG.md` may be
  linked in, like the Claude per-account home links `~/.claude`. Never link
  `agent.db`, `config.yml` or `models.yml`.

### 6.2 Per-turn rendering

The runner (`omp-runtime.mjs`, `provider-options.mjs`) writes two files and
keeps the ACP launch identity constant for a conversation.

1. **`models.yml`** in the managed agent dir. It is the same for every turn,
   so it is rendered once per runtime digest:
   ```yaml
   providers:
     anthropic:
       apiKey: "!'<daemon executable>' provider token --turn --provider anthropic"
     openai-codex:
       apiKey: "!'<daemon executable>' provider token --turn --provider openai-codex"
   ```
   Key the helper by OMP provider, not role, so `models.yml` stays static. The
   daemon maps the provider to the turn's main or advisor account.
2. **Per-conversation overlay** at a fixed path
   (`<runtimeRoot>/harness-config/omp-<conversation>.yml`): the existing
   `ompRuntimeConfig()` plus:
   ```yaml
   modelRoles:
     default: anthropic/claude-opus-5-5:high      # implementation model + effort
     smol: anthropic/claude-opus-5-5               # all chat roles pinned to the
     slow: anthropic/claude-opus-5-5               # implementation model (or a
     plan: …  commit: …  tiny: …  memory: …        # cheap model on the SAME
     task: …  vision: …  widget: …                 # account; decision D5)
     advisor: openai-codex/gpt-6-sol:low           # or omitted when Off
   advisor:
     enabled: true                                 # false when Off
     reviewMode: agent-end                         # default cadence (D5)
   ```
3. **Launch arguments are constant**:
   `omp acp --config <runtime overlay> --config <conversation overlay> --hook
<hook>`.
   - Drop `--model`, `--thinking` and `--advisor`; the overlay carries all three.
   - Forward a fixed set of env names (e.g. `DIETER_TURN_TOKEN`), whether or not
     a turn uses them.
   - This settles managed-oh-my-pi E1/E6. Changing the model, effort, advisor
     or account between turns doesn't change the identity.
   - Phase 0 check L5 confirms that a resumed OMP session takes the new
     `modelRoles.default`. If it doesn't, switch through the ACP `model` config
     option (E2).
4. **Only the providers a turn uses are reachable.** The helper refuses a
   provider the turn has no account for, so an unpinned role can't silently
   spend the other account.

### 6.3 Engine and accounts

- **Two selections per conversation.**
  - `selection.account_id`: the implementation account. Its provider follows
    from the model prefix (`anthropic/` → Claude, `openai-codex/` → ChatGPT).
  - A new advisor selection: model, effort and account.
  - Stored on the card next to `provider_account_id`, as
    `advisor_provider_account_id`.
- **`resolveTurnAuth`** (`turn_admission.go`) accepts `omp-acp`:
  - It resolves both accounts with the existing fallback order (explicit, then
    the conversation's last, then the provider default, then the only signed-in
    account).
  - It refuses the turn when either account isn't signed in on the owner
    daemon.
  - `accounts.harnessProvider` stops being keyed on the adapter alone.
- **`GetProviderTurnToken`** gains `provider` (the OMP provider). It returns
  the matching account's token:
  - **ChatGPT:** `codexToken` as today (Codex app-server refresh under the
    account lock).
  - **Claude** (new, opt-in): read the per-account Claude Code store (Keychain
    item `Claude Code-credentials-<sha256(dir)[:8]>`, or `.credentials.json` on
    Linux) and return the **access token only**.
    - When the token is expired or within 5 minutes of expiry, first ask
      Claude Code to refresh. Run a prompt-less Claude Code call with
      `CLAUDE_CONFIG_DIR` under the account lock, then re-read.
    - Claude Code stays the single refresher; Dieter never uses the refresh
      token. Live check L2 confirms that the call refreshes.
- **Auth failures.**
  - A 401 that survives the helper rerun reaches the runner as today's
    `auth-failure` frame. It marks that account's login expired and keeps the
    resume-once retry.
  - Report which role failed, so the notice names the right account.
- **Quotas.** Usage reporting per account is unchanged. Turns on OMP count
  against the same account usage that Claude Code and Codex turns show.

### 6.4 Models

- Replace the three-selector filter (`omp-models.mjs`) with the managed list:
  - Claude: the same Claude models the Claude Code harness offers, under OMP's
    ids (`anthropic/claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`,
    `claude-fable-5-x`).
  - ChatGPT: the `openai-codex/gpt-6-*` models.
- Offer each group only when the machine has a signed-in account of that kind,
  and Claude only with the opt-in.
- `omp models --json` in the managed home needs no credentials for the bundled
  catalog. It is still the source of names, context windows and thinking
  levels.
- Add `group` (Claude / ChatGPT) to `HarnessModel`, as managed-oh-my-pi §3.3
  planned, so pickers can show sections.
- The advisor choices are the same list plus Off.

### 6.5 API, CLI parity, proto

Per [AGENTS.md](../../AGENTS.md):

- **Proto.**
  - `HarnessSelection.advisor` (`model`, `effort`, `account_id`) replaces the
    boolean `advisor` provider option.
  - `GetProviderTurnTokenRequest.provider`.
  - A per-account `allow_omp` flag on `ProviderAccount` (Claude only; KV,
    synced, no secret).
- **CLI.**
  - `dieter card create|send --advisor-model M --advisor-effort E
--advisor-account ID|off`.
  - `dieter provider allow-omp ACCOUNT on|off`.
  - `dieter provider token --turn --provider P`.
- **Tests.** Local, direct-TLS and relay e2e (`internal/testkit/topology`).
  The fixture backend serves fake tokens to a loopback upstream, as in this
  spike.

### 6.6 Apps (rules in the Kotlin core)

- **`ProviderKinds.forHarness`.** For `omp`, the account picker lists the
  accounts of the selected model's provider. Changing the model to another
  provider re-picks that provider's default account.
- **`AgentControls`: a new Advisor control** (Off, or model plus account),
  also in `Creation`. Mac shows it as a composer chip. Compose and iOS get it
  from the shared core.
- **Settings › Providers.** Each Claude account gets "Allow Oh My Pi to use
  this login". When it is switched on, a sheet states the Anthropic terms and
  the account risk. It is off by default.
- **Transcript.**
  - The agent row shows the implementation and advisor accounts.
  - Advisor notes appear as their own capability (managed-oh-my-pi §3.4/E5);
    the capabilities hook already records OMP events.

## 7. Live checks before building

Each needs the user's go-ahead. L1, L2 and L4 use a real Claude subscription
through OMP, which is the account risk in §4.2.

| #   | Check                                                                                                                                          | Pass condition                                                           |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| L1  | One OMP ACP turn on a managed Claude account through the helper, with a ChatGPT advisor                                                        | `end_turn`; both accounts' usage moves; no account notice from Anthropic |
| L2  | Expired or near-expiry Claude Code token: does the prompt-less SDK call (`accountInfo()`) with `CLAUDE_CONFIG_DIR` refresh it in the Keychain? | New `expiresAt` in the store, written by Claude Code; no Dieter refresh  |
| L3  | Codex over WebSocket (OMP's default; the spike forced SSE with `PI_CODEX_WEBSOCKET=0`) with a helper token                                     | Turn completes; a 401 on the socket also reruns the helper               |
| L4  | A Claude Code turn and an OMP turn on the same login at the same time                                                                          | Neither invalidates the other; no refresh-token rotation by OMP          |
| L5  | Change the model, effort, advisor and account between turns with constant launch args                                                          | Resume keeps the session; the new models are used                        |

### 7.1 Results so far (2026-11-27, mini-home)

Decisions taken: D1 accepted (Claude as a per-account opt-in), D3 clean break
(OMP 19.2.1 is already the latest release and what `origin/main` pins), D4
managed models only, D6 live checks approved.

| #   | Result                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| L1  | **Passed.** Real OMP ACP turns (`live/live-turn.sh`), credentials only from the `!command` helper: (a) main `claude-sonnet-5-5` + advisor `claude-haiku-5-5:low` on the host Claude login `pa_cccav…`; (b) main `claude-sonnet-5-5` on that login + advisor `openai-codex/gpt-6-sol:low` on a ChatGPT Pro login; (c) main `openai-codex/gpt-6-sol` + advisor `claude-haiku-5-5:low`. All `end_turn`; OMP's own transcripts show each role on the intended provider and model. The ChatGPT login was a throwaway one (the host login on this machine is dead, below).                           |
| L2  | **Passed.** On a throwaway Claude Max login, `live/expire-claude-login.mjs` moved the stored `expiresAt` into the past. `claude auth status --json` did **not** refresh (it still says logged in). Dieter's prompt-less usage probe (`usage-claude.mjs`, SDK `accountInfo()` + usage) made Claude Code refresh in about 1 s: new access token, refresh token rotated by Claude Code, 480 min left. Then a live OMP turn started on the expired login: the helper asked the probe to refresh (1.2 s), served the new token, and the turn ended `end_turn`. The login was signed out afterwards. |
| L3  | **Passed on OMP's default transport.** (b) and (c) ran without `PI_CODEX_WEBSOCKET`, so OMP chose the transport from the backend's model discovery (`prefer_websockets`); OMP does not log which. A forced Codex refresh through `account/read {refreshToken: true}` took 1.6 s and the helper then served the new token. A 401 on a socket was not forced live.                                                                                                                                                                                                                               |
| L4  | **Passed.** The OMP turn ran on the same login as a live Claude Code turn (this spike's own session), which kept working. The Keychain item's modification date did not change; OMP never sees a refresh token.                                                                                                                                                                                                                                                                                                                                                                                |
| L5  | **Passed with a correction** (`resume-probe.sh`, offline). With constant launch args, a loaded session takes a new **advisor** from the overlay, but keeps its stored **implementation model and effort**: those change through the ACP `model`/`thinking` config options (`session/set_config_option`). Turn 2 then ran on Codex `gpt-6-sol:high` with a Claude Opus advisor, and the Codex request carried turn 1's Claude reply.                                                                                                                                                            |

Design consequences:

- §6.2 item 3: model and effort go through ACP config options on every turn
  (OMP offers every available model there), not through `modelRoles.default`.
  The overlay keeps the advisor and the pinned auxiliary roles.
- OMP gives a `!command` 10 s and drops a failing one silently ("No API key
  found"). The daemon must refresh before the turn (and in the background) so
  the helper only reads; a refresh that needs Claude Code or the Codex
  app-server can take longer than 10 s.
- OMP runs the helper with OMP's own `HOME`; the production helper is the
  `dieter` CLI talking to the daemon, so it must not depend on `HOME`.
- Claude refresh on demand = run the existing usage probe for the account
  (`ProbeClaudeUsage`) under the account lock, then read the store again.
  Claude Code stays the only refresher. The probe needs `USER`/`LOGNAME`
  (Claude Code finds its Keychain item by user name; without them it reports
  "signed out" and refreshes nothing) and the real `HOME`.
- `claude auth status` never refreshes, so `checkLogin` keeps reporting an
  expired-but-refreshable Claude login as signed in. That is correct for
  sign-in state, but the token service must not treat it as proof of a usable
  access token.
- OMP asks for both providers' keys at startup (discovery), also for a
  provider the turn does not use. The daemon answers "no account" for those at
  once, without refreshing anything.

Separate finding (not part of this design): `dieter provider check` reports
the host ChatGPT account `pa_d5h6…` as signed in on mini-home, but its
`~/.codex` login is dead: Codex answers "Your access token could not be
refreshed. Please log out and sign in again" and `account/read` returns no
account. `checkLogin` (`internal/engine/accounts/status.go`) only parses
`auth.json` for host Codex logins and never asks Codex, so a dead login looks
healthy and Codex turns on it fail.

## 8. Plan

Implemented on the `omp-managed-accounts` branch; the built design is
[ADR 0007](../adr/0007-oh-my-pi-managed-accounts.md). It differs from §6 where
§7.1 said so (model and thinking through ACP options and the hook, not
`modelRoles.default`), and in the API: the advisor is three provider options
(`advisor_model`, `advisor_effort`, `advisor_account`) instead of a
`HarnessSelection.advisor` message, and the opt-in is `omp_access`
(`dieter provider omp-access ACCOUNT on|off`). The plan as estimated:

About 20 agent-days after D1–D6. Each milestone ships behind the per-account
opt-in.

| #   | Milestone                                                                                                                                  | Days |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------ | ---- |
| M0  | Live checks L1–L5 (with the user present for logins)                                                                                       | 1–2  |
| M1  | Managed home, rendered `models.yml` + per-conversation overlay, role pinning, constant launch identity, clean break (runtime + Go harness) | 4    |
| M2  | Engine: OMP accounts, two-account resolution, card advisor fields, helper `--provider`, ChatGPT path                                       | 3    |
| M3  | Claude token service + refresh via Claude Code, opt-in flag; ADR superseding 0006's Claude rule; invariants and threat model               | 3    |
| M4  | Catalog: managed model list, groups, advisor choices                                                                                       | 2    |
| M5  | Proto, API, CLI parity, topology e2e, fixture backend                                                                                      | 3    |
| M6  | Kotlin core rules, Mac composer chip and Providers toggle, Compose/iOS via core, Maestro flow                                              | 4    |
| M7  | Docs (user guide, dieter-cli skill), runtime tests for P1–P6 and R1 so an OMP bump that changes them fails                                 | 1–2  |

## 9. Decisions needed

Taken on 2026-11-27 and recorded in
[ADR 0007](../adr/0007-oh-my-pi-managed-accounts.md): D1 accepted as
recommended, D2 option B, D3 clean break, D4 managed models only, D5 as
recommended, D6 live checks run (§7.1).

| #   | Decision                                                                                 | Recommendation                                                                                          |
| --- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| D1  | Accept breaking the "no Claude credentials in Dieter" invariant for OMP                  | Only as a per-account opt-in, default off. New ADR. Access tokens only; Claude Code stays the refresher |
| D2  | Credential delivery                                                                      | B: `!command` helper over the turn token. A (static env) only as a fallback                             |
| D3  | Managed home and clean break for existing OMP conversations                              | Yes (no import of `~/.omp`)                                                                             |
| D4  | Keep the user's own OMP models (`~/.omp/agent/models.yml`, e.g. the Tailscale endpoints) | No: managed means account models only, as asked. Revisit as an "extra providers" setting later          |
| D5  | Auxiliary roles and advisor cadence                                                      | Pin auxiliary roles to the implementation model; advisor `agent-end` by default (one review per run)    |
| D6  | Run the live checks on your real Claude Max and ChatGPT Pro accounts                     | Yes for ChatGPT; Claude only after D1                                                                   |

## 10. Risks

- **Anthropic.**
  - Blocking or suspension of accounts used through OMP, without notice.
  - OMP fingerprint drift: each OMP bump may change Claude Code imitation
    details.
  - Mitigations: opt-in, a clear warning, and runtime tests that catch
    request-shape changes on OMP bumps.
- **OMP churn.** OMP moves fast (18.12 → 19.2 in a month). Pin it, and keep
  P1–P6/R1 as runtime tests against the fake upstream.
- **Token exposure to the agent.** The agent's own shell can run `dieter
provider token --turn` (it has the turn token), as it can for Sign in with
  ChatGPT today.
  - The token is the turn's access token only: hours for Claude, days for
    ChatGPT. It is never a refresh token.
  - On the same user account, the Claude Code Keychain item is not a stronger
    boundary.
  - Record this in the threat model.
- **Cost.** An advisor that reviews every turn doubles model usage, and so
  does an unpinned auxiliary role on an expensive model. Pinning and
  `agent-end` keep it bounded.

## Appendix A. Running the probes

```sh
W=tmp/omp-managed-auth                      # scratch; never commit
mkdir -p $W/pkg $W/bun $W/run/bin
(cd $W/pkg && npm init -y >/dev/null && npm install --ignore-scripts @oh-my-pi/pi-coding-agent@19.2.1)
(cd $W/bun && npm init -y >/dev/null && npm install bun@1.4.5)
ln -sf "$(readlink -f $W/bun/node_modules/.bin/bun)" $W/run/bin/bun
tools/spikes/omp-managed-auth/probe.sh         $PWD/$W/pkg/node_modules/.bin/omp $PWD/$W/run/bin $PWD/$W/probe   </dev/null
tools/spikes/omp-managed-auth/refresh-probe.sh $PWD/$W/pkg/node_modules/.bin/omp $PWD/$W/run/bin $PWD/$W/refresh </dev/null
cat $W/probe/summary.txt $W/refresh/summary.txt
```

- `fake-upstream.mjs`: the loopback Anthropic/Codex stand-in.
  - `FAKE_UPSTREAM_REJECT` lists token fingerprints that answer 401.
  - `FAKE_UPSTREAM_BODIES` keeps request bodies, which never contain
    credentials.
- `acp-probe.mjs`: a minimal ACP client launched with Dieter's flags.
- `token-helper.sh`: the stand-in for `dieter provider token --turn`.
