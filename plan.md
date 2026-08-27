# Native Workspaces, Changesets, and Pull Requests

Status: server, daemon, gateway relay, persistence, and CLI are implemented and
tested. macOS and Android product integration is the next phase.

Last reviewed: 2026-08-27.

## 1. Purpose of this document

This is the implementation handoff for the teams adding the new Git workspace
features to the macOS and Android clients. It documents what the server already
does, how clients must use it, what product flows are possible now, and which
ideas from the reference screenshots still require more server work.

The authoritative API is
[`api/proto/dieter/v1/dieter.proto`](api/proto/dieter/v1/dieter.proto). The
native clients must use these RPCs through the existing authenticated
direct-daemon-or-gateway connection. They must not run Git, inspect the
repository path, call GitHub directly, or read `DIETER_HOME`.

## 2. Product decisions that are already settled

### 2.1 There is no repository-policy object

A project has defaults, not a separate repository policy:

- `default_workspace_mode`: `main`, `branch`, or `worktree`;
- `base_remote`: normally `origin`, but it may be empty for local-only work;
- `base_branch`: normally `main`, but it is repository-specific; and
- `validation_commands`: an ordered list of daemon-host commands.

Every board card and every standalone chat then has its own workspace selection:

- `workspace_mode`;
- optional `workspace_branch`; and
- optional `workspace_base_branch`.

The project values are defaults copied/resolved for new work. The per-conversation
selection is the actual execution choice. Do not introduce a second client-side
policy model or allow cards and chats to drift into different implementations.

### 2.2 A card and a chat use exactly the same interface

Both `CreateCard` and `CreateChat` accept `CreateConversationRequest`. Both return
`Card`; a standalone chat is a card with `scope == "chat"`. All workspace,
changeset, file, terminal, Git-operation, and PR RPCs use that same `card_id`.

Native code should therefore build one reusable conversation-workspace feature
and present it from both the board-card conversation and standalone-chat
conversation. Avoid parallel `CardWorkspace` and `ChatWorkspace` state machines.

### 2.3 Workspace modes

| Mode | Execution location | Branch behavior | Isolation | Intended use |
| --- | --- | --- | --- | --- |
| `main` | Registered project checkout | Uses its current/base branch | None | Explicit small tasks where working directly in the checkout is desired |
| `branch` | Registered project checkout | Switches the shared checkout to the selected/generated branch | Git branch only | Compatibility or explicitly shared-checkout work |
| `worktree` | `$DIETER_HOME/worktrees/<project-id>/<card-id>` on the daemon host | Uses the selected branch or a Dieter-generated `dieter/...` branch | Filesystem and branch | Recommended default for concurrent cards/chats |

The worktree path is daemon-local metadata. Never assume `.worktrees/`, never
construct the path on a client, and never use `Workspace.path` as a remote file
URL. Send `card_id` plus a repository-relative path to file and terminal RPCs.

`main` and `branch` share the registered checkout. The daemon rejects unsafe
checkout/Git operations while another conversation is active there. Worktrees
are the mode that gives independent conversations independent working folders.

### 2.4 Selection and provisioning lifecycle

1. The user chooses a mode during card/chat creation, or accepts the project
   default.
2. `UpdateConversationWorkspace` may change the selection until the first agent
   prompt is sent. `Card.initial_prompt_sent_at` is the client-visible lock
   boundary.
3. `GetWorkspace`, a card-scoped file/terminal call, or the first agent turn
   lazily provisions the durable workspace.
4. After the first turn, normal mode editing is rejected. The only supported
   migration is a clean `branch` workspace to `worktree`, using the durable
   `migrate` Git operation.
5. Integration marks the workspace `cleanup_pending`. Cleanup is a separate,
   explicit operation so a successful merge is never hidden by a cleanup error.

Existing projects and conversations hydrate safely as `main` when no workspace
fields are present.

## 3. What the server supports now

### 3.1 Project and conversation configuration

- `UpdateProjectWorkspaceSettings`
- workspace fields on `Project`
- workspace fields on `CreateConversationRequest`
- `UpdateConversationWorkspace`
- workspace and PR summaries on every hydrated `Card`

Validation commands are argv-based; no shell is used. Each command has an
executable, arguments, optional contained working directory, environment,
display name, and timeout. The daemon rejects unsafe working directories,
invalid environment names, and timeouts above one hour.

### 3.2 Workspace inspection and lifecycle

- `GetWorkspace` provisions if needed and returns refreshed Git state.
- `ListProjectWorkspaces` lists durable workspaces for cleanup/administration.
- States: `reserved`, `provisioning`, `ready`, `conflicted`,
  `cleanup_pending`, `orphaned`, `recovery_required`, and `failed`.
- The response includes mode, branch/base/upstream, SHAs, ahead/behind counts,
  changed-line counts, revision, active operation ID, integration markers, and
  adoption history.
- Workspace and repository locks work across daemon processes and recover stale
  lock holders.

`GetWorkspace` is not a purely passive read: it may create a branch/worktree.
Call it when entering a conversation workspace or when an explicit refresh is
needed, not in a rapid UI polling loop.

### 3.3 Workspace-scoped files and terminals

All existing file requests now accept `card_id`:

- `ListFiles`
- `ReadFile`
- `SaveFile`
- `CreateFile`
- `MoveFile`
- `DeleteFile`

When `card_id` is present, the daemon resolves the conversation workspace and
ignores the registered checkout as the content root. Existing project-only use
remains compatible. In a conversation UI, always send `card_id`.

Files use repository-relative slash-separated paths. `.git`, path escape, and
unsafe symlink traversal are rejected. Editable files are bounded to 5 MiB.
`SaveFile` uses `FileDocument.revision` for optimistic concurrency; an
`Aborted` response means reload before editing/saving again.

Terminals now accept and return `card_id` through:

- `ListTerminals`
- `CreateTerminal`
- the existing terminal watch/input/resize/rename/close RPCs.

A terminal created for a card starts in that card's workspace. Active terminals
also make destructive or checkout-changing Git operations fail with
`FailedPrecondition`; the user must close the terminal first.

### 3.4 Changesets and review comments

- `GetChangeset` returns the current `revision`, comparison/head/base SHAs,
  aggregate additions/deletions, changed files, and commits.
- A changeset includes both commits since the comparison base and current
  staged, unstaged, and untracked changes.
- `volatile == true` means an agent turn is currently active and the view may
  change immediately.
- `GetFileDiff` returns the complete current file patch in bounded pages.
- `GetCommitDiff` uses the same surface for one commit/file.
- `FileDiff.truncated`, `next_offset`, and `total_bytes` drive pagination. A
  page is at most 1 MiB.
- Binary files are identified without pretending to provide a text patch.
- `AddChangeComment` and `ListChangeComments` provide durable comments anchored
  to card, changeset revision, path, side (`new` or `old`), and optional line.

Always pass the latest changeset revision to diff, comment, and Git mutation
requests. A revision covers HEAD, base, index, working tree, and untracked file
content. If the workspace changes, the daemon returns `Aborted`; discard the
stale rendering, fetch a new changeset, and preserve any unsent comment text
locally for the user.

Change comments are review annotations only. They do not wake an agent, resume
a harness turn, or count as approval. “Ask agent to address review” must use the
existing `SendMessage` RPC, optionally quoting or summarizing the selected
change comments.

There is currently no edit, delete, resolve, or reply RPC for change comments.

### 3.5 Durable Git operations

All Git mutations use one interface:

1. Fetch a fresh `Changeset`.
2. Call `StartGitOperation` with `card_id`, `kind`, the changeset
   `expected_revision`, and string parameters.
3. Treat the returned operation as `queued`, not completed.
4. Open `WatchGitOperation` and render operation snapshots plus ordered logs.
5. Persist the highest log `sequence`; reconnect using `after_sequence`.
6. Refresh `GetWorkspace`, `GetChangeset`, and `GetCard` after a terminal state.

Supported statuses are:

- active: `queued`, `running`;
- paused for user/agent work: `waiting_for_resolution`;
- terminal: `succeeded`, `failed`, `canceled`, `interrupted`.

Closing a screen, canceling a client coroutine/task, losing the gateway tunnel,
or canceling `WatchGitOperation` does **not** cancel the Git operation. Only an
explicit `CancelGitOperation` requests cancellation. A conflicted operation
cannot be canceled through that RPC; use `abort_conflict`.

The daemon admits only one Git operation per workspace. It also rejects Git
operations while that card's agent turn or terminal is active. Operations on a
shared `main`/`branch` checkout are rejected while another project conversation
is active. Map these failures to a non-destructive “workspace busy” state and
offer retry.

#### Operation kinds and parameters

All values in `parameters` are strings; booleans are exactly `"true"` or
`"false"`.

| Kind | Parameters | Behavior |
| --- | --- | --- |
| `commit` | required `subject`; optional `body`; `include_untracked` defaults to `true` | Stages and commits workspace changes; validation is not implicit |
| `update` | `fetch` defaults to `true`; `validate` defaults to `true` | Fast-forwards a clean `main`, otherwise rebases the conversation branch onto the base |
| `continue_conflict` | none | Continues the current conflicted rebase after files are resolved |
| `abort_conflict` | none | Aborts the current rebase/merge and cancels the waiting operation |
| `validate` | none | Runs all project validation commands in order |
| `merge_local` | `strategy`: `squash` (default), `merge_commit`, or `fast_forward`; optional squash `subject`; `validate` defaults to `true` | Prepares and validates in an isolated integration worktree, then fast-forwards the registered base checkout |
| `push` | optional `force_with_lease`; required `expected_remote_sha` when forcing | Pushes the conversation branch to the configured base remote |
| `cleanup` | none | Removes only clean and safely integrated work; deletes only Dieter-managed branches |
| `discard` | none | Creates recovery artifacts, then force-removes the workspace/managed branch |
| `adopt` | required `target_card_id` | Transfers the existing workspace to an inactive same-project card/chat that has no workspace |
| `migrate` | required `mode=worktree` | Moves a clean started `branch` conversation into a worktree |
| `create_pr` | optional `title`, `body`, `draft`; `push` defaults to `true` | Idempotently pushes and creates or reuses an open GitHub PR for the head branch |
| `refresh_pr` | none | Refreshes aggregate PR, checks, review, mergeability, and SHA state |
| `merge_pr` | `strategy`: `squash` (default), `merge`, or `rebase`; optional `expected_head_sha` | Merges through GitHub with head-SHA protection and marks cleanup pending |

`expected_revision` is technically optional for compatibility, but native
clients should always send it for user-triggered mutations. The daemon also
captures expected base/head SHAs when admitting local merges, preventing a
prepared result from landing after either side moves.

### 3.6 Conflicts

`update` may enter `waiting_for_resolution`. The operation then includes
`GitConflict` entries with relative paths and hunk counts, while the workspace
state becomes `conflicted`.

The supported resolution flows are:

1. **Human resolution:** open each path through card-scoped file APIs, save the
   resolved content, ensure conflict markers are gone, then start
   `continue_conflict`.
2. **Agent resolution:** send a normal human chat message asking the same
   durable conversation to resolve the listed paths. When the agent turn ends,
   refresh the changeset and start `continue_conflict`.
3. **Abort:** start `abort_conflict`.

If conflicts still exist, `continue_conflict` itself returns to
`waiting_for_resolution`; this is not a generic failure. Do not offer normal
commit/update/merge actions until conflict resolution or abort completes.

### 3.7 Local integration, cleanup, discard, and adoption

Local integration is intentionally multi-step:

1. If uncommitted changes exist, run `commit` first.
2. Optionally run `update` to rebase onto the latest configured base.
3. Run `merge_local` with the selected strategy; configured validation runs by
   default.
4. After success, refresh and verify `Workspace.state == "cleanup_pending"`.
5. Optionally run `cleanup`.
6. Moving a board card to Done is a separate `MoveCard` request.

Do not present these as one transaction. If merge succeeds but cleanup or card
movement fails, show the integrated result and allow the remaining action to be
retried independently.

`discard` is destructive from the user's perspective, so require confirmation.
Before removal, the daemon writes recovery data under its central recovery
directory: a branch bundle when applicable, staged and unstaged binary patches,
an archive of regular untracked files, and `RESTORE.txt`. Native clients cannot
download or restore these artifacts yet; tell the user that recovery is on the
daemon host and include the operation log/result in support details.

`adopt` enables “continue these leftover changes in a new chat.” The target must
be in the same project, inactive, and without a provisioned workspace. A useful
client flow is: create a deferred-start chat, adopt into its returned card ID,
then open/start that chat.

### 3.8 GitHub pull requests

Call `GetSCMCapabilities` before showing enabled PR actions. Current SCM support
is GitHub only and runs on the daemon host:

- a configured remote must resolve to one `owner/repository` GitHub URL;
- `git` push access must work on the daemon host;
- `gh` must be installed there; and
- `gh auth status` must succeed for the remote hostname.

Dieter's gateway OAuth session authenticates the person to Dieter; it does not
provide repository credentials and must not be used for GitHub operations.

The normal PR flow is:

1. Commit and validate.
2. Call `GetSCMCapabilities` and explain any `unavailable_reason`.
3. Run `create_pr`; it pushes by default.
4. Refresh `GetCard` to obtain `pull_request`, or wait for the next hydrated card
   projection.
5. Run `refresh_pr` when the PR panel is opened, on explicit refresh, after a
   push, and at a conservative foreground interval.
6. Gate the client action using `state`, `draft`, `mergeable`, `review_decision`,
   `checks_state`, and the latest known head SHA.
7. Run `merge_pr` with `expected_head_sha`.
8. Run `cleanup` separately after the merge succeeds.

PR creation is idempotent for an already-open PR with the same head branch.
`checks_state` is currently only `passed`, `running`, or `failed`; individual
check names are not exposed. `review_decision` is aggregate state, not a reviewer
list. Always offer `pull_request.url` for opening the provider page.

There is no automatic push after every agent commit. A client may offer a
clearly labeled manual or opt-in “push latest” action by running `push`; it must
not silently create a background policy that the daemon does not own.

## 4. Common native-client implementation plan

The Mac and Android teams should share the following behavior even though their
view code differs.

### Phase A: transport wrappers and client state

Add typed wrappers for every RPC listed in sections 3.1–3.8. Keep all calls on
the existing endpoint abstraction so direct TLS and gateway relay behave
identically.

Recommended per-conversation client state:

- current `Workspace`;
- current `Changeset`;
- diffs keyed by `(revision, commit_sha, path)`;
- change comments keyed by revision;
- `SCMCapabilities`;
- the PR summary from the hydrated `Card`;
- active `GitOperation`, ordered log frames, and highest sequence; and
- independent loading/error state for workspace, changes, SCM, and mutation.

Clear revision-keyed diffs when the changeset revision changes. Preserve editor
drafts and unsent review comments separately from server projections.

Do not persist a Git operation as “canceled” merely because its watch task was
canceled. On reconnect, use `Workspace.current_operation_id`, `GetGitOperation`,
and `WatchGitOperation(after_sequence:)` to recover.

### Phase B: project defaults and conversation creation

Add project settings for mode, base remote, base branch, and validation command
configuration. Add the same mode/branch/base fields to both card and chat
creation. Display the resolved project default before submission.

For deferred cards/chats, allow `UpdateConversationWorkspace` while
`initial_prompt_sent_at` is empty. Once it is set, replace the picker with a
read-only mode/branch summary and expose only valid lifecycle operations such
as branch-to-worktree migration.

Worktree should be the recommended isolated choice, but the UI must preserve
the user's explicit project default and per-conversation selection.

### Phase C: make existing files and terminals conversation-aware

This is required for correctness, not an optional enhancement:

- when Files is opened from a card/chat, send `card_id` on every file RPC;
- when a terminal is created/listed from a card/chat, send `card_id`;
- display `Terminal.card_id` so users can distinguish project-level and
  conversation-level terminals; and
- keep project-only Files/Terminals behavior for their existing global screens.

Without this phase, a worktree conversation could display or edit the registered
main checkout, which is a data-integrity bug.

### Phase D: changeset review

Build a conversation-level Changes destination backed by `GetChangeset`:

- summary counts and comparison base;
- changed-file list with status, binary/conflict indication, and line counts;
- inline or split rendering from the unified patch;
- lazy diff pagination;
- commit list and commit-specific diffs;
- revision-scoped line comments; and
- explicit volatile/stale refresh states.

“Viewed” files may be maintained as local client preference keyed by
`card_id + revision + path`; there is no shared server field for it.

### Phase E: Git actions and conflict recovery

Create one reusable operation coordinator that starts, watches, reconnects,
cancels, and refreshes after operations. All action sheets/buttons should call
that coordinator rather than implementing separate polling loops.

Derive action availability from server state:

- disable mutations while `current_operation_id` is non-empty;
- show a conflict-specific action set for `conflicted` or
  `waiting_for_resolution`;
- show cleanup/discard actions for `cleanup_pending` and inactive leftovers;
- treat `orphaned`, `recovery_required`, and `failed` as support/recovery states,
  not as permission to recreate or delete silently; and
- handle `FailedPrecondition` as busy/retryable unless the message explains a
  permanent precondition.

### Phase F: PR workflow

Add capability discovery, create/refresh/push/merge actions, aggregate checks
and review status, provider URL, expected-head protection, and separate cleanup.
Hide or disable PR creation in `main` mode. Show `unavailable_reason` rather
than a generic network error when `gh` or daemon-host auth is missing.

### Phase G: project workspace administration

Use `ListProjectWorkspaces` to join durable workspace records with cards/chats
from the sync projection. This can support active/leftover grouping, Review,
Adopt, Cleanup, and confirmed Discard.

The current native RPC cannot calculate fresh directory sizes or bulk-clean all
workspaces. Do not display precise size or “Clean up all” as implemented server
behavior. Those require either individual operations plus client orchestration,
or a future server endpoint.

## 5. macOS implementation notes

The Swift protobuf and gRPC sources are already regenerated. Verify them with:

```sh
./apps/mac/scripts/generate-swift-proto.sh --check
```

Recommended integration points:

- Add RPC wrappers in
  `apps/mac/Sources/DieterMac/Networking/DieterRPC.swift`.
- Put authoritative selection/workspace/changeset/operation state and stream
  task ownership in
  `apps/mac/Sources/DieterMac/Model/DieterStore.swift`.
- Extend both creation flows in `UI/Forms.swift` and/or their current shared
  creation components; do not implement only board cards.
- Add `cardID` overloads to the existing Files and Terminal store/RPC methods.
- Add the conversation-level Changes surface from `UI/ConversationView.swift`.
- Add project defaults to the existing project management/settings surface.
- Reuse the app's current endpoint, reconnect, and foreground-refresh behavior.
  Do not open a second connection specifically for Git operations.

Swift streaming detail: `WatchGitOperation` is a server stream. Own its task in
the store, retain the last log sequence, and cancel the local task when selection
changes without calling `CancelGitOperation`. Explicit user cancellation is a
separate store action.

Add pure reducer/policy tests beside `DieterMacTests` for operation state,
action availability, revision replacement, and stream resumption. Add a native
UI smoke that uses `scripts/isolated-gateway`; never point UI automation at a
developer's running daemon or production gateway.

## 6. Android implementation notes

Android compiles protobuf/grpc-kotlin sources directly from `api/proto`, so a
normal Gradle build already exposes the new generated messages and coroutine
stub methods.

Recommended integration points:

- Extend the `DieterRepository` interface and gRPC implementation in
  `apps/android/app/src/main/java/com/dbpprt/dieter/data/DieterRepository.kt`.
- Put durable UI projections and operation-stream ownership in the existing
  `DieterConnectionManager`/ViewModel boundary; do not let composables own
  long-running server operations.
- Add project defaults to the existing `WorkspaceManagementScreen`. Note that
  this existing screen uses “workspace” to mean Dieter's overall project
  management area; name Git-specific types and state explicitly to avoid
  confusing the two concepts.
- Extend the shared card/chat creation policy and payload builders with mode,
  branch, and base branch.
- Add `cardId` to repository file and terminal methods when invoked from a
  conversation.
- Build one Changes screen/component that accepts any conversation `Card`.
- Collect `WatchGitOperation` as a reconnectable `Flow`, deduplicate by
  sequence, and keep it alive across ordinary Compose recomposition.

Use lifecycle-aware collection for rendering, but keep the operation recovery
identity in the connection/state layer so backgrounding the app does not imply
server cancellation. On resume, fetch the operation and reopen the stream from
the last sequence.

Add JVM tests for payload construction, state reducers, operation availability,
stale revision handling, and sequence deduplication. Add instrumented coverage
against the isolated gateway for both direct screen recreation and tunnel
reconnect.

## 7. Mapping the reference screenshots to current capability

The screenshots are product references, not exact API promises.

| Screenshot idea | Available now | Native/client responsibility or gap |
| --- | --- | --- |
| Changes tab with file list and unified/split diff | Yes | Render patch, paginate, maintain local viewed state |
| Commit list and per-commit diff | Yes | Use `Changeset.commits` and `GetCommitDiff` |
| Update from main and conflict file list | Yes | Run `update`; render waiting operation conflicts |
| Resolve with agent | Yes, composed from existing APIs | `SendMessage`, wait for turn, then `continue_conflict` |
| Pre-merge validation result/log | Yes | Run `merge_local` or `validate`; render operation results/logs |
| Squash, merge commit, fast-forward local merge | Yes | `merge_local.strategy` |
| Commit uncommitted work before merge | Yes as two operations | Client runs `commit`, then `merge_local`; not atomic |
| Remove worktree/branch after merge | Yes as separate operation | Run `cleanup` after integration succeeds |
| Move card to Done after merge | Existing API, separate step | Call `MoveCard`; never imply merge rollback if movement fails |
| Create/open/refresh/merge GitHub PR | Yes | Use capability and PR operation flow |
| Aggregate checks/review/mergeability chip | Yes | Refresh PR and use `PullRequestSummary` |
| Individual build/lint/e2e rows or reviewer names | No | Requires a richer PR-details RPC |
| Automatically push every new agent commit | No | Manual/opt-in client orchestration only |
| Adopt leftover workspace into a new chat | Yes | Create deferred chat, then `adopt` |
| Confirmed discard with daemon recovery | Yes | Run `discard`; restore UI/API is not implemented |
| Worktree disk size | Not through current native RPC | Do not show precise size yet |
| Clean up all | No bulk operation | Sequence individual safe cleanups or add a future RPC |
| Shared viewed-file state | No | Keep it device-local unless a server model is added |
| Resolve/edit/delete change comments | No | Requires additional comment lifecycle RPCs |

## 8. Error and concurrency contract

Native clients should branch on gRPC/Connect status codes first, then display the
server message as detail:

| Code | Meaning in these flows | Client behavior |
| --- | --- | --- |
| `Aborted` | Changeset/file revision became stale | Refresh and preserve unsent local text |
| `FailedPrecondition` | Active agent, terminal/process, shared-checkout user, or unmet lifecycle condition | Explain busy/precondition and offer retry or the required action |
| `ResourceExhausted` | Bounded queue/log/file/stream capacity reached | Stop retry loops and show the limit |
| `NotFound` | Card, workspace, operation, PR, or file no longer exists | Refresh parent projection and close stale detail |
| `PermissionDenied` | File path/symlink protection | Do not retry with path rewriting |
| `InvalidArgument` | Invalid mode, parameter, path, validation config, or unsupported transition | Treat as a client/request bug unless user input caused it |
| `Canceled` / `DeadlineExceeded` | Transport/request ended | Re-read durable operation state before deciding outcome |

Never infer operation failure from a dropped stream. Never start a duplicate
operation merely because the initial response or terminal frame was lost. First
read `Workspace.current_operation_id` and `GetGitOperation`.

The gateway is only an authenticated relay for these methods. It stores no
project, branch, workspace, changeset, operation, PR, comment, GitHub credential,
or recovery data.

## 9. Manual server/API verification with the CLI

The CLI is useful as an executable contract while building native clients:

```sh
dieter project open --workspace worktree --base-remote origin --base-branch main /path/to/repo
dieter project workspace --mode worktree --base-remote origin --base-branch main PROJECT_ID

dieter card create --project PROJECT_ID --board BOARD_ID --lane todo \
  --title "Workspace test" --workspace worktree --base-branch main --format id
dieter card workspace --mode worktree --base-branch main CARD_ID

dieter workspace show CARD_ID
dieter workspace changes CARD_ID
dieter workspace diff --path README.md --revision REVISION CARD_ID
dieter workspace scm CARD_ID

dieter workspace run --kind commit --revision REVISION \
  --param subject="Workspace test" CARD_ID
dieter workspace run --kind update --revision REVISION CARD_ID
dieter workspace run --kind validate --revision REVISION CARD_ID
dieter workspace operation OPERATION_ID
```

Run `dieter workspace --help` and `dieter workspace run --help` before destructive
operations. CLI comments are non-triggering just like RPC change comments.

For isolated native end-to-end testing, start the throwaway gateway/daemon
harness in a separate terminal:

```sh
go run ./scripts/isolated-gateway --addr 127.0.0.1:14243
```

It prints `DIETER_ISOLATED_ADDR`, `DIETER_ISOLATED_TOKEN`,
`DIETER_ISOLATED_DAEMON`, `DIETER_ISOLATED_PROJECT`, and
`DIETER_ISOLATED_BOARD`, then blocks until interrupted. It creates a real Git
repository, an enrolled daemon tunnel, and a deterministic mock harness without
touching the normal daemon or gateway.

## 10. Required native acceptance coverage

Both native implementations should prove the following matrix for a board card
and a standalone chat:

1. Create with project default and with each explicit mode.
2. Change selection before first turn and verify it locks after first prompt.
3. Provision `main`, `branch`, and `worktree`; confirm returned path/mode/branch
   without constructing paths client-side.
4. Read, create, save, move, and delete a file through `card_id`; prove the
   registered checkout is untouched for a worktree.
5. Create/resume/close a card-scoped terminal and prove Git operations are busy
   while it runs.
6. Render tracked, staged, unstaged, untracked, renamed, deleted, binary, and
   conflicted changes.
7. Page a large diff and reject/refresh a stale revision.
8. Add and reload line comments without waking the agent.
9. Commit and validate while streaming logs; reconnect the watch by sequence.
10. Rebase into a real conflict, resolve through file APIs, continue, and abort
    in a second case.
11. Locally integrate with squash, merge commit, and fast-forward where valid;
    verify cleanup is separate.
12. Discard and surface the recovery-artifact log message.
13. Adopt a leftover worktree into a deferred same-project chat.
14. Migrate a clean started branch workspace to worktree.
15. Exercise SCM unavailable states without `gh`/auth.
16. Against a disposable GitHub repository or fake provider fixture, create,
    idempotently recreate, refresh, head-protected merge, and cleanup a PR.
17. Drop the gateway/watch connection during a running operation and prove the
    operation continues and the client resumes it without duplication.
18. Background/recreate the native screen and prove that local task cancellation
    does not call `CancelGitOperation`.

Minimum repository checks after native implementation:

```sh
./apps/mac/scripts/generate-swift-proto.sh --check
swift test --package-path apps/mac

export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
(cd apps/android && ./gradlew test)

go test -race ./...
go vet ./...
go build ./cmd/dieter
go build ./cmd/dieter-gateway
```

Do not stop or repoint a developer's running daemon/gateway for end-to-end tests.
Use `scripts/isolated-gateway` or an explicitly separate `DIETER_HOME`, loopback
address, and process.

## 11. Server extensions to consider only after the first native slice

The current API is sufficient for the primary screenshots and lifecycle. These
are legitimate follow-up server additions, but the native teams should not fake
them as durable features:

- richer PR details: named checks, reviewers, review threads, requested changes;
- shared viewed-file/review-resolution state;
- edit/delete/resolve/reply operations for change comments;
- paginated Git-operation history per conversation;
- fresh workspace disk-size measurement and explicit stale classification;
- safe bulk cleanup planning/execution;
- recovery artifact listing, download, and guided restore;
- daemon-owned auto-push policy with explicit opt-in and failure state;
- a preflight conflict/mergeability operation that does not mutate the branch;
- multi-file or structured conflict-resolution helpers; and
- non-GitHub SCM providers.

Until those exist, keep related UI state local, label it accurately, or omit the
feature. The daemon remains the sole authority for Git state and mutation.
