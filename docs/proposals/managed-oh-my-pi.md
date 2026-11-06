# Proposal: a Dieter-managed Oh My Pi

Status: spike and plan, 2026-10-20 · scope: harness runtime, catalog and
discovery, settings API and CLI, Kotlin core, Mac app

## TL;DR

Dieter already runs Oh My Pi (OMP) `@oh-my-pi/pi-coding-agent` 18.12.2 from its
pinned runtime through ACP. It uses the operator's own `~/.omp/agent` for
credentials, models and settings, and shows a hard-coded list of three Codex
models. This proposal turns it into an installation that Dieter owns and
configures:

- **Managed home.** Every Dieter OMP process uses `DIETER_HOME/omp/agent`.
  Dieter renders its config from the repository's shipped defaults plus
  per-machine settings. It no longer reads `~/.omp`.
- **Subscription discovery.** Codex (ChatGPT) subscriptions are found
  automatically through a credential helper that reads Codex's own store
  without writing to it. **Claude subscriptions cannot be wired into OMP.**
  Anthropic's terms forbid third-party tools from using or intermediating
  Claude.ai credentials, and OMP's Anthropic provider imitates Claude Code's
  request fingerprint. Claude models reach OMP with an Anthropic API key.
  Opus-on-subscription reaches an advisor seat only through the unmodified
  Claude Code binary (Phase 4).
- **Models.** The catalog shows every model OMP can actually use on that
  machine, grouped by provider. Model and thinking can change between turns
  through ACP session options rather than launch arguments.
- **Advisor and implementer.** The conversation model is the implementer. A
  new per-conversation **Advisor** picker (Off or any discovered model) drives
  OMP's native advisor (`modelRoles.advisor`, `advisor.enabled`). This works
  under ACP: verified in source.
- **Web and crawling.** OMP's built-in `web_search` (works without keys),
  URL reading with 78 site scrapers, and an optional browser, configured per
  machine. OMP has no multi-page crawler; we ship a bounded crawl skill and an
  optional Firecrawl key.
- **Skills and MCP from the repo.** A versioned asset tree in the runtime
  (skills, agent definitions, advisor guidance, MCP server catalog) is part of
  the runtime digest. Users toggle items per machine and add their own MCP
  servers.
- **UI.** Mac Settings › Agents gets an editable Oh My Pi page per machine.
  The composer gets an Advisor picker. Android and iOS get the composer picker
  for free from the shared core.

The plan has five phases (0–4); Phases 0–3 take roughly 3–4 weeks. Phase 0
is a set of experiments that settle the open technical questions before any
API is added.

## 1. Where we are

| Area                   | Today                                                                                                                                                                                                                                             |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Runtime                | OMP 18.12.2 pinned in `internal/harness/runtime/package.json`, run under managed Bun 1.4.3 behind `@ai-sdk/harness-acp` (`omp-runtime.mjs`). The upstream release is 18.12.4 with no breaking changes.                                            |
| Launch                 | `omp acp --config <overlay> --hook <hook> --thinking=<e> [--advisor] --model=<sel>` (`provider-options.mjs`, `ompACPArgs`). The overlay only sets stream timeouts and turns off async jobs and auto-backgrounding.                                |
| Credentials and config | Not isolated. `HOME`, `PI_CODING_AGENT_DIR` and `OMP_PROFILE` are forwarded (`runner.mjs`, `harness.go` `harnessEnvironment`). OMP reads the operator's `~/.omp/agent`: `agent.db` OAuth, `models.yml`, `config.yml`, `WATCHDOG.yml`, extensions. |
| Models                 | `omp-models.mjs` filters discovery down to three fixed `openai-codex/gpt-6-*` selectors. Other models the operator configured never show up.                                                                                                      |
| Advisor                | A boolean provider option that passes `--advisor`. The advisor model is whatever `modelRoles.advisor` says in the operator's `~/.omp`. Dieter can't show or choose it.                                                                            |
| Effort                 | Locked after the first message, because `--thinking` is a launch argument (no `effort-selection` capability).                                                                                                                                     |
| Dieter tools           | `present_content` and the background-process tools reach OMP as the ACP bridge's `ai-sdk-harness-tools` MCP server. Dieter passes no other MCP servers and no skills.                                                                             |
| Settings               | No per-machine harness settings. Mac Settings › Agents is read-only (`SettingsPages.swift`).                                                                                                                                                      |
| Credential readers     | `quota-openai.mjs` and `quota-claude.mjs` already locate Codex (`auth.json` or Keychain `Codex Auth`) and Claude Code (`.credentials.json` or Keychain `Claude Code-credentials`) logins without writing to them.                                 |

The operator's own `~/.omp/agent/agent.db` currently holds an `anthropic`
OAuth credential disabled after `invalid_grant` (2026-10-12) and one of two
`openai-codex` credentials disabled after a 401 on refresh (2026-10-17). The
cause is not proven. Separate grants that rotate refresh tokens and are
refreshed by more than one client are a plausible explanation, and the managed
design below avoids that pattern.

## 2. What OMP 18.12 provides

Verified in the pinned package source unless marked otherwise.

| Need                | OMP facility                                                                                                                                                                                                                                                                                                                                                                                |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Relocate everything | `PI_CODING_AGENT_DIR` moves the agent dir: `agent.db`, `config.yml`, `models.yml`, `sessions/`, `agents/`, skills.                                                                                                                                                                                                                                                                          |
| Layered config      | env > flags > `--config` overlays (repeatable) > project (`.omp/config.yml`, plus a raw merge of project `.claude/settings.json`) > global `config.yml` > defaults. Objects deep-merge; **arrays replace**.                                                                                                                                                                                 |
| Credentials         | `agent.db` (SQLite, unencrypted, 0600). Precedence: `--api-key` > `models.yml` `apiKey` > stored OAuth > `/login` key > env. A `models.yml` `apiKey` may be `!command`: the output is cached per process and the command reruns after a 401.                                                                                                                                                |
| Foreign logins      | **None.** OMP never reads Claude Code or Codex credential stores. Its own `anthropic` and `openai-codex` OAuth logins use the Claude Code and Codex public client IDs.                                                                                                                                                                                                                      |
| Model list          | `omp models --json` lists models whose provider has usable auth: `{provider, id, selector, name, contextWindow, thinking[], cost, …}`.                                                                                                                                                                                                                                                      |
| Roles               | `modelRoles`: `default, smol, slow, vision, plan, commit, tiny, memory, task, advisor`, plus kind roles such as `web`. Fallbacks go in `retry.fallbackChains`.                                                                                                                                                                                                                              |
| Advisor             | A separate agent with read-only tools and an `advise` tool (`nit`/`concern`/`blocker`) whose notes are injected as `<advisory>` blocks. Model from `modelRoles.advisor`, falling back to `slow` and never to the main model. **Under ACP it is pinned off unless a layer sets it**; `--advisor` or an overlay with `advisor.enabled: true` turns it on (`main.ts` `applyProtocolDefaults`). |
| Subagents           | Model from `task.agentModelOverrides.<agent>`, then the agent file's `model:`, then the parent's model. Agent files live in `<agentDir>/agents/*.md` and `.omp/agents/*.md`.                                                                                                                                                                                                                |
| ACP model switching | Session config options `mode`, `model` and `thinking`. `model` offers `session.getAvailableModels()`, which is the `enabledModels` cycle list.                                                                                                                                                                                                                                              |
| MCP                 | **ACP forces `enableMCP: false`**. Only `mcpServers` from `session/new`/`load`/`resume` are used (stdio, http, sse). A server that fails to connect fails the session.                                                                                                                                                                                                                      |
| Skills              | `SKILL.md` directories from the native agent dir, `skills.customDirectories`, and by default project `.agents/skills`, `.claude/skills`, `.codex/skills`, `.github/skills`. Per-source switches exist (`skills.enableClaudeUser`, …).                                                                                                                                                       |
| Context files       | Project `AGENTS.md` and `CLAUDE.md` load by default (searching up to the repo root); `RULES.md` always applies; `disabledProviders` switches sources off.                                                                                                                                                                                                                                   |
| Web                 | `web_search` chain `parallel, hosted, exa, firecrawl, searxng, startpage, duckduckgo, …`; keyless engines work. `hosted` uses the session provider's native search (Codex included). The `read` tool fetches URLs (native, trafilatura, lynx, Jina, Firecrawl) and has 78 site scrapers. `browser` is puppeteer-core and downloads Chromium on first use. No multi-page crawler.            |
| Network on startup  | Catalog refresh (`catalog.stencil.so`), update check (interactive only), `dev.autoqa` reports (asks for consent; headless pushes need `PI_AUTO_QA_PUSH`), background session titles, plugin marketplace checks.                                                                                                                                                                             |

## 3. Assessment per requirement

### 3.1 A Dieter-shipped, Dieter-configured installation: feasible

The binary is already shipped and pinned. The missing parts are isolation and
rendering: point `PI_CODING_AGENT_DIR` at `DIETER_HOME/omp/agent`, stop
forwarding `OMP_PROFILE`, and render `config.yml` and `models.yml` there.
Without isolation nothing below is deterministic, because the operator's
`config.yml` beats Dieter's protocol defaults.

**Clean break.** OMP keeps its sessions in the agent dir, so conversations
started against `~/.omp` can't be resumed by the managed install. They
continue as a new OMP session seeded with the Dieter transcript, using the
existing fork-seed path. No import of `~/.omp` content.

### 3.2 Discover Claude and Codex subscriptions: Codex yes, Claude no

**Codex.** Feasible and in line with how the AI SDK harness packages already
treat Codex logins. A runtime helper (`omp-credential.mjs`) prints the current
Codex access token, reusing the store logic in `quota-openai.mjs` (file or
Keychain, `CODEX_HOME`, `DIETER_CODEX_ACCOUNT_HOMES`). The managed `models.yml`
references it:

```yaml
providers:
  openai-codex:
    apiKey: "!'<runtime>/bin/node' '<runtime>/omp-credential.mjs' codex"
```

The exact `!command` quoting follows OMP's rules and is settled by E3. OMP
caches the token for the process and reruns the helper after a 401. Dieter
never writes the token anywhere, so there is no second grant and no rotation
race. When the access token has expired, Codex must refresh it. Phase 0
experiment E4 checks whether the bundled Codex app-server can be asked to
refresh (Codex then remains the only process that refreshes and writes). If it
can't, the fallback is OMP's own device-code login (`openai-codex-device`),
started from the Mac UI, with the grant kept in the managed `agent.db`.

**Residual policy risk (OpenAI).** OpenAI documents ChatGPT-plan access for
open-source partners through "Sign in with ChatGPT". OMP reuses the Codex CLI's
client ID. This is common practice and not explicitly prohibited, but it isn't
explicitly sanctioned either.

**Claude.** Not something Dieter can ship. Anthropic's [Claude Code legal and
compliance page](https://code.claude.com/docs/en/legal-and-compliance), under
"Authentication and credential use":

> Anthropic does not permit third-party developers to offer Claude.ai login
> into their own applications, or to route requests through Free, Pro, or Max
> plan credentials on behalf of their users. Moreover, developers may not
> collect, store, or intermediate Claude.ai credentials or session tokens.

A helper that reads the Claude Code Keychain item and hands the token to OMP is
exactly "intermediating" a Claude.ai credential. OMP's Anthropic provider also
sends Claude Code's user agent, beta flags and billing fingerprint. The same
page explicitly allows "an end user signing in to the unmodified Claude Code
binary with their own Claude subscription", which is how Dieter's Claude Code
harness works today. So:

- Claude models in OMP come from an **Anthropic API key**. They are billed
  per token.
- Dieter shows the detected Claude Code login in the accounts list as
  "available to the Claude Code harness" and does not offer it to OMP.
- Dieter does not offer OMP's `anthropic` OAuth login in its UI.
- Opus **on the subscription** as an advisor is Phase 4: a cross-harness
  advisor run by the unmodified Claude Code binary (§4.6).

### 3.3 Expose the models: feasible

- Replace the three-selector filter with discovery from the managed home.
  `omp models --json` already lists only providers with usable credentials.
- Add `group` (provider label such as "Codex", "Anthropic API", "OpenRouter")
  to `HarnessModel` so pickers can section a longer list. This is the one proto
  field the catalog needs.
- A per-machine **visible models** list, defaulting to a curated set from
  the shipped base config, becomes OMP's `enabledModels`. That makes every
  visible model selectable through the ACP `model` option.

**Suspected existing defect.** `--model` and `--thinking` are launch
arguments, and launch arguments are part of the ACP implementation identity
(`@ai-sdk/harness-acp` `createImplementationIdentity`). The catalog declares
OMP `model-selection: between-turns`, but a model change makes resume fail with
"ACP lifecycle state is incompatible with the configured implementation."
`turn_selection_test.go` only checks re-selecting the same model. E1 confirms
this. The fix is the same change this proposal needs anyway: drop `--model`
and `--thinking` from the launch, select both through ACP session config
options, and declare `effort-selection: between-turns`.

### 3.4 Opus as advisor, another model as implementer: feasible with OMP's own advisor

- **Implementer** is the conversation model, chosen in the existing picker.
- **Advisor** becomes `advisor_model`, a `type: enum` provider option that
  replaces the boolean `advisor`. Its choices are `off` plus the discovered
  models, and it is `mutable: true`. The catalog needs one feature: an option
  whose choices are filled from discovery (`choicesFrom: models`, merged in
  `discovery.go` `mergeDiscoveredAdapter`). Clients already render enum options
  as pickers, so Android and iOS pick it up without UI work. Mac promotes it to
  a composer chip, like fast mode.
- Optional `advisor_review` enum (`turn` or `agent-end`) and, in Phase 3,
  `subagent_model` (written to `modelRoles.task`), so that "Opus plans, GPT
  implements in subagents" is also possible.
- These per-turn values are written to a **per-conversation overlay** at a
  path that never changes (`<runtimeRoot>/harness-config/omp-<conversation>.yml`).
  Adding that one path changes the identity once. Changing the file's content
  doesn't, so changing the advisor between turns doesn't break resume. E6
  checks that each turn's OMP process rereads it.
- "Opus" here means an Anthropic API key or another provider with Opus
  access (such as OpenRouter). With only a Codex subscription, the advisor
  choices are the Codex models.
- Advisor notes appear in the Dieter transcript. The capabilities hook already
  records OMP events (E5 finds the advisor's event or result); otherwise Dieter
  parses the injected `<advisory>` blocks. They are shown as a new capability,
  `advisor`, at level `notes`.
- Cost: by default an advisor reviews every turn, adding a second model's
  usage to each one. The picker says so, and machine settings set the default
  to `agent-end`.

### 3.5 Crawlers and web tools: feasible, with one gap

- `web_search` works without keys and uses the implementer's hosted search
  where available. Per-machine settings control the provider order and
  optional keys (Exa, Brave, Tavily, Perplexity, Jina, Kagi, Parallel,
  Firecrawl, SearXNG endpoint).
- Reading a page (`read` on a URL, with scrapers) is on by default.
- **Browser**: off by default, because puppeteer-core downloads Chromium at
  run time, against the pinned-runtime rule. When enabled it uses the
  machine's installed Chrome (E8 confirms the setting key).
- **Crawling**: OMP has none. Ship a `web-crawl` skill that crawls a site
  with explicit page and depth limits using `web_search` and `read`. With a
  Firecrawl key, the skill uses Firecrawl's crawl endpoint instead.
- Keys are passed to the OMP worker as environment variables only when they
  are configured. Phase 1 reads them from the daemon environment
  (`DIETER_HOME/.env`). Phase 3 reads them from vault items (§4.5).

### 3.6 Skills and MCP shipped from the repo: feasible, with two constraints

Assets live under `internal/harness/runtime/omp/` and are therefore part of the
content-addressed runtime and its release archive:

```
internal/harness/runtime/omp/
  base-config.yml        # managed defaults (roles, web, telemetry off, foreign user sources off)
  WATCHDOG.md            # advisor guidance tuned for Dieter cards
  agents/                # e.g. reviewer.md, implementer.md with model roles
  skills/
    dieter-cli/          # generated copy of .agents/skills/dieter-cli (drift-checked by `just generate`)
    web-crawl/
  mcp-servers.yml        # catalog of shippable MCP servers, all disabled unless noted
```

- **Skills** reach OMP through `skills.customDirectories` (the absolute runtime
  path). Do **not** use `HarnessAgent({ skills })`: the ACP adapter writes those
  into `<cwd>/.agents/skills`, which would put Dieter files into project
  repositories. Skills in the project itself (`.agents/skills`, `.claude/skills`)
  keep loading. That is how a user's repository configures its agents.
- **MCP** servers reach OMP only through ACP `mcpServers`. The runner passes the
  enabled servers to `HarnessAgent({ mcpServers })`, next to Dieter's own tool
  server. Constraints:
  1. stdio servers must come from the runtime's `package-lock.json`. No
     `npx -y` at run time.
  2. One failing server fails the whole session. The runner preflights stdio
     servers, drops a failing one and records a turn warning (E7).
  3. Remote (http) servers send data to third parties, so they are opt-in.
- A project's own `.mcp.json` / `.omp/mcp.json` is passed through only when the
  machine setting "Load project MCP servers" is on (off by default).
- Machine-level foreign user sources stay off for determinism
  (`~/.claude/skills`, `~/.codex/AGENTS.md`, …). Do not forward
  `CLAUDE_CONFIG_DIR` to OMP: when set, it silently turns those sources back on.

### 3.7 Configurable from the Mac UI: feasible, mostly new surface

There is no per-machine harness configuration anywhere today. It needs a
typed settings API with CLI parity, Kotlin core rules and a Mac page (§4.4,
§4.5).

## 4. Design

### 4.1 Managed home and config layers

```
DIETER_HOME/omp/agent/           PI_CODING_AGENT_DIR for every Dieter OMP process (machine-local, never replicated)
  config.yml                     rendered by the runner: base-config.yml + machine settings
  models.yml                     credential references only (`!command` helpers); no secrets
  WATCHDOG.md, agents/           synced from the runtime assets
  agent.db, sessions/, …         owned by OMP
DIETER_HOME/harness/omp.yaml     Dieter's typed machine settings (atomic write under the central lock)
```

| OMP layer           | Content                                                                                            | Changes         |
| ------------------- | -------------------------------------------------------------------------------------------------- | --------------- |
| Global `config.yml` | Shipped base and machine settings: visible models, web, skills, foreign sources off, telemetry off | Settings edits  |
| Project             | The user's repository (`.omp/config.yml`, `.claude/settings.json`), unchanged                      | Repo            |
| Overlay 1 (exists)  | Dieter enforcement: stream timeouts, async and auto-background off                                 | Runtime release |
| Overlay 2 (new)     | The conversation's roles: `advisor.*`, `modelRoles.advisor`, `modelRoles.task`                     | Every turn      |

Overlays beat project config, so a repository can't turn Dieter's enforcement
back off. The runner (`runner.mjs`) renders both files before each launch; Go
stores and validates the settings and sends them in the request.

Telemetry and background calls are off in the base: `dev.autoqa: false`,
`startup.checkUpdate: false`, `marketplace.autoUpdate: off`, Dieter-owned
titles. E9 measures what still leaves the machine (for example the catalog
refresh).

### 4.2 Launch

```
omp acp --config <overlay-1> --config <overlay-2> --hook <hook>
```

Model and thinking are set through ACP `session/set_config_option` (via the
adapter's model mapping) on every turn. Launch arguments are then the same for
the whole conversation, so the ACP identity no longer changes when the user
switches model, thinking or advisor. Bump the pin to 18.12.4 in the same change
(MCP progress and cancel fixes, plugin lockfile 0600, and a reported fix for
debug dumps that wrote credentials to disk).

### 4.3 Accounts and discovery

A new runtime probe reports per machine:

- Codex logins (all `DIETER_CODEX_ACCOUNT_HOMES`): email, plan, and whether a
  token is usable now.
- The Claude Code login (identity only).
- Which API-key providers are configured.

It reuses `quota-openai.mjs` and `quota-claude.mjs`. `omp-discovery.mjs` then
runs `omp models --json` against the managed home. E10 checks whether
discovery runs the `!command` helpers and therefore needs credential access.

### 4.4 Settings API (CLI parity)

The settings are per machine: credentials, Chrome and MCP binaries differ per
host. Account-wide defaults through KV can come later.

- `settings.proto`, `SettingsService`:
  - `GetHarnessProfile` / `UpdateHarnessProfile` (harness id plus a typed
    `OMPProfile` message: visible models, default advisor and review mode,
    subagent model, web options, skill toggles, MCP servers, credential sources)
  - `ListHarnessAccounts`
- `HarnessModel.group` and catalog `choicesFrom`.
- Go: a new `internal/store/harnessprofiles` package, the handlers in
  `internal/api/settings.go`, and the profile carried in `harness.Request`.
- CLI:
  - `dieter harness omp show|set`
  - `dieter harness omp mcp add|remove|enable|disable`
  - `dieter harness omp skills enable|disable`
  - `dieter harness accounts`

  All of them work with `--machine`. Each is mapped in `rpcCommand` and tested
  end to end over local, direct-TLS and relay routes (`-tags e2e`). Regenerate
  the CLI reference, and update the dieter-cli skill and
  `site/content/docs/harnesses.md`.

### 4.5 Secrets for web and MCP keys

- **Phase 1:** keys come from the daemon environment, with the names added to
  the OMP worker's allowlist only when configured.
- **Phase 3:** a settings entry maps an environment variable name to a vault
  item field. The daemon decrypts it at launch and puts it in the worker
  environment, and redacts it from transcripts (as `dieter vault exec` does).
  This is a new path from the vault into worker environments without a
  per-card opt-in, so it needs a threat-model entry. Decision D5.

### 4.6 Phase 4: Claude Code as a cross-harness advisor

For Opus on the user's own subscription:

- Dieter runs the advisor as a read-only Claude Code session (official binary,
  the user's login, plan permission mode) in the same working tree.
- It reviews at the implementer's turn end, or when the implementer calls a
  Dieter `consult_advisor` tool.
- Its notes go back to the implementer as a follow-up when they meet a
  severity threshold.
- This works for any implementer harness (OMP, Codex) and stays within
  Anthropic's terms for the unmodified binary. It is a Dieter engine feature,
  not an OMP one, and should get its own proposal once Phase 2 shows how
  advisor notes are used in practice.

### 4.7 Mac

**Settings › Agents › machine › Oh My Pi**, with these sections:

| Section  | Contents                                                                                                                     |
| -------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Accounts | Discovered Codex logins with a "Use in OMP" toggle; Anthropic and other API keys; the Claude Code login with its explanation |
| Models   | Visible models, default implementer, default advisor and cadence, subagent model                                             |
| Web      | Search on/off, provider order and keys, browser off or system Chrome                                                         |
| Skills   | Shipped skills, project skills on/off                                                                                        |
| MCP      | Shipped servers, custom servers, project servers on/off                                                                      |
| Status   | Runtime version, last discovery, warnings                                                                                    |

The rules live in the Kotlin core (`harness/OmpProfile.kt`, admin commands
and a slice). The page consumes client-contract rows only (API-boundary
check). The composer adds the Advisor chip and a model menu grouped by
provider.

## 5. Phases

### Phase 0: spike experiments (2–3 days)

Run these against a temporary `DIETER_HOME`, a free loopback port and the
fixture gateway, using disposable or read-only access to credentials:

| #   | Experiment                                                                                              | Pass                                                                           |
| --- | ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| E1  | Change an OMP conversation's model on turn 2 with today's launch                                        | Confirms or rules out the identity-mismatch defect (§3.3)                      |
| E2  | Switch model and thinking through ACP config options with managed `enabledModels`                       | Model applied; identity unchanged; resume works                                |
| E3  | `models.yml` `!command` helper for `openai-codex`; force a 401                                          | Turn succeeds; helper reruns; `~/.codex` unchanged                             |
| E4  | Ask the bundled Codex to refresh an expired token (app-server auth status or account read with refresh) | Codex refreshes and writes its own store; else adopt the device-login fallback |
| E5  | Overlay with `advisor.enabled` and an advisor on a different provider than the implementer              | Notes are produced; a hook event or result is found for the transcript         |
| E6  | Change overlay 2 between turns                                                                          | The next turn uses the new advisor without an identity change                  |
| E7  | Pass a pinned stdio MCP server and a failing one through `mcpServers`                                   | The working one is available; the failure is handled by preflight              |
| E8  | `skills.customDirectories` and browser executable settings                                              | Shipped skills listed; nothing written into the checkout; Chrome reused        |
| E9  | Egress audit of a managed turn with telemetry off                                                       | List of remaining hosts                                                        |
| E10 | `omp models --json` in the managed home with only the Codex helper                                      | Codex models listed; whether discovery runs the helper is known                |

Deliverable: this page updated with the results and the decisions in §6.

### Phase 1: managed home, Codex discovery, full catalog (4–6 days)

- Managed agent dir and rendered `config.yml`/`models.yml`. Stop forwarding
  `OMP_PROFILE`, `PI_CODING_AGENT_DIR` and `CLAUDE_CONFIG_DIR` to OMP.
- Credential helper, account probe, discovery without the fixed filter,
  `HarnessModel.group`.
- Model and thinking through ACP options; `effort-selection: between-turns`.
  Delete `ompVisibleModels`, the launch-candidate fallback for `--model`, and
  the boolean `advisor`.
- Bump to 18.12.4. Settings API with `visible models` and credential sources;
  CLI. Read-only Mac status section.
- Done when a fresh machine with only a Codex login sees the Codex models in
  OMP with no `omp login`, switches model and thinking mid-conversation, and
  `~/.omp` is untouched.

### Phase 2: advisor and implementer (3–4 days)

- `choicesFrom: models`; `advisor_model` and `advisor_review` options;
  overlay 2; advisor notes in the transcript.
- Mac composer chip and the Settings Models section; shared core rules.
- Done when a conversation with implementer `openai-codex/gpt-6-sol` and
  advisor `anthropic/claude-opus-…` (API key) shows advisor notes, the advisor
  is changed on turn 3 without a resume failure, and the same works from
  `dieter card send --provider-option advisor_model=…`.

### Phase 3: web, skills, MCP, secrets (5–7 days)

- Asset tree, shipped skills (with the generated `dieter-cli` copy), the
  `web-crawl` skill, web settings, the MCP catalog with preflight, custom
  servers, project-MCP passthrough, vault-backed keys and a `subagent_model`
  option.
- Mac Web, Skills and MCP sections. Docs and threat-model updates.
- Done when a pinned stdio MCP server and a custom http server both work in a
  turn; the shipped skills are listed by OMP; a crawl stays within its bounds;
  and no file appears in the checkout.

### Phase 4: Claude Code advisor across harnesses (5–8 days, separate proposal)

See §4.6. Depends on decision D1.

### Verification per phase

- Start with `just check-changed --dry-run`; run the selected checks once at
  the end.
- Runtime: `node --test` for the `.mjs` units.
- Go: `go test` for harness, engine, api and cli, plus `-tags e2e` for the new
  CLI routes.
- Clients: `just kotlin :core:runtime:jvmTest`, then `just framework` and
  `just mac test_unit`; check its summary line, not only the exit code.
- One `just e2e mac flows:<new settings flow>`.
- One real turn per phase against the operator's Codex login, from an isolated
  `DIETER_HOME`. Never against the running daemon or `Dieter.app`.

## 6. Decisions needed

| #   | Decision                                                  | Recommendation                                                                                                                              |
| --- | --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | Claude subscription and OMP                               | Don't connect them. Anthropic API key in OMP now; Claude Code cross-harness advisor (Phase 4) for subscription Opus.                        |
| D2  | Managed home vs the operator's `~/.omp`                   | Managed only (clean break, no import). Users who want their own OMP setup run `omp` themselves.                                             |
| D3  | Codex token source                                        | Borrow from Codex's store, with Codex doing the refresh (if E4 passes); otherwise a separate device login stored in the managed `agent.db`. |
| D4  | Settings scope                                            | Per machine now; account-wide defaults through KV later if needed.                                                                          |
| D5  | Vault items to worker environment without per-card opt-in | Allow for the keys the machine profile names, redacted from transcripts; record it in the threat model.                                     |
| D6  | Shipped MCP servers                                       | Ship the catalog with everything off. Candidates: a pinned Playwright MCP (local), Context7 and Exa (remote, opt-in).                       |
| D7  | Browser tool                                              | Off by default; system Chrome only. Never let OMP download Chromium.                                                                        |

## 7. Invariants and threat model

- **Storage.** Everything new lives under `DIETER_HOME`, and nothing is written
  into repositories. That rules out the ACP adapter's `skills` option (§3.6).
- **Credentials.** The threat-model asset row "Harness and provider credentials
  … in each tool's normal configuration" changes:
  - The managed OMP borrows Codex tokens read-only and stores none.
  - With the D3 fallback, OMP's own grant lives in `DIETER_HOME/omp/agent/agent.db`
    (user-only, never replicated).
  - Vault-backed keys enter worker environments (D5).

  Record this in an ADR when Phase 1 lands.

- **Gateway.** Unchanged. Settings, accounts and models travel over the
  existing end-to-end routes. Account rows reuse the credential-free shapes of
  the quota snapshots.
- **Pinning.** Assets and MCP servers are inside the runtime digest; the
  Chromium download is disabled (D7). Remote MCP and web engines are new,
  documented egress.
- **Unsandboxed.** Unchanged: OMP workers run as the daemon user. An advisor
  adds read-only review; it does not restrict anything.

## 8. Risks

- **Upstream churn.** OMP publishes a patch roughly daily and a major roughly
  monthly; config keys and ACP behaviour move. Mitigation: pin exactly; keep
  the rendered config small; cover E1–E10 as runtime tests so a pin bump fails
  loudly.
- **Provider enforcement.** Tokens borrowed from Codex may be restricted by
  OpenAI policy. Keep the device-login fallback ready. Claude is excluded by
  design.
- **Cost.** An advisor on every turn adds a second model's usage to each turn.
  Default to `agent-end` and show this in the UI.
- **Session failure on MCP errors.** Preflight, and drop failing servers with a
  visible warning.
- **Losing the operator's tuned `~/.omp`.** Intentional (D2). The release notes
  must say so and point to the new settings.
