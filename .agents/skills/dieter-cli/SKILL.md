---
name: dieter-cli
description: Operate Dieter conversations, projects, workspaces, files, structured remote executions, terminals, schedules, prompts, and enrolled daemon machines through the authenticated daemon CLI.
---

# Use Dieter CLI

Use the `dieter` binary for Dieter state and actions. Operational commands call
the running daemon; never edit `DIETER_HOME` or use project-repository metadata
as a substitute. Every card or standalone chat is one durable harness
conversation owned by its daemon.

## Choose the target

Omit `--machine` to use the running daemon on this machine:

```sh
dieter status
dieter project list --format jsonl
```

`dieter status` returns daemon-wide active project, board, card, and chat
counts; it is the cheapest bounded directory overview for one machine.

For another enrolled machine, authenticate once and pass its exact ID or unique
name as a global option before the command:

```sh
dieter auth login --gateway https://dieter.example.com
dieter machine list --format jsonl
dieter --machine <machine-id> status
dieter --machine <machine-id> project list --format jsonl
```

Remote commands prefer the daemon's authenticated direct TLS route and fall
back to the bounded gateway relay. The gateway routes requests but does not
store projects, transcripts, files, schedules, or harness credentials. Use
`dieter machine show <machine-id>` and `dieter machine route <machine-id>` to
inspect presence and advertised routes. Directory output includes the daemon's
release `version` and compatibility `apiVersion`; use the latter when deciding
whether a native client can safely target a machine in a mixed-version fleet.

The initial task should supply an exact card ID. Never guess one. Resolve names
only for interactive discovery, then retain returned IDs for mutation.

## Work inside a card

Load bounded context before acting and use comments only for non-triggering
annotations:

```sh
dieter card context <card-id>
dieter card transcript --last 20 <card-id>
dieter card comment --message "Meaningful progress." <card-id>
dieter card move --lane review <card-id>
```

Comments never wake the agent and never count as approval. A human message does
resume the same durable harness session:

```sh
dieter card send --message "Address the review feedback." <card-id>
dieter card send --message "Inspect these inputs." \
  --attach screenshot.png --attach notes.pdf <card-id>
```

Use `card poll` for one bounded update and `card watch` for JSON Lines streaming.
Fetch a large tool payload separately with `card tool-output` when the transcript
contains only its bounded preview.

Standalone chats share conversation, workspace, transcript, attachment, and
archive operations:

```sh
dieter chat list --project <project-id> --format jsonl
dieter chat create --project <project-id> --title "Investigate" \
  --prompt "Trace the failure" --workspace worktree --format id
dieter chat pin <chat-id>
```

## Discover and create work

Prefer bounded machine-readable output:

```sh
dieter harness list --format jsonl
dieter project list --format jsonl
dieter board list --project <project-id> --format jsonl
dieter card list --project <project-id> --board <board-id> \
  --lane running --format jsonl --limit 10
```

Paths passed to project commands are paths on the targeted daemon host:

```sh
dieter project directories /path/on/daemon
dieter project open --prompt-file prompt.md /path/on/daemon/repo
dieter board create --project <project-id> --name Delivery --workflow review
dieter card create --project <project-id> --board <board-id> \
  --lane todo --title "Implement recovery" --prompt-file task.md \
  --workspace worktree --format id
```

`card start` admits a draft's first turn. `card send` admits a human follow-up.
Both return without waiting for the agent to finish. Do not replay either just
because the client disconnected; inspect the card and conversation first.

Boards own their labels. Use label IDs for filtering and assignment:

```sh
dieter board label add --board <board-id> --name Backend --color '#3366ff'
dieter board label list --board <board-id>
dieter card labels --set <label-id>,<label-id> <card-id>
dieter card list --board <board-id> --label <label-id> --format jsonl
```

Archiving is reversible. Inspect before changing retention or archive state:

```sh
dieter board retention --archive-done after_30_days <board-id>
dieter card list --board <board-id> --archived --format jsonl
dieter card archive <card-id>
dieter card unarchive <card-id>
```

## Inspect code and Git work

File commands operate on a project directory or a conversation's selected
worktree through the daemon. Existing text saves are revision checked:

```sh
dieter file list --card <card-id> --format jsonl
dieter file read --card <card-id> path/to/file.go
dieter file save --card <card-id> --revision auto \
  --file /tmp/replacement.go path/to/file.go
```

Inspect the current workspace revision before commenting on or mutating Git
state:

```sh
dieter workspace show <card-id>
dieter workspace changes <card-id>
dieter workspace diff --path path/to/file.go <card-id>
dieter workspace comments <card-id>
dieter workspace scm <card-id>
```

Git operations are daemon-owned, serialized, and durable. Supply the expected
revision where the operation depends on the changeset, and repeat `--param` for
kind-specific values:

```sh
dieter workspace run --kind validate --revision <revision> --wait <card-id>
dieter workspace operation <operation-id>
dieter workspace watch <operation-id>
```

Kinds include `commit`, `update`, `continue_conflict`, `abort_conflict`,
`validate`, `merge_local`, `push`, `cleanup`, `discard`, `adopt`, `create_pr`,
`refresh_pr`, and `merge_pr`. Inspect help and current state before destructive
or externally visible Git operations.

## Run commands on a daemon host

Prefer `remote exec` for agent automation. It submits exact argv values without
an implicit shell, preserves stdout and stderr separately, reports the remote
exit code, and retains bounded output by sequence so a disconnected client can
resume without stopping the process:

```sh
dieter --machine <machine-id> remote exec --card <card-id> \
  --idempotency-key validation-<stable-input-digest> \
  --format jsonl -- go test ./...
dieter --machine <machine-id> remote list --card <card-id> --format jsonl
dieter --machine <machine-id> remote show <execution-id>
dieter --machine <machine-id> remote watch --after <sequence> \
  --format jsonl <execution-id>
```

Put every command and argument after the required `--`. Dieter does not parse
shell syntax there. If pipes, redirects, expansion, or compound commands are
actually required, request the shell explicitly as argv:

```sh
dieter remote exec --project <project-id> -- /bin/sh -c \
  'go test ./... && go vet ./...'
```

Use `--detach --format id` for asynchronous admission and then `remote wait`
to propagate the remote exit code. Supply a stable `--idempotency-key` when a
network retry must not launch a second process. The same key with different
argv, environment, directory, input, timeout, PTY, or output limits is rejected.
Use `remote input`, `remote signal`, `remote resize`, `remote cancel`, and
`remote close` with an exact execution ID. Canceling a watch never cancels the
process; `remote cancel` is explicit.

Use `remote shell` only when a program genuinely needs a PTY. It opens and
attaches a native shell on the daemon host; disconnecting leaves it available
for `remote attach`. The older `terminal` group remains the screen-oriented,
durable PTY interface and is often better for human interaction.

## Terminals, schedules, and policy

Daemon-owned PTYs survive client disconnects and can be reattached:

```sh
dieter terminal list --card <card-id> --format jsonl
dieter terminal create --card <card-id> --name validation --format id
dieter terminal attach <terminal-id>
dieter terminal close <terminal-id>
```

Schedule occurrence records are authoritative. Running a schedule creates a
real occurrence and may start an agent, so inspect the definition and recent
runs first. Schedule definitions and occurrence history are returned as
bounded pages (50 by default, 100 maximum); pass the opaque `NEXT PAGE` token
back with `--page-token` to continue:

```sh
dieter schedule list --project <project-id> --page-size 50 --format json
dieter schedule list --project <project-id> --page-token <token> --format json
dieter schedule show <schedule-id>
dieter schedule runs <schedule-id> --page-size 50
dieter schedule runs <schedule-id> --page-token <token>
dieter schedule run <schedule-id>
dieter schedule pause <schedule-id>
dieter schedule resume <schedule-id>
```

Inspect prompt and admission policy freely. Change them only when the task asks
for that operational change:

```sh
dieter settings show
dieter settings options
dieter prompt show
dieter prompt preview --card <card-id>
```

Screen sharing uses explicit daemon policy plus WebRTC signaling. Check
`dieter screen capabilities` and `dieter screen settings`; do not enable capture
or control, start a session, restart/shut down a machine, revoke enrollment, or
delete data without explicit authorization.

## Command discipline

- Inside the Dieter repository, use `just daemon build`, `just daemon test`,
  and `just gateway build` for component development. `just daemon run` and
  `just gateway run` stay in the foreground and never manage an installed
  service.
- Run `dieter help <group> <action>` or append `--help` before unfamiliar
  mutations. Every command provides offline help.
- Prefer exact IDs and `--format jsonl`, `--format json`, or `--format ids` for
  automation. Streaming commands emit JSON Lines.
- Use global `--timeout` for slow unary operations. Watch, attach, and signaling
  commands run until completion, count, or interruption.
- Never stop or replace an operator's live daemon for testing. Use isolated
  temporary daemon/gateway instances on random loopback ports.
- Never edit `DIETER_HOME` manually during normal operation.
