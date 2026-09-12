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
Use `dieter daemon status` when diagnosing this machine's process and gateway
tunnel. Its `gatewayLastAcknowledgedAt` value is bidirectional liveness proof;
a reconnect affects relay transports only and does not stop a running agent.

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
Use `dieter machine gateway` for the running gateway build identity and
`dieter --machine <machine-id> machine info` for live CPU, memory, process, and
optional Apple/NVIDIA/AMD GPU telemetry. Optional GPU fields are omitted when a
driver cannot provide them; zero remains a real measurement.

Machine restart, shutdown, and daemon update require the exact confirmation
phrases shown by `--help` and are available only when the target daemon reports
the matching capability. Linux power control is non-interactive
systemd-logind/PolicyKit; never attempt to provide sudo or an administrator
password through Dieter. Automatic daemon update currently supports only a
Homebrew-managed macOS service:

```sh
dieter --machine <machine-id> machine update --confirm UPDATE
```

The update is detached, non-interactive, and logged on the target under
`DIETER_HOME/logs/update.log`; a transport disconnect does not imply failure
because the daemon service intentionally restarts and reconnects.

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

When `--effort` is omitted for a new card or chat, Dieter uses that model's
`defaultEffort` from the harness registry. Pass `--effort default` to defer to
the provider's native default instead.

Use `card poll` for one bounded update and `card watch` for JSON Lines streaming.
Fetch a large tool payload separately with `card tool-output` when the transcript
contains only its bounded preview.

To show a deliverable in the conversation's native workspace pane, call the
`present_content` harness tool or the explicit daemon command:

```sh
dieter card present <card-id> --path docs/plan.md --title "Implementation plan"
dieter card present <card-id> --path src/main.go --line 42
dieter chat present <chat-id> --url https://example.com
```

The tool is bound to its current conversation. CLI commands require an exact
conversation ID; global `--machine` selects its owning daemon. File paths resolve
in that conversation's worktree, not the CLI machine or another project checkout.
Absolute paths within that worktree are accepted and normalized. Files must be
regular, at most 5 MiB, and cannot escape through symlinks or access `.git`.
URLs must use HTTP(S) without embedded credentials. `--line` is one-based and
applies only to files; `--title` is optional, at most 256 characters.

Presentation persists the latest typed request and returns its ID. Native
clients open or focus the appropriate content tab when they consume it. This
does not send a message, resume an agent, or guarantee the user viewed it.
Ordinary links in transcript text never trigger presentation automatically.

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
dieter board create --project <project-id> --name Delivery --workflow review \
  --base-remote origin --remote-publish pull_request
dieter board git --base-remote private --remote-publish push_base <board-id>
dieter card create --project <project-id> --board <board-id> \
  --lane todo --title "Implement recovery" --prompt-file task.md \
  --workspace worktree --format id

# Story-only quick task: GPT Spark generates a 4–6 word persisted title while
# the normal card defaults remain unchanged.
dieter card create --project <project-id> --board <board-id> \
  --lane todo --auto-title --prompt "Add keyboard navigation" \
  --workspace worktree --format id
```

Harness-defined options use repeatable `--provider-option KEY=VALUE` flags.
For example, Codex chats and tasks using GPT-5.4, GPT-5.5, GPT-5.6, or GPT-6
Astra can select Fast mode with `--provider-option fast_mode=true`; schedules
accept the same option and apply it to every task they create. GPT-5.3 Codex
and Spark do not support this option.

`card start` admits a draft's first turn. `card send` admits a human follow-up.
Both return without waiting for the agent to finish. Do not replay either just
because the client disconnected; inspect the card and conversation first.
Messages sent during an active turn are queued in order. Remove one that has
not started yet—and receive its complete text and attachments as JSON—with:

```sh
dieter card queue remove --message <message-id> <card-id>
```

For an existing card or chat, `send --model MODEL --effort EFFORT` changes the
next message's selection within the same provider when its harness advertises
`model-selection` / `effort-selection` with level `between-turns`. Codex,
Claude Code and Pi support both; OMP and DSH support model changes. OMP's
thinking level stays fixed after the first message. Mutable options such as
Codex `--provider-option fast_mode=true` apply to the next message too.
`--effort default` explicitly resets reasoning; omitting effort retains the
current value for the same model and uses the configured default after a model
change. Queued messages retain separate durable selections, and removing one
returns `selection` alongside its text and attachments for editing. Neither
selection changes nor queued messages reconfigure an already running turn.

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

Inspect local, uncommitted Git state through exactly one scope. A worktree
conversation is addressed by card ID. The registered project directory is
addressed by `--project`; a project-mode card is intentionally rejected because
that checkout is shared rather than owned by the card:

```sh
dieter workspace show <card-id>
dieter workspace changes <worktree-card-id>
dieter workspace diff --section unstaged --path path/to/file.go <worktree-card-id>
dieter workspace changes --project <project-id-or-name>
dieter workspace diff --project <project-id-or-name> \
  --section staged --path path/to/file.go
dieter workspace comments <card-id>
dieter workspace scm <card-id>
```

`changes` separates the staged index from unstaged/untracked working-tree
edits. A path can appear in both sections. `diff --section` accepts `staged`,
`unstaged`, or `combined`; always carry the newest returned revision into a
mutation.

Git operations are daemon-owned, serialized, and durable. Supply the expected
revision where the operation depends on the changeset, and repeat `--param` for
kind-specific values:

```sh
dieter workspace run --kind stage --project <project-id-or-name> \
  --revision <revision> --param path=path/to/file.go --wait
dieter workspace run --kind commit --project <project-id-or-name> \
  --revision <revision> --param subject="Focused change" --wait
dieter workspace run --kind validate --wait <worktree-card-id>
dieter workspace operation <operation-id>
dieter workspace watch <operation-id>
```

Project targets support `stage`, `unstage`, `discard_changes`, `commit`, and
`validate`. An empty stage/unstage path means all files; `discard_changes`
requires one path and creates recovery artifacts first. `commit` commits only
the staged index unless `--param stage_all=true` is explicitly supplied.
Worktree targets additionally support `update`, `continue_conflict`,
`abort_conflict`, `merge_local`, `push`, `cleanup`, `discard`, `adopt`,
`create_pr`, `refresh_pr`, and `merge_pr`. Inspect help and current state before
destructive or externally visible Git operations.

New board cards snapshot the board's configured remote and publish mode. The
`manual` mode preserves explicit local merge, branch push, and PR choices;
`pull_request` prevents a local base merge; and `push_base` publishes the
validated integration result to the configured base branch during
`merge_local`. Existing conversations keep their snapshotted values.

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

## Task token usage

`dieter card show CARD` returns `card.tokenUsage`; `dieter card context CARD`
returns `tokenUsage`. JSON card/chat listings include the same summary without
fetching transcripts. Fields are `inputTokens`, `outputTokens`, `totalTokens`,
`reportedMessages`, `missingMessages`, and `partial`. Treat partial counts as
incomplete provider data. Copied fork history and separate subagent counters
are excluded; the summary is not a billing estimate.

### Merge a card's request into another task

`dieter card merge --into TARGET CARD` queues the source card's initial request
and attachments in a started target on the same board, moves the idle source to
Done, and saves its `mergedIntoCardId` link. The source must have no active turn
or queued messages. Retrying the same merge is safe. Both conversations and
workspaces are retained; this operation does not merge Git branches.

On macOS, drag a card over a started task and hold for two seconds. A merge icon
and “Release to merge request” appear; dropping then performs the merge.
Dropping earlier keeps the usual card ordering behavior.

Draft agent settings can be changed in Edit card or with
`dieter card update --provider codex --model MODEL --effort high --provider-option fast_mode=true CARD`.
Settings are locked once the initial request has been sent. These commands also
support the global `--machine ID|NAME` option for direct TLS or gateway relay.

### Browser capture project routing

Agents can maintain browser host mappings, with optional ports, on a project
through the daemon:

```sh
dieter project update --hostname app.example.com --hostname localhost:4018 PROJECT_ID
dieter project show PROJECT_ID
dieter project update --clear-hostnames PROJECT_ID
```

`--hostname` is repeatable and replaces the complete list; omitting both hostname
flags preserves it. Use `--machine ID|NAME` for projects on another daemon.
Mappings are stored centrally with project metadata. CLI inputs accept DNS names
(punycode for international names) or IPv4 addresses, optionally followed by
`:port`. Use bare IPv6 addresses for host-only mappings and brackets for an IPv6
address with a port, such as `'[::1]:4018'`. Ports must be numeric and between 1
and 65535. Hostnames are lowercased and trailing dots removed; IP addresses and
ports are canonicalized. The list is deduplicated, sorted, and limited to 64
entries. CLI inputs cannot contain URLs, paths, or wildcards; subdomains require
their own entries.

Capture task checks board mappings before mappings on active projects. Within each scope,
an exact host-and-port match wins; if none exists, a bare-host mapping matches
that host on any port. Matching uses the URL's explicit port, or port 80 for HTTP
and 443 for HTTPS when omitted. For example, `localhost:4018` takes priority over
`localhost` within board mappings. Multiple equally specific destinations require
a manual choice; no match also asks for a destination. The user still reviews
and submits the Quick Task. Mappings do not grant access to a website or start
any task.

Board hostname mappings take priority over project mappings for Capture task.
Users can edit URLs/host mappings in Board settings or remember a captured URL's
host mapping for the selected board when saving a Quick Task. Global Quick Task is
available in the sidebar and always shows project and board selectors. Unmatched
or ambiguous captures stage a draft with no destination until the user chooses.
Tasks are saved as drafts; capture does not start an agent.

```sh
dieter board hostnames --hostname localhost:4018 --hostname '[::1]:4018' BOARD_ID
dieter board hostnames --append --hostname preview.example.com BOARD_ID
dieter board hostnames --clear BOARD_ID
dieter board show BOARD_ID
```

The default replaces the full list; `--append` adds atomically and deduplicates.
CLI inputs use the host or host-and-port format above. Board settings also accepts
HTTP(S) URLs and stores their hostname plus an explicit port when present. The
same normalization, matching rules, and 64-entry limit apply.
