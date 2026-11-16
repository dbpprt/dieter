# Conversation Changes that always work

Status: implemented, 2026-11-15 (all three phases in one change) · deep dive on daemon 0.6.445 and `main` at `c46265e0`

Every conversation should show its Git changes in place, on every client,
while agents write to the same files, and quickly. Today a conversation that
uses the project directory (the default mode) either cannot show changes at all
or shows them with an "agent is editing" banner, a diff that never settles, and
Git actions that fail after they start. This plan removes the causes; it does
not tune the symptoms.

## As built

All three phases shipped together. Where the build differs from the design
below:

- **Push triggers (D4).** The hub reads each watched directory on an adaptive
  interval (750 ms while an agent works there, 3 s otherwise, never closer
  than 250 ms or ten times the last read) and rereads at once when a Git
  operation, a file save or a transfer invalidates the directory
  (`StatusReader.Invalidated`). There is no inotify and no tool-result
  trigger: `git status` costs 20–30 ms on this repository, and one reader
  serves every stream on a directory, so polling while watched is cheap and
  works the same on macOS and Linux.
- **Activity is per view.** Deactivating a conversation's review no longer
  stops its checkout; the view that shows the checkout starts and stops it
  (`ReviewCommand.checkout`). This keeps the Mac's switch between the worktree
  and checkout views free of a stop/start race.
- **Chats too.** Android and iOS showed no Changes pane for chats; chats work
  in a worktree or the project directory like cards, so they have it now.
- **Side finding fixed.** `dieter … --project p_…` passes a project ID
  straight to the daemon instead of resolving it through `GetState`.
- **Wording.** The core shows the daemon's message for `FAILED_PRECONDITION`,
  `ABORTED` and `INVALID_ARGUMENT` refusals without the `gRPC CODE:` prefix.

Verification:

- Go unit, API and CLI tests, including a CLI end-to-end test over the local
  route, direct TLS and the relay.
- Kotlin core unit tests and a core end-to-end test against a real fixture
  daemon.
- Mac unit tests and the extended `conversation` Mac flow.
- The `changes` Maestro smoke flow on an Android emulator and an iOS
  simulator.

## What breaks

| Surface (project-directory conversation)              | What the user gets                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Android, iOS, Android desktop: conversation → Changes | Always `gRPC FAILED_PRECONDITION: project-directory changes are project-scoped; request them with project_id`.                                                                                                                                                                                                                                                                                                                                         |
| Mac: conversation header **Changes** tab              | A "Changes belong to the project" placeholder with an **Open Project Changes** button, never the changes.                                                                                                                                                                                                                                                                                                                                              |
| Mac: workspace pane **Review** tab, project Changes   | Amber "An agent is editing this checkout. Git actions resume when it finishes." The selected diff keeps reloading while the agent writes. Stage and commit fail with "workspace changed; refresh the changeset". Discard and update fail with `gRPC FAILED_PRECONDITION: workspace is busy: another conversation is active in the shared checkout`. After a failed first read the bar says "Updating checkout state…" and every action stays disabled. |
| CLI: `dieter workspace changes CARD`                  | `FailedPrecondition`, the same refusal as mobile.                                                                                                                                                                                                                                                                                                                                                                                                      |

Project mode is not an edge case. `selectedMode` in
`internal/git/workspace/manager.go` picks it when no mode is chosen; 118 of the
169 workspaces on the operator's Mac are project mode.

## Evidence

**Live daemon, read-only** (0.6.445, loopback Connect calls with the local
token; no state changed):

| Call                                                    | Result                                                          |
| ------------------------------------------------------- | --------------------------------------------------------------- |
| `GetChangeset{card_id}` for a project-mode card         | `failed_precondition` in under 2 ms                             |
| `GetChangeset{project_id}` for the same checkout        | 200, 39 files, about 5 ms (59 ms cold)                          |
| `GetWorkspace{card_id}`                                 | 200, 40–65 ms                                                   |
| `git status --porcelain=v2 …` in the checkout           | 20–30 ms for 3,151 tracked files                                |
| `dieter workspace changes --project …` (CLI end to end) | about 1.3 s, almost all of it the CLI's own `GetState` (1.27 s) |

Daemon-side reads are fast on this machine. The breakage is semantic, and the
slowness users feel comes from the client loops below, multiplied by round
trips on remote routes (the daemon log shows a peer falling back to the gateway
relay).

**Isolated reproduction.** A throwaway test against an in-process daemon with a
temporary store (`newConnectTestClient`, project-mode chat, two dirty files):

1. `GetChangeset{card_id}` → `failed_precondition`.
2. Read the list, then write `agent.txt`, then request the `README.md` diff
   with the list's revision → `aborted: workspace changed; refresh the
changeset`.
3. Read the list, write `agent.txt`, stage `README.md` with the list's
   revision → the operation ends `failed` with the same message.

A write to an unrelated file defeats both the read and the mutation.

## Root causes

### RC1. Each app decides how to show a conversation's changes, and they disagree

- The daemon refuses card-scoped changes for project-mode conversations by
  design (`ErrProjectChangesRequireProject`,
  `internal/git/changeset/service.go:22`, `:97`; also
  `internal/git/operations/manager.go` `resolveTarget`). Clients must switch to
  a `project_id` request themselves.
- The core has two controllers, `WorkspaceReview` (card) and `ProjectChanges`
  (checkout), and leaves the choice to each app.
- The Mac pane switches on `scope.workspaceMode`
  (`ConversationContentModel.swift:564`); its header tab shows
  `ProjectDirectoryChangesRedirect` instead (`ConversationView.swift:139`).
  Compose always uses the card controller (`CardPanes.kt:42` →
  `ReviewScreen` → `WorkspaceReview.kt:264`), so it can never succeed.
- This breaks the binding rule that client rules live in the Kotlin core
  ([invariants](../invariants.md#product-shape)).

### RC2. One whole-tree revision guards reads and file-scoped writes

- `revision()` (`internal/git/status.go:286`) hashes the status output plus
  mode, size and mtime of every unstaged file. Any write anywhere changes it:
  an agent, the user's editor, a build writing an untracked file.
- `FileDiffTarget` rejects a diff read unless the caller's revision is
  current (`changeset/service.go:162`). A diff read is therefore racing every
  writer in the tree. Multi-page diffs are worse: each page re-runs `git
status` and `git diff` and must hit the same revision.
- `ProjectChanges` answers `ABORTED` with `refresh()` (`ProjectChanges.kt:412`),
  and a refresh whose revision moved reloads the diff (`:311`, `:313`). While an
  agent writes, refresh and diff call each other until the agent pauses; each
  round is two RPCs, two forced `git status` runs and a `git diff`. Nothing
  joins overlapping refreshes (the 2 s poller, view commands and this loop can
  all run at once), unlike `WorkspaceReview.refresh`.
- Stage, unstage, discard and commit carry the list's revision, up to 2 s old,
  and `execute` re-checks it under the lock (`operations/manager.go:306`).
  Staging `README.md` fails because `agent.txt` changed.
- Review comments are listed only for the exact revision
  (`ListChangeComments`, `internal/api/git.go`), so every write anywhere
  hides every comment in a worktree review.
- The diff cache in `ProjectChanges` is keyed by that revision, so each poll
  during agent work refetches and re-lays the selected diff even when that
  file did not change.

### RC3. An active agent is treated as an error, not a state

- [Concurrent turns in one checkout are a product
  invariant](../invariants.md#execution); the view must expect concurrent
  writers. Instead `volatile` turns into a warning banner, and the daemon
  refuses discard and update with a generic "workspace is busy" fault that
  clients print as `gRPC FAILED_PRECONDITION: …` (`Failures.message` prefixes
  every gRPC error).
- `volatile` and the active operation are computed project-wide, not for the
  checkout (`ProjectCheckoutActive(value.ProjectID, "")` and
  `ActiveProjectGitOperation(value.ProjectID)`, `internal/api/git.go:46`,
  `:49`).
- `ProjectChangesView.allows` has no agent rule, so the Mac enables discard
  and update, the daemon refuses them, and the failure is reported after the
  click. Worktree reviews gate correctly through `WorkspaceAvailability`.
- The Mac model reports any failed command, including refresh, select, bind
  and layout, as `operationError` (`ProjectChangesModel.swift:186`). A
  transient read failure looks like a failed Git action.
- `busy` includes `needsReconciliation`, which only a successful refresh
  clears. One failed first read leaves "Updating checkout state…" and
  disabled actions until the next success.

### RC4. Every surface polls, and nothing pushes

- `ProjectChanges` polls `GetChangeset` every 2 s; `WorkspaceReview` polls
  `GetWorkspace` (with the 60 s provisioning deadline) and `GetChangeset` every
  5 s. Each open surface on each client polls on its own, also over the relay.
- New edits show up after a poll interval at best, and the daemon runs `git
status` once per client per interval.
- macOS has no file watcher (`internal/host/folders/platform_darwin.go:11`:
  kqueue needs one descriptor per file), so push has to come from a shared
  daemon-side reader, not from the clients.

### RC5 (adjacent). A worktree review shows only uncommitted files

`changesForWorkspace` fills the file list from `git status` alone;
`Changeset.commits` is never populated (only `internal/api/convert.go` reads
it), and additions and deletions are always 0
(`internal/git/workspace/manager.go:310`). An agent that commits in its
worktree leaves an empty Changes view, and the commit-diff UI has nothing to
list.

## Target behaviour

These are the acceptance criteria for the whole plan:

1. Every conversation with a working directory has an in-place Changes view on
   Mac (pane and header tab), Android, iOS and the CLI. A project-mode
   conversation shows its checkout, labelled as shared ("Shared checkout ·
   main"). A worktree conversation shows its branch.
2. Reads never fail because something else changed. A selected diff appears
   while agents write, and updates when that file changes.
3. An active agent appears as a state chip ("Agent working · live"), never as
   an error, and never blocks reading.
4. A mutation fails only if what it acts on changed. Writes to `B` do not
   affect staging `A`; a commit commits exactly the index the user reviewed.
5. Actions that cannot run now are disabled up front with the reason, decided
   in the core. The daemon enforces the same rule as a backstop, with a
   human-readable message.
6. Fast:
   - the list appears within 150 ms locally, or one round trip plus 50 ms
     remotely;
   - a write shows up within about 0.5 s while the view is visible;
   - clients do not poll;
   - each directory has one daemon status reader, however many clients
     watch it.

## Design

### D1. The daemon resolves a conversation to its working directory

- A `card_id` target means the conversation's working directory, whatever its
  mode: a worktree conversation resolves to its worktree, a project-mode
  conversation to its checkout (`card.CheckoutID`).
- This applies to `GetChangeset`, `GetFileDiff`, `GetCommitDiff`,
  `StartGitOperation` (checkout kinds) and the new `WatchChangeset`.
- Delete `ErrProjectChangesRequireProject` and every client branch that
  exists only to work around it.
- `Changeset` gains `scope` (`worktree` | `checkout`), `checkout_id` and
  `project_id`, so clients label the view without guessing.
- An operation started through a project-mode conversation is a checkout
  operation: an empty `CardID` plus `requested_by_card_id`. The project page
  and the conversation then show the same operation, and the
  one-operation-per-checkout rule holds.
- Why on the daemon: it owns the workspace record, so its mode is
  authoritative. The client's `workspace_mode` can lag, and the mode is
  editable until the first message. CLI parity follows without extra work.

### D2. Separate change detection from preconditions

- **Detection.** `Changeset.revision` stays as a cheap head for "something
  changed". It never guards anything.
- **Per-file revision.** Each `ChangedFile` gains `revision`, computed from the
  status output already in hand. Porcelain v2 carries the HEAD and index object
  names and modes; add `lstat` mode, size and mtime for the worktree side. This
  needs no extra Git command.
- **Index fingerprint.** `Changeset` gains `index_fingerprint`, a hash of HEAD
  plus `(path, mode, object)` of the staged entries, from the same output. It
  needs no `git write-tree`, so the read path writes nothing to the operator's
  repository.
- **Reads.** `GetFileDiff` and `GetCommitDiff` stop requiring
  `expected_revision` and never return `ABORTED`.
  - The response carries the file's `revision`.
  - Later pages pass it back. A bounded LRU of rendered patches (for example
    16 MiB, keyed by directory, path, section and file revision) serves every
    page from one rendering.
  - If the file changed in between, the daemon returns the first page of the
    new rendering with `restarted`.
- **Writes.**
  - `stage`, `unstage` and `discard_changes` carry `expected_files`
    (path → revision) for exactly the paths they act on. For a folder or
    "all", that is the reviewed set. Folder discard removes only the reviewed
    untracked files.
  - `commit` carries `expected_index`.
  - On rejection the error names the changed paths: "README.md changed while
    you were staging it; review it again".
  - `push`, `update` and `validate` act on the branch and need no revision.
- **Comments.** Comments anchor to path, side, line and the file's revision.
  A comment shows inline while its file revision matches, and collapses as
  "outdated" otherwise, as on code hosts. Writes elsewhere no longer hide
  comments.

### D3. Activity is state; the core gates actions

- Replace `volatile` with
  `activity { agent_active, agent_card_ids, operation_id }`, computed for the
  checkout (fix both project-wide lookups in `internal/api/git.go`).
- Core rules give every disabled kind a reason:
  - **Checkout:** discard and update are disabled while a project-mode turn is
    active in that checkout ("Wait for the agent to finish, or stop it").
    Stage, unstage, commit, validate and push stay available, since the agent
    and the user legitimately share the tree.
  - **Worktree:** keep `WorkspaceAvailability`; add its reason string.
- The daemon returns the same rules as typed faults with human messages.
  `Failures.message` shows the daemon's text for known fault kinds and keeps
  the gRPC code only for unknown errors.
- **Stale while revalidating.** A failed read keeps the last good list and
  diff, and shows a small "Couldn't refresh · Retry" line. A read failure is
  never an operation error and never a full-screen error once data exists.
  The first read retries with backoff, and only an operation start, not a
  read, can block mutations.

### D4. Push from one reader per directory

- **Daemon `changeset.Hub`.** Subscribers register per resolved working
  directory. One reader per directory runs `git status`, reusing
  `StatusReader`'s coalescing, and publishes only when the revision changes.
  Its triggers:
  1. a finished Git operation (today's `InvalidatePath`);
  2. a finished tool call in a turn whose working directory is this one (the
     engine already sees each tool result);
  3. inotify on Linux (the folders engine has the pattern), and FSEvents on
     macOS later if needed;
  4. an adaptive fallback poll: 750 ms while a turn is active in the
     directory, 3 s otherwise, and never more often than ten times the last
     status duration, which protects huge repositories.
- **RPC.**
  `GitService.WatchChangeset(WatchChangesetRequest{card_id | project_id, checkout_id, heartbeat_ms}) returns (stream ChangesetFrame)`.
  The first frame is the full changeset, then one frame per revision change,
  plus heartbeats.
  - Streams are capped (like `maxChangeStreams`).
  - Frames are bounded: the file list stops at a cap with `files_truncated`
    and totals, so an enormous tree degrades instead of failing. This also
    replaces `ErrTooManyChanges` on this path.
- **CLI.** `dieter workspace watch-changes [--project P] [CARD]` as JSON Lines,
  with offline help, the `rpcCommand` mapping and the generated reference. End
  to end over the local route, direct TLS and the relay
  (`internal/testkit/topology`).
- **Core.** The controllers subscribe while visible and resubscribe with
  backoff after reconnects. The 2 s and 5 s pollers are deleted. The selected
  diff reloads only when its own file revision changes; the diff cache is keyed
  by file revision.

### D5. One conversation Changes surface in the core

- Extract the checkout logic of `ProjectChanges` into `CheckoutChanges`, which
  has two targets: a card or a project and checkout. It covers staged and
  unstaged sections, per-path stage, unstage and discard, commit, update,
  validate and push.
  - `ProjectChanges` becomes the project page's binding.
  - `WorkspaceReview` delegates to `CheckoutChanges` when the daemon reports
    `scope = checkout`.
- The review slice carries `scope` and, for checkouts, the checkout sub-slice.
  Apps render from the slice alone:
  - **Mac:** delete `usesProjectReview` and `ProjectDirectoryChangesRedirect`;
    the header tab and the pane show the same view.
  - **Compose:** `ReviewScreen` renders the checkout layout (sections and
    commit box) for checkout scope.
- Mac `ProjectChangesModel` separates command failures from operation errors
  (RC3).
- `refresh` becomes single-flight in both controllers, and no read path calls
  `refresh` from an error handler.

### D6 (adjacent). Worktree reviews show the branch

- Populate `commits` from `rev-list merge-base..HEAD`, capped at 100.
- Fill per-file additions and deletions against the merge base from
  `diff --numstat`, computed off the hot path and cached by HEAD, index
  fingerprint and revision.
- Show "Committed on this branch" above "Uncommitted". An agent that commits
  still has a reviewable result, and the merge checklist counts real commits.

### Not in scope: per-conversation attribution

"Edited by this conversation" in a shared checkout needs turn records. The
[agent workspaces spike](agent-workspaces-results.md) measured an exact
shadow-git turn snapshot at 0.16–0.25 s on this repository. It can later add a
filter or badges on top of D1–D5. It is not needed for the view to work.

## Phases

Each phase ships on its own. Wire changes are clean breaks: no compatibility
branches, raise the client floor once
([invariants](../invariants.md#releases-and-compatibility)).

### Phase 1: make it work everywhere (D1, D2, D3, D5)

| Area         | Files                                                                                                                                                                                                                                                                                                                                                                                       |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Proto        | `api/proto/dieter/v1/git.proto`: `Changeset.scope`, `checkout_id`, `index_fingerprint`, `activity`; `ChangedFile.revision`; `GetDiffRequest.file_revision` (replaces `expected_revision`); `FileDiff.file_revision`, `restarted`; `StartGitOperationRequest.expected_files`, `expected_index`; comment anchors. `just generate`.                                                            |
| Daemon       | `internal/git/status.go` (per-file revision, index fingerprint); `internal/git/changeset/service.go` (card → checkout resolution, reads without revision, patch LRU); `internal/git/operations/manager.go` (path and index preconditions, checkout operations from cards, typed busy faults); `internal/api/git.go` (activity per checkout); `internal/store/workspaces` (comment anchors). |
| Core         | `workspace/CheckoutChanges.kt` (new, from `ProjectChanges.kt`); `WorkspaceReview.kt` (scope delegation, single flight, revision-free diff reads, outdated comments); `WorkspaceRules.kt` (checkout gating and reasons); `runtime/Failures.kt`; `client/SliceMappers.kt`, `client/ReviewCommands.kt`; client proto slices.                                                                   |
| Mac          | `ConversationContentModel.swift`, `ConversationContentPane.swift`, `ConversationView.swift`, `ConversationChrome.swift` (delete the redirect); `ProjectChangesModel.swift`, `ProjectChangesView.swift` (errors, activity chip, disabled reasons).                                                                                                                                           |
| Compose      | `tools/ReviewScreen.kt` (checkout scope layout, reusing the `ProjectChangesScreen` rows); `store/ReviewModel.kt`.                                                                                                                                                                                                                                                                           |
| CLI and docs | help text for `workspace changes`, `diff` and `run` (a CARD may be project mode); regenerated CLI reference; `.agents/skills/dieter-cli/SKILL.md`; `site/content/docs/workspace.md` ("open the project's Changes" becomes "in place").                                                                                                                                                      |

Tests:

- **Go: changeset and operations.**
  - A diff read after an unrelated write succeeds.
  - Staging `A` after a write to `B` succeeds; after a write to `A` it fails
    and names `A`.
  - A commit after the index changed fails.
  - Multi-page diffs survive a write to another file and restart on a write to
    their own file.
  - A project-mode `card_id` resolves to its checkout.
  - Activity and active operations are filtered by checkout.
- **Go: `internal/api/workspace_git_test.go`.** The full conversation flow
  through `card_id` in project mode. It replaces the assertion that
  card-scoped requests must fail.
- **Kotlin core.**
  - No refresh and diff ping-pong against a fake session whose revision moves
    on every call.
  - Single-flight refresh.
  - A cache hit when another file changed.
  - Gating reasons.
  - Scope routing of the review slice.
  - Stale-while-revalidate on read failures.
- **Devices.** Maestro flows for a project-mode conversation's Changes pane on
  Android and iOS (`tests/maestro`, showcase fixture) and the Mac pane
  smoke.

### Phase 2: push (D4)

- Daemon: `changeset.Hub`, engine tool-result trigger, Linux inotify,
  `WatchChangeset`.
- CLI: `watch-changes`; topology e2e over local, direct TLS and relay; stream
  and frame bounds tests.
- Core: subscriptions replace both pollers.
- Measure before and after, locally and over the relay:
  - open-to-list latency;
  - write-to-visible latency;
  - daemon `git status` runs per minute with two clients watching one
    directory;
  - daemon CPU while a view is open and nothing changes.

### Phase 3: worktree branch view (D6)

Commits, numstat cache, "Committed on this branch" section, merge checklist on
real commits; core, Mac and Compose rendering; tests for agent-committed work.

## Risks and decisions

- **Staging what the agent is still writing.** If the agent rewrites `A`
  between review and execution, the stage is rejected with the path named.
  That is correct: the user staged content they did not see. A commit only
  takes the index, so writes elsewhere cannot change what is committed.
- **Discard and update stay blocked while a project-mode turn runs** in that
  checkout. They would destroy or rebase the agent's working state. The UI
  says so up front.
- **mtime granularity.** File revisions use nanosecond mtimes, as today's
  revision does. A same-size rewrite within one timestamp tick goes unnoticed
  until the next change; this is unchanged from today and acceptable for
  display. Mutations re-read status under the lock.
- **Huge trees.** The bounded file list with totals and the adaptive reader
  interval keep the view working where `ErrTooManyChanges` and fixed polling
  fail today.
- **macOS watching.** There is no fsnotify, so pushes come from tool-result
  triggers and the adaptive poll. FSEvents (cgo, CoreServices) is an
  optimization only if measurements call for it.

## Side findings (separate follow-ups)

- `dieter … --project NAME` resolves the project through `GetState`, which
  takes 1.27 s on this store, so every project-scoped CLI command pays over a
  second before its real RPC.
- `activeRuntimeLeases` deletes stale lease files from a read path without the
  central writer lock (`internal/store/leases/leases.go:150`).
- The daemon used about 0.86 CPU-seconds per second while idle during this
  session. Few samples fell in Dieter handler code. A remote-desktop session
  (`dieter-capture` at 60 fps) was active at the time; this is unattributed,
  not a Changes cost.
