---
title: "Agents & models"
linkTitle: "Agents & models"
description: "Use your existing local agent configuration and the capabilities of the selected host."
group: "Reference"
weight: 42
slug: "harnesses"
---

Dieter integrates six harnesses through a pinned JavaScript runtime. Each uses
its normal local configuration on the **execution machine**.

| Harness                | Default configuration                       |
| ---------------------- | ------------------------------------------- |
| Codex                  | `~/.codex` or `CODEX_HOME`                  |
| Claude Code            | `~/.claude` or `CLAUDE_CONFIG_DIR`          |
| Pi                     | `~/.pi/agent` or `PI_AGENT_DIR`             |
| Oh My Pi               | `~/.omp/agent`, with `OMP_PROFILE` when set |
| DeepSeek Harness (DSH) | `~/.dsh` or `DSH_HOME`                      |
| Antigravity (Google)   | `agy` on PATH, `~/.gemini/antigravity-cli`  |

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

Codex, Claude Code, Pi, and Antigravity support model and effort changes between turns.
Antigravity reaches Dieter's host tools through an MCP server named `dieter` that the
harness registers in agy's own configuration (`agy mcp add dieter …`) the first time a
turn offers them; outside a Dieter turn that server offers no tools.
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
