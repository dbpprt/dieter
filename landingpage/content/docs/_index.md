---
title: "Meet Dieter"
linkTitle: "Meet Dieter"
description: "Your coding agents. Your machines. One native workspace."
group: "Overview"
weight: 1
---

Dieter brings coding agents running on your own machines into one workspace.
Start a task on your Mac, let a Linux workstation do the work, and check the
result from your phone. Every card and standalone chat keeps its own durable
conversation.

Dieter is open source under the MIT license. The name is pronounced **DEE-ter**.

## Start here

| You want to… | Go to |
| --- | --- |
| See what the apps can do | [Product tour](/docs/tour/) |
| Install a daemon and a client | [Installation](/docs/installation/) |
| Run your first task | [Quick start](/docs/quickstart/) |
| Organize projects, boards, and checkouts | [Projects & tasks](/docs/projects/) |
| Review files, changes, and running commands | [Conversation workspace](/docs/workspace/) |
| Connect more machines | [Machines & routes](/docs/machines/) |
| Automate Dieter | [CLI guide](/docs/cli/) |
| Operate your own gateway | [Self-hosting](/docs/gateway/) |
| Build or contribute | [Development](/docs/development/) |

## The product in a minute

**Agents run on daemon hosts.** Install `dieter` on Apple Silicon macOS or Linux
amd64/arm64. It starts agents beside your Git checkout using their normal local
configuration. Codex, Claude Code, Pi, Oh My Pi, and DeepSeek Harness are supported.

**Native apps are your workspace.** macOS and Android provide boards, chats,
files, terminals, schedules, and machine tools. The iPhone and iPad client is in
beta; see the [platform guide](/docs/installation/#iphone-and-ipad-beta) for its
current distribution and workflows.

**The gateway connects your devices.** It authenticates accounts and enrolled
machines, advertises routes, and relays requests when needed. It stores control
metadata and normalized quota snapshots, not your repositories or conversations.
There is no browser-based Dieter application; this website is documentation.

## What stays where

Shared project metadata and portable settings replicate between your account's
daemons. Checkouts, conversations, schedules, files, and execution stay with
their owning machine. Closing a client does not cancel agent work.

Agents have the permissions of the daemon user. Your chosen model provider may
receive prompts, code, and tool output according to its own configuration.
“Local execution” describes where the agent and tools run; it does not imply
that model inference is local. Read the [security model](/docs/security/).
