---
name: dieter-cli
description: Work with Dieter's direct-storage CLI where every card is one durable local harness conversation.
---

# Use Dieter CLI

Use `dieter`, not Dieter's browser API or central data files. The initial task
supplies the exact card ID. Never invent one.

Load bounded Dieter context and post non-triggering progress:

```sh
dieter card context <card-id>
dieter card comment <card-id> --message "Meaningful progress."
dieter card move <card-id> --lane review
```

Comments never resume the agent or count as approval.

Inspect before mutation and prefer exact IDs plus bounded machine output:

```sh
dieter status
dieter project list --format jsonl
dieter board list --project <project-id> --format jsonl
dieter card list --project <project-id> --board <board-id> \
  --lane running --format jsonl --limit 10
```

Register a Git project and create work:

```sh
dieter project open /path/to/repo --prompt-file prompt.md
dieter board create --project <project-id> --name Delivery --workflow review
dieter card create --project <project-id> --board <board-id> \
  --lane todo --title "Implement recovery" --prompt-file task.md --format id
```

Boards define their own labels. Use exact label IDs for filtering and assignment:

```sh
dieter board label add --board <board-id> --name Backend --color '#3366ff'
dieter board label list --board <board-id>
dieter card labels <card-id> --set <label-id>,<label-id>
dieter card list --project <project-id> --board <board-id> \
  --label <label-id> --format jsonl
```

Archiving is reversible. Operators can set a board's Done retention policy and
inspect archived cards without editing the central store:

```sh
dieter board retention --archive-done after_30_days <board-id>
dieter card list --board <board-id> --archived --format jsonl
dieter card archive <card-id>
dieter card unarchive <card-id>
```

Operators can inspect and resume the same durable session:

```sh
dieter card transcript <card-id> --last 20
dieter card send <card-id> --message "Address the review feedback."
dieter card send <card-id> --message "Inspect these inputs." \
  --attach screenshot.png --attach notes.pdf
```

Inspect or operate project schedules through the direct store as well:

```sh
dieter schedule list --project <project-id> --format jsonl
dieter schedule show <schedule-id>
dieter schedule runs <schedule-id>
dieter schedule run <schedule-id>
dieter schedule pause <schedule-id>
dieter schedule resume <schedule-id>
```

`dieter schedule run` creates a real occurrence and may start an agent. Inspect
the schedule and its recent runs before invoking it. Global admission policy is
available through `dieter settings show`; do not change it unless the task
explicitly asks for an operational policy change.

Read `dieter <group> <action> --help` before unfamiliar mutations. Never edit
`DIETER_HOME` manually during normal operation.
