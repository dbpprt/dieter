---
# Generated: regenerate the body with
#   go run ./tools/clidocs -o site/content/docs/reference/cli.md
# then restore this front matter and drop the generator's "# Dieter CLI reference" heading.
title: "CLI reference"
linkTitle: "CLI reference"
description: "Every dieter command and its offline help, generated from the CLI's command table."
group: "Reference"
weight: 46
slug: "cli-reference"
searchHeadingsOnly: true
---

For task-oriented examples, start with the [CLI guide](/docs/cli/). Run
`dieter help COMMAND [ACTION]` for the help of the release you have installed.

Generated from the CLI command table by `go run ./tools/clidocs`. Every
section is the command's offline `--help` output.

## dieter

```text
Dieter — control local or enrolled Dieter daemon machines

Usage:
  dieter [global options] <command> [options]

Global options:
  --store PATH             DIETER_HOME (default ~/.dieter)
  --gateway URL            Require this enrolled gateway origin
  --machine ID|NAME        Target an enrolled daemon; omit for the local daemon
  --timeout DURATION       Unary command and connection timeout (default 15s)
  --harness-config PATH    Local daemon harness registry YAML
  --help, -h               Show this help
  --version                Print the version

Commands:
  machine      List, route, rename, revoke, inspect, control, or privately lock machines
  status       Show target daemon health, runtime, route, and state counts
  harness      List target daemon harnesses, models, and options
  quota        Show, summarize, refresh, and reset provider-account quotas
  project      Create, browse, map hostnames, relocate, archive, and restore projects
  board        Manage boards, retirement/restore, hostnames, workflows, and labels
  card         Create, edit, read, present files, merge, and manage board conversations
  chat         Manage standalone conversations and present files or URLs
  workspace    Inspect changes and run durable Git/SCM operations
  file         Browse, edit, copy and sync project/workspace files
  terminal     Create, attach, control, and close daemon-host PTYs
  remote       Run resumable commands and native shells on a daemon host
  screen       Share screens/clipboard, configure virtual displays, inspect latency
  schedule     Create, preview, dispatch, pause, and inspect schedules
  kv           Shared portable JSON, ordering, and live account subscriptions
  vault        End-to-end encrypted passwords and TOTP shared by your machines
  peer         Inspect and edit account peer settings (leaderless sync)
  settings     Inspect and update prompt and daemon settings
  prompt       Inspect, update, scope, and preview prompt templates
  watch        Stream this machine's change frames as JSON Lines
  storage      Print the target daemon's central storage path
  doctor       Check local Linux/macOS runtime and service prerequisites
  setup        Authorize, enroll, and install the daemon and macOS privacy helper
  daemon       Start, enroll, recover, inspect, or manage this local daemon service
  serve        Alias for "dieter daemon start"
  version      Print the version

Without --machine, operational commands use the running local daemon API. With
--machine, the CLI uses the local daemon's enrollment to authenticate to the
gateway, prefers direct TLS, then tries WebRTC (direct or TURN), and falls back
to the bounded gateway relay.
Status reports the selected route. It never reads a remote machine's storage.
Read watches renew credentials and resume after transient failures, with five
retries between delivered frames. Revocation stops recovery; mutations and
process starts are never replayed by watch recovery.

Run "dieter help <command> [action]" or append --help at any command depth.
```

## dieter machine (alias: machines)

```text
Usage: dieter machine <action>

Actions:
  list [--format table|json|jsonl|ids]       List enrolled machines
  gateway                                    Show the connected gateway build
  watch [--count N]                          Stream gateway presence as JSON Lines
  show [MACHINE]                             Show gateway presence and route
  route [MACHINE]                            Inspect direct routes and relay channel health
  privacy <status|setup|on|off> [--key ID]    Control macOS local display/input privacy
  info [MACHINE]                             Show live host telemetry (local by default)
  rename --name NAME [MACHINE]               Rename an enrolled machine
  revoke --confirm MACHINE_ID [MACHINE]       Revoke an enrolled machine
  restart --confirm RESTART [MACHINE]
  shutdown --confirm "SHUT DOWN" [MACHINE]
  update --confirm UPDATE [MACHINE]           Update a managed daemon service
  rtc [MACHINE]                              Get signed WebRTC configuration
  connection <start|show|close>               Manage data-only WebRTC signaling

Pass MACHINE or global --machine to select a remote daemon. Info, restart, and
shutdown and update target the local daemon when MACHINE is omitted. Update is
non-interactive and available to Homebrew-managed macOS services and
Dieter-managed Linux systemd user services.
```

### dieter machine list

```text
Usage: dieter machine list [--format table|json|jsonl|ids]
```

### dieter machine gateway

```text
Usage: dieter machine gateway
```

### dieter machine watch

```text
Usage: dieter machine watch [--count N]
```

### dieter machine show

```text
Usage: dieter machine show [options] [MACHINE]
```

### dieter machine route

```text
Usage: dieter machine route [options] [MACHINE]
```

### dieter machine info

```text
Usage: dieter machine info [options] [MACHINE]
```

### dieter machine rename

```text
Usage: dieter machine rename [options] [MACHINE]
```

### dieter machine revoke

```text
Usage: dieter machine revoke [options] [MACHINE]
```

### dieter machine restart

```text
Usage: dieter machine restart [options] [MACHINE]
```

### dieter machine shutdown

```text
Usage: dieter machine shutdown [options] [MACHINE]
```

### dieter machine update

```text
Usage: dieter machine update [options] [MACHINE]
```

### dieter machine rtc

```text
Usage: dieter machine rtc [options] [MACHINE]
```

### dieter machine connection

```text
Usage: dieter machine connection <start|show|close> [options]

Inspect or manage data-only WebRTC signaling on the selected daemon.
Use --machine ID|NAME for a remote daemon. Normal commands select WebRTC automatically.
start requires protobuf JSON containing rtcConfiguration and offerSdp.
```

### dieter machine connection start

```text
Usage: dieter machine connection start [--request FILE] [SESSION]

Start with a signed RTC configuration and gathered SDP offer; show reports the
selected ICE mode (direct or turn); close disconnects only this transport.
```

### dieter machine connection show

```text
Usage: dieter machine connection show [--request FILE] [SESSION]

Start with a signed RTC configuration and gathered SDP offer; show reports the
selected ICE mode (direct or turn); close disconnects only this transport.
```

### dieter machine connection close

```text
Usage: dieter machine connection close [--request FILE] [SESSION]

Start with a signed RTC configuration and gathered SDP offer; show reports the
selected ICE mode (direct or turn); close disconnects only this transport.
```

### dieter machine privacy

```text
Usage: dieter [--machine ID|NAME] machine privacy <status|setup|on|off> [--key ID]

Black out local displays and block physical input while agents and remote control continue.
Setup registers the privileged input helper; approve it and grant Input Monitoring on the target Mac.
Requires macOS Accessibility permission. Stays on across disconnects and daemon restarts;
unlock explicitly or reboot to clear. This is session privacy, not an authentication lock.
```

### dieter machine privacy status

```text
Usage: dieter [--machine ID|NAME] machine privacy status

Black out local displays and block physical input while agents and remote control continue.
Setup registers the privileged input helper; approve it and grant Input Monitoring on the target Mac.
Requires macOS Accessibility permission. Stays on across disconnects and daemon restarts;
unlock explicitly or reboot to clear. This is session privacy, not an authentication lock.
```

### dieter machine privacy setup

```text
Usage: dieter [--machine ID|NAME] machine privacy setup [--key ID]

Black out local displays and block physical input while agents and remote control continue.
Setup registers the privileged input helper; approve it and grant Input Monitoring on the target Mac.
Requires macOS Accessibility permission. Stays on across disconnects and daemon restarts;
unlock explicitly or reboot to clear. This is session privacy, not an authentication lock.
```

### dieter machine privacy on

```text
Usage: dieter [--machine ID|NAME] machine privacy on [--key ID]

Black out local displays and block physical input while agents and remote control continue.
Setup registers the privileged input helper; approve it and grant Input Monitoring on the target Mac.
Requires macOS Accessibility permission. Stays on across disconnects and daemon restarts;
unlock explicitly or reboot to clear. This is session privacy, not an authentication lock.
```

### dieter machine privacy off

```text
Usage: dieter [--machine ID|NAME] machine privacy off [--key ID]

Black out local displays and block physical input while agents and remote control continue.
Setup registers the privileged input helper; approve it and grant Input Monitoring on the target Mac.
Requires macOS Accessibility permission. Stays on across disconnects and daemon restarts;
unlock explicitly or reboot to clear. This is session privacy, not an authentication lock.
```

## dieter status

```text
Usage: dieter status [--format table|json]
```

## dieter harness (alias: harnesses)

```text
Usage: dieter harness list [--format table|json|jsonl|ids]
```

### dieter harness list

```text
Usage: dieter harness list [--format table|json|jsonl|ids]
```

## dieter quota (alias: quotas)

```text
Usage: dieter quota <action>

Actions:
  list [PROVIDER] [--format table|json|jsonl]  List account quotas and provider summaries
  watch [PROVIDER] [--count N]                Stream quota updates as JSON Lines
  refresh [PROVIDER] [--account KEY]          Request a bounded refresh and show the result
  include PROVIDER --account KEY              Include an account in its header summary
  exclude PROVIDER --account KEY              Exclude an account from its header summary
  reset openai --account KEY --confirm RESET  Consume one available reset credit

PROVIDER is openai, codex, or claude. Quotas are gateway-account scoped and
combine accounts discovered by all online enrolled machines. Summary values
show the lowest remaining window; separate account quotas are never summed.
```

### dieter quota list

```text
Usage: dieter quota list [PROVIDER] [--format table|json|jsonl]
```

### dieter quota watch

```text
Usage: dieter quota watch [PROVIDER] [--count N]
```

### dieter quota refresh

```text
Usage: dieter quota refresh [PROVIDER] [--account KEY] [--format table|json]

Claude refresh respects its five-minute polling interval and ten-minute failure cooldown.
```

### dieter quota include

```text
Usage: dieter quota include PROVIDER --account KEY
```

### dieter quota exclude

```text
Usage: dieter quota exclude PROVIDER --account KEY
```

### dieter quota reset

```text
Usage: dieter quota reset openai --account KEY --confirm RESET
```

## dieter project (alias: projects)

```text
Usage: dieter project <action>

Actions:
  consolidate SOURCE DESTINATION  Combine project identities; retain all boards and owners
  attach PROJECT PATH  Attach this machine’s checkout to an existing shared project
  checkouts PROJECT    List checkouts across machines
  detach CHECKOUT      Detach a local checkout
  create PATH       Create and register a Git working tree on the target daemon
  open PATH         Register an existing Git working tree on the target daemon
  directories PATH  Browse daemon-host directories and Git repositories
  list              List active projects; use --removed for archived projects
  show PROJECT      Show project metadata
  update PROJECT    Update project path, name, summary, prompt, or browser hostnames
  workspace PROJECT Update Git base and validation commands
  remove PROJECT    Archive a project
  restore PROJECT   Restore an archived project
```

### dieter project create

```text
Usage: dieter project create [options] PATH

Options:
  --operation-id ID           Reuse for a safe retry of project creation
  --name NAME                 Project display name
  --summary TEXT              Project summary
  --prompt TEXT               Project instructions
  --prompt-file FILE          Read project instructions from FILE or -
  --board-name NAME           Initial board name (default Main)
  --workflow direct|review    Initial board workflow
  --base-remote REMOTE        Git base remote
  --base-branch BRANCH        Git base branch
  --validation-file FILE      Validation command JSON
  --format json|id            Output format
```

### dieter project open

```text
Usage: dieter project open [options] PATH

Options:
  --operation-id ID           Reuse for a safe retry of project creation
  --name NAME                 Project display name
  --summary TEXT              Project summary
  --prompt TEXT               Project instructions
  --prompt-file FILE          Read project instructions from FILE or -
  --board-name NAME           Initial board name (default Main)
  --workflow direct|review    Initial board workflow
  --base-remote REMOTE        Git base remote
  --base-branch BRANCH        Git base branch
  --validation-file FILE      Validation command JSON
  --format json|id            Output format
```

### dieter project directories

```text
Usage: dieter project directories [PATH]
```

### dieter project list

```text
Usage: dieter project list [--removed] [--format table|json|jsonl|ids]
```

### dieter project show

```text
Usage: dieter project show PROJECT
```

### dieter project update

```text
Usage: dieter project update [--path PATH] [--name NAME] [--summary TEXT] [--prompt TEXT|--prompt-file FILE] [--hostname HOST[:PORT] ...|--clear-hostnames] PROJECT

Repeat --hostname to replace the complete list of exact browser hosts or host:port mappings.
Ports are 1-65535; use brackets for IPv6 ports, for example '[::1]:4018'. No URL, path, or wildcard.
Capture tries board mappings before project mappings. Within each scope, an exact port wins,
then a bare host is the fallback; HTTP and HTTPS default to ports 80 and 443.
Use --clear-hostnames to remove all mappings; omit both flags to preserve them.
```

### dieter project workspace

```text
Usage: dieter project workspace [--base-remote REMOTE] [--base-branch BRANCH] [--validation-file FILE --checkout ID] PROJECT
```

### dieter project remove

```text
Usage: dieter project remove PROJECT
```

### dieter project restore

```text
Usage: dieter project restore PROJECT
```

### dieter project consolidate

```text
Usage: dieter project consolidate SOURCE DESTINATION
Keep destination project defaults and retain every source board, label, checkout, and conversation with its existing ID and machine owner. Source references become durable redirects.
```

### dieter project attach

```text
Usage: dieter project attach [--name NAME] PROJECT PATH
Attach an existing Git working tree on the selected machine to a shared project.
```

### dieter project detach

```text
Usage: dieter project detach CHECKOUT
Detach a checkout on the selected machine without deleting project or conversation data.
```

### dieter project checkouts

```text
Usage: dieter project checkouts PROJECT
List the shared checkout directory; paths are shown only for the selected machine.
```

## dieter board (alias: boards)

```text
Usage: dieter board <action>

  hostnames BOARD  Replace, append, or clear exact browser hosts

Actions:
  create              Create a fixed direct or review workflow board
  list                List boards
  show BOARD           Show one board
  retire BOARD         Retire an empty board without deleting its records
  restore BOARD        Restore a retired board by exact ID
  rename BOARD         Rename a board
  retention BOARD      Configure automatic Done-card archiving
  git BOARD            Configure the default remote and publishing mode
  label add            Create a board label
  label list           List board labels
  label update LABEL   Update label name, color, or instructions
  label remove LABEL   Delete a board label
```

### dieter board retire

```text
Usage: dieter board retire --revision REV --operation ID BOARD

Use an exact board ID and its retirementRevision from board show. Retirement refuses active, archived, pending card or schedule references. Records and labels are retained; restore is reversible. A late peer reference makes retirement blocked and the board visible.
The operation ID is a durable local replay receipt: retry identical input only on the same daemon. Success means local durability, not acknowledgement by every replica.
```

### dieter board restore

```text
Usage: dieter board restore --revision REV --operation ID BOARD

Use an exact board ID and its retirementRevision from board show. Retirement refuses active, archived, pending card or schedule references. Records and labels are retained; restore is reversible. A late peer reference makes retirement blocked and the board visible.
The operation ID is a durable local replay receipt: retry identical input only on the same daemon. Success means local durability, not acknowledgement by every replica.
```

### dieter board hostnames

```text
Usage: dieter board hostnames [--hostname HOST[:PORT] ...] [--append|--clear] BOARD

Accepts exact hosts or host:port mappings. Replaces the complete list by default.
--append adds without replacing; --clear removes all.
Ports are 1-65535; use brackets for IPv6 ports, for example '[::1]:4018'. No URL, path, or wildcard.
Capture tries board mappings before project mappings. Within each scope, an exact port wins,
then a bare host is the fallback; HTTP and HTTPS default to ports 80 and 443.
```

### dieter board create

```text
Usage: dieter board create --project PROJECT --name NAME [--workflow direct|review] [--description TEXT] [--archive-done POLICY] [--base-remote REMOTE] [--remote-publish manual|pull_request|push_base]
```

### dieter board list

```text
Usage: dieter board list [--project PROJECT] [--retired] [--page-size N --after ID --snapshot REV] [--format table|json|jsonl|ids]

Active boards are the default. --retired returns a bounded page; JSON includes nextId and snapshotRevision for continuation.
```

### dieter board show

```text
Usage: dieter board show BOARD
```

### dieter board rename

```text
Usage: dieter board rename --name NAME BOARD
```

### dieter board retention

```text
Usage: dieter board retention --archive-done POLICY BOARD

POLICY: never, immediately, after_1_day, after_7_days, after_30_days, or after_90_days.
```

### dieter board git

```text
Usage: dieter board git [--base-remote REMOTE] [--remote-publish manual|pull_request|push_base] BOARD

manual preserves explicit Git actions, pull_request requires PR publishing, and push_base pushes validated local integrations to the configured base branch.
```

### dieter board label

```text
Usage: dieter board label <action> [options]

Actions:
  add --board BOARD --name NAME [--color COLOR] [--instructions TEXT]
  list --board BOARD
  update --board BOARD [--name NAME] [--color COLOR] [--instructions TEXT] LABEL
  remove --board BOARD LABEL
```

### dieter board label add

```text
Usage: dieter board label <action> [options]

Actions:
  add --board BOARD --name NAME [--color COLOR] [--instructions TEXT]
  list --board BOARD
  update --board BOARD [--name NAME] [--color COLOR] [--instructions TEXT] LABEL
  remove --board BOARD LABEL
```

### dieter board label list

```text
Usage: dieter board label <action> [options]

Actions:
  add --board BOARD --name NAME [--color COLOR] [--instructions TEXT]
  list --board BOARD
  update --board BOARD [--name NAME] [--color COLOR] [--instructions TEXT] LABEL
  remove --board BOARD LABEL
```

### dieter board label update

```text
Usage: dieter board label <action> [options]

Actions:
  add --board BOARD --name NAME [--color COLOR] [--instructions TEXT]
  list --board BOARD
  update --board BOARD [--name NAME] [--color COLOR] [--instructions TEXT] LABEL
  remove --board BOARD LABEL
```

### dieter board label remove

```text
Usage: dieter board label <action> [options]

Actions:
  add --board BOARD --name NAME [--color COLOR] [--instructions TEXT]
  list --board BOARD
  update --board BOARD [--name NAME] [--color COLOR] [--instructions TEXT] LABEL
  remove --board BOARD LABEL
```

## dieter card (alias: cards)

```text
Usage: dieter card <action>

Actions:
  create       Create a board conversation
  list         Search board conversations
  show         Show card metadata
  context      Print bounded agent context
  transcript   Read the durable conversation
  poll         Fetch one bounded conversation update
  watch        Stream conversation updates as JSON Lines
  tool-output  Fetch a full tool input/output payload
  present      Present a file or URL in this conversation’s native workspace pane
  fork         Fork a completed conversation into a standalone chat
  send         Submit a human message to the daemon-owned turn lifecycle
  queue        Manage messages waiting behind the active turn
  read         Mark a displayed model response as seen
  merge        Add an idle card’s initial request to a started task; mark source Done
  move         Move a card between workflow lanes
  start        Start a draft card idempotently
  labels       Replace board-label assignments
  cancel       Request cancellation of the active turn
  rename       Rename a card
  update       Update title and initial prompt
  archive      Archive a card
  unarchive    Restore a card
  workspace    Select the project directory or an isolated worktree
```

### dieter card present

```text
Usage: dieter card present (--path PATH [--line N] | --url URL) [--title TITLE] CARD

Request presentation in the exact conversation's native workspace pane.
Paths belong to its owning daemon/worktree (relative paths are recommended).
URLs must be HTTP(S). File size is limited to 5 MiB. This does not resume the
agent or guarantee that a connected client has displayed the request.
Returns the durable presentation ID and normalized target as JSON.
Global --machine selects the owning daemon through authenticated direct/relay routes.
```

### dieter card create

```text
Usage: dieter card create --project PROJECT --board BOARD (--title TITLE | --auto-title) --workspace project|worktree [options]

Options:
  --checkout CHECKOUT      Checkout on the target machine; required if it has several
  --lane todo|running       Todo creates a draft; Running starts immediately
  --auto-title              Save immediately; GPT Spark improves the title in the background
  --prompt TEXT             Initial task brief
  --prompt-file FILE        Read the task brief from FILE or -
  --attach FILE             Attach a file; repeat up to four times
  --provider HARNESS        Harness provider
  --model MODEL             Model for the first turn
  --effort EFFORT           Reasoning or thinking effort
  --provider-option K=V     Provider option; repeat as needed
  --labels LABELS           Comma-separated label IDs
  --workspace MODE          project or worktree
  --branch BRANCH           Optional worktree branch
  --base-branch BRANCH      Optional worktree base branch
  --base-remote REMOTE      Optional board/project remote override
  --remote-publish MODE     manual, pull_request, or push_base
  --vault                   Let this conversation's agent turns use the account
                            vault (fixed at creation; see dieter vault --help)
  --format json|id          Output format

Destination defaults to the running local daemon. Pass global --machine ID|NAME
before the command to create on another enrolled machine.
```

### dieter card list

```text
Usage: dieter card list [--project PROJECT] [--board BOARD] [--lane LANE] [--label LABEL] [--status STATUS] [--query TEXT] [--archived] [--limit N] [--format table|json|jsonl|ids]
```

### dieter card show

```text
Usage: dieter card show CARD

Includes cumulative provider-reported tokenUsage (input/output/total and partial coverage).
```

### dieter card context

```text
Usage: dieter card context CARD

Includes cumulative provider-reported tokenUsage (input/output/total and partial coverage).
```

### dieter card transcript

```text
Usage: dieter card transcript [--last N] [--before INDEX] CARD
```

### dieter card poll

```text
Usage: dieter card poll [--last N] [--after-seq N] CARD
```

### dieter card watch

```text
Usage: dieter card watch [--last N] [--after-seq N] [--count N] CARD

An up-to-date --after-seq receives a current metadata acknowledgment without
resending unchanged messages; this initial frame counts toward --count.

Read subscriptions renew credentials and resume from their last delivered checkpoint
after transient failures (up to five retries between frames). Revocation stops
recovery. Mutations, process starts, and stdin writes are never replayed.
```

### dieter card tool-output

```text
Usage: dieter card tool-output --message MESSAGE --tool-call TOOL [--revision REVISION] CARD
```

### dieter card fork

```text
Usage: dieter card fork [--at MESSAGE_ID] [--title TITLE] [--format json|id] CARD
```

### dieter card send

```text
Usage: dieter card send [--message TEXT|--file FILE] [--attach FILE ...] [--provider P] [--model M] [--effort E] [--provider-option K=V] CARD
Model, effort and mutable provider options apply to this message where supported.
During a running turn, the message and its selection are queued together.
The provider stays fixed after the first message. Use --effort default to reset reasoning.
```

### dieter card queue

```text
Usage: dieter card queue <action>

Actions:
  remove   Remove a message that has not started yet
```

### dieter card queue remove

```text
Usage: dieter card queue remove --message MESSAGE_ID CARD

Removes a queued message and prints its complete content as JSON.
```

### dieter card read

```text
Usage: dieter card read --response-seq SEQ CARD

Mark the displayed model response as seen. Use responseSeq from card show; stale receipts cannot clear newer replies. Also available as chat read and with global --machine.
```

### dieter card merge

```text
Usage: dieter card merge --into TARGET CARD

Queue CARD's initial request and attachments in a started target on the same board. The source must be idle with an empty queue. Move it to Done and link it to TARGET. Retries are idempotent; conversations and workspaces are preserved.
```

### dieter card move

```text
Usage: dieter card move --lane todo|running|review|done [--after CARD] [--before CARD] [--revision REV] CARD
```

### dieter card start

```text
Usage: dieter card start CARD
```

### dieter card labels

```text
Usage: dieter card labels --set LABELS CARD

LABELS is a comma-separated list of board label IDs; empty clears labels.
```

### dieter card cancel

```text
Usage: dieter card cancel CARD

Requests cancellation and returns once the active turn has been signaled.
Queued messages start after that turn finishes cleanup.
```

### dieter card rename

```text
Usage: dieter card rename --title TITLE CARD
```

### dieter card update

```text
Usage: dieter card update [--title TITLE] [--prompt TEXT|--prompt-file FILE] [--provider P] [--model M] [--effort E] [--provider-option K=V] CARD
Agent settings are editable only before the initial task is sent.
```

### dieter card archive

```text
Usage: dieter card archive CARD

Includes cumulative provider-reported tokenUsage (input/output/total and partial coverage).
```

### dieter card unarchive

```text
Usage: dieter card unarchive CARD

Includes cumulative provider-reported tokenUsage (input/output/total and partial coverage).
```

### dieter card workspace

```text
Usage: dieter card workspace --mode project|worktree [--branch BRANCH] [--base-branch BRANCH] [--base-remote REMOTE] [--remote-publish manual|pull_request|push_base] CARD
```

## dieter chat (alias: chats)

```text
Usage: dieter chat <action>

Actions:
  create, list, show, context, transcript, watch, tool-output, present, fork, send,
  queue, read, cancel, rename, update, archive, unarchive, workspace, pin, unpin

Standalone chats use the same durable conversation and workspace operations as
cards but are not assigned to a board lane.
```

### dieter chat present

```text
Usage: dieter card present (--path PATH [--line N] | --url URL) [--title TITLE] CARD

Request presentation in the exact conversation's native workspace pane.
Paths belong to its owning daemon/worktree (relative paths are recommended).
URLs must be HTTP(S). File size is limited to 5 MiB. This does not resume the
agent or guarantee that a connected client has displayed the request.
Returns the durable presentation ID and normalized target as JSON.
Global --machine selects the owning daemon through authenticated direct/relay routes.
```

### dieter chat create

```text
Usage: dieter chat create --project PROJECT (--title TITLE | --auto-title) --workspace project|worktree [options]

Options:
  --checkout CHECKOUT      Checkout on the target machine; required if it has several
  --lane todo|running       Todo creates a draft; Running starts immediately
  --auto-title              Save immediately; GPT Spark improves the title in the background
  --prompt TEXT             Initial task brief
  --prompt-file FILE        Read the task brief from FILE or -
  --attach FILE             Attach a file; repeat up to four times
  --provider HARNESS        Harness provider
  --model MODEL             Model for the first turn
  --effort EFFORT           Reasoning or thinking effort
  --provider-option K=V     Provider option; repeat as needed
  --labels LABELS           Comma-separated label IDs
  --workspace MODE          project or worktree
  --branch BRANCH           Optional worktree branch
  --base-branch BRANCH      Optional worktree base branch
  --base-remote REMOTE      Optional board/project remote override
  --remote-publish MODE     manual, pull_request, or push_base
  --vault                   Let this conversation's agent turns use the account
                            vault (fixed at creation; see dieter vault --help)
  --format json|id          Output format

Destination defaults to the running local daemon. Pass global --machine ID|NAME
before the command to create on another enrolled machine.
```

### dieter chat list

```text
Usage: dieter chat list [--archived] [--format table|json|jsonl|ids]
```

### dieter chat show

```text
Usage: dieter card show CARD

Includes cumulative provider-reported tokenUsage (input/output/total and partial coverage).
```

### dieter chat context

```text
Usage: dieter card context CARD

Includes cumulative provider-reported tokenUsage (input/output/total and partial coverage).
```

### dieter chat transcript

```text
Usage: dieter card transcript [--last N] [--before INDEX] CARD
```

### dieter chat poll

```text
Usage: dieter card poll [--last N] [--after-seq N] CARD
```

### dieter chat watch

```text
Usage: dieter card watch [--last N] [--after-seq N] [--count N] CARD

An up-to-date --after-seq receives a current metadata acknowledgment without
resending unchanged messages; this initial frame counts toward --count.

Read subscriptions renew credentials and resume from their last delivered checkpoint
after transient failures (up to five retries between frames). Revocation stops
recovery. Mutations, process starts, and stdin writes are never replayed.
```

### dieter chat tool-output

```text
Usage: dieter card tool-output --message MESSAGE --tool-call TOOL [--revision REVISION] CARD
```

### dieter chat fork

```text
Usage: dieter card fork [--at MESSAGE_ID] [--title TITLE] [--format json|id] CARD
```

### dieter chat send

```text
Usage: dieter card send [--message TEXT|--file FILE] [--attach FILE ...] [--provider P] [--model M] [--effort E] [--provider-option K=V] CARD
Model, effort and mutable provider options apply to this message where supported.
During a running turn, the message and its selection are queued together.
The provider stays fixed after the first message. Use --effort default to reset reasoning.
```

### dieter chat queue

```text
Usage: dieter card queue <action>

Actions:
  remove   Remove a message that has not started yet
```

### dieter chat queue remove

```text
Usage: dieter card queue remove --message MESSAGE_ID CARD

Removes a queued message and prints its complete content as JSON.
```

### dieter chat read

```text
Usage: dieter card read --response-seq SEQ CARD

Mark the displayed model response as seen. Use responseSeq from card show; stale receipts cannot clear newer replies. Also available as chat read and with global --machine.
```

### dieter chat start

```text
Usage: dieter card start CARD
```

### dieter chat labels

```text
Usage: dieter card labels --set LABELS CARD

LABELS is a comma-separated list of board label IDs; empty clears labels.
```

### dieter chat cancel

```text
Usage: dieter card cancel CARD

Requests cancellation and returns once the active turn has been signaled.
Queued messages start after that turn finishes cleanup.
```

### dieter chat rename

```text
Usage: dieter card rename --title TITLE CARD
```

### dieter chat update

```text
Usage: dieter card update [--title TITLE] [--prompt TEXT|--prompt-file FILE] [--provider P] [--model M] [--effort E] [--provider-option K=V] CARD
Agent settings are editable only before the initial task is sent.
```

### dieter chat archive

```text
Usage: dieter card archive CARD

Includes cumulative provider-reported tokenUsage (input/output/total and partial coverage).
```

### dieter chat unarchive

```text
Usage: dieter card unarchive CARD

Includes cumulative provider-reported tokenUsage (input/output/total and partial coverage).
```

### dieter chat workspace

```text
Usage: dieter card workspace --mode project|worktree [--branch BRANCH] [--base-branch BRANCH] [--base-remote REMOTE] [--remote-publish manual|pull_request|push_base] CARD
```

### dieter chat pin

```text
Usage: dieter chat pin CHAT
```

### dieter chat unpin

```text
Usage: dieter chat unpin CHAT
```

## dieter workspace (alias: workspaces, git)

```text
Usage: dieter workspace <action>

Actions:
  show CARD                 Provision and show a conversation workspace
  list [--project PROJECT]  List durable project workspaces
  changes [target]          Show local changes for a worktree card or project
  diff [target]             Read a staged, unstaged, or combined file diff
  comments CARD             List changeset review comments
  comment [options] CARD    Add a changeset review comment
  scm CARD                  Show daemon-host source-control capabilities
  operation OPERATION       Show a durable Git operation
  watch OPERATION           Stream operation and log frames as JSON Lines
  run --kind KIND [target]  Start a serialized durable Git operation
  cancel OPERATION          Request cancellation of an operation

Project targets support stage, unstage, discard_changes, commit, update,
validate, and push.
Worktree cards additionally support update, continue_conflict, abort_conflict,
validate, merge_local, push, cleanup, discard, adopt, create_pr, refresh_pr,
and merge_pr. Commit uses the staged index; pass --param stage_all=true only
when explicitly committing every local change. Repeat --param KEY=VALUE for
kind-specific parameters.
```

### dieter workspace show

```text
Usage: dieter workspace show CARD
```

### dieter workspace list

```text
Usage: dieter workspace list --project PROJECT
```

### dieter workspace changes

```text
Usage: dieter workspace changes [--project PROJECT] [CARD]
```

### dieter workspace diff

```text
Usage: dieter workspace diff --path PATH [--project PROJECT] [--section combined|staged|unstaged] [--revision REVISION] [--commit SHA] [--offset N] [--limit N] [CARD]
```

### dieter workspace comments

```text
Usage: dieter workspace comments [--revision REVISION] CARD
```

### dieter workspace comment

```text
Usage: dieter workspace comment --path PATH --revision REVISION --message TEXT [--side new|old] [--line N] [--author NAME] [--commit SHA] CARD
```

### dieter workspace scm

```text
Usage: dieter workspace scm CARD
```

### dieter workspace operation

```text
Usage: dieter workspace operation OPERATION
```

### dieter workspace watch

```text
Usage: dieter workspace watch [--after SEQUENCE] [--count N] OPERATION

Read subscriptions renew credentials and resume from their last delivered checkpoint
after transient failures (up to five retries between frames). Revocation stops
recovery. Mutations, process starts, and stdin writes are never replayed.
```

### dieter workspace run

```text
Usage: dieter workspace run --kind KIND [--project PROJECT] [--revision REVISION] [--param KEY=VALUE ...] [--wait] [CARD]
```

### dieter workspace cancel

```text
Usage: dieter workspace cancel OPERATION
```

## dieter file (alias: files)

```text
Usage: dieter file <action>

Every action accepts either --project PROJECT or --card CARD. A card scope uses
that conversation's selected project directory or isolated worktree.

Actions:
  cp SOURCE DESTINATION       Copy binary files; remote: selects the daemon scope
  sync SOURCE DESTINATION     One-way directory sync with optional --delete
  stat PATH                   Transfer metadata and optional checksum
  scan PATH                   Bounded transfer directory page
  upload ACTION               Inspect, resume protocol, or abort an upload
  list [PATH]                 List a directory
  read PATH                   Read text or binary file content
  save PATH                   Revision-checked update of an existing text file
  create PATH                 Create a file or directory
  move SOURCE DESTINATION     Move or rename a file or directory
  delete PATH                 Delete a file; directories require --recursive
```

### dieter file list

```text
Usage: dieter file list (--project PROJECT|--card CARD) [--checkout ID] [--hidden] [--format table|json|jsonl] [PATH]
```

### dieter file read

```text
Usage: dieter file read (--project PROJECT|--card CARD) [--checkout ID] [--output FILE|-] [--format content|json] PATH
```

### dieter file save

```text
Usage: dieter file save (--project PROJECT|--card CARD) [--checkout ID] (--content TEXT|--file FILE|--file -) [--revision REVISION|--revision auto] PATH
```

### dieter file create

```text
Usage: dieter file create (--project PROJECT|--card CARD) [--checkout ID] [--kind file|directory] [--content TEXT|--file FILE] PATH
```

### dieter file move

```text
Usage: dieter file move (--project PROJECT|--card CARD) [--checkout ID] SOURCE DESTINATION
```

### dieter file delete

```text
Usage: dieter file delete (--project PROJECT|--card CARD) [--checkout ID] [--recursive] PATH
```

### dieter file cp

```text
Usage: dieter file cp (--project PROJECT|--card CARD) [--checkout ID] [OPTIONS] SOURCE DESTINATION

Exactly one endpoint must start with remote:; other paths are on this CLI machine.
Remote paths are relative to the selected workspace. Directories copy their contents.
Options: --recursive (cp), --dryrun, --delete (sync only), --checksum, --size-only,
  --no-clobber, ordered --exclude GLOB / --include GLOB, --concurrency N (1..8),
  --bandwidth-limit BYTES_PER_SECOND, --no-progress, --format text|jsonl.
Sync compares size and modification time; --checksum compares SHA-256 instead.
Hidden files are included; .git and transfer partials are protected. Symlinks and
special files are unsupported. Empty directories are not copied. Delete runs only
after a complete successful scan and copy phase; excluded files are protected.
Rerun an interrupted command to resume. Uploads expire after 24 hours.
```

### dieter file sync

```text
Usage: dieter file sync (--project PROJECT|--card CARD) [--checkout ID] [OPTIONS] SOURCE DESTINATION

Exactly one endpoint must start with remote:; other paths are on this CLI machine.
Remote paths are relative to the selected workspace. Directories copy their contents.
Options: --recursive (cp), --dryrun, --delete (sync only), --checksum, --size-only,
  --no-clobber, ordered --exclude GLOB / --include GLOB, --concurrency N (1..8),
  --bandwidth-limit BYTES_PER_SECOND, --no-progress, --format text|jsonl.
Sync compares size and modification time; --checksum compares SHA-256 instead.
Hidden files are included; .git and transfer partials are protected. Symlinks and
special files are unsupported. Empty directories are not copied. Delete runs only
after a complete successful scan and copy phase; excluded files are protected.
Rerun an interrupted command to resume. Uploads expire after 24 hours.
```

### dieter file stat

```text
Usage: dieter file stat (--project PROJECT|--card CARD) [--checkout ID] [--checksum] PATH
       dieter file scan (--project PROJECT|--card CARD) [--checkout ID] [--after NAME] [--revision REV] [--page-size N] PATH
       dieter file upload <begin|chunk|show|commit|abort> [OPTIONS]

stat and scan emit protobuf JSON. scan returns a bounded directory page; carry
its revision and next name into the following request. Restart on conflict.

Upload protocol commands (JSON output):
  begin (--project PROJECT|--card CARD) [--checkout ID] --operation ID
        --revision REV|missing --size BYTES --sha256 HASH --modified-nanos NS
        [--mode 420] PATH
  chunk --offset BYTES --file FILE UPLOAD_ID
  show UPLOAD_ID
  commit UPLOAD_ID
  abort UPLOAD_ID

Chunks are at most 1 MiB; offsets must be aligned except at the end of a file.
Replay uses identical input and operation ID. Commit is idempotent. Sessions
expire after 24 hours. Use cp/sync for automatic chunking, checksums and resume.
```

### dieter file scan

```text
Usage: dieter file stat (--project PROJECT|--card CARD) [--checkout ID] [--checksum] PATH
       dieter file scan (--project PROJECT|--card CARD) [--checkout ID] [--after NAME] [--revision REV] [--page-size N] PATH
       dieter file upload <begin|chunk|show|commit|abort> [OPTIONS]

stat and scan emit protobuf JSON. scan returns a bounded directory page; carry
its revision and next name into the following request. Restart on conflict.

Upload protocol commands (JSON output):
  begin (--project PROJECT|--card CARD) [--checkout ID] --operation ID
        --revision REV|missing --size BYTES --sha256 HASH --modified-nanos NS
        [--mode 420] PATH
  chunk --offset BYTES --file FILE UPLOAD_ID
  show UPLOAD_ID
  commit UPLOAD_ID
  abort UPLOAD_ID

Chunks are at most 1 MiB; offsets must be aligned except at the end of a file.
Replay uses identical input and operation ID. Commit is idempotent. Sessions
expire after 24 hours. Use cp/sync for automatic chunking, checksums and resume.
```

### dieter file upload

```text
Usage: dieter file stat (--project PROJECT|--card CARD) [--checkout ID] [--checksum] PATH
       dieter file scan (--project PROJECT|--card CARD) [--checkout ID] [--after NAME] [--revision REV] [--page-size N] PATH
       dieter file upload <begin|chunk|show|commit|abort> [OPTIONS]

stat and scan emit protobuf JSON. scan returns a bounded directory page; carry
its revision and next name into the following request. Restart on conflict.

Upload protocol commands (JSON output):
  begin (--project PROJECT|--card CARD) [--checkout ID] --operation ID
        --revision REV|missing --size BYTES --sha256 HASH --modified-nanos NS
        [--mode 420] PATH
  chunk --offset BYTES --file FILE UPLOAD_ID
  show UPLOAD_ID
  commit UPLOAD_ID
  abort UPLOAD_ID

Chunks are at most 1 MiB; offsets must be aligned except at the end of a file.
Replay uses identical input and operation ID. Commit is idempotent. Sessions
expire after 24 hours. Use cp/sync for automatic chunking, checksums and resume.
```

## dieter terminal (alias: terminals)

```text
Usage: dieter terminal <action>

Actions:
  list [scope]                 List daemon-owned terminal sessions
  create [scope]               Create a PTY on the target daemon
  attach TERMINAL              Stream output and forward stdin until exit
  watch TERMINAL               Stream terminal frames as content or JSON Lines
  write --data TEXT TERMINAL   Write bytes to a running PTY
  resize --columns N --rows N TERMINAL
  rename --name NAME TERMINAL
  close TERMINAL               Stop and remove a terminal session

Create scope is exactly one of --project PROJECT, --card CARD, or --home.
--home starts in the target daemon user's home and works without a project.
```

### dieter terminal list

```text
Usage: dieter terminal list [--project PROJECT|--card CARD] [--format table|json|jsonl|ids]
```

### dieter terminal create

```text
Usage: dieter terminal create (--project PROJECT|--card CARD|--home) [--name NAME] [--shell PATH] [--directory PATH] [--columns N] [--rows N] [--format json|id]
```

### dieter terminal attach

```text
Usage: dieter terminal attach [--after SEQUENCE] [--no-input] TERMINAL
```

### dieter terminal watch

```text
Usage: dieter terminal watch [--after SEQUENCE] [--format content|jsonl] [--count N] TERMINAL

Read subscriptions renew credentials and resume from their last delivered checkpoint
after transient failures (up to five retries between frames). Revocation stops
recovery. Mutations, process starts, and stdin writes are never replayed.
```

### dieter terminal write

```text
Usage: dieter terminal write (--data TEXT|--file FILE|--file -) TERMINAL
```

### dieter terminal resize

```text
Usage: dieter terminal resize --columns N --rows N TERMINAL
```

### dieter terminal rename

```text
Usage: dieter terminal rename --name NAME TERMINAL
```

### dieter terminal close

```text
Usage: dieter terminal close TERMINAL
```

## dieter remote

```text
Usage: dieter remote <action>

Agent-oriented remote execution uses exact argv values, explicit exit status,
separate stdout/stderr, bounded resumable output, and optional PTY input. Every
action honors global --machine and uses verified direct TLS before relay.

Actions:
  exec SCOPE -- COMMAND [ARG...]     Run exact argv and wait for its exit
  shell SCOPE                        Open and attach a native remote PTY shell
  list [SCOPE]                       List retained executions
  show EXECUTION                     Show execution state
  watch EXECUTION                    Resume output from a sequence
  wait EXECUTION                     Wait for exit and propagate its exit code
  attach EXECUTION                   Watch output and forward stdin
  input EXECUTION                    Write bounded stdin bytes or EOF
  signal EXECUTION                   Send interrupt, terminate, kill, or hangup
  resize EXECUTION                   Resize a PTY execution
  cancel EXECUTION                   Gracefully terminate an execution
  close EXECUTION                    Stop and remove an execution

SCOPE is exactly one of --project PROJECT or --card CARD. Use IDs rather than
names in automation. A disconnected watch never cancels the remote process.
Output subscriptions renew credentials and resume after transient failures, with
five retries between delivered frames. Recovery never repeats process starts or
stdin writes; revoked credentials stop recovery.
Use exec --card CARD --detach to register a background process in that
conversation's native Processes workspace tab. Its output remains available
after the agent turn or tab closes; only explicit stop/timeout/daemon shutdown
ends it. The harness start_background_process tool uses the same execution API.
```

### dieter remote exec

```text
Usage: dieter remote exec (--project PROJECT|--card CARD) [--checkout ID] [options] -- COMMAND [ARG...]

Options: --name NAME --directory PATH --env KEY=VALUE --input TEXT --input-file FILE|- --stdin --keep-input --timeout DURATION --idempotency-key KEY --pty --columns N --rows N --max-output BYTES --detach --format content|jsonl|json|id
```

### dieter remote shell

```text
Usage: dieter remote shell (--project PROJECT|--card CARD) [--checkout ID] [--name NAME] [--shell PATH] [--directory PATH] [--env KEY=VALUE] [--columns N] [--rows N] [--timeout DURATION] [--idempotency-key KEY] [--detach] [--format content|jsonl|json|id]
```

### dieter remote list

```text
Usage: dieter remote list [--project PROJECT|--card CARD] [--status STATUS] [--format table|json|jsonl|ids]
```

### dieter remote show

```text
Usage: dieter remote show EXECUTION
```

### dieter remote watch

```text
Usage: dieter remote watch [--after SEQUENCE] [--format content|jsonl] [--count N] EXECUTION

Read subscriptions renew credentials and resume from their last delivered checkpoint
after transient failures (up to five retries between frames). Revocation stops
recovery. Mutations, process starts, and stdin writes are never replayed.
```

### dieter remote wait

```text
Usage: dieter remote wait [--after SEQUENCE] [--format content|jsonl] EXECUTION

Read subscriptions renew credentials and resume from their last delivered checkpoint
after transient failures (up to five retries between frames). Revocation stops
recovery. Mutations, process starts, and stdin writes are never replayed.
```

### dieter remote attach

```text
Usage: dieter remote attach [--after SEQUENCE] [--format content|jsonl] EXECUTION

Read subscriptions renew credentials and resume from their last delivered checkpoint
after transient failures (up to five retries between frames). Revocation stops
recovery. Mutations, process starts, and stdin writes are never replayed.
```

### dieter remote input

```text
Usage: dieter remote input [--data TEXT|--file FILE|-] [--eof] EXECUTION
```

### dieter remote signal

```text
Usage: dieter remote signal --signal interrupt|terminate|kill|hangup EXECUTION
```

### dieter remote resize

```text
Usage: dieter remote resize --columns N --rows N EXECUTION
```

### dieter remote cancel

```text
Usage: dieter remote cancel EXECUTION
```

### dieter remote close

```text
Usage: dieter remote close EXECUTION
```

## dieter screen (alias: screens)

```text
Usage: dieter screen <action>

Actions:
  capabilities                 Inspect displays, codecs, permissions, and readiness
  permissions [--request-control] Probe capture and input permission through the daemon
  start --request FILE         Start WebRTC signaling; stream daemon signals as JSON Lines
  signal --file FILE           Send one trickle ICE/heartbeat signal to a session
  sessions                     List viewers, controller, and capture resources
  control take|release SESSION  Transfer or release control
  status SESSION               Show current stream configuration and performance
  configure SESSION [options]  Change display, quality and stream ceilings live
  virtual ACTION SESSION       Experimental virtual desktop: status, set, presented, restore
  resolution ACTION SESSION    Experimental physical desktop modes: modes, set, restore
  refresh SESSION              Request a fresh keyframe, including an idle screen
  clipboard ACTION SESSION     Read, write, copy, paste, or toggle clipboard sharing
  close SESSION                Close a remote-desktop session

Hosting is automatically available when the required OS permissions are granted.
Use "dieter daemon permissions" on the host for guided setup; capabilities reports
ready, permission required, or unsupported. There is no enable/disable setting.

"start" accepts protobuf JSON from FILE or stdin (-). It can also consume
additional RemoteDesktopSignal JSON Lines from --signal-input FILE while the
daemon response stream remains open. Use "dieter machine rtc" to obtain signed
ICE configuration for remote sessions. Media and encrypted control travel over
the negotiated WebRTC connection, never through the CLI RPC transport.
Configure supports 1–120 fps; above 60 fps geometry is capped at 1920x1080.
Check capabilities.maxFps for older hosts. Motion trades pixels before cadence;
auto/detail preserve their cadence-first policy. All limits are adaptive.
```

### dieter screen virtual

```text
Usage: dieter screen virtual <status|set|presented|restore> SESSION [options]

Experimental macOS virtual desktop, owned by the controlling session.
Enable DIETER_SCREEN_VIRTUAL_DISPLAY=1 on the host before starting its daemon.
set requires --width PIXELS --height PIXELS [--scale 1|2] [--disable-physical].
Dimensions must fit H.264 3840x2160 or HEVC 1920x1080, with even logical pixels.
The actual host desktop changes. Only one controlling session can own it.
presented requires --display ID --generation N: send ONLY after rendering a frame
from that exact display/media generation. An unseen desktop restores after 15s.
Physical disabling additionally requires DIETER_SCREEN_VIRTUAL_DISABLE=1 and
hardware qualification; the physical main is disabled only after presentation.
restore re-enables physical output before removing the virtual display. Control
handoff, disconnect, helper failure, and local display changes also restore it.
Supports local, verified direct TLS, and gateway relay with --machine ID|NAME.
```

### dieter screen virtual status

```text
Usage: dieter screen virtual <status|set|presented|restore> SESSION [options]

Experimental macOS virtual desktop, owned by the controlling session.
Enable DIETER_SCREEN_VIRTUAL_DISPLAY=1 on the host before starting its daemon.
set requires --width PIXELS --height PIXELS [--scale 1|2] [--disable-physical].
Dimensions must fit H.264 3840x2160 or HEVC 1920x1080, with even logical pixels.
The actual host desktop changes. Only one controlling session can own it.
presented requires --display ID --generation N: send ONLY after rendering a frame
from that exact display/media generation. An unseen desktop restores after 15s.
Physical disabling additionally requires DIETER_SCREEN_VIRTUAL_DISABLE=1 and
hardware qualification; the physical main is disabled only after presentation.
restore re-enables physical output before removing the virtual display. Control
handoff, disconnect, helper failure, and local display changes also restore it.
Supports local, verified direct TLS, and gateway relay with --machine ID|NAME.
```

### dieter screen virtual set

```text
Usage: dieter screen virtual <status|set|presented|restore> SESSION [options]

Experimental macOS virtual desktop, owned by the controlling session.
Enable DIETER_SCREEN_VIRTUAL_DISPLAY=1 on the host before starting its daemon.
set requires --width PIXELS --height PIXELS [--scale 1|2] [--disable-physical].
Dimensions must fit H.264 3840x2160 or HEVC 1920x1080, with even logical pixels.
The actual host desktop changes. Only one controlling session can own it.
presented requires --display ID --generation N: send ONLY after rendering a frame
from that exact display/media generation. An unseen desktop restores after 15s.
Physical disabling additionally requires DIETER_SCREEN_VIRTUAL_DISABLE=1 and
hardware qualification; the physical main is disabled only after presentation.
restore re-enables physical output before removing the virtual display. Control
handoff, disconnect, helper failure, and local display changes also restore it.
Supports local, verified direct TLS, and gateway relay with --machine ID|NAME.
```

### dieter screen virtual presented

```text
Usage: dieter screen virtual <status|set|presented|restore> SESSION [options]

Experimental macOS virtual desktop, owned by the controlling session.
Enable DIETER_SCREEN_VIRTUAL_DISPLAY=1 on the host before starting its daemon.
set requires --width PIXELS --height PIXELS [--scale 1|2] [--disable-physical].
Dimensions must fit H.264 3840x2160 or HEVC 1920x1080, with even logical pixels.
The actual host desktop changes. Only one controlling session can own it.
presented requires --display ID --generation N: send ONLY after rendering a frame
from that exact display/media generation. An unseen desktop restores after 15s.
Physical disabling additionally requires DIETER_SCREEN_VIRTUAL_DISABLE=1 and
hardware qualification; the physical main is disabled only after presentation.
restore re-enables physical output before removing the virtual display. Control
handoff, disconnect, helper failure, and local display changes also restore it.
Supports local, verified direct TLS, and gateway relay with --machine ID|NAME.
```

### dieter screen virtual restore

```text
Usage: dieter screen virtual <status|set|presented|restore> SESSION [options]

Experimental macOS virtual desktop, owned by the controlling session.
Enable DIETER_SCREEN_VIRTUAL_DISPLAY=1 on the host before starting its daemon.
set requires --width PIXELS --height PIXELS [--scale 1|2] [--disable-physical].
Dimensions must fit H.264 3840x2160 or HEVC 1920x1080, with even logical pixels.
The actual host desktop changes. Only one controlling session can own it.
presented requires --display ID --generation N: send ONLY after rendering a frame
from that exact display/media generation. An unseen desktop restores after 15s.
Physical disabling additionally requires DIETER_SCREEN_VIRTUAL_DISABLE=1 and
hardware qualification; the physical main is disabled only after presentation.
restore re-enables physical output before removing the virtual display. Control
handoff, disconnect, helper failure, and local display changes also restore it.
Supports local, verified direct TLS, and gateway relay with --machine ID|NAME.
```

### dieter screen resolution

```text
Usage: dieter screen resolution <modes|set|restore> SESSION [options]

Experimental physical desktop resolution, independent of video stream ceilings.
"modes" lists the selected display's supported modes and current mode ID.
"set" requires --display ID --mode ID --expected-current ID from a fresh modes
response. It requires the controlling session and temporarily changes the actual
remote monitor for everyone using it. "restore" restores the leased original mode.
Control handoff, display selection, session closure, and helper exit also restore
the mode. A later local display change takes precedence. Supports --machine ID|NAME.
```

### dieter screen resolution modes

```text
Usage: dieter screen resolution modes SESSION

Usage: dieter screen resolution <modes|set|restore> SESSION [options]

Experimental physical desktop resolution, independent of video stream ceilings.
"modes" lists the selected display's supported modes and current mode ID.
"set" requires --display ID --mode ID --expected-current ID from a fresh modes
response. It requires the controlling session and temporarily changes the actual
remote monitor for everyone using it. "restore" restores the leased original mode.
Control handoff, display selection, session closure, and helper exit also restore
the mode. A later local display change takes precedence. Supports --machine ID|NAME.
```

### dieter screen resolution set

```text
Usage: dieter screen resolution set SESSION --display ID --mode ID --expected-current ID

Usage: dieter screen resolution <modes|set|restore> SESSION [options]

Experimental physical desktop resolution, independent of video stream ceilings.
"modes" lists the selected display's supported modes and current mode ID.
"set" requires --display ID --mode ID --expected-current ID from a fresh modes
response. It requires the controlling session and temporarily changes the actual
remote monitor for everyone using it. "restore" restores the leased original mode.
Control handoff, display selection, session closure, and helper exit also restore
the mode. A later local display change takes precedence. Supports --machine ID|NAME.
```

### dieter screen resolution restore

```text
Usage: dieter screen resolution restore SESSION

Usage: dieter screen resolution <modes|set|restore> SESSION [options]

Experimental physical desktop resolution, independent of video stream ceilings.
"modes" lists the selected display's supported modes and current mode ID.
"set" requires --display ID --mode ID --expected-current ID from a fresh modes
response. It requires the controlling session and temporarily changes the actual
remote monitor for everyone using it. "restore" restores the leased original mode.
Control handoff, display selection, session closure, and helper exit also restore
the mode. A later local display change takes precedence. Supports --machine ID|NAME.
```

### dieter screen clipboard

```text
Usage: dieter screen clipboard read|write|paste|copy|cut|enable|disable SESSION [options]

Share text, images and regular files with an existing controlling screen session.
write updates the host clipboard; paste also invokes the native paste shortcut
once. copy/cut invoke the host shortcut and return the copied content. read returns
protobuf JSON (binary data is base64). enable/disable controls session sharing.

write/paste require exactly one format:
  --file FILE|-      UTF-8 text, at most 1 MiB (use - for stdin)
  --image FILE       PNG, JPEG, TIFF or WebP, at most 8 MiB
  --attach FILE      Regular file; repeat for up to 64 files, 8 MiB combined
read/copy/cut optionally accept:
  --output-dir DIR   Save binary items under a new private directory; never overwrite

Folders, links and duplicate filenames are rejected. Temporary native clipboard
files use DIETER_HOME/clipboard; the next transfer prunes old (24h) batches
and retains at most eight batches.
Mutations are never automatically retried. Supports global --machine ID|NAME
with direct TLS and relay fallback. Binary sharing requires an updated daemon.
```

### dieter screen clipboard read

```text
Usage: dieter screen clipboard read|write|paste|copy|cut|enable|disable SESSION [options]

Share text, images and regular files with an existing controlling screen session.
write updates the host clipboard; paste also invokes the native paste shortcut
once. copy/cut invoke the host shortcut and return the copied content. read returns
protobuf JSON (binary data is base64). enable/disable controls session sharing.

write/paste require exactly one format:
  --file FILE|-      UTF-8 text, at most 1 MiB (use - for stdin)
  --image FILE       PNG, JPEG, TIFF or WebP, at most 8 MiB
  --attach FILE      Regular file; repeat for up to 64 files, 8 MiB combined
read/copy/cut optionally accept:
  --output-dir DIR   Save binary items under a new private directory; never overwrite

Folders, links and duplicate filenames are rejected. Temporary native clipboard
files use DIETER_HOME/clipboard; the next transfer prunes old (24h) batches
and retains at most eight batches.
Mutations are never automatically retried. Supports global --machine ID|NAME
with direct TLS and relay fallback. Binary sharing requires an updated daemon.
```

### dieter screen clipboard write

```text
Usage: dieter screen clipboard read|write|paste|copy|cut|enable|disable SESSION [options]

Share text, images and regular files with an existing controlling screen session.
write updates the host clipboard; paste also invokes the native paste shortcut
once. copy/cut invoke the host shortcut and return the copied content. read returns
protobuf JSON (binary data is base64). enable/disable controls session sharing.

write/paste require exactly one format:
  --file FILE|-      UTF-8 text, at most 1 MiB (use - for stdin)
  --image FILE       PNG, JPEG, TIFF or WebP, at most 8 MiB
  --attach FILE      Regular file; repeat for up to 64 files, 8 MiB combined
read/copy/cut optionally accept:
  --output-dir DIR   Save binary items under a new private directory; never overwrite

Folders, links and duplicate filenames are rejected. Temporary native clipboard
files use DIETER_HOME/clipboard; the next transfer prunes old (24h) batches
and retains at most eight batches.
Mutations are never automatically retried. Supports global --machine ID|NAME
with direct TLS and relay fallback. Binary sharing requires an updated daemon.
```

### dieter screen clipboard paste

```text
Usage: dieter screen clipboard read|write|paste|copy|cut|enable|disable SESSION [options]

Share text, images and regular files with an existing controlling screen session.
write updates the host clipboard; paste also invokes the native paste shortcut
once. copy/cut invoke the host shortcut and return the copied content. read returns
protobuf JSON (binary data is base64). enable/disable controls session sharing.

write/paste require exactly one format:
  --file FILE|-      UTF-8 text, at most 1 MiB (use - for stdin)
  --image FILE       PNG, JPEG, TIFF or WebP, at most 8 MiB
  --attach FILE      Regular file; repeat for up to 64 files, 8 MiB combined
read/copy/cut optionally accept:
  --output-dir DIR   Save binary items under a new private directory; never overwrite

Folders, links and duplicate filenames are rejected. Temporary native clipboard
files use DIETER_HOME/clipboard; the next transfer prunes old (24h) batches
and retains at most eight batches.
Mutations are never automatically retried. Supports global --machine ID|NAME
with direct TLS and relay fallback. Binary sharing requires an updated daemon.
```

### dieter screen clipboard copy

```text
Usage: dieter screen clipboard read|write|paste|copy|cut|enable|disable SESSION [options]

Share text, images and regular files with an existing controlling screen session.
write updates the host clipboard; paste also invokes the native paste shortcut
once. copy/cut invoke the host shortcut and return the copied content. read returns
protobuf JSON (binary data is base64). enable/disable controls session sharing.

write/paste require exactly one format:
  --file FILE|-      UTF-8 text, at most 1 MiB (use - for stdin)
  --image FILE       PNG, JPEG, TIFF or WebP, at most 8 MiB
  --attach FILE      Regular file; repeat for up to 64 files, 8 MiB combined
read/copy/cut optionally accept:
  --output-dir DIR   Save binary items under a new private directory; never overwrite

Folders, links and duplicate filenames are rejected. Temporary native clipboard
files use DIETER_HOME/clipboard; the next transfer prunes old (24h) batches
and retains at most eight batches.
Mutations are never automatically retried. Supports global --machine ID|NAME
with direct TLS and relay fallback. Binary sharing requires an updated daemon.
```

### dieter screen clipboard cut

```text
Usage: dieter screen clipboard read|write|paste|copy|cut|enable|disable SESSION [options]

Share text, images and regular files with an existing controlling screen session.
write updates the host clipboard; paste also invokes the native paste shortcut
once. copy/cut invoke the host shortcut and return the copied content. read returns
protobuf JSON (binary data is base64). enable/disable controls session sharing.

write/paste require exactly one format:
  --file FILE|-      UTF-8 text, at most 1 MiB (use - for stdin)
  --image FILE       PNG, JPEG, TIFF or WebP, at most 8 MiB
  --attach FILE      Regular file; repeat for up to 64 files, 8 MiB combined
read/copy/cut optionally accept:
  --output-dir DIR   Save binary items under a new private directory; never overwrite

Folders, links and duplicate filenames are rejected. Temporary native clipboard
files use DIETER_HOME/clipboard; the next transfer prunes old (24h) batches
and retains at most eight batches.
Mutations are never automatically retried. Supports global --machine ID|NAME
with direct TLS and relay fallback. Binary sharing requires an updated daemon.
```

### dieter screen clipboard enable

```text
Usage: dieter screen clipboard read|write|paste|copy|cut|enable|disable SESSION [options]

Share text, images and regular files with an existing controlling screen session.
write updates the host clipboard; paste also invokes the native paste shortcut
once. copy/cut invoke the host shortcut and return the copied content. read returns
protobuf JSON (binary data is base64). enable/disable controls session sharing.

write/paste require exactly one format:
  --file FILE|-      UTF-8 text, at most 1 MiB (use - for stdin)
  --image FILE       PNG, JPEG, TIFF or WebP, at most 8 MiB
  --attach FILE      Regular file; repeat for up to 64 files, 8 MiB combined
read/copy/cut optionally accept:
  --output-dir DIR   Save binary items under a new private directory; never overwrite

Folders, links and duplicate filenames are rejected. Temporary native clipboard
files use DIETER_HOME/clipboard; the next transfer prunes old (24h) batches
and retains at most eight batches.
Mutations are never automatically retried. Supports global --machine ID|NAME
with direct TLS and relay fallback. Binary sharing requires an updated daemon.
```

### dieter screen clipboard disable

```text
Usage: dieter screen clipboard read|write|paste|copy|cut|enable|disable SESSION [options]

Share text, images and regular files with an existing controlling screen session.
write updates the host clipboard; paste also invokes the native paste shortcut
once. copy/cut invoke the host shortcut and return the copied content. read returns
protobuf JSON (binary data is base64). enable/disable controls session sharing.

write/paste require exactly one format:
  --file FILE|-      UTF-8 text, at most 1 MiB (use - for stdin)
  --image FILE       PNG, JPEG, TIFF or WebP, at most 8 MiB
  --attach FILE      Regular file; repeat for up to 64 files, 8 MiB combined
read/copy/cut optionally accept:
  --output-dir DIR   Save binary items under a new private directory; never overwrite

Folders, links and duplicate filenames are rejected. Temporary native clipboard
files use DIETER_HOME/clipboard; the next transfer prunes old (24h) batches
and retains at most eight batches.
Mutations are never automatically retried. Supports global --machine ID|NAME
with direct TLS and relay fallback. Binary sharing requires an updated daemon.
```

### dieter screen sessions

```text
Usage: dieter screen sessions

List the connected viewers, active controller, four-client limit, shared capture
streams, and hardware encoders as JSON. Supports --machine ID|NAME.
```

### dieter screen control

```text
Usage: dieter screen control take|release SESSION

Give a connected control-capable client exclusive keyboard/mouse control, or
release its current grant. Taking control first releases the previous client's
held input. Viewers keep streaming. Control handoff uses revocable grants.
Prints session state as JSON. Supports --machine ID|NAME.
```

### dieter screen control take

```text
Usage: dieter screen control take|release SESSION

Give a connected control-capable client exclusive keyboard/mouse control, or
release its current grant. Taking control first releases the previous client's
held input. Viewers keep streaming. Control handoff uses revocable grants.
Prints session state as JSON. Supports --machine ID|NAME.
```

### dieter screen control release

```text
Usage: dieter screen control take|release SESSION

Give a connected control-capable client exclusive keyboard/mouse control, or
release its current grant. Taking control first releases the previous client's
held input. Viewers keep streaming. Control handoff uses revocable grants.
Prints session state as JSON. Supports --machine ID|NAME.
```

### dieter screen capabilities

```text
Usage: dieter screen capabilities
```

### dieter screen permissions

```text
Usage: dieter screen permissions [--request-control]

Ask the running daemon to discard one captured frame and check event-posting
permission. Prints the daemon/helper paths and both results as JSON. Does not
inject input or change settings. --request-control explicitly allows a macOS
Accessibility prompt or verifies the Linux XTest/RemoteDesktop portal path on
the daemon host. A Linux portal prompt can remain open for up to two minutes.
Supports --machine ID|NAME.
```

### dieter screen start

```text
Usage: dieter screen start --request FILE|- [--signal-input FILE|-] [--count N] [--codec auto|h264|hevc] [--reference-recovery]
HEVC requires a compatible signed H265 offer and hardware at up to 1080p60; codec changes require a new session.
Reference recovery requires the generic RTP frame descriptor and acknowledgements after decoder completion. Omitted flags preserve request JSON.
```

### dieter screen signal

```text
Usage: dieter screen signal --file FILE|-
```

### dieter screen close

```text
Usage: dieter screen close SESSION
```

### dieter screen status

```text
Usage: dieter screen status SESSION
JSON includes paced sendMs, approximate captureToSendMs, receiver jitterBufferMs and renderMs; queueMs measures socket work only. Stages overlap and are not a glass-to-glass total.
renderMeasurement distinguishes Metal presentation from Android EGL submission. Optional decoder/encoder diagnostics report accepted configuration, not measured latency gains. mediaRtpBytes, repairRtpBytes, probeRtpBytes and fecRtpBytes exclude transport overhead. recoveryDiagnostics reports bounded packet history and repair decisions.
```

### dieter screen configure

```text
Usage: dieter screen configure SESSION [--display ID] [--quality auto|detail|motion] [--width N] [--height N] [--fps N] [--bitrate N] [--embedded-cursor=true|false]
Ceilings are adaptive; unspecified values retain the current session configuration.
```

### dieter screen refresh

```text
Usage: dieter screen refresh SESSION
```

## dieter schedule (alias: schedules)

```text
Usage: dieter schedule <action>

Actions:
  create                 Create a recurring project schedule
  list                   List one bounded page of schedules
  show SCHEDULE          Show a schedule and recent occurrences
  preview                Preview cron occurrence times
  update SCHEDULE        Replace a schedule definition
  run SCHEDULE           Dispatch one manual occurrence
  pause SCHEDULE         Disable automatic occurrences
  resume SCHEDULE        Enable automatic occurrences
  runs SCHEDULE          List one bounded page of occurrence history
  delete SCHEDULE        Delete the definition; cards and history remain
```

### dieter schedule create

```text
Usage: dieter schedule create --project PROJECT --board BOARD --name NAME --cron EXPRESSION --title TITLE --prompt TEXT [options]

Options:
  --timezone AREA/LOCATION           IANA timezone (default UTC)
  --action draft|run                 Create a draft or immediately run it
  --workspace project|worktree       Conversation workspace selection
  --labels ID,ID                     Board-label IDs
  --provider HARNESS --model MODEL --effort EFFORT
  --provider-option KEY=VALUE        Repeatable harness option
  --enabled=true|false
  --open-card skip_if_open|always
  --vault=true|false                 Cards it creates may use the account vault
```

### dieter schedule list

```text
Usage: dieter schedule list [--project PROJECT] [--page-size N] [--page-token TOKEN] [--format table|json|jsonl|ids]
```

### dieter schedule show

```text
Usage: dieter schedule show [--runs N] SCHEDULE
```

### dieter schedule preview

```text
Usage: dieter schedule preview --cron EXPRESSION [--timezone AREA/LOCATION] [--count N]
```

### dieter schedule update

```text
Usage: dieter schedule update --project PROJECT --board BOARD --name NAME --cron EXPRESSION --title TITLE --prompt TEXT [options] SCHEDULE

Options:
  --timezone AREA/LOCATION           IANA timezone (default UTC)
  --action draft|run                 Create a draft or immediately run it
  --workspace project|worktree       Conversation workspace selection
  --labels ID,ID                     Board-label IDs
  --provider HARNESS --model MODEL --effort EFFORT
  --provider-option KEY=VALUE        Repeatable harness option
  --enabled=true|false
  --open-card skip_if_open|always
  --vault=true|false                 Cards it creates may use the account vault
```

### dieter schedule run

```text
Usage: dieter schedule run SCHEDULE
```

### dieter schedule pause

```text
Usage: dieter schedule pause SCHEDULE
```

### dieter schedule resume

```text
Usage: dieter schedule resume SCHEDULE
```

### dieter schedule runs

```text
Usage: dieter schedule runs [--page-size N] [--page-token TOKEN] SCHEDULE
```

### dieter schedule delete

```text
Usage: dieter schedule delete SCHEDULE
```

## dieter kv

```text
Usage: dieter kv <get|list|put|delete|move|watch> [options]

Account-scoped portable JSON state replicated between daemons. Writes acknowledge
local durability, not a quorum. Revisions are local compare-and-set checks.
Use global --machine ID|NAME for verified TLS, WebRTC, or relay targeting.

  get      Read a key, its deterministic value and all causal siblings
  list     Read a bounded snapshot page including tombstones
  put      Write JSON with an observed revision (empty means create only)
  delete   Persist a causal tombstone
  move     Position one ordered key using stable neighboring keys
  watch    Stream bounded changes; apply reset before replacement snapshots
```

### dieter kv get

```text
Usage: dieter kv get --namespace NS --key KEY [--account ID]
Read the selected value and all causal siblings.
Mutations may pass --account ID --daemon ID to pin an uncertain retry.
Retry identical input and --operation only on that same daemon.
```

### dieter kv list

```text
Usage: dieter kv list [--namespace NS] [--prefix PREFIX] [--after KEY --epoch EPOCH --sequence N]
Read up to 64 entries. Pass nextKey and cursor for subsequent pages.
Mutations may pass --account ID --daemon ID to pin an uncertain retry.
Retry identical input and --operation only on that same daemon.
```

### dieter kv put

```text
Usage: dieter kv put --namespace NS --key KEY --file FILE [--revision REV] [--operation ID]
Write JSON (maximum 32 KiB). Read all siblings before resolving conflicts.
Mutations may pass --account ID --daemon ID to pin an uncertain retry.
Retry identical input and --operation only on that same daemon.
```

### dieter kv delete

```text
Usage: dieter kv delete --namespace NS --key KEY --revision REV [--operation ID]
Retain a tombstone; deleting does not remove causal history.
Mutations may pass --account ID --daemon ID to pin an uncertain retry.
Retry identical input and --operation only on that same daemon.
```

### dieter kv move

```text
Usage: dieter kv move --namespace NS --key KEY [--parent ID] [--after KEY] [--before KEY] [--revision REV] [--operation ID]
Write an atomic parent/rank position. Empty neighbors append to this list.
Mutations may pass --account ID --daemon ID to pin an uncertain retry.
Retry identical input and --operation only on that same daemon.
```

### dieter kv watch

```text
Usage: dieter kv watch [--namespace NS] [--prefix PREFIX] [--epoch EPOCH --sequence N] [--count N]
Watch until canceled or count frames. Reset replaces the cache; publish at caughtUp.
Mutations may pass --account ID --daemon ID to pin an uncertain retry.
Retry identical input and --operation only on that same daemon.
```

## dieter vault

```text
Usage: dieter vault <action> [options]

An account-wide password and TOTP vault shared by your machines. Items
replicate end-to-end encrypted; the gateway relays only ciphertext and vault
contents never cross the gateway relay route. Each machine joins once.

Setup and machines:
  status         Show vault state, members and this caller's access
  init           Create the vault on the first machine; prints a recovery key
  join           Join from another machine (approval code or recovery key)
  approve        Approve a joining machine after comparing its code
  remove-member  Revoke a machine and rotate to a new key
  rotate         Rotate the vault key; --recovery-key replaces the recovery key

Items:
  list           List items (no secrets)
  show           Show one item's metadata
  add            Add an item with name, URLs, username, password, TOTP, notes
  edit           Change fields of an item
  remove         Delete an item
  get            Print one field; secret fields require --reveal
  totp           Print the current TOTP code
  exec           Run a command with item fields in its environment
  audit          Show this machine's vault access log

ITEM is an exact vi_ ID or a unique case-insensitive name. Secrets are never
accepted as command-line arguments: use --password-file -, --prompt or
--generate. Agent turns may use the vault only when their card, chat or
schedule was created with --vault; agents cannot change membership or keys.
Prefer exec over get so secrets do not enter transcripts.
```

### dieter vault status

```text
Usage: dieter vault status [--format table|json]
Show vault state, machine members, pending join codes and this caller's access.
```

### dieter vault members

```text
Usage: dieter vault status [--format table|json]
Show vault state, machine members, pending join codes and this caller's access.
```

### dieter vault init

```text
Usage: dieter vault init [--name NAME] [--format text|json]

Create the account vault with this machine as its first member. The printed
recovery key is shown once and never stored: keep it offline. It unlocks the
vault on any machine with dieter vault join --recovery-key-stdin.
```

### dieter vault join

```text
Usage: dieter vault join [--name NAME] [--recovery-key-stdin] [--format text|json]

Without a recovery key, publish this machine's vault key and print a join code.
On an existing member, compare that code and run:
  dieter vault approve MEMBER --code CODE
The code is derived from both machines' views, so a relay that substitutes keys
produces a different code. With --recovery-key-stdin, read the recovery key
from stdin and unlock immediately.
```

### dieter vault approve

```text
Usage: dieter vault approve MEMBER --code CODE
Approve a pending machine. Compare CODE with the code its dieter vault join printed;
dieter vault status lists pending members with the code this machine expects.
```

### dieter vault remove-member

```text
Usage: dieter vault remove-member MEMBER
Revoke a machine and rotate to a key it never receives. It keeps anything it
already decrypted: change those passwords. Unenroll a lost machine too.
```

### dieter vault rotate

```text
Usage: dieter vault rotate [--recovery-key]
Create a new vault key, reseal it to every member and re-encrypt all items.
--recovery-key also replaces the recovery key and prints the new one once.
```

### dieter vault list

```text
Usage: dieter vault list [--query TEXT] [--url URL] [--format table|json|jsonl|ids]
List item metadata. --url matches items for that host and its subdomains.
```

### dieter vault show

```text
Usage: dieter vault show ITEM
Print item metadata as JSON. Secret values are never included.
```

### dieter vault add

```text
Usage: dieter vault add --name NAME [--url URL]... [--username USER] [options]

Add an item. Secrets are read from files, stdin or a no-echo prompt.

Options:
  --name NAME                Unique item name
  --url URL                  Login URL; repeat for several
  --username USER            Account user name or email
  --password-file FILE|-     Read the password from FILE or stdin
  --generate                 Generate the password on the daemon; it is not printed
  --length N                 Generated length (default 24)
  --no-symbols               Generate letters and digits only
  --totp-file FILE|-         Read an otpauth://totp URI or base32 TOTP secret
  --notes-file FILE|-        Read notes
  --prompt                   Prompt for password and TOTP without echo (terminal)
  --format json|id           Output format

Example:
  printf '%s' "$PASSWORD" | dieter vault add --name GitHub --url https://github.com/login --username me --password-file -
```

### dieter vault edit

```text
Usage: dieter vault edit ITEM [options]

Change item fields. Unspecified fields keep their value. Editing an item with
a conflict keeps the shown version and resolves the conflict.

Options:
  --name NAME                Rename
  --url URL                  Add a URL; repeat for several
  --replace-urls             Replace all URLs with the given --url values
  --username USER            Set the user name
  --clear-totp               Remove the TOTP secret
  --clear-notes              Remove notes
  --password-file FILE|-     Read the password from FILE or stdin
  --generate                 Generate the password on the daemon; it is not printed
  --length N                 Generated length (default 24)
  --no-symbols               Generate letters and digits only
  --totp-file FILE|-         Read an otpauth://totp URI or base32 TOTP secret
  --notes-file FILE|-        Read notes
  --prompt                   Prompt for password and TOTP without echo (terminal)
```

### dieter vault remove

```text
Usage: dieter vault remove ITEM
Delete an item on every member machine.
```

### dieter vault get

```text
Usage: dieter vault get ITEM [--field FIELD]... [--reveal] [--format value|json]

Print item fields: password (default), username, url, name, totp or notes.
password, totp and notes require --reveal. One field prints its raw value;
several print JSON. Prefer dieter vault exec so secrets stay out of output.
```

### dieter vault totp

```text
Usage: dieter vault totp ITEM [--no-wait] [--format value|json]
Print the current TOTP code. With fewer than 5 seconds left, wait for the next
code unless --no-wait is set.
```

### dieter vault exec

```text
Usage: dieter vault exec ITEM --env NAME=FIELD... -- COMMAND [ARG...]

Run COMMAND locally with item fields in its environment. FIELD is password,
username, url, name, totp or notes. Arguments run without a shell; wrap in
sh -c only when needed. stdin, stdout and stderr pass through and the exit
status is preserved. Secrets are not printed.

Example:
  dieter vault exec GitHub --env GH_USER=username --env GH_PASS=password -- ./login.sh
```

### dieter vault audit

```text
Usage: dieter vault audit [--item ITEM] [--card CARD] [--limit N] [--format table|jsonl]
Show this machine's vault access log, newest first. It never contains secret values.
```

## dieter peer

```text
Usage: dieter peer <status|show|changes|list|put|delete|merge> [options]

Leaderless account settings replicated by enrolled daemons, including while clients
are closed. Local commits work offline after first account discovery. Concurrent
values and deletions are preserved; read all versions and put with their revision
to resolve. Shared project and board operations use these records directly.
Use global --machine ID|NAME to address another daemon over authenticated routes.

  show     Read one shared record and all conflicting values
  changes  Read an incremental change page using a durable sequence cursor
  status   Account, actor, conflicts, and bounded per-peer sync progress/blockers
  list     One bounded snapshot page, including conflicts and tombstones
  put      Resolve a typed shared field from a JSON file
  delete   Write a causal deletion using the current record revision
  merge    Import a bounded protobuf JSON MergePeerRecordsRequest (recovery/sync)
```

### dieter peer show

```text
Usage: dieter peer show
  --kind KIND --id ID
Read one shared record.
```

### dieter peer changes

```text
Usage: dieter peer changes
  [--account HASH] [--epoch EPOCH] [--sequence N]
Read a bounded incremental change page.
```

### dieter peer status

```text
Usage: dieter peer status
Show enrolled account, conflicts, and bounded per-peer attempts, successes, directions, checkpoints and sanitized record blockers. Catchup means durable page progress with more work pending. A successful exchange is not acknowledgement by every machine.
```

### dieter peer list

```text
Usage: dieter peer list
  [--account HASH] [--after KEY --snapshot REVISION]
Return up to 64 records. Pass nextKey and snapshotRevision for the next page.
```

### dieter peer put

```text
Usage: dieter peer put
  --kind KIND --id ENTITY.FIELD --file FILE [--revision HASH]
FILE contains the JSON value for the typed shared field. Prefer project/board commands for normal edits; the daemon rejects unrecognized kinds and fields.
Omit revision only for a new record. Resolve conflicts by supplying the current revision.
```

### dieter peer delete

```text
Usage: dieter peer delete
  --kind KIND --id ID --revision HASH
Persist a tombstone; concurrent unseen writes remain visible as conflicts.
```

### dieter peer merge

```text
Usage: dieter peer merge
  --file FILE
Import at most 64 records (2 MiB total) using protobuf JSON with account and records fields.
This joins causal versions, never replaces the store or runs an agent.
```

## dieter settings

```text
Usage: dieter settings <action>

Actions:
  show                         Show global prompt settings
  options                      List valid projects, boards, and harnesses
  update [options]             Update global prompt settings

Update requires --file FILE containing the Settings JSON object emitted by "show".
```

### dieter settings show

```text
Usage: dieter settings show
```

### dieter settings options

```text
Usage: dieter settings options
```

### dieter settings update

```text
Usage: dieter settings update --file FILE
```

## dieter prompt (alias: prompts)

```text
Usage: dieter prompt <action>

Actions:
  show                         Show global prompt and skill templates
  update [options]             Update global templates
  project [options] PROJECT    Set or inherit a project prompt template
  board [options] BOARD        Set or inherit a board prompt template
  preview [options]            Render the effective prompt for a scope
```

### dieter prompt show

```text
Usage: dieter prompt show
```

### dieter prompt update

```text
Usage: dieter prompt update [--template TEXT|--template-file FILE] [--board-skill TEXT|--board-skill-file FILE] [--chat-skill TEXT|--chat-skill-file FILE]
```

### dieter prompt project

```text
Usage: dieter prompt project [--inherit|--template TEXT|--template-file FILE] PROJECT
```

### dieter prompt board

```text
Usage: dieter prompt board [--inherit|--template TEXT|--template-file FILE] BOARD
```

### dieter prompt preview

```text
Usage: dieter prompt preview [--project PROJECT] [--board BOARD] [--card CARD] [--labels ID,ID] [--scope board|chat]
```

## dieter watch

```text
Usage: dieter watch changes [--count N]

Stream this machine's change frames as JSON Lines until interrupted, the same
stream native clients hold for every online machine. Frames name the
machine's peer identity and account and carry its replica of the account's
shared records (projects, boards, labels, cards, checkouts and KV, with every
causal sibling and its rank), then what only it knows: owner-only details of
the cards it runs and of its checkouts (paths, validation commands), the live
activity of its conversations and its peer replication issues.
resetRecords or resetLocal replaces what was received for that half. A frame
with caughtUp has delivered everything the machine held; heartbeats repeat the
cursor. Use --machine to watch another machine.

Read subscriptions renew credentials and resume from their last delivered checkpoint
after transient failures (up to five retries between frames). Revocation stops
recovery. Mutations, process starts, and stdin writes are never replayed.
```

### dieter watch changes

```text
Usage: dieter watch changes [--count N]

Stream this machine's change frames as JSON Lines until interrupted, the same
stream native clients hold for every online machine. Frames name the
machine's peer identity and account and carry its replica of the account's
shared records (projects, boards, labels, cards, checkouts and KV, with every
causal sibling and its rank), then what only it knows: owner-only details of
the cards it runs and of its checkouts (paths, validation commands), the live
activity of its conversations and its peer replication issues.
resetRecords or resetLocal replaces what was received for that half. A frame
with caughtUp has delivered everything the machine held; heartbeats repeat the
cursor. Use --machine to watch another machine.

Read subscriptions renew credentials and resume from their last delivered checkpoint
after transient failures (up to five retries between frames). Revocation stops
recovery. Mutations, process starts, and stdin writes are never replayed.
```

## dieter storage

```text
Usage: dieter storage
```

## dieter doctor

```text
Usage: dieter doctor [--format table|json]

Check the local daemon's runtime, storage, service-manager, shell, and optional
durability dependencies. Doctor is read-only and does not initialize storage.
```

## dieter setup

```text
Usage: dieter setup [--gateway URL] [--name NAME] [--no-open] [--no-start]

Authorize this machine with GitHub and start the platform-managed daemon service.
On macOS, setup also registers the signed background privacy helper and guides
Screen Recording, Accessibility, Login Items approval and Input Monitoring.
Privacy stays off until explicitly enabled. --no-open and --no-start skip privacy
helper registration; use "dieter machine privacy setup" later on this Mac.
Project registration is separate; use
"dieter project open PATH" explicitly after setup.
The default gateway is https://gateway.getdieter.com; use --gateway for self-hosting.
Retrying incomplete enrollment updates the gateway while preserving the machine key.
```

## dieter daemon

```text
Usage: dieter daemon <action>

Actions:
  start        Run the local data plane and persistent gateway tunnel
  service      Install and manage the platform daemon service
  enroll       Enroll this machine with the Dieter gateway
  recover      Restore a revoked local daemon ID with this replacement key
  unenroll     Revoke this machine and remove its local gateway credential
  status       Show service, local API, enrollment, and gateway health
  logs         Show or follow the daemon service log
  permissions  Verify screen/input permissions through the running daemon
```

### dieter daemon service

```text
Usage: dieter daemon service <action>

Install and manage Dieter's per-user daemon service. Service commands never
delete DIETER_HOME or project data.

Actions:
  install    Install or refresh the service definition and enable it
  start      Start the installed service
  restart    Gracefully restart the installed service
  stop       Stop the installed service
  status     Show the native service-manager status
  uninstall  Disable and remove the service definition, preserving all data
```

### dieter daemon service install

```text
Usage: dieter daemon service install
```

### dieter daemon service start

```text
Usage: dieter daemon service start
```

### dieter daemon service restart

```text
Usage: dieter daemon service restart
```

### dieter daemon service stop

```text
Usage: dieter daemon service stop
```

### dieter daemon service status

```text
Usage: dieter daemon service status
```

### dieter daemon service uninstall

```text
Usage: dieter daemon service uninstall
```

### dieter daemon enroll

```text
Usage: dieter daemon enroll [--gateway URL] [--name NAME] [--no-open]

Enroll this machine with the GitHub account configured by the Dieter gateway.
Retry incomplete enrollment with --gateway to correct the origin without changing
the machine key. Completed enrollments retain their identity.
Gateway URLs require HTTPS; HTTP is allowed only on literal loopback addresses.
```

### dieter daemon unenroll

```text
Usage: dieter daemon unenroll

Revoke this machine at its Dieter gateway and remove the local enrollment
credential. Projects, conversations, schedules, and harness settings remain.
```

### dieter daemon recover

```text
Usage: dieter daemon recover --old-id ID --confirm RECOVER

Restore a revoked daemon ID using this enrolled replacement's matching key.
This changes the saved local credential only after the gateway accepts and the
returned certificate is verified. Restart the daemon service manually afterward;
verify the restored daemon before revoking the replacement ID.
```

### dieter daemon status

```text
Usage: dieter daemon status [--format table|json]
```

### dieter daemon logs

```text
Usage: dieter daemon logs [--lines N] [--follow]
```

### dieter daemon permissions

```text
Usage: dieter daemon permissions [--check] [--no-open]

Verify capture and input permission through the running daemon, including with
--machine ID|NAME. --check discards one encoded frame and checks event-posting
permission without injecting input or changing settings. No local fallback is
used when the daemon is unavailable. Screen sharing is always available when
the required permissions are granted. Onboarding never restarts the daemon.
```

## dieter serve

Alias for "dieter daemon start".

### dieter daemon start

```text
Usage: dieter daemon start [--addr ADDRESS] [--direct-addr ADDRESS --direct-host HOST] [--env-file PATH] [--service [--runtime PATH]] [--verbose]

Run the machine-local Dieter data plane and, when enrolled, its persistent
outbound gateway tunnel. The local API is always loopback-only. An enrolled
daemon automatically advertises an authenticated loopback route; direct flags
add an optional LAN, Tailscale, or public route.
A package manager may supply --runtime with a fixed executable directory.
Service startup activates a staged verified release there before workers begin.
An enrolled daemon also verifies any gateway-signed endpoint relocation at startup,
preserving its enrolled identity and shared account. Discovery failure retains
its current address. Status reports the selected network endpoint.
```

## dieter version

Print the version.
