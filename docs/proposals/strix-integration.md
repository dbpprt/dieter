# Proposal: Strix as a Dieter harness

Status: Phase 1 implemented, 2026-11-13 (see section 8) · scope: harness
catalog and runtime, daemon harness environment, engine and API rules, vault,
threat model; no client or protocol changes

## TL;DR

[Strix](https://github.com/usestrix/strix) (Apache-2.0, v1.7.1) is an
open-source autonomous pentesting agent. It runs a graph of LLM agents on the
host, gives them offensive tooling inside a Docker sandbox (Kali image with
Caido, a browser, nuclei and others), and writes validated findings, SARIF and a
report to a run directory.

The recommendation is to add **Strix as a harness**. A card picks the Strix
harness and a model, and its turn scans the card's checkout:

- **One turn = one headless Strix process.** The first message starts
  `strix -n --target <checkout> --instruction <message>`. Each follow-up message
  resumes the same run with `strix -n --resume <run> --instruction <message>`.
  Strix injects that instruction into the root agent's inbox. Cancel sends
  SIGINT. Strix stops in about 2 s, removes its container and stays resumable.
- **The transcript comes from the run directory, not from stdout.** Strix keeps
  its full live state on disk: `run.json`, `.state/agents.json`, the per-agent
  SQLite history in `.state/agents.db`, `.state/todos.json` and
  `vulnerabilities.json`. A projector tails these files and emits what the
  runner already sends:
  - AI SDK UI chunks for the root agent
  - `subagents` capability events for the agent graph
  - `task-plan` events from Strix todos
  - one collapsible card per finding

  No new part types are needed, so Android, iOS and macOS get it without client
  changes.

- **The spike ran the real engine end to end** with a scripted
  OpenAI-compatible model on this Mac. It used the pinned 1.7.1 binary, a
  wheel install, the real Docker sandbox, a child agent, a filed finding and
  `finish_scan`. It covered the start, resume, interrupt, resume-after-interrupt,
  budget-stop and two-concurrent-scan cases. All runs replay through the
  projector with the transcript invariants intact.
- **Three things must be handled for Strix specifically:**
  1. Strix writes `LLM_API_KEY` in plaintext into its config file on every run.
     Dieter therefore gives each turn a throwaway `--config` file and an
     isolated `HOME`.
  2. Exit codes are ambiguous. `run.json` `status` decides the outcome.
  3. The sandbox can reach the host's loopback services on macOS.

  Docker is a hard requirement. Dieter detects it but does not manage it.

Phase 1 (the harness) is about 2–3 weeks. Phase 2 (findings, report, fix
handoff) and Phase 3 (scheduled and diff-scoped scans) build on it.

## 1. What Strix is (verified in source, 2026-11-13, `928b1ca`)

| Aspect       | Facts                                                                                                                                                                                                                                                                                          |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Engine       | Python 3.12+, `openai-agents` + LiteLLM. Root agent plus child agents (`create_agent`, `wait_for_agents`, `agent_finish`, `finish_scan`); 48 tools per agent in the spike run.                                                                                                                 |
| Sandbox      | Docker only (`STRIX_RUNTIME_BACKEND=docker` is the only backend). Image `ghcr.io/usestrix/strix-sandbox:1.4.1`, linux/amd64 and linux/arm64, 1.45 GB compressed. Caps `NET_ADMIN`, `NET_RAW`, plus `host.docker.internal:host-gateway`. A local target directory is bind-mounted **writable**. |
| Models       | Any LiteLLM model id (`STRIX_LLM`, `LLM_API_KEY`, `LLM_API_BASE`, `STRIX_API_TYPE`, `STRIX_REASONING_EFFORT`). Optional ChatGPT-subscription login (`strix auth login chatgpt`) that reuses Codex's OAuth client; upstream calls it "not officially supported by OpenAI".                      |
| Model access | Upstream's own list marks Claude Opus 5.5 as needing Anthropic's Cyber Verification Program, GPT-6.1 Sol OpenAI's Daybreak and Gemini 4 Argon Google's Fairwind. Its recommended default is Z.ai GLM-5.3 via OpenRouter or Vercel AI Gateway.                                                  |
| Interfaces   | Interactive TUI (Go Bubble Tea sidecar over a private framed protocol v3), headless `-n`, `strix view` (local web viewer reading the run dir), `strix cloud` (managed SaaS).                                                                                                                   |
| Artifacts    | `strix_runs/<run>/` under the **current directory**: `run.json`, `.state/{agents.json,agents.db,todos.json}`, `vulnerabilities.json`, `vulnerabilities/<id>.md`, `vulnerabilities.csv`, `findings.sarif`, `coverage.json`, `penetration_test_report.md`, `strix.log`.                          |
| Releases     | GitHub release per version with PyInstaller archives (`macos-arm64` 92.5 MB, `linux-x86_64` 115 MB, `linux-arm64` 113 MB) and platform wheels. **No checksum file or signature.** PyPI lags: it has 1.7.0; 1.7.1 exists only on GitHub.                                                        |
| Defaults     | Telemetry on (PostHog, Scarf) unless `STRIX_TELEMETRY=0`; update check unless `STRIX_NO_UPDATE_CHECK=1` or a CI variable is set.                                                                                                                                                               |

## 2. Options

| Option                                                                                                                        | Verdict                                                                                                                                                                                                                                                                   |
| ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **A. Strix harness** (adapter `strix`, headless process per turn, run-dir projection)                                         | **Recommended.** It fits "every card is one durable harness conversation". It reuses subagent, task-plan and tool rendering, card lanes, the scheduler, channels and labels, and needs no client or protocol work.                                                        |
| B. Skills only (`npx skills add usestrix/strix` in a project; a Claude or Codex card runs `strix -n` as a background process) | Already works today with no Dieter change. The coding agent orchestrates, the transcript shows one opaque long process, and findings are not surfaced. Document it as the zero-cost path.                                                                                 |
| C. Drive the interactive TUI protocol (Dieter impersonates `strix-tui` over `STRIX_TUI_FD`)                                   | Rejected. The protocol is private and versioned (v3), and it checks exact capability lists, so every Strix release could break Dieter. The richer interactivity it would give (messages to a running agent, budget pause) is not needed for v1; resume covers follow-ups. |
| D. `strix cloud` (managed SaaS)                                                                                               | Out of scope. It uploads source to a third party and bills credits. It can still be used from any card through the CLI.                                                                                                                                                   |

## 3. Spike results (2026-11-13, mini-home, Apple Silicon, macOS 27)

The setup used a Colima VM (vz, 4 CPU, 6 GiB, disk on `/Volumes/External`), Strix
1.7.1 and the scripted model `tools/spikes/strix/fake-llm.mjs`. The fake model is
schema-driven: it only calls tools the request offers. The target was a small
Node service with an intentional command injection and an IDOR. The raw
evidence is in `/Volumes/External/strix-spike/evidence/` and the run
directories in `/Volumes/External/strix-spike/state/s1…s8`.

| Check                                                     | Result                                                                                                                                                                                                                                                                                      |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Fresh scan, white-box (`s1`)                              | Exit 2, `status=completed`, 1 critical finding. The child agent spawned and finished. `exec_command` really ran in the container. The container was removed afterwards. Engine time 1.5 s; process total 24 s.                                                                              |
| Time to first projected event                             | PyInstaller binary: 9.5–11.5 s, and 21.6 s on the very first run. Wheel install: 3.5–8.0 s. The remainder is Python imports, the Docker checks and a model preflight. The binary's `--version` takes 5–7 s of wall time but only 1.3 s of CPU, because the onefile unpacks on every launch. |
| Follow-up message (`s1` turn 2, `--resume` + instruction) | The instruction reached the root as a high-priority user message, and the run ended `completed` again. The first projection replayed old items; fixed with a cursor (`prime()`). In production the cursor lives in harness session state.                                                   |
| Interrupt mid-run (`s3`, `s7`)                            | SIGINT led to exit in 1.5–2.1 s with **exit code 1**, `status=interrupted`, and the container removed. `agents.json` keeps children at `running`, so the projector finalizes them as `cancelled`.                                                                                           |
| Resume after interrupt (`s3`)                             | Coordinator restored, child respawned, instruction injected, `completed`. While the child was alive, `finish_scan` was refused ("Cannot finish scan while child agents are still active"): the upstream gate works.                                                                         |
| Budget stop (`s4`, `--max-budget 0.004`)                  | **Exit 0**, `status=stopped`, `scan_results=null`. The reason appears only in `strix.log`.                                                                                                                                                                                                  |
| Two concurrent scans (`s4` + `s5`)                        | Both worked, each in its own container.                                                                                                                                                                                                                                                     |
| Missing Docker                                            | Exit 1 after about 5 s with a boxed message; no run directory.                                                                                                                                                                                                                              |
| Unknown flag (`--run-name`)                               | argparse error with **exit 2**. Strix has no flag to name a fresh run; the name is generated (`target_6984`).                                                                                                                                                                               |
| Secret persistence                                        | Every run writes all `STRIX_*`/`LLM_*` env values, **including `LLM_API_KEY`**, to `$HOME/.strix/cli-config.json` (0600). With `--config <file>` they go only to that file, and the home stays clean (`s8`).                                                                                |
| Checkout hygiene                                          | The target repository was still clean after 8 scans; Strix's own artifacts stay in the cwd.                                                                                                                                                                                                 |
| Host reachability from the sandbox                        | From the sandbox image, `host.docker.internal` (192.168.5.2 on Colima) reaches services bound to the Mac's **127.0.0.1**. The fake model returned 200. The Dieter daemon on `:4242` returned 403, so the local API token is the barrier, not loopback binding.                              |
| Install sizes                                             | Binary 93.6 MB. Wheel: venv 290 MB plus a 316 MB uv cache, 7 s to install. The wheel install picked up Homebrew Python 3.13; production would pin a managed interpreter.                                                                                                                    |
| Projection replay (`replay.mjs` over s1–s7)               | All pass: chunks start with `start` and end with `finish`, tool call IDs are unique, every tool call of a completed run has an output, subagents end in a terminal state, and there is one card per finding.                                                                                |

Exit codes therefore carry no reliable meaning on their own:

| Exit | Can mean                                           |
| ---- | -------------------------------------------------- |
| 0    | clean scan, **or** budget stop (`stopped`)         |
| 1    | fatal error, **or** user interrupt (`interrupted`) |
| 2    | findings, **or** an argparse usage error           |

The adapter reads `run.json` `status` (`completed`, `stopped`, `interrupted`,
`failed`). It falls back to the exit code only when no run directory exists.

## 4. Design

### 4.1 Catalog

Add an embedded `strix` harness to `internal/harness/catalog/harnesses.yaml`
(the catalog already supports `boolean`, `enum` and `string` options):

- `adapter: strix`
- capabilities: `model-selection: between-turns`,
  `effort-selection: between-turns` (`STRIX_REASONING_EFFORT`),
  `subagents: progress`, `task-plan: snapshots`
- models: LiteLLM ids with a small default list (upstream's recommendations
  that need no special access, plus the user's own entries through
  `harnesses.yaml`). There is no live discovery.
- options:
  - `scan_mode`: enum `quick`, `standard`, `deep`; default `quick`
  - `max_budget_usd`: string, required, default `10`. An unbounded scan is
    never the default.
  - `targets`: string, extra live targets (URLs, domains or an API spec path)
    in addition to the checkout
  - `scope_mode`: enum `auto`, `diff`, `full`. `diff` passes `--diff-base` from
    the project's Git base.
  - `fail_on`: kept for scheduled gates (Phase 3)

### 4.2 Install and pinning

Recommendation for v1: **the upstream PyInstaller archive per platform, pinned
by SHA-256 in Dieter's source.** Upstream publishes no checksums, so Dieter
computes them when it bumps the version, as it does for `HarnessRuntimeSHA256`.
The daemon downloads the archive on the first Strix turn into
`DIETER_HOME/runtime/tools/strix/<version>/`, verifies it and extracts it.
Archives exist for exactly Dieter's platforms: darwin-arm64, linux-amd64 and
linux-arm64. The macOS binary is only ad-hoc signed; files Dieter downloads
carry no quarantine attribute.

Alternative: the platform wheel from the GitHub release (not PyPI, which lags),
installed with a managed `uv` and a pinned interpreter. Startup is about 3–6 s
faster and Python is upgradable, but it costs about 600 MB, adds a second
toolchain to manage, and Python packaging has more failure modes. Revisit it if
startup latency matters; it does not for scans that run minutes to hours.

Pin the sandbox image by digest (`STRIX_IMAGE=ghcr.io/usestrix/strix-sandbox@sha256:…`,
index digest `c8e70302…` for 1.4.1). Strix pulls it itself when it is missing,
behind a console spinner nobody sees, so the first turn looks idle for about
100 s. Phase 1 posts a transcript note when Strix starts the pull
(`provider-status` only means "reconnecting" to the clients); a pre-pull with
progress is a follow-up.

### 4.3 Runtime adapter

Add `internal/harness/runtime/strix-runtime.mjs`. `runner.mjs` dispatches to it
before creating a `HarnessAgent`, the same way it dispatches the `mock` harness.
It reuses `send`, the heartbeat, the capability collector and the signal
handlers:

- **Working directory and run directory.** The cwd is
  `DIETER_HOME/runtime/strix/<sessionId>`, so `strix_runs/` never lands in the
  checkout, and every session has at most one run.
- **Environment.**
  - `HOME=<state>/home` and `--config <state>/turn-<n>.json`. The config file is
    created 0600 before the run and deleted at turn end, even on crash
    recovery.
  - `STRIX_TELEMETRY=0`, `STRIX_NO_UPDATE_CHECK=1`.
  - The model variables.
  - `DOCKER_HOST` resolved by the daemon (see 4.5), plus `DOCKER_CONFIG` from
    the real home so Docker context resolution survives the isolated `HOME`.
- **Arguments.**
  - First turn: `-n --target <checkout> [--target <t>…] --scan-mode … --max-budget … --instruction <prompt>`.
  - Later turns: `-n --resume <runName> --instruction <prompt> --max-budget …`.

  A turn's prompt is passed as `--instruction-file` when it exceeds a safe argv
  size.

- **Projection.** This is `tools/spikes/strix/projector.mjs` hardened:
  - Poll every 500 ms with `node:sqlite` read-only and `busy_timeout` (Node 22+
    is already required).
  - Root items become text and dynamic tool parts.
  - Child activity becomes `recentOutput` on subagent events.
  - Todos become the task plan.
  - Findings become `strix_finding` tool cards.
  - At the end, a summary text: the executive summary, findings by severity,
    the report path, and the cost.
- **Session state.** Send `{type:"session", state:{runName, lastRowId}}`, and
  read it back from `request.session` on the next turn. This replaces the
  spike's file-based `prime()`. It relies on the runtime lease, which allows
  one active turn per conversation.
- **Signals.**
  - A user cancel needs no forwarding: Strix stays in the worker's process
    group, so the daemon's SIGINT to the group reaches it directly. Strix stops
    and removes its sandbox (about 130 ms through the daemon); the daemon's
    9-second wait and SIGKILL of the group remain the backstop. Removing
    containers a killed Strix leaves behind (label `strix-run-id`) is a
    follow-up.
  - SIGUSR1 (daemon restart suspend) also stops Strix with SIGINT. The
    continuation becomes a resume turn with no new instruction, so a restart
    costs about 10 s and no completed work.
- **Steering.** Off. Headless Strix has no steer channel, and agent-channel
  wakes must not start scans (see 4.6).
- **Usage.** Read from `run.json` `llm_usage`: tokens and `cost`, attributed per
  agent.

### 4.4 Credentials

- **API keys come from the vault.** A per-machine Strix setting names a vault
  item. At turn start the daemon reads the item's secret field, as
  `dieter vault exec` does, and puts it into `Run.Environment` only, never into
  argv or the stdin request. API keys are the user's own; vault replication
  stays end-to-end encrypted and never reaches the gateway.
- **No subscription bridging.** Dieter does not wire Claude.ai or Codex logins
  into Strix:
  - Anthropic's terms forbid intermediating Claude.ai credentials.
  - Upstream's ChatGPT mode reuses Codex's OAuth client and is unsupported by
    OpenAI.
  - Copying refresh tokens causes rotation races
    (see the provider-accounts spike, card `c_3f06225f6b34887657459f28`).

  An operator who wants ChatGPT mode can run `strix auth login chatgpt`
  themselves. It writes into Strix's managed home, which Phase 1 would have to
  keep persistent; this is an open question below.

- **Grey-box credentials for targets.** Credentials for the systems under test
  (logins, TOTP) are a separate concern. They end up in Strix's instruction,
  `run.json` and the model context by design. Phase 2 can let a card reference
  a vault item and pass it as a `--workspace-file` instead of instruction text.

### 4.5 Docker detection

Not in Phase 1: harnesses have no availability field (adding one needs a
`settings.proto` field and client work). A missing Docker fails the turn within
about 5 s with Strix's own message ("Cannot connect to Docker at …"). The
intended follow-up: discovery marks the harness available only when all of
these hold:

- the Strix tool is installed or installable
- a Docker endpoint answers: `DOCKER_HOST`, otherwise the current Docker
  context resolved from the operator's `~/.docker`, otherwise the default
  socket
- the endpoint's architecture matches an image platform

Unavailability is shown with its reason, for example "Docker isn't running
(checked colima-default context)". Dieter never starts or installs Docker.

### 4.6 Safety and scope

Strix attacks what it is given, so:

- **Targets are conversation options.** People and coding agents can configure
  `targets` with `dieter card create --provider strix --provider-option targets=…`.
  Agent turns may start scans and send follow-ups; direct channel wakes can
  start idle scans within the existing wake budget. The original human-only
  proposal is superseded by [automatic Strix launches](automatic-strix-launch.md).
  Headless Strix still has no live steering interface.
- **Worktree workspaces only.** The checkout is bind-mounted writable, and
  Strix agents can patch files (`apply_patch`, auto-fix). The shared-checkout
  mode is refused for this harness.
- **The budget is mandatory.** A turn without `--max-budget` is rejected.
- **Threat model addition.** On macOS the sandbox reaches host loopback
  services through `host.docker.internal`, and that includes the Dieter daemon
  (`:4242` answered 403). The local API token and the device-key TLS stay the
  barrier. The token file lives under `DIETER_HOME`, which is never mounted;
  only the card's worktree is. Document that LLM-driven offensive tooling runs
  next to the daemon, and ask upstream for a way to drop `host-gateway` when
  the target is a checkout only.

### 4.7 Invariants

| Invariant                                          | Effect                                                                                                                                                                                         |
| -------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Harness workers run unsandboxed as the daemon user | Kept. Strix's own Docker sandbox is extra isolation for its tools, not a Dieter sandbox.                                                                                                       |
| Data under `DIETER_HOME`, none in repositories     | Kept. The run directory, the Strix home and the per-turn config live under `DIETER_HOME/runtime/strix`. Edits the Strix agents make to the checkout are agent work, like those of any harness. |
| One active turn per conversation                   | Required. The projection cursor and resume assume it.                                                                                                                                          |
| Gateway stores no project data or credentials      | Kept. Nothing new reaches the gateway, and model keys travel inside the E2E vault.                                                                                                             |
| CLI parity                                         | No new RPC in Phase 1: harness and option selection already go through existing card and conversation calls. A Phase 2 findings RPC would follow the AGENTS.md parity checklist.               |

## 5. Plan

| Phase                         | Scope                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | Estimate  |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- |
| 0. Spike                      | Done (this document, `tools/spikes/strix`).                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | –         |
| 1. Harness                    | Catalog entry and options. Pinned binary install with SHA-256. Image digest pin and pre-pull status. `strix-runtime.mjs` (projection, session cursor, signals, per-turn config cleanup). Daemon env (`DOCKER_HOST`, `DOCKER_CONFIG`, model vars) and the vault-item setting. Docker discovery. The worktree-only rule and budgeted direct wakes (superseding the original no-wake proposal). Runtime unit tests on recorded run directories (`replay.mjs` turned into `node --test`). A Linux `-tags e2e` daemon test with `fake-llm.mjs` and real Docker. Threat model and user docs. | 2–3 weeks |
| 2. Findings                   | Present `penetration_test_report.md` and finding files in the workspace pane at turn end. Add "Fix with…", which creates one card per finding (or one per severity band) on a coding harness, with the finding Markdown as the prompt and the Strix card linked. Export SARIF. Pass grey-box credentials from a vault item as a workspace file. A first-class finding part (Kotlin core plus three clients) only if tool cards prove insufficient.                                                                                                                                     | 1–2 weeks |
| 3. Recurring and review scans | Scheduled Strix cards through the existing scheduler (nightly `quick` with a budget). Diff-scoped scans of a card's branch (`--scope-mode diff --diff-base <project base>`) as an optional Review-lane check with `--fail-on high`.                                                                                                                                                                                                                                                                                                                                                    | 1 week    |

Upstream requests (small and generally useful):

- a `stop_reason` field in `run.json` for budget and turn-limit stops
- a way to skip `persist_current()` in headless runs
- a `--run-name` for fresh runs
- distinct exit codes for interrupts and usage errors
- an option to drop `host-gateway`
- published checksums for release assets

## 6. Decisions (2026-11-13)

1. **Build the harness** (Option A), not only documented skills.
2. **Packaging:** the upstream single-file PyInstaller executable, pinned by
   SHA-256 per platform.
3. **Credentials:** API keys from a vault item only; no ChatGPT-subscription
   bridging.
4. **Default models:** upstream's recommendations that need no provider
   security program, plus **From the vault item** (`STRIX_LLM` in the notes) for
   self-hosted endpoints.
5. **Live verification** on the self-hosted GLM-5.3 Flash endpoint on gx10
   (section 8).

## 7. Reproducing the spike

See `tools/spikes/strix/README.md`. In short: start a Docker engine, pull the
sandbox image, run `fake-llm.mjs`, then `worker.mjs` per turn, then
`replay.mjs` over the state directories.

## 8. Phase 1 implementation

| Piece              | Where                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Catalog            | `strix` in `internal/harness/catalog/harnesses.yaml`: adapter `strix`, options `scan_mode`, `scope` and `targets` (fixed by the first message: a resumed run keeps them, and Strix ignores `--scan-mode deep` on resume) plus `max_budget_usd` and `credentials` (per turn); no model discovery (`discoverable` in `discovery.go`). Attachments become `--workspace-file`s; the operator's `~/.strix/mcp-servers.json` is passed as `--mcp-config`. |
| Pinned executable  | `internal/harness/strix.go`: Strix 1.7.1 per platform (darwin-arm64, linux-amd64, linux-arm64), SHA-256-verified download through `downloadPinned` (shared with the runtime archive), atomic install under `DIETER_HOME/runtime/tools/strix/1.7.1`, version probe.                                                                                                                                                                                  |
| Worker environment | `strixHarnessEnvironment`: the allowlisted harness environment plus Docker client settings and `DIETER_STRIX_BIN`.                                                                                                                                                                                                                                                                                                                                  |
| Runtime adapter    | `internal/harness/runtime/strix-runtime.mjs`, dispatched from `runner.mjs` before any AI SDK import: per-turn config and instruction files, Strix environment allowlist, run-directory projection, session cursor, cancel and suspend handling, report summary.                                                                                                                                                                                     |
| Engine rules       | `internal/engine/strix.go`: worktree only (creation and admission), credentials from the vault item (audited, redacted), the submitted instruction as the prompt, no live steering or coding-agent channel digest, budgeted direct channel wakes.                                                                                                                                                                                                   |
| API rule           | Local agent caller tokens are validated independently of the selected provider (`validateTurnCaller`, `internal/api/vault.go`). Agents may create, start and continue scans.                                                                                                                                                                                                                                                                        |
| Tests              | `strix-runtime.test.mjs` (projection, resume cursor, arguments, environment, completed/failed/interrupted/suspended turns with a fake Strix), `strix_test.go` (install, rejection cases, a worker turn through `runner.mjs`), `internal/api/strix_test.go`, `TestChannelWakeStartsStrixAfterCredentialsAreReady`.                                                                                                                                   |
| Docs               | User guide (`site/content/docs/harnesses.md#strix`), threat model, environment reference, CLI skill, changelog.                                                                                                                                                                                                                                                                                                                                     |

**Live runs on GLM-5.3 Flash (gx10, tailnet endpoint), 2026-11-13.**

- Spike worker, fixture service, `quick`, nominal prices
  ($0.5/$2 per million tokens) with a $3 budget: `completed` in 11 min 21 s, 82
  model requests (root 15, one validator agent 67), 5.83 M input and 12.5 k
  output tokens. One HIGH finding, the `/ping` OS command injection, validated
  with a working PoC (`;id>/tmp/pwned_ci`) and a write-up with evidence,
  impact and counterevidence. The IDOR was examined but not filed before the
  budget wrap-up. The checkout was unchanged.
- Through an isolated working-tree daemon (temporary `DIETER_HOME`, loopback
  only): the CLI refused a project-mode Strix card; a worktree card with the
  vault item `strix` (gx10 key, URL, `STRIX_LLM` and prices in its notes)
  installed the pinned executable on its first turn and ran the scan; see the
  card's transcript in `/Volumes/External/strix-spike/e2e`.

**Follow-ups (Phase 2+):** present the report and finding files in the
workspace pane (they live under `DIETER_HOME`, outside the worktree, so the
presentation path rule needs a Strix exception or a copy); "Fix with…" cards per
finding; SARIF export; grey-box target credentials from a vault item as a
workspace file; an availability field for harnesses so a missing Docker shows
before a turn; scheduled and diff-scoped scans; the upstream requests in
section 5.
