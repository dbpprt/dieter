---
title: "Introduction"
linkTitle: "Introduction"
description: "Run Codex, Claude Code, Pi, and Oh My Pi across every machine you own, from one open-source app. Chats, boards, and schedules for coding agents at scale."
group: "Overview"
weight: 1
---

Dieter is pronounced **DEE-ter** (/ˈdiː.tər/).

Dieter runs your local coding agents across every machine you own, the Mac mini
in your office, a server at home, your laptop, and puts them behind one macOS and
Android app. Each agent runs on the machine that holds the code, close to its Git
working tree, credentials, and tools. You keep control from anywhere.

{{< callout type="note" title="The idea" >}}
**Every machine**, enroll them all and work from one project list.
**Every agent**, Codex, Claude Code, Pi, and Oh My Pi, each from its own config.
**From anywhere**, drive it from macOS or Android; the code never leaves home.
{{< /callout >}}

## What Dieter is

Dieter is a control plane for **local** coding agents. Codex, Claude Code, Pi,
and Oh My Pi run through pinned [Vercel AI SDK Harnesses](https://ai-sdk.dev/docs/ai-sdk-harnesses/overview)
without a sandbox, each on the machine that holds the repository. Every dieter
card and standalone chat is exactly one durable conversation in a real Git
working tree.

There is **no web UI and no cloud agent runtime.** The public gateway is a
machine-to-machine control and relay service; Dieter data and harness
credentials never leave their daemon host.

## The three parts

| Component | Responsibility |
| --- | --- |
| `dieter daemon` | Owns projects, durable conversations, persistent PTY terminals, schedules, files, and local harness workers. |
| `dieter-gateway` | Authenticates one GitHub account and connects any number of enrolled daemons. |
| Native clients | macOS and Android apps that aggregate every daemon and speak the same `dieter.v1.DieterService` API. |

The native clients build their own project directory by querying every online
daemon through the authenticated relay. Each project is shown with its owning
hostname, and opening its board, chats, terminals, files, or schedules
automatically moves the active connection to that daemon. The gateway never sees
or stores that directory.

{{< callout type="warn" title="Harnesses run with your permissions" >}}
Harnesses have the permissions of the user running the daemon. Never expose the
raw loopback data plane. Native clients use the gateway or an authenticated TLS
route advertised by the daemon.
{{< /callout >}}

## Where to next

- **[Installation](/docs/installation/)**, Homebrew packages, source builds, and requirements.
- **[Quick start](/docs/quickstart/)**, from `brew install` to running your first agent.
- **[Architecture](/docs/architecture/)**, how the daemon, gateway, and clients fit together.
- **[Security model](/docs/security/)**, enrollment, assertions, and what the gateway can and cannot see.
