---
title: "Agents & models"
linkTitle: "Agents & models"
description: "Use your existing local agent configuration and the capabilities of the selected host."
group: "Reference"
weight: 42
slug: "harnesses"
---

Dieter integrates five harnesses through a pinned JavaScript runtime. Each uses
its normal local configuration on the **execution machine**.

| Harness | Default configuration |
| --- | --- |
| Codex | `~/.codex` or `CODEX_HOME` |
| Claude Code | `~/.claude` or `CLAUDE_CONFIG_DIR` |
| Pi | `~/.pi/agent` or `PI_AGENT_DIR` |
| Oh My Pi | `~/.omp/agent`, with `OMP_PROFILE` when set |
| DeepSeek Harness (DSH) | `~/.dsh` or `DSH_HOME` |

Authenticate or configure the provider on that machine first. Dieter does not
transfer provider credentials between hosts or store them on the gateway.

## Inspect the actual catalog

```sh
dieter harness list --format jsonl
dieter --machine MACHINE_ID harness list --format jsonl
```

The catalog is loaded from the selected execution owner. OMP is intentionally
curated to the exact Codex-authenticated GPT-6 Luna, Sol, and Astra selectors
plus the Tailscale GLM selector. Discovery uses the pinned OMP build used for new
turns, so a separate global `omp` upgrade cannot add stale or unrelated choices.
Dieter passes the chosen selector when it launches OMP because OMP's ACP model
option intentionally contains only the user's smaller cycling list. Other
harness catalogs remain machine-local. DSH models are discovered from its
standard ACP session options. A successful prior catalog is retained through
transient refresh failures.

The embedded registry is
[`config/harnesses.yaml`](https://github.com/dbpprt/dieter/blob/main/config/harnesses.yaml).
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

The first catalog refresh or turn installs the exact locked OMP/DSH runtime under
`DIETER_HOME`. Dieter also installs the pinned Bun executable required by OMP once
per daemon home and shares it across content-addressed harness releases. Updating
a separately installed global agent CLI does not update Dieter's bundled bridge
or its advertised OMP catalog.
Managed daemon updates prepare the new content-addressed runtime first; a turn
already in flight remains pinned to its digest across recovery, and the next turn
uses the current runtime.

DSH is installed lazily through the ACP bootstrap at its tested version; a global
`dsh` installation is not required. See the
[DSH integration reference](https://github.com/dbpprt/dieter/blob/main/docs/deepseek-dsh-harness.md)
for provider configuration and diagnostics.

## Provider quotas

Mac and Android can show remaining account allowance and reset windows. Separate
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

Quota snapshots can be stale or unavailable. Card token totals are a different
measure: provider-reported usage, potentially partial, and not a cost estimate.

## Execution permissions

Harness workers run unsandboxed as the daemon user. Independent conversations
can run concurrently; there is no global, harness, or board parallel-session cap.
Each conversation has one active turn, and machine/storage/process resource
bounds still apply. Read the [security model](/docs/security/).
