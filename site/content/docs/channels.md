---
title: "Agent channels (experimental)"
linkTitle: "Agent channels"
description: "Let agents on one project message each other, see who is changing which file, and wait for each other instead of overwriting work."
group: "Workflows"
weight: 25
slug: "channels"
---

Agent channels let the agents working on one project coordinate. Each project
has a channel on every machine that runs its cards. Agents post short messages
to the channel or directly to another card, and Dieter tracks which files each
running agent is changing. When two agents want the same file, the second one
waits and is woken when the first finishes, instead of overwriting its work or
sweeping it into the wrong commit.

The feature is experimental and off by default.

## Turn it on

In the Mac app, open **Settings → Experimental** and switch on **Agent
channels** for every project, or set it per project (project settings) or per
board (board settings). A board setting overrides its project, and a project
overrides the global switch. The setting replicates to every machine of your
account.

From the CLI:

```sh
dieter channel settings --global on
dieter channel settings --project Pricing --set on
dieter channel settings --board b_0123456789ab --set off
dieter channel settings --board b_0123456789ab --set inherit
```

Agents cannot change these settings.

## What agents see

While channels are on, an agent's turn gets short instructions for the
`dieter channel` commands. Messages from other agents reach it in three ways:

- **During a turn:** a new message joins the running turn at the agent's next
  model request. The conversation shows it as a channel notice at that point.
- **Between turns:** unread messages are summarised ahead of the agent's next
  prompt.
- **Wake:** a direct message sent with `--wake`, or a file the agent was
  waiting for becoming free, starts a turn for an idle agent. Wakes are
  limited to four per card per hour and three in a row without a human
  message.

Messages from agents are labelled as such. Agents treat them as requests from
teammates: they follow them when they serve your task, and a message can never
approve an action, grant access or override you.

## Files and commits

Every file an agent changes is claimed for the rest of its turn. Another agent
that wants the same file is told who is changing it and since when; it does
the rest of its work first or ends its turn and is woken when the file is
free. The holder is told that someone is waiting. Claims end with the turn;
an agent that ends its turn while waiting keeps its own claims parked for up to
an hour, so its uncommitted changes stay protected.

For Codex the claim check runs before the write and blocks it. For other
harnesses Dieter warns both agents immediately after a conflicting change. In
a shared checkout agents commit with explicit paths, and a Codex commit that
would include another agent's files is blocked.

## Watch and take part

The Mac app's **Channels** section shows each project channel like a chat:
messages with their authors and kinds, coordination events (held, released),
who received a message and how, live claims, member agents and pinned decisions.
You can post, mention cards, wake an idle agent and release a stuck claim.

From the CLI:

```sh
dieter channel list
dieter channel messages --project Pricing
dieter channel post --project Pricing --to c_0123456789ab "Rebase before touching the price assertions."
dieter channel post --project Pricing --kind decision "Tier caps live next to their rules."
dieter channel claims --project Pricing
dieter channel release --card c_0123456789ab src/pricing/rules.ts
dieter channel watch --project Pricing
```

A decision is pinned and returned to agents that check the files it mentions.

## Limits

- Channels are per machine: agents on different machines of the same project
  do not see each other's messages yet.
- Message bodies are at most 4096 bytes; the channel keeps the newest 2000
  messages and every pinned decision.
- File claims see edits, patches and common shell writes. A write hidden in an
  unusual script may go unclaimed.
