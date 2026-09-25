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
State, conversation and KV watches wake on commit notifications; a two-second
recovery check covers missed filesystem notifications and interrupted writers.
`watch state --interval` bounds the rate of updates during bursts.
`card watch --after-seq N` (also `chat watch`) immediately acknowledges an
up-to-date cursor with current metadata and no unchanged messages. This initial
frame counts toward `--count`; retain the cached transcript when applying it.
A stale cursor receives the existing snapshot/delta recovery.
`dieter watch sync --count 3` emits metadata, deltas, and transport-only
heartbeats. A heartbeat or `observedCursor` is reachability evidence, not applied
workspace data. Persist a cursor only with its complete projection, never from a
heartbeat or a frame with `projectionPending=true`. Native resume falls back to
an explicit reset when the exact projection identity is no longer retained.

For another enrolled machine, first enroll the local daemon, then pass the
target's exact ID or unique name as a global option before the command. The CLI
uses the local daemon enrollment automatically and never stores a separate CLI
login. An explicit global `--gateway` must match that enrollment:

```sh
dieter setup --gateway https://dieter.example.com
dieter machine list --format jsonl
dieter --machine <machine-id> status
dieter --machine <machine-id> project list --format jsonl
```

Remote commands prefer the daemon's authenticated direct TLS route, then try
a data-only WebRTC route when supported, with bounded gateway relay fallback.
`status` reports `webrtc-direct` or `webrtc-turn` from the selected ICE pair.
TURN still relays traffic; end-to-end daemon TLS and per-RPC authorization remain
in force. WebRTC sessions are independent of screen sharing and expire after
one hour; transport recovery must not replay mutations. State, sync, card, terminal, remote-execution,
and Git-operation watches renew direct credentials and resume from the last
delivered sequence or complete sync projection. Transient failures allow five
retries between delivered frames; revocation and permanent errors stop recovery.
Mutations, process starts, and stdin writes are never replayed by this recovery.
The gateway routes requests and stores only control-plane state plus normalized,
credential-free provider quota snapshots. It does not store projects,
transcripts, files, schedules, provider credentials, or harness credentials. Use
`dieter machine show <machine-id>` and `dieter machine route <machine-id>` to
inspect presence and advertised routes. Directory output includes the daemon's
release `version` and compatibility `apiVersion`; use the latter when deciding
whether a native client can safely target a machine in a mixed-version fleet.
Gateway URLs require HTTPS. HTTP is allowed only for literal loopback addresses
(for example, `http://127.0.0.1:8080`) used by isolated local gateways.
Daemon enrollment requires explicit browser approval after GitHub sign-in.
The operator checks the machine name and enrollment code; the page also shows
the key fingerprint. Opening the verification URL alone does not grant enrollment.
Use `dieter machine gateway` for the running gateway build identity and
`dieter --machine <machine-id> machine info` for live CPU, memory, process, and
optional Apple/NVIDIA/AMD GPU telemetry. Optional GPU fields are omitted when a
driver cannot provide them; zero remains a real measurement.

Accidental re-enrollment does not move conversation ownership. If a revoked
original machine ID and its active replacement share the *same* Ed25519 key,
the original account owner can recover it with an updated gateway and CLI.
First preserve `DIETER_HOME`, confirm the original transcripts remain on the
owner host, and check the two gateway records and key identity. Then run on
the affected host (never with global `--machine`):

```sh
dieter daemon recover --old-id ORIGINAL_ID --confirm RECOVER
dieter daemon service restart
```

Recovery authenticates the replacement, proves possession of its key, and
restores the original ID without automatically revoking the replacement.
Verify `dieter daemon status`, access an original chat, and only then use
`dieter machine revoke REPLACEMENT_ID` from another enrolled machine. A lost
response before the local credential is saved can be retried; do not guess
whether the server committed or edit `identity.json` or gateway SQLite.
Different keys or accounts require a separate audited recovery process.

`dieter harness list` returns the selected machine's catalog. OMP discovery uses
the same Dieter-pinned OMP build as new turns, not a separately installed global
`omp`, and exposes only GPT-6 Luna, Sol, Astra, and the Tailscale GLM route. The
first OMP catalog refresh can install that pinned build and Dieter's pinned Bun;
later refreshes reuse them. New turns pass the selected model at OMP launch rather
than relying on OMP's narrower ACP cycling-model option; old durable sessions
retain bounded resume compatibility.

Provider quotas are scoped to the enrolled daemon's gateway account, not one
daemon. Do not pass global `--machine`:

```sh
dieter quota list
dieter quota list openai --format json
dieter quota watch --count 3
dieter quota refresh openai
dieter quota exclude openai --account <opaque-key>
dieter quota include openai --account <opaque-key>
dieter quota reset openai --account <opaque-key> --confirm RESET
```

The table abbreviates opaque account keys. JSON retains the opaque key so it
can be passed to account-specific commands; it is an owner-scoped HMAC, not a
provider account ID. OpenAI rows may also include the bounded display email
returned by the structured account API. Provider summaries choose the lowest remaining percentage
across included account windows and never sum or average separate allowances.
Use `quota include` or `quota exclude` to change summary membership. OpenAI
`quota reset` consumes one reset credit, requires `--confirm RESET`, and is
routed to an online daemon that currently has the exact account.

Machine restart, shutdown, and daemon update require the exact confirmation
phrases shown by `--help` and are available only when the target daemon reports
the matching capability. Linux power control is non-interactive
systemd-logind/PolicyKit; never attempt to provide sudo or an administrator
password through Dieter. Automatic daemon update supports Homebrew-managed
macOS services and Dieter-managed Linux systemd user services:

```sh
dieter --machine <machine-id> machine update --confirm UPDATE
```

The update is detached, non-interactive, and logged on the target under
`DIETER_HOME/logs/update.log`; a transport disconnect does not imply failure
because the daemon service intentionally restarts and reconnects. The signed
candidate prepares its content-addressed harness runtime before restart. An
in-flight turn checkpoints and remains pinned to that runtime digest across
recovery; the affinity ends with the turn, so a later message in the same chat
uses the current runtime.

Linux verifies the release workflow's GitHub OIDC Sigstore identity and signed
SHA-256 manifest, stages the daemon/capture-helper pair under `DIETER_HOME/service`, and
restarts from a separate systemd update unit. Listener binding plus recovered
worker protocol activity commits the activation; an unacknowledged start rolls
back on the next restart. Use
`dieter doctor` for Node/npm/Git, cosign, systemd, logind, tmux, shell, and
private-storage and optional Linux screen-backend diagnostics. Manage the user unit with `dieter daemon service`.
Never run the Linux daemon as root or edit the unit behind Dieter's CLI.

Homebrew stages signed daemon/helper releases under
`$(brew --prefix)/var/dieter/service`; the service runs real files at its fixed
`bin` path. `brew upgrade` preserves the running pair. `brew services restart`
activates the staged release; startup failure before listener and recovered-turn
readiness rolls back on the next service start. User data remains under
`DIETER_HOME`. Never
invoke the internal `__service-stage` packaging command during normal operation.

For opt-in twice-daily **app and daemon** updates on macOS arm64, use
`python3 scripts/macos_auto_update.py install` on each host. See
`docs/macos-auto-update.md` before installation. The updater checks at 09:00 and
21:00 local time plus login; it waits for the app and active work to close,
requires the signed candidate's read-only compatibility probe, and retains
private backups. API/storage changes and disconnected gateways defer updates.
Older releases without the probe are ineligible. It never resets data or
registrations. Inspect `DIETER_HOME/auto-update/status.json`; uninstall the
schedule with the installed script's `uninstall` command. This is an opt-in
local installer, not a remote daemon RPC or a gateway updater.

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
dieter setup
dieter project directories /path/on/daemon
dieter project open --prompt-file prompt.md /path/on/daemon/repo
dieter board create --project <project-id> --name Delivery --workflow review \
  --base-remote origin --remote-publish pull_request
dieter board git --base-remote private --remote-publish push_base <board-id>
dieter card create --project <project-id> --board <board-id> \
  --lane todo --title "Implement recovery" --prompt-file task.md \
  --workspace worktree --format id

# Story-only quick task: save immediately, then GPT Spark improves the same
# task's title in the background. ID and later title edits are preserved.
# Use --lane running for immediate execution, without waiting for Spark.
dieter card create --project <project-id> --board <board-id> \
  --lane todo --auto-title --prompt "Add keyboard navigation" \
  --workspace worktree --format id
```

`dieter setup` enrolls and starts the local daemon but never discovers or
registers the current Git working tree, and it does not accept project paths.
Register each project explicitly with `dieter project open PATH` after setup.

`card create` and `chat create` use the running local daemon when global
`--machine` is omitted. Pass global `--machine ID|NAME` before the command to
create on another enrolled machine. `--checkout` selects among checkouts on the
already targeted machine; it never redirects creation to another checkout owner.

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

`card cancel` acknowledges after it has signaled the active turn. If messages
are queued, the first stays durable and starts only after the interrupted turn
has finished provider cleanup; a slow provider shutdown does not make the
cancellation request fail.

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

For background work inside the active harness, use `start_background_process`
with an exact `argv` array, optional `name`, `workingDirectory`, `environment`,
`timeoutMs`, and `idempotencyKey`. The tool registers the execution to its owning
conversation and returns the admitted execution ID. `list_background_processes`,
`read_background_process` (with the returned `afterSequence`), and
`stop_background_process` stay bound to that conversation. Reads return bounded
stdout/stderr pages; a tool timeout is not evidence the command stopped.

The equivalent CLI command is:

```sh
dieter remote exec --card <card-id> --name "Preview server" \
  --detach --format json -- npm run dev
```

The native Processes workspace tab shows this conversation's registered commands,
their live output and exit state, and an explicit Stop button. Closing the tab,
disconnecting, or finishing an agent turn only detaches observers. Processes
remain owned by the daemon until exit, timeout, explicit cancellation, or daemon
shutdown; completed output is retained within the execution manager's limits.

Use `remote shell` only when a program genuinely needs a PTY. It opens and
attaches a native shell on the daemon host; disconnecting leaves it available
for `remote attach`. The older `terminal` group remains the screen-oriented,
durable PTY interface and is often better for human interaction.

## Terminals, schedules, and policy

Daemon-owned PTYs survive client disconnects and, when the host has `tmux`,
daemon restarts. Machine-home terminals do not require a registered project:

```sh
dieter terminal list --card <card-id> --format jsonl
dieter terminal create --card <card-id> --name validation --format id
dieter --machine <machine-id> terminal create --home --name shell --format id
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

```sh
dieter screen sessions
dieter screen control take <session-id>
dieter screen control release <session-id>
```

Screen sharing supports up to four clients per machine. Matching display,
codec profile, and stream settings share a hardware encoder when decoded-reference
recovery is disabled. Recovery-enabled viewers use independent encoders so one
viewer cannot invalidate another viewer’s references. All renditions still use
one native capture stream per physical display, with at most four encoders.
Each viewer adapts independently and can change displays or disconnect without
closing another session. Only one client controls mouse and keyboard at a time.
The first control-capable client receives control; other clients use Take Control
(or `dieter screen control take SESSION`). Release Control leaves the video open.
Control handoff is part of the current contract; every viewer uses revocable grants.
`dieter screen sessions` reports connected clients and allocated capture resources.

For an authorized screen session, use `dieter screen status SESSION` for active
quality and timing, `dieter screen configure SESSION --quality auto|detail|motion`
for live policy, and `dieter screen refresh SESSION` to refresh an idle screen.
`configure` also accepts `--display ID`, `--width`, `--height`, `--fps`, `--bitrate`
(kbps) and `--embedded-cursor=true|false`; omitted fields retain their values.
Limits are adaptive ceilings up to 3840×2160/60 fps or 1920×1080/120 fps. `--fps`
accepts 1–120; values above 60 clamp the requested geometry to 1920×1080. Check
`screen capabilities` for the target's `maxFps` before requesting high refresh.
Motion policy trades resolution before cadence under sustained congestion;
automatic/detail policies retain their cadence-first behavior. Screen media uses native macOS
capture with hardware H.264 or opt-in HEVC, or Linux X11/portal capture with H.264.
Linux requires the documented GStreamer and desktop-session dependencies; Wayland
source selection remains locally portal-mediated. Screen input uses the shared
application contract, signed session bindings, and machine-wide control grants.
Adaptation preserves idle-screen geometry and recovery evidence across quiet
intervals, reduces cadence before resolution, and requires fresh congestion
evidence before shrinking pixels. Heartbeat and statistics freshness are separate.
A brief receiver heartbeat gap releases held input and pauses control without
closing video. Fresh feedback resumes control and discards stale queued input;
peer/signaling grace periods and session leases still bound disconnected sessions.
Fresh, epoch-validated WebRTC heartbeats renew the lease only while authenticated
signaling remains attached. Delayed unary renewals therefore do not end healthy
video; detached/revoked signaling still expires normally. Mac viewers retry
recoverable session expiry with a fresh route and bounded backoff. Native helper
keepalives do not wait for individual replies; acknowledged command traffic also
proves liveness. Silent helper/daemon IPC still expires after three seconds.
Mac and Android reopen a fresh session after transient native capture loss;
permission and policy failures remain terminal.
Recovery probes are bounded to a doubled rate, 64 KiB / 250 ms, every three seconds
during active/resumed video, including bounded refreshes while idle quality is
degraded; acknowledged delivery validates capacity and congestion
revokes it. The daemon log records session IDs, quality changes, measurement age,
delivered bandwidth, transport queue growth and GCC state.
`status` separates socket work (`queueMs`), paced sending (`sendMs`), approximate
capture-to-send age (`captureToSendMs`), jitter-buffer residence (`jitterBufferMs`),
and decoded-frame-to-output timing (`renderMs`). `renderMeasurement` distinguishes
Mac Metal presentation from Android EGL submission. Receiver timing is available
with updated native viewers; zero can mean no fresh sample. These stages overlap and
are not a physical glass-to-glass total. Capture admits one encoded frame at a time
and replaces pending raw surfaces; compatible peers request immediate playout.
Mac and Android display at decoder completion and dispatch the first pointer
movement immediately, with four-millisecond coalescing for bursts. RTT-aware
packet repair deadlines range from 50–250 ms per frame; stale timing retains the
compatibility window. These deadlines do not impose a playback delay.
All screen commands support global `--machine ID|NAME` with verified direct TLS
and authenticated relay fallback.

Experimental physical desktop modes are separate from stream width/height ceilings:

```sh
dieter screen resolution modes SESSION
dieter screen resolution set SESSION --display DISPLAY_ID --mode MODE_ID --expected-current CURRENT_MODE_ID
dieter screen resolution restore SESSION
```

`modes` lists the session's selected display and supported logical/pixel dimensions
and refresh rates. Use the returned display, mode, and current-mode IDs for `set`;
stale lists and non-controlling sessions are rejected. This changes the actual
remote monitor for everyone using it. The temporary mode restores on control
handoff/release, display selection, session closure, or display-helper exit. A later
local display change takes precedence. It never writes permanent display preferences
or creates virtual displays. Mirrored/unsupported displays report an error without
ending video. Mac users opt in under Settings → Experimental → Match remote
resolution in fullscreen, which is disabled by default and restores on exit.
Fullscreen keyboard capture needs local Mac Accessibility permission; Cmd-Shift-Escape
always releases capture. System shortcuts, including Cmd-Control-F, reach the remote
while captured. Permission loss, secure local input, or tap interruption releases capture.

Text, image and file clipboard sharing is available on updated Mac and Android viewers. Enable
**Share clipboard** in Screen options (Mac) or the bottom bar (Android). Mac
⌘C/⌘X and remote app menus copy back to the local clipboard; ⌘V transfers the
local content and then invokes the host paste shortcut. Android provides Copy and
Paste buttons, IME clipboard actions and the host's ⌘V hardware shortcut.
Synchronization runs only for the focused controlling viewer. View-only viewers
cannot read or write it. Connecting or taking control does not overwrite either
clipboard; subsequent supported changes sync in both directions. Clipboard access can
require an OS pasteboard grant; a denied request leaves video running.

UTF-8 plain text supports up to 1 MiB, including empty text, Unicode and newlines.
PNG, JPEG, TIFF and WebP images and up to 64 regular files support 8 MiB combined.
Folders, symbolic links, duplicate filenames and rich-text formatting are not
transferred. Binary clipboard support is negotiated from the host's capture capabilities.
A dedicated encrypted
WebRTC channel uses 16 KiB chunks and bounded buffering. Native clipboard IPC runs
in a separate instance of the installed helper, outside capture and heartbeat
queues. A stale control grant is rejected before a mutation. Failed/uncertain
pastes are never automatically retried; the daemon retains the most recent 128
mutation results per session for duplicate detection. Reconnecting creates a new
session and never replays clipboard operations. Contents never enter Dieter history
or logs. Native file URLs use private staging under `DIETER_HOME/clipboard` (the
Android app uses its private files directory and granted content URIs). The next
file transfer removes batches older than 24 hours and retains at most eight batches
(64 MiB); disconnecting does not invalidate the most recently copied files.

The CLI uses the same daemon implementation over local, direct TLS or relay:

```sh
dieter screen clipboard enable SESSION
dieter screen clipboard read SESSION
dieter screen clipboard write SESSION --file clipboard.txt
dieter screen clipboard paste SESSION --file - < clipboard.txt
dieter screen clipboard paste SESSION --image screenshot.png
dieter screen clipboard paste SESSION --attach report.pdf --attach diagram.png
dieter screen clipboard copy SESSION
dieter screen clipboard read SESSION --output-dir ./received-files
dieter screen clipboard cut SESSION
dieter screen clipboard disable SESSION
```

`read` prints protobuf JSON, including `hasText`, `changed`, `revision`, `text` and
`items` (binary data is base64). `--output-dir` saves binary items into a new
directory without overwriting files and omits their data from the JSON output.
`write` only changes the host clipboard; `paste` also invokes its paste shortcut.
`copy` and `cut` invoke the host shortcut and return the resulting content after the
clipboard changes.
`write` and `paste` require exactly one of `--file` (UTF-8; `-` reads stdin),
`--image`, or repeatable `--attach`. All operations require
an existing controlling session; they do not silently take control. Clipboard
errors are surfaced separately; a broken clipboard channel reopens the screen
session without replaying the interrupted paste. Transient connection failures
retry while the screen tab stays open: 250 ms initially, capped at five seconds,
with no attempt limit. Mac wake and Android resume reopen the authenticated route.
Explicit Disconnect, closing the tab, and permanent permission/identity/policy
errors stop recovery. Mac inactivity disconnect is optional and disabled by
default; explicitly configured inactivity limits remain honored.

Screen sharing is automatically available on supported enrolled hosts once OS
capture and input grants are present. There are no screen settings/update commands
or saved enable switches. `dieter screen capabilities` reports `availability`
(ready, permission required, or unsupported), `ready`, and an actionable reason.
Linux portal consent may be requested when a session starts. A client can still
choose a session without control. Do not start a session, request OS prompts,
restart/shut down a machine, revoke enrollment, or delete data without authorization.

For authorized onboarding:

```sh
dieter daemon permissions
dieter screen capabilities
```

Grant permissions on the target host; global `--machine ID|NAME` selects it.
Revoking OS grants or daemon enrollment prevents access. The Mac app separately
requires Screen Recording and Accessibility for Dieter.app and guides these in
its required setup screen. App permission does not grant daemon permission.

For authorized permission diagnostics, `dieter screen permissions` returns JSON
with the actual daemon/helper paths, capture verification, and input permission.
It discards one encoded frame and never injects input. Exit is nonzero if either
check fails. `--request-control` explicitly allows an Accessibility prompt on macOS
or verifies the active Linux XTest/RemoteDesktop portal path. `dieter daemon permissions --check` provides the same service-side
check as text. Both support global `--machine ID|NAME` and never fall back to a
helper launched by the CLI. Interactive `dieter daemon permissions` guides the
user through one required OS grant at a time and verifies readiness. It does not
restart the service. Old Cellar grants require a one-time grant to the new fixed
daemon path; follow an OS-requested restart with another service-side check.

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

### Screen codec selection

Native viewers start with H.264. Their video quality menu can select Automatic
or strict HEVC. HEVC uses hardware encoding/decoding, 8-bit 4:2:0 SDR Main,
up to 1920×1080 at 60 fps. `screen capabilities` exposes codec-specific modes.
Automatic selects HEVC only when both endpoints advertise a compatible mode;
codec initialization or first-frame decoding failure retries H.264 once per
connection. Transient reconnects retain that decision. Strict HEVC reports an
unsupported mode instead of silently changing codecs. Changing codecs creates a
fresh authenticated session and releases held input.

`dieter screen start --request offer.json --codec auto|h264|hevc` overrides the
protobuf JSON codec preference without rewriting SDP. The request must include
an offer supporting the requested codec. Omitting the flag preserves the JSON
preference (an absent field means automatic). CLI signaling supports the same
local, verified direct TLS, and authenticated relay routes. Existing H.264-only
clients and hosts remain compatible. HEVC remains opt-in pending matched-quality
bandwidth and physical-device latency benchmarks.

Screen bitrate reductions can now react to fresh TWCC congestion evidence outside
the slower resolution/cadence loop, at most once per 100 ms. A single jitter burst,
RTT increase, stale report or quiet desktop is insufficient. Shared viewers keep
independent encoder ceilings. Rate recovery retains the measured slow path with
a two-second hold after a fast reduction. The Mac renderer uses a dedicated
thread and a single replaceable pending frame. Isolated developer A/B tests can
set `DIETER_SCREEN_FAST_BITRATE=0` on the daemon or
`DIETER_SCREEN_PRESENTATION=display-link` on the Mac viewer (default `immediate`).
These environment switches are diagnostics; CLI operations and session RPCs are
unchanged. Never restart the operator daemon to change them during tests.

### Screen reference recovery and adaptive FEC

Native Mac and Android viewers negotiate decoded-reference recovery for H.264
and HEVC. Supporting VideoToolbox encoders recover from an acknowledged long-term
reference after loss. Decoder completion, frame identity, display generation,
and the authenticated input epoch scope each acknowledgement. Unsupported
hardware, clients without the required codec capability, expired references, or an unacknowledged recovery use
the existing keyframe path. Each recovery viewer gets its own bounded encoder.

`dieter screen start --request offer.json --reference-recovery` opts an automation
receiver into this protocol. The offer must advertise the generic frame descriptor
RTP extension, and the receiver must acknowledge `reference` host events only
after successful decoding through `decodedReferences` in receiver feedback.
Omitting the flag preserves the request JSON; `--reference-recovery=false`
explicitly disables it. Signaling works over local, direct TLS, and relay routes.

FlexFEC-03 protection is negotiated automatically. Fresh moderate loss without
queue growth selects a 10% or 20% repair-byte allowance; stale feedback, sustained
clean traffic, excessive loss, or queue growth disables repair. Encoder bitrate
reserves this allowance within the existing bandwidth budget. Media never waits
for a parity group. Protection adds redundancy and cannot repair every loss burst.
`screen sessions` / `screen status SESSION` report `referenceRecovery`,
`referenceAcks`, `referenceRecoveryFrames`, `referenceRecoveries` (decoded),
`fecPercent`, `fecPackets`, and `fecBytes`.

For disposable-process A/B tests, `DIETER_SCREEN_LTR=0` disables reference recovery
and `DIETER_SCREEN_FEC=0` disables FEC negotiation. Do not restart an operator daemon
for these comparisons. `DIETER_TEST_SCREEN_RECOVERY=1 just mac screens-test`
runs the native H.264/HEVC recovery matrix. Android coverage uses
`just e2e run --case screens.screen-recovery-end-to-end-test`.
Both use authenticated disposable fixtures and targeted packet loss, without
altering saved credentials or system network configuration.

### Screen performance diagnostics

`screen status SESSION` includes `encoderConfiguration`, `decoderImplementation`,
optional `decoderHardware`/`decoderLowLatencyAccepted`, `renderMeasurement`,
`contentChangedFraction`, `contentMeasurementSequence`, `contentSamples` and
`contentClass`. Configuration acceptance and metadata classification are not
proof of measured latency/visual quality. Missing optional capability means unknown.

`mediaRtpBytes`, `repairRtpBytes`, `probeRtpBytes` and `fecRtpBytes` separate serialized
RTP traffic; they exclude SRTP, RTCP, SCTP, ICE, IP/UDP and TURN overhead.
`recoveryDiagnostics` reports history decisions and current retention, bounded to
4,096 packets/4 MiB per session across streams. Old generations cannot repair a
new display; the pacer rechecks repair usefulness after waiting. Existing CLI
status/configuration operations carry diagnostics over all three routes.

Performance candidates remain isolated-process switches: Mac
`DIETER_SCREEN_PRESENTATION=bounded|low-latency|immediate|display-link`; daemon
`DIETER_SCREEN_CONTENT_ADAPTATION=1`, `DIETER_SCREEN_OVERLAP=1`, and native helper
`DIETER_SCREEN_ENCODER_BURST_MS=100|250|500`. Defaults retain current compatibility
behavior until matched qualification. Never restart the live service to set them.
The qualified one-credit fallback remains available with older helpers.

`scripts/qualify_screens.py --help` describes reproducible local/device evidence
collection. The physical Android runner requires an exact serial and a separate
fixture application ID; the original emulator-only runner remains unchanged in
its device policy. Do not present a skipped/unavailable matrix cell as a pass.

### Data-only WebRTC control signaling

All commands support the normal local target or global `--machine ID|NAME`.
`machine route` includes `controlWebrtc` when the connected daemon supports this
transport. The gateway provides account authentication, discovery, ICE
configuration, bootstrap signaling, and fallback; API payloads then use the
selected peer or TURN path. Clients retain direct TLS preference.

```sh
dieter machine rtc MACHINE
dieter --machine MACHINE machine connection start --request offer.json
dieter --machine MACHINE machine connection show SESSION
dieter --machine MACHINE machine connection close SESSION
```

The start file is protobuf JSON containing `rtcConfiguration` and `offerSdp`.
The response contains the gathered answer, session ID, expiry, state and mode.
Mode is `unknown` before ICE selection and then `direct` or `turn`; candidate
kinds describe the selected path without exposing addresses. A data-only peer
must create the reliable ordered `dieter-control-tls-v1` channel and speak the
bounded byte framing in `docs/webrtc-control-transport.md`. It carries the
ordinary authenticated TLS/gRPC connection, not unencrypted protobuf RPCs.
A close is transport-only. Existing agent turns, terminals and remote executions
continue; callers resume eligible watches using their existing cursors.

### Shared projects and peer storage

One project can have checkouts on many machines. Use `project attach --name NAME
PROJECT PATH` on the checkout owner, `project checkouts PROJECT`, `project detach
CHECKOUT`, and `project consolidate SOURCE DESTINATION`. Consolidation retains the
destination settings and all boards/conversations; it does not move repository files.

Shared metadata can be read/edited through any replica. Use global `--machine`
to target the immutable owner for conversation detail, schedules, files, Git,
terminals, and executions. Supply `--checkout ID` for project-local operations;
multiple local checkouts require an explicit choice. `project workspace` changes
portable defaults; `--validation-file FILE --checkout ID` edits local validation.
`card move --lane LANE --after LEFT --before RIGHT --revision REV CARD` uses stable
neighbors; no anchors appends. The revision is the card's placementRevision.

`peer status` shows account/actor, record/conflict counts and the last completed
exchange. It is not acknowledgement by every machine. `peer list` returns a bounded
snapshot; follow nextKey and snapshotRevision with `--after` and `--snapshot`.
`peer changes` uses an epoch/sequence checkpoint. All operations use the daemon API.

Use `peer show --kind KIND --id ENTITY.FIELD` to inspect all conflicting versions.
Resolve with `peer put --kind KIND --id ENTITY.FIELD --revision REV --file value.json`.
The file holds that field's typed JSON value. Read every sibling before resolving.
List output is protobuf JSON; valueJson is base64. Do not blindly replay uncertain
mutations or fabricate clocks. `peer merge --file FILE` joins up to 64 records and
2 MiB for recovery. Domain operations are preferred over raw record writes.

Daemon synchronization needs no client. Initialized replicas accept offline edits;
credential discovery and RTC bootstrap may require the gateway. Paths, secrets,
transcripts, queues, and executable validation stay on the owner. There are no
parallel-agent caps; one conversation still has one active turn. Transport and
storage bounds remain. Never edit DIETER_HOME directly. See docs/peer-store.md.

Application contract 1 is the only supported contract across gateway, daemon,
CLI, native clients, sync, and screen input. Missing or mismatched versions are
rejected. Unsupported development stores require a fresh `DIETER_HOME`; no
import or migration command is provided. Never delete or convert existing data.
Never stop or replace the operator's daemon as part of testing or implementation.

### Shared navigation and portable KV

Use `kv get`, `kv list`, `kv put`, `kv delete`, `kv move`, and `kv watch` for
account-scoped portable JSON. All use the daemon API and global `--machine`.
Folders, membership, project ordering, pinned-project membership/order,
pinned-chat ordering, disclosure, and lane sort direction share the `navigation`
namespace across native clients. See
`docs/client-navigation-folders.md` for keys and projection rules.

`kv put --namespace NS --key KEY --file value.json --revision REV` replaces the
observed local revision (omit revision only for creation). `kv move` accepts
`--parent`, `--after`, and `--before` for atomic fractional positions. `kv delete`
requires `--revision` and retains a tombstone. Values are at most 32 KiB.
`kv list` pages with `--after`, `--epoch`, and `--sequence`; a changed snapshot
requires restarting the list. Watch frames may coalesce updates: apply reset,
then publish the replacement at caughtUp. Cursors belong to a replica.

Mutations accept `--operation ID --account ID --daemon ID`. Preserve exact input
and retry only on that admitting daemon after an uncertain response; errors
include its identity and operation ID. Receipts are durable and bounded.
Acknowledgement means local durability, not a quorum or globally linearizable
CAS. Read every causal sibling before resolving meaningful conflicts. Gateway
storage and execution ownership are unaffected. Never write central storage
files directly or restart the operator daemon to test synchronization.

## Gateway endpoint relocation

`dieter serve` / `dieter daemon start` checks the authenticated gateway's signed
endpoint assertion before starting workers. The proposed HTTPS endpoint must be
signed by the enrolled gateway key and authenticate the same account. A verified
move atomically updates only the network endpoint, preserving the durable issuer,
enrollment, keys and peer account. Discovery failures retain the enrolled route.
`dieter daemon status` reports the network endpoint; explicit global `--gateway`
continues to require that endpoint. Never edit daemon identity or peer storage
manually, and never unenroll/re-enroll as a hostname migration shortcut.
Production rollout updates/restarts are operator work, never a testing method.
