---
name: nauclio-cli
description: Work with Nauclio's direct-storage CLI where every card is one durable local harness conversation.
---

# Use Nauclio CLI

Use `nauclio`, not Nauclio's browser API or central data files. The initial task
supplies the exact card ID. Never invent one.

Load bounded Nauclio context and post non-triggering progress:

```sh
nauclio card context <card-id>
nauclio card comment <card-id> --message "Meaningful progress."
nauclio card move <card-id> --lane review
```

Comments never resume the agent or count as approval.

Inspect before mutation and prefer exact IDs plus bounded machine output:

```sh
nauclio status
nauclio project list --format jsonl
nauclio board list --project <project-id> --format jsonl
nauclio card list --project <project-id> --board <board-id> \
  --lane running --format jsonl --limit 10
```

Register a Git project and create work:

```sh
nauclio project open /path/to/repo --prompt-file prompt.md
nauclio board create --project <project-id> --name Delivery --workflow review
nauclio card create --project <project-id> --board <board-id> \
  --lane todo --title "Implement recovery" --prompt-file task.md --format id
```

Boards define their own labels. Use exact label IDs for filtering and assignment:

```sh
nauclio board label add --board <board-id> --name Backend --color '#3366ff'
nauclio board label list --board <board-id>
nauclio card labels <card-id> --set <label-id>,<label-id>
nauclio card list --project <project-id> --board <board-id> \
  --label <label-id> --format jsonl
```

Archiving is reversible. Operators can set a board's Done retention policy and
inspect archived cards without editing the central store:

```sh
nauclio board retention --archive-done after_30_days <board-id>
nauclio card list --board <board-id> --archived --format jsonl
nauclio card archive <card-id>
nauclio card unarchive <card-id>
```

Operators can inspect and resume the same durable session:

```sh
nauclio card transcript <card-id> --last 20
nauclio card send <card-id> --message "Address the review feedback."
nauclio card send <card-id> --message "Inspect these inputs." \
  --attach screenshot.png --attach notes.pdf
```

Inspect or operate project schedules through the direct store as well:

```sh
nauclio schedule list --project <project-id> --format jsonl
nauclio schedule show <schedule-id>
nauclio schedule runs <schedule-id>
nauclio schedule run <schedule-id>
nauclio schedule pause <schedule-id>
nauclio schedule resume <schedule-id>
```

`nauclio schedule run` creates a real occurrence and may start an agent. Inspect
the schedule and its recent runs before invoking it. Global admission policy is
available through `nauclio settings show`; do not change it unless the task
explicitly asks for an operational policy change.

Read `nauclio <group> <action> --help` before unfamiliar mutations. Never edit
`NAUCLIO_HOME` manually during normal operation.
