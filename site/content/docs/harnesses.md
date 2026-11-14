---
title: "Agents & models"
linkTitle: "Agents & models"
description: "Use your existing local agent configuration and the capabilities of the selected host."
group: "Reference"
weight: 42
slug: "harnesses"
---

Dieter integrates six harnesses through a pinned JavaScript runtime. The coding
agents use their normal local configuration on the **execution machine**.

| Harness                | Default configuration                        |
| ---------------------- | -------------------------------------------- |
| Codex                  | `~/.codex` or `CODEX_HOME`                   |
| Claude Code            | `~/.claude` or `CLAUDE_CONFIG_DIR`           |
| Pi                     | `~/.pi/agent` or `PI_AGENT_DIR`              |
| Oh My Pi               | `~/.omp/agent`, with `OMP_PROFILE` when set  |
| DeepSeek Harness (DSH) | `~/.dsh` or `DSH_HOME`                       |
| Strix                  | a vault item and Docker; see [Strix](#strix) |

Authenticate or configure the provider on that machine first. Dieter does not
transfer provider credentials between hosts or store them on the gateway.

## Inspect the actual catalog

```sh
dieter harness list --format jsonl
dieter --machine MACHINE_ID harness list --format jsonl
```

The catalog is loaded from the selected execution owner. OMP is intentionally
curated to the exact Codex-authenticated GPT-6 Luna, Sol, and Astra
selectors. Discovery uses the pinned OMP build used for new
turns, so a separate global `omp` upgrade cannot add stale or unrelated choices.
Dieter passes the chosen selector when it launches OMP because OMP's ACP model
option intentionally contains only the user's smaller cycling list. Other
harness catalogs remain machine-local. Codex models follow the installed CLI's
live catalog; when discovery is unavailable, a bundled fallback list applies.
DSH models are discovered from its standard ACP session options. A successful
prior catalog is retained through transient refresh failures.

The embedded registry is
[`internal/harness/catalog/harnesses.yaml`](https://github.com/dbpprt/dieter/blob/main/internal/harness/catalog/harnesses.yaml).
It declares models, reasoning levels, capabilities, and typed provider options.
Override it with `$DIETER_HOME/harnesses.yaml`, `DIETER_HARNESS_CONFIG`, or the
`--harness-config` flag. The registry and discovered catalog are the authoritative
model list; this page does not freeze a second copy of it.

## Choose model and reasoning

A new conversation uses the selected model's `defaultEffort` when defined.
`--effort default` explicitly selects the provider's native default.

Codex, Claude Code, and Pi support model and effort changes between turns.
OMP and DSH support model changes; OMP thinking stays fixed after the first
message. Provider options appear only where the catalog advertises them.
Supported Codex models expose mutable **Fast mode** with
`--provider-option fast_mode=true`; it uses the provider's faster service tier
at a higher usage rate.

A queued follow-up retains its own model, effort, attachments, and options.
Changing that selection does not reconfigure the already-running turn.

## Runtime lifecycle

The first catalog refresh or turn installs Dieter's harness runtime under
`DIETER_HOME`. It contains the Claude Agent SDK with its Claude Code executable,
Codex and OMP at the versions locked in Dieter's `package-lock.json`, which are
their latest releases when Dieter is built. Each agent's bridge links its
packages from that runtime on first use and checks that the CLI reports the
locked version, so Claude Code, Codex and OMP never install anything from npm and
hosts need no global installation of them. Pi runs inside the runtime itself.
Dieter also installs the pinned Bun executable required by OMP once per daemon
home and shares it across content-addressed harness releases. Published daemons
take the runtime and Bun from a prebuilt archive of their own release, verified
against the SHA-256 built into the binary; daemons built from source install them
with npm. Updating a separately installed global agent CLI does not change the
version Dieter runs or its advertised OMP catalog.
Managed daemon updates prepare the new content-addressed runtime first; a turn
already in flight remains pinned to its digest across recovery, and the next turn
uses the current runtime.

DSH is installed lazily from npm through the ACP bootstrap at its tested version,
so DSH hosts need npm; a global `dsh` installation is not required. Its bootstrap
revalidates npm package metadata, so a cached package list cannot hide a newly
published pinned dependency. Use `dieter harness list` for the current provider
configuration and `dieter doctor` for host diagnostics.

## Strix

[Strix](https://github.com/usestrix/strix) is an open-source autonomous
pentesting agent. A Strix conversation scans its card's worktree, plus any
targets you add, with a team of agents that use offensive tooling in a Docker
sandbox and validate each finding with a proof of concept. Only test systems
you own or are authorized to test.

**Requirements on the execution machine**

- A running Docker engine (Docker Desktop, OrbStack or Colima on macOS). Dieter
  uses `DOCKER_HOST`, otherwise the current Docker context. The first scan pulls
  the ~1.5 GB sandbox image.
- A vault item with the model credentials, named `strix` unless you set the
  **Credentials** option. Its password is the model API key, its first URL is an
  optional OpenAI-compatible API base, and `KEY=VALUE` lines in its notes may set
  `STRIX_LLM` (the model, as a [LiteLLM](https://docs.litellm.ai/docs/providers)
  id), `STRIX_API_TYPE`, `LLM_EXTRA_HEADERS`, `LLM_EXTRA_BODY`, the
  `STRIX_LLM_*_COST_PER_MTOK` prices, and keys for Strix's web search
  (`PERPLEXITY_API_KEY` or `EXA_API_KEY`, with `STRIX_WEB_SEARCH_PROVIDER`) and
  Postman targets (`POSTMAN_API_KEY`). The keys reach only the Strix process.
- A worktree workspace: Strix's agents can edit the files they test.

```sh
printf '%s' "$API_KEY" | dieter vault add --name strix --password-file -
dieter card create --project PROJECT --board BOARD --workspace worktree \
  --provider strix --model openrouter/z-ai/glm-5.3 \
  --provider-option max_budget_usd=5 --title "Security review" \
  --prompt "White-box review; focus on injection and access control" --lane running
```

The **From the vault item** model uses the item's `STRIX_LLM`, which suits a
self-hosted OpenAI-compatible endpoint (`STRIX_LLM=openai/MODEL` with the
endpoint as the item's URL and `STRIX_API_TYPE=chat_completions`).

**Options** (shown in every app's agent settings; `--provider-option` in the
CLI):

| Option           | Values                                        | Changes after the first message |
| ---------------- | --------------------------------------------- | ------------------------------- |
| `scan_mode`      | `quick` (default), `standard`, `deep`         | no                              |
| `scope`          | `full` (default) or `changes`                 | no                              |
| `targets`        | extra URLs, domains or an OpenAPI file        | no                              |
| `max_budget_usd` | model spend at which Strix stops (default 10) | yes                             |
| `credentials`    | vault item name (default `strix`)             | yes                             |

A follow-up continues the same Strix run, which keeps its scan mode, scope and
targets; start a new card for a different scan. **Changes only** tests the
worktree branch's commits since it left its base branch (Strix's diff scope).
Model and reasoning can change between messages. Strix counts spend from
LiteLLM prices; for a free or unknown model, set prices in the item's notes so
the budget still bounds the scan.

Files attached to a message are placed in Strix's sandbox workspace and named
in that turn's instruction, for example an OpenAPI file or a wordlist. MCP
servers in the execution machine's `~/.strix/mcp-servers.json` are available to
the agents, as with the Strix CLI.

**How a scan appears.** The root agent's messages and tool calls form the
transcript, its helper agents appear as subagents, and its todo list is the
task plan. Each finding is a card with the full write-up. A completed scan ends
with Strix's penetration test report; all artifacts (report, SARIF, findings)
stay in the run directory named at the end, under `DIETER_HOME/runtime`.

**Follow-ups and stopping.** A new message continues the same Strix run with
that message as its instruction, for example to dig into a finding. Stopping
the turn interrupts Strix, which removes its sandbox; the next message resumes
the run. A budget stop is not a failure: send a message to continue past it.

**Safety rules.** Agents cannot start or message a Strix conversation, and agent
channel messages never wake or steer one: only a person starts a scan. Strix
runs with telemetry and update checks off. Its sandbox can reach services on the
execution machine through `host.docker.internal`, including ones bound to
localhost, so run it on a machine where that is acceptable. Dieter installs the
pinned Strix executable on first use, verified against the SHA-256 built into
Dieter.

## Background commands

Agents start long-running builds, tests and servers with Dieter's registered
process tools, which appear in the conversation's **Processes** tab. A process
finishing does not wake an idle conversation: an agent must collect required
build or test results before ending its turn, or verify that a persistent
server is ready. OMP's and Claude Code's own background execution is disabled,
because promised follow-ups would be lost when their provider session closes.

## Provider reconnects

A provider stream that drops mid-turn is retried by the harness, not failed.
While it retries, the Mac, iOS and Android working indicators show
**Reconnecting to provider (2/5)…** (or **(waiting for network)…**), and
`card poll`/`card watch` output carries a transient `providerStatus`. The daemon
clears it when the stream recovers or the turn ends. A turn fails only on the
provider's final error, which leads the failure text; worker diagnostics follow
it in the log.

## Provider quotas

Mac, Android, and iOS can show remaining account allowance and reset windows. Separate
accounts and windows stay separate. A provider summary takes the lowest remaining
percentage among included accounts; it never adds or averages allowances.

```sh
dieter quota list
dieter quota refresh openai
dieter quota exclude openai --account OPAQUE_KEY
dieter quota include openai --account OPAQUE_KEY
```

These commands are **gateway-account scoped** and do not accept `--machine`.
Explicit `DIETER_CODEX_ACCOUNT_HOMES` paths can expose up to eight local Codex
profiles on a daemon. OpenAI reset credits require an exact confirmation:
`dieter quota reset openai --account OPAQUE_KEY --confirm RESET` consumes a credit.

OpenAI and Claude quota collectors read the existing OAuth credentials on the
host and call the providers' usage APIs directly. OpenAI polling does not launch
Codex or refresh plugin marketplaces, and Codex credentials stay read-only:
Codex itself must refresh an expired token. OpenAI supports file credentials and
profile-specific macOS Keychain entries; process-only and encrypted secret
stores are unsupported. Claude quota polling runs every five minutes, with a
ten-minute cooldown after failed requests; account discovery and manual refresh
share that limit.

Quota snapshots can be stale or unavailable. Card token totals are a different
measure: provider-reported usage, potentially partial, and not a cost estimate.

## Execution permissions

Harness workers run unsandboxed as the daemon user. Independent conversations
can run concurrently; there is no global, harness, or board parallel-session cap.
Each conversation has one active turn, and machine/storage/process resource
bounds still apply. Read the [security model](/docs/security/).
