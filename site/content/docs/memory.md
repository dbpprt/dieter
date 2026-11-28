---
title: "Agent memory (recall earlier work across your machines)"
linkTitle: "Agent memory"
description: "Turn on memory for a project: agents recall what earlier conversations found on any of your machines, save lessons and decisions, and dreams keep the memories tidy."
group: "Workflows"
weight: 29
slug: "memory"
---

With **agent memory** on, a project remembers its conversations. Before an
agent investigates a problem from scratch, it searches what earlier
conversations of the project found, on every machine of your account. It
saves the lessons and decisions worth keeping, and they reach every later
conversation. Memory runs inside Dieter: there is nothing to install or run,
no extra model key, and nothing leaves your machines.

Memory is off until you turn it on for a project.

## Turn it on

- **Mac:** the project's settings › **Agent memory**.
- **Android, iPhone and iPad:** the project's administration › **Agent memory**.
- **CLI:**

```sh
dieter project update --memory=true PROJECT
dieter memory status
```

The project's settings then show what is indexed on that machine, how many
memories are saved, and when the last and next dream are.

New conversations of the project use memory. The new-conversation form has an
**Agent memory** toggle, and a conversation's menu switches it later:

```sh
dieter card memory CARD off      # or: dieter chat memory CHAT off
dieter card create … --memory off
```

Turning memory off for a conversation keeps what was already indexed;
`dieter memory forget --card CARD` removes it.

## What agents get

A conversation with memory gets two tools:

- **`memory_recall`** searches the project's saved memories and its earlier
  conversations on every machine that owns some of them. Each match names the
  card, the machine, the title, the matching passages and the final answer.
  The agent can read a conversation in full with
  `dieter --machine MACHINE card transcript CARD`. Agents call it before
  investigating a problem; the instructions tell them to treat what they find
  as possibly outdated notes and to check it against the code.
- **`memory_save`** saves one curated memory: a **lesson** (a rule learned the
  hard way), a **decision** (what was decided and why), a **fact** or a
  **pattern**. Agents save when a decision settles or a non-obvious problem is
  solved, or when you ask them to remember something. Saving the same lesson
  again strengthens it; a near-identical memory replaces the old one.

Harnesses that load tools on demand, such as Claude Code, find both tools by
name. Without them, `dieter memory search "QUERY"` does the same inside a
turn. An agent turn only ever reaches its own project's memory.

## What gets indexed

When a turn of a memory conversation ends, the machine that owns the
conversation indexes it: your prompt, the tools the agent ran with their
results and errors, and the final answer. Reasoning, Dieter's own tool
traffic, `<private>…</private>` blocks and common secret formats (API keys,
tokens, private keys, passwords in URLs) are left out. Vault values never
reach transcripts in the first place.

A search finds conversations and saved memories by their words and by their
meaning, so "the assistant keeps getting logged out" finds the conversation
about HTTP 401 errors. Dieter embeds each conversation's title, prompts and
final answers with a small language model built into Dieter. It runs on the
machine itself, uses no account or key, and needs about 60 MB of memory while
it works, released a few minutes after the last search. The first start after
an update that changes the model indexes the conversations once more in the
background; until then, search finds them by their words.

Each machine keeps its own index (`DIETER_HOME/memory/memory.db`). It is not
copied between machines: a search asks the other machines when it runs. A
machine that is asleep or offline is missing from the answer until it is back,
and the result names it. Saved memories are different: they replicate to
every machine, so they are always complete.

## Search and save yourself

```sh
dieter memory search --project PROJECT why does the gateway tunnel stay offline after sleep
dieter memory search --project PROJECT --file internal/link/tunnel.go reconnect
dieter memory save --project PROJECT --kind decision "Config files are TOML: ops uses TOML everywhere."
dieter memory forget --project PROJECT --memory mem_…
dieter memory reindex --project PROJECT
```

## Dreams

A **dream** keeps a project's saved memories tidy. It is a conversation
labelled **Memory** on the project's first board, so you can watch it. Its
agent reads the saved memories and the conversations since the last dream,
then changes the memories in one batch:

- merges duplicates;
- supersedes outdated memories with corrected text;
- retires memories that newer conversations contradict;
- adds the decisions and lessons the conversations established;
- marks the memories it checked against their sources as verified.

Dieter checks the batch before applying any of it: at most a set number of
changes, at most a set share of the memories retired or superseded, and every
new memory cites cards of the project. A dream changes no code or files.

Dreams use one setting for your account:

- **Mac:** **Settings › Agent memory**.
- **Android, iPhone and iPad:** **Settings › Conversations › Agent memory**.
- **CLI:**

```sh
dieter memory settings
dieter memory settings update --dreaming on --harness claude-code --model opus
dieter memory settings update --apply review --window 02:00-06:00 --min-hours 24 --min-tasks 5
```

- **Dreaming** on starts dreams by themselves: at most every `--min-hours`
  hours per project, after `--min-tasks` finished conversations, inside the
  local time `--window`. They run on one machine: the one you name with
  `--run-on`, or for each project the machine with most of its conversations.
- **Harness, model, effort and account.** Any harness in your catalog except
  Strix. Claude Code and Codex dreams run on a
  [provider account](/docs/providers/).
- **Apply.** `auto` applies a checked batch at once; `review` keeps it until
  you apply or discard it.
- **Limits** (`--max-changes`, `--max-retire-percent`) and extra
  `--instructions` for every dream. Edit the Memory label's instructions on a
  board to change the procedure itself.

A dream conversation shows a banner with what it changed. In review mode it
offers **Apply** and **Discard**; after it is applied, **Undo** restores the
memories it changed. Start a dream from the project's settings with **Start a
dream now**, or from the CLI:

```sh
dieter memory dream start PROJECT
dieter memory dream list PROJECT
dieter memory dream apply CARD        # apply a staged batch
dieter memory dream discard CARD
dieter memory dream undo CARD         # restore what an applied dream changed
```

Agents cannot change the setting, start dreams, apply them, forget memories
or switch memory.

## Privacy and cost

- Memory never leaves your machines. Searches between machines use the same
  end-to-end encrypted routes as everything else; the gateway stores nothing
  of it.
- Indexing and search cost no model usage: the embedding model runs on your
  machine. Dreams are agent turns and use your plan or key like any
  conversation; they are off until you turn them on.
- Everything an agent recalls was written by an agent or a tool. A web page or
  file an agent read can plant misleading text, so agents verify what they
  recall, and you can forget any memory or conversation.
