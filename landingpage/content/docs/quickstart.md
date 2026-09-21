---
title: "Quick start"
linkTitle: "Quick start"
description: "From brew install to your first running agent on a real Git working tree, in a few minutes."
group: "Guides"
weight: 11
slug: "quickstart"
---

This walks from a clean macOS or systemd Linux machine to a running agent
conversation with access to your gateway.

## 1 · Install and set up the daemon

```sh
# Linux (after installing cosign)
curl -fsSL https://github.com/dbpprt/dieter/releases/latest/download/install.sh | sh
dieter setup

# Apple Silicon macOS
brew install dbpprt/tap/dieter
dieter setup

# On either host, register a project explicitly after setup
dieter project open ~/Development/orbit
```

`dieter setup` opens the gateway's GitHub authorization page. It never registers
the current Git working tree or any other project; `dieter project open PATH`
does that explicitly. On macOS setup guides Screen Recording and Accessibility
permissions and starts Homebrew. On Linux it installs a systemd user service and
runs as a headless host without those permission steps. It never stores a GitHub
token on the daemon host.

## 2 · Install the app and sign in

```sh
brew install --cask dbpprt/tap/dieter-app
open -a Dieter
```

Sign in to the same gateway origin. Dieter builds one project directory from
every enrolled daemon, and `orbit` appears tagged with its hostname.

## 3 · Open a project and create a card

Open `orbit`. The active connection moves to the daemon that owns it. Create a
card on the board: each card is exactly one durable conversation in the real
working tree.

{{< callout type="note" title="Comments never wake the agent" >}}
Human chat messages resume the same harness session and drive a turn. Comments
are notes for you and your team; they never wake the agent or count as approval.
{{< /callout >}}

## 4 · Drive it from the CLI, too

Everything the app does is available from the `dieter` CLI, which is ideal for
scripting or for agents operating Dieter. Prefer bounded context:

```sh
dieter card context <exact-card-id>
dieter card comment <exact-card-id> --message "Meaningful progress."
dieter card move <exact-card-id> --lane review
```

Many commands accept `--format jsonl` or `--format id` for machine use.

## 5 · Keep an eye on things

```sh
dieter daemon status
dieter daemon logs --follow
```

Managed logs are bounded and stored under `$DIETER_HOME/logs` (default
`~/.dieter/logs`).

## Next steps

- **[Enroll more machines](/docs/machines/)** and advertise direct routes over a tailnet or LAN.
- **[Run your own gateway](/docs/gateway/)** to host the control plane yourself.
- **[Configure harnesses](/docs/harnesses/)** to set models, effort, and provider options.
- **[Screens](/docs/screens/)** to view and control an enrolled machine.
