---
title: "Quick start"
linkTitle: "Quick start"
description: "From brew install to your first running agent on a real Git working tree, in a few minutes."
group: "Guides"
weight: 11
slug: "quickstart"
---

This walks from a clean machine to a running agent conversation. It assumes
Apple Silicon macOS and access to your gateway.

## 1 · Install and set up the daemon

```sh
brew install dbpprt/tap/dieter
dieter setup ~/Development/orbit
```

`dieter setup` opens the gateway's GitHub authorization page, registers the Git
working tree by canonical path, guides Screen Recording and Accessibility
permissions, starts the Homebrew service, and waits for both the local API and
the gateway tunnel. It never stores a GitHub token on the daemon host.

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
