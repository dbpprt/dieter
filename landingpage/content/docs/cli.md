---
title: "CLI guide"
linkTitle: "CLI guide"
description: "Discover, inspect, and automate the same operations as the native clients."
group: "Reference"
weight: 44
slug: "cli"
---

`dieter` is both the local daemon executable and its supported automation client.
Operational commands call the running daemon API. They do not edit storage files.

## Discover commands offline

```sh
dieter --help
dieter help card create
dieter remote exec --help
```

Every group and leaf has offline help. Use it for the exact required arguments,
formats, confirmations, and bounds in your installed release. Uppercase IDs in
this guide are placeholders; retain real IDs returned by discovery.

## Choose a machine

Without `--machine`, operational commands use the local daemon. Place the global
option **before** the command to target another enrolled host:

```sh
dieter machine list --format jsonl
dieter --machine MACHINE_ID status
dieter --machine MACHINE_ID project list --format jsonl
```

Remote authentication uses the local daemon enrollment, not a second CLI login.
Verified direct TLS is preferred, followed by supported WebRTC and gateway relay.
`--checkout` chooses among checkouts on the selected machine, not a different host.
Quota commands are account-wide and reject `--machine`.

## Command map

| Group | Use it for |
| --- | --- |
| `setup`, `doctor`, `daemon` | Enrollment, prerequisites, permissions, service state, logs, and Linux user units |
| `machine` | Directory, routes, live telemetry, contract/release versions, updates, power, and connection signaling |
| `harness`, `quota` | Host model catalogs and account quota windows |
| `project`, `board` | Shared project identities, local checkouts, board settings, labels, host mappings, retention |
| `card`, `chat` | Durable conversations, follow-ups, queues, read receipts, presentation, archives |
| `workspace` | Uncommitted changes, revisions, Git and SCM operations |
| `file` | Directory listings, file reads, revision-checked saves |
| `terminal` | Daemon-owned interactive PTYs |
| `remote` | Exact-argv processes, resumable output, explicit input and cancellation |
| `screen` | Capabilities, session signaling, control, quality, clipboard, diagnostics |
| `schedule` | Templates, previews, occurrence history, and dispatch |
| `settings`, `prompt` | Portable settings and scoped prompt configuration |
| `peer`, `kv` | Peer synchronization, portable records, revisions, ordering, and subscriptions |
| `watch`, `status`, `storage`, `version` | Bounded observation, counts, paths, and build identity |

## Common recipes

### Set up and inspect

```sh
dieter setup --gateway https://dieter.example.com
dieter project open ~/Development/my-project
dieter doctor
dieter daemon status
dieter daemon logs --follow
```

Use your real gateway origin. Run `daemon start` or `serve` for foreground
operation only when a daemon is not already running.

### Create and follow a task

```sh
dieter project list --format jsonl
dieter board list --project PROJECT_ID --format jsonl
dieter card create --project PROJECT_ID --board BOARD_ID \
  --lane running --auto-title --prompt "Add keyboard navigation" \
  --workspace worktree --format id
dieter card context CARD_ID
dieter card transcript --last 20 CARD_ID
dieter card watch CARD_ID
```

Creating or sending returns after admission, not after the agent finishes.
Do not replay a start or message simply because the connection dropped.

### Continue and review

```sh
dieter card send CARD_ID --message "Address the review feedback."
dieter card move CARD_ID --lane review
dieter card queue remove CARD_ID --message MESSAGE_ID
```

Queue removal returns the complete payload and selection so a caller can restore a draft for editing.

Completed, unseen replies appear in **Needs attention** on Mac and Android.
Viewing the latest reply acknowledges it across clients. Automation can use
`dieter card read --response-seq SEQ CARD_ID` with the `responseSeq` returned by
`card show` after displaying that response. This also works with `chat read`
and global `--machine`; an old receipt cannot clear a newer reply.

### Inspect and commit selected changes

```sh
dieter workspace changes --project PROJECT_ID
dieter workspace diff --project PROJECT_ID --section unstaged --path src/main.go
dieter workspace run --project PROJECT_ID --kind stage \
  --revision REVISION --param path=src/main.go --wait
dieter workspace changes --project PROJECT_ID
dieter workspace run --project PROJECT_ID --kind commit \
  --revision NEW_REVISION --param subject="Focused change" --wait
```

Re-read the changeset after a mutation and use its **new** revision. Worktree
conversations can be addressed by card ID; project-directory changes use
`--project` because they belong to the shared checkout.

### Run and observe a process

```sh
dieter remote exec --card CARD_ID --detach -- npm run dev
dieter remote list --card CARD_ID
dieter remote wait EXECUTION_ID
```

The process belongs to the daemon. Leaving an observer does not stop it. Use
`remote --help` for explicit read, stdin, and stop operations.

### Inspect schedules and quotas

```sh
dieter schedule list --project PROJECT_ID --page-size 50
dieter schedule runs SCHEDULE_ID --page-size 50
dieter quota list
dieter quota watch --count 3
```

Continue paginated schedule output with its opaque `--page-token`. Each quota
account/window remains separate; provider summaries never combine allowances.

## Automation rules

Use bounded contexts and lists; fetch full tool payloads only when needed.
Watches resume read state after transient transport failures, with up to five
retries between delivered frames. Revocation and permanent errors stop recovery.
A mutation, process start, or stdin frame is not replayed by watch recovery.

Prefer documented idempotency keys when an operation supports them. After an
uncertain response, inspect state before retrying. Use CLI operations for all
Dieter state changes instead of editing `DIETER_HOME`.

For deeper command examples and behavioral boundaries, read the maintained
[Dieter CLI skill](https://github.com/dbpprt/dieter/blob/main/.agents/skills/dieter-cli/SKILL.md).
