---
title: "Harnesses"
linkTitle: "Harnesses"
description: "Dieter runs Codex, Claude Code, Pi, and Oh My Pi through each harness's own configuration, no re-auth, no proxy, no sandbox."
group: "Reference"
weight: 21
slug: "harnesses"
---

Dieter uses each harness's normal user configuration. Nothing is proxied or
re-authenticated; your existing agent credentials are read from their usual
location on the daemon host.

## Supported harnesses

| Harness | Configuration |
| --- | --- |
| Codex | `~/.codex` or `CODEX_HOME` |
| Claude Code | `~/.claude` or `CLAUDE_CONFIG_DIR` |
| Pi | `~/.pi/agent` or `PI_AGENT_DIR` |
| Oh My Pi | `~/.omp/agent`, with `OMP_PROFILE` when set |

Codex, Claude Code, Pi, and Oh My Pi run through pinned
[Vercel AI SDK Harnesses](https://ai-sdk.dev/docs/ai-sdk-harnesses/overview)
without a sandbox. The first agent turn installs the exact JavaScript harness
runtime from `internal/harness/runtime/package-lock.json` under `DIETER_HOME`.

## The registry

The model, effort, context, capability, and typed provider-option registry is
`config/harnesses.yaml`. Each harness declares a default model, a list of
selectable models, an effort/thinking scale, and capability flags such as
subagents and task-plan.

Override the entire registry with any of:

```sh
$DIETER_HOME/harnesses.yaml     # per-daemon file
DIETER_HARNESS_CONFIG=<path>    # environment
--harness-config <path>         # flag
```

## Capabilities

- **Concurrent turns** are permitted in the same registered project folder. Only
  explicit global, harness, and board parallel-session limits restrict separate
  chats; a single conversation still has at most one active turn.
- **Parallel-session limits** are enforced at runtime lease acquisition, so
  HTTP, CLI, and scheduled starts share one policy.
- **Durability** is built in. A graceful daemon shutdown parks active harness
  turns with provider continuation state, and startup resumes them without
  replaying the user prompt.

{{< callout type="warn" title="Harnesses run unsandboxed as your user" >}}
Harness workers run locally on the daemon host with the permissions of the user
running the daemon. This is what keeps agents close to the code, credentials,
and tools, so treat daemon host access accordingly.
{{< /callout >}}
