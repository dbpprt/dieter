---
title: "CLI reference"
linkTitle: "CLI reference"
description: "The dieter command operates the daemon, projects, boards, cards, chats, and schedules — and is built for agents to drive too."
group: "Reference"
weight: 20
slug: "cli"
---

The `dieter` binary is both the daemon and the operator CLI. Many commands accept
`--format jsonl` or `--format id` for machine and agent use.

## Setup & service

```sh
dieter setup <path>              # register a tree, enroll, guide permissions, start service
dieter serve                     # alias for `dieter daemon start`
dieter daemon start              # run the daemon
dieter daemon status             # inspect the running service
dieter daemon logs --follow      # tail bounded managed logs
dieter version
dieter status
```

## Enrollment & permissions

```sh
dieter daemon enroll --gateway <url> --name "<label>"
dieter daemon unenroll
dieter daemon permissions        # reopen the macOS permission guide
dieter daemon permissions --check
```

## Projects & boards

```sh
dieter project open <path>
dieter project list
dieter project update ...

dieter board create ...
dieter board list
dieter board label ...
dieter board retention ...
```

## Cards & chats

```sh
dieter card create ...
dieter card list
dieter card context <exact-card-id>          # bounded context for an agent
dieter card comment <exact-card-id> --message "..."
dieter card move <exact-card-id> --lane <lane>
dieter card labels <exact-card-id> ...
dieter card archive <exact-card-id>
dieter card unarchive <exact-card-id>

dieter chat ...
```

{{< callout type="tip" title="Driving Dieter as an agent" >}}
Read `.agents/skills/dieter-cli/SKILL.md` in the repository. Prefer bounded
context (`dieter card context`), report progress with `dieter card comment`, and
move work with `dieter card move`. Comments never wake the agent, and you should
never edit central storage directly during normal operation.
{{< /callout >}}

## Schedules

```sh
dieter schedule list
dieter schedule edit ...
```

Schedule occurrence records are authoritative: Dieter uses deterministic card
identity and never replays a turn that may already have been dispatched.

## Service management (Homebrew)

```sh
brew services restart dieter
brew upgrade dieter
```

Managed logs live under `$DIETER_HOME/logs` (default `~/.dieter/logs`). A
Homebrew uninstall removes the service and binary but preserves `DIETER_HOME`.
