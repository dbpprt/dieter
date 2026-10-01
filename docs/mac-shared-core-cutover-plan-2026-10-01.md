# macOS cutover to the shared core

Date: 2026-10-01. Status: in progress.

The macOS app (`apps/mac`, target `DieterMac`) moves onto the shared Kotlin
Multiplatform core (`apps/core`) the way Android did: every client rule lives
in the core, and the Mac app keeps SwiftUI/AppKit presentation plus platform
adapters. This is the macOS column of W7 in
[the core implementation plan](kmp-core-implementation-plan-2026-09-30.md).
The iOS app stays on the Swift stack until its own cutover and must keep
building throughout.

## 1. Starting point

- **Mac app.** About 65k lines in `DieterMac`:
  - `AppSession` (`typealias DieterStore`) and its `DieterStore+*`
    extensions hold about 6k lines of orchestration: connection, route
    selection, sync, replica, outbox, optimistic overlays, and projections.
  - About a dozen `@Observable` feature models each hold their own RPC
    binding: conversation, composer, files, terminals, schedules, worktree
    changes, project changes, fleet, processes, screens, and quotas.
  - `DieterCore` (3.2k lines) and `DieterClient` (3.1k lines) hold the
    policies and the transport. Both are shared with iOS.
- **Core.** Every domain is implemented and tested in Kotlin. Apple reaches it
  only through `DieterShared`: `dispatch(command bytes)` and
  `observe(slice, scope)`. That façade has 28 commands and 5 slices (session,
  workspace, outbox, activity, conversation), and only the adapter harness in
  `apps/core/harness/apple` uses it. That harness transport is relay-only,
  and the WebRTC control route is not injectable.
- **Legacy import.** The core already imports the macOS formats: gateways,
  tokens, `pending-commands.json`, shared-KV caches, drafts, creation choices,
  terminal selections, and notifications. `sync-state.json` is dropped.

## 2. Decisions

1. **Contract (D7, confirmed).**
   - Schema-first commands and slices over the generic byte façade.
   - SwiftProtobuf stays the Mac UI model, so views keep their `Dieter_V1_*`
     types. The client schema is split into domain files under
     `model/src/commonMain/proto/dieter/client/v1/`.
   - Swift is generated into `apps/mac/Sources/DieterAPI/Generated` by the
     existing script, with a freshness manifest.
2. **Presentation lives in the core.**
   - Slices carry presentation-ready fields: timeline items, live activity,
     machine rows, notices, diff rows, schedule summaries, and so on.
   - Pure helpers that views call while rendering, with only primitive
     inputs (relative ages, byte sizes, compact paths), are exported
     synchronously through one `SharedRules` object. That avoids an
     asynchronous round trip per cell.
   - View mechanics stay in Swift: scroll ownership, render windows, layout,
     and AppKit editors.
3. **Instance surfaces.**
   - Some core domains are per-view instances: files, the file tree,
     terminals, workspace review, project changes, and screens.
   - They are opened by subscribing to a scoped slice and closed when the
     last subscription ends, as conversations already are.
   - Commands address them by the same scope.
4. **Staged cutover.** The app keeps building and running after every stage.
   - Stage M3.1 moves connection, sync, outbox, board, and conversation onto
     the core.
   - Until each feature domain moves, its model keeps the existing
     temporary data-plane leases (`ConnectionManager.temporaryLease`). They
     read the same `gateway-sessions.json` token that the core's secure store
     writes.
   - Each later stage moves one domain and deletes its Swift logic and its
     lease use. The last stage removes `ConnectionManager` from `DieterMac`.
5. **iOS is untouched.**
   - `DieterCore` and `DieterClient` stay for iOS.
   - `DieterMac` stops using their policy files.
   - Files that only the Mac used are deleted as their domain moves.
   - The package, including the `DieterShared` binary target, must still
     build for iOS.
6. **Behaviour unifies on the core.** These Mac-only differences are
   accepted, and each is noted in its stage's commit:
   - remote plaintext gateways are rejected;
   - the relay route is labelled "Relay";
   - the core's backoff and cooldown tables apply;
   - there is one data plane per machine instead of an idle pool with
     background WebRTC upgrade;
   - the first launch after the cutover starts with a cold projection cache.
7. **The legacy import runs once, before `start()`.**
   - Nothing legacy is deleted until the stage that removes the reader.
   - The client ID (`DieterSyncClientID`) is kept, because outbox
     idempotency depends on it.

## 3. Architecture after the cutover

```
DieterMac (SwiftUI/AppKit views, AppKit adapters)
  └─ AppSession + feature models: thin @Observable adapters
       └─ SharedCore (Swift target)
            ├─ CoreClient: dispatch / observe; live, and a scripted fake for tests
            ├─ platform services: grpc-swift RPC bridge (gateway, relay,
            │   pinned direct TLS), WebRTC control channels, file secure store,
            │   UserDefaults settings, URLSession, CryptoKit, os_log,
            │   UserNotifications with actions, SwiftTerm and screen media sinks
            └─ legacy inputs reader (macOS formats)
                 └─ DieterShared.xcframework (Kotlin/Native, static, arm64)
```

- **Swift targets.**
  - `SharedCore` is a new library target in the Mac package. The
    `CoreBridge` code in `apps/core/harness/apple` moves into it, and the
    harness is retired.
  - The binary target is `apps/mac/Frameworks/DieterShared.xcframework`. It
    is git-ignored and assembled by `just mac build`, `just mac test`, and
    `just ios build` whenever its core inputs change.
- **Threading.**
  - The core runs on its single dispatcher.
  - Slice updates are decoded off the main thread and applied on the main
    actor.
  - A gap in the per-subscription sequence triggers a resubscribe.
- **Tests.**
  - Adapters depend on the `CoreClient` protocol, so the Mac view and
    layout tests feed scripted slices through a fake.
  - Integration tests drive the real framework against the isolated
    gateway.

## 4. Stages

Each stage lists what it moves, what it deletes, and what must pass before
the next one starts. "Mac green" means `just mac check`, `just mac core-test`,
and `just ios build`.

### M1 — Foundation (additive; app behaviour unchanged)

- **Build.**
  - Add recipes `just core apple-framework debug|release` and a freshness
    check.
  - Add the binary target, wired into `build.sh`, `just mac test`, and
    `just ios build`.
  - CI: Java and Gradle for the `macos`, `ios_quick`, `ios`, release `macos`,
    and `native-e2e` jobs.
  - `check_changed.py` routes `apps/core/` changes to macOS and iOS as well.
- **Façade.**
  - Inject a `ControlChannelFactory` for WebRTC.
  - Carry notification actions and the session through.
  - Make `observe` safe for unknown slices, so an old framework cannot crash
    a newer app.
  - Add the routing and transcript options the Mac needs.
  - Add the `SharedRules` synchronous export.
- **`SharedCore` target.**
  - The production RPC bridge:
    - pinned direct TLS (the chain and SPIFFE checks move from `DieterRPC`
      into a shared helper);
    - 32 MiB message limits;
    - grpc-swift errors mapped to gRPC status codes;
    - a bounded channel table.
  - The platform services, `CoreClient`, and slice folding.
  - The legacy inputs reader.
- **Tests.**
  - Port the harness test to `SharedCoreIntegrationTests`, run by
    `just mac core-test` against the isolated gateway, including a direct TLS
    route.
  - Unit tests for folding, status mapping, and legacy input reading.
- **Exit:** Mac green; `just core test` green.

### M2 — Contract expansion (Kotlin; JVM end-to-end tested)

Domain files and `ClientApi` handlers, each with `ClientApi` end-to-end tests
against the isolated gateway:

| Domain | Slices | Commands (examples) |
| --- | --- | --- |
| Session | machine rows, availability, feed status, sync warnings, gateways | set gateways, clean sync, connect/disconnect |
| Metadata | harness catalogs, settings options, runtime per machine | ensure catalog |
| Workspace | retired boards, settings, chats vs cards, archives | merge, fork, update draft, add label, list archived |
| Navigation | layout, pending status | the 17 layout edits |
| Composition | drafts per conversation, captures, creation memory | text, attachments, selection, capture edits, submit |
| Conversation | presentation (timeline, live activity, failure, delivery, queue, usage) | send, queue edit, steer, retry, tool output, load later |
| Activity | inbox, island, menu bar, notification settings | notification actions, dismiss |
| Files | listing, document and draft, tree | navigate, open, edit, save, reload, create, move, delete |
| Terminals | list and selection, output stream, overview | create, write, resize, rename, close |
| Schedules | list, runs, editor, preview | save, toggle, run, delete |
| Review and changes | workspace review, project changes, project workspaces | git operations, comments, merge flow |
| Admin | projects, checkouts, boards, labels, prompts, settings, conflicts | the 28 administration operations |
| Machines | telemetry, operations, quotas | select, refresh, perform, quota inclusion |
| Executions | processes per conversation | watch, cancel |
| Search | palette results | query |
| Screens | session state; the native media engine protocol | open, input, clipboard, close |

**Exit:** `just core test` and `just core apple-test` green, with every new
command and slice covered.

### M3 — Mac cutover (Swift; one domain per step, legacy deleted per step)

1. **Session, workspace, outbox, board, conversation, activity, and the
   legacy import.**
   - `AppSession` becomes a slice adapter that keeps the member names views
     use today.
   - Deleted: `DieterStore+Connection`, `+Sync`, `+Projection`, the
     transport and outbox halves of `+Conversation`, `DurableOutbox` and
     `OutboxDelivery`, `ConnectionEffects`, and `DieterSnapshotDecoder`.
   - Feature models keep their temporary leases for now.
   - **As built.**
     - `Services/CoreSession.swift` folds the session, workspace, outbox,
       metadata, and board slices into the existing `AppSession` values.
       Machine IDs stay `origin#daemon`, so feature models and drafts keep
       their keys.
     - `Services/FeaturePlane.swift` keeps one legacy data plane to the
       attached machine for the feature models (`rpc`), and rebuilds it
       when the core attaches another machine or the transport stops.
       Opening a conversation on another machine attaches that machine, as
       the legacy app did, so its files, terminals, and review panes work.
     - `ConversationModel` observes the conversation slice. The core marks
       which leading messages are loaded history (`earlier_count`), so
       `olderConversationMessages` and the live window keep their meaning.
       A read receipt is still sent only once the reply is in the transcript.
     - Sign-in is `BeginSignIn` plus the `dieter-mac://` callback;
       `DieterAuthentication` is deleted. The notification switch writes the
       core's `notifications.enabled`.
     - Archived chats are not in the live workspace and are still listed over
       the feature plane until archives move (step 10). The Inbox shows live
       labels for the open conversation only until step 5.
     - UI fixtures that inject state set `coreFoldsHeld`; the latest slices
       apply when released.
     - Core fixes found on the way: a conversation opened under its local ID
       is found by its server ID; conversation deltas carry the card and
       machine IDs; the outbox slice lists failed operations and per-machine
       message and change counts; machine rows carry their sync warnings.
     - Tests: `CoreSessionAdapterTests` (scripted core), the history and
       scroll layout tests ported to the scripted core, and
       `AppSessionCoreIntegrationTests` (the whole session against the
       isolated gateway, run by `just mac core-test`). Tests of the deleted
       Swift logic (durable outbox, transcript cache, connection recovery,
       the conversation reducer, machine routing, directory merging, PKCE)
       were removed; the core's suites cover those behaviours.
   - **Operator safety.** Only the app entry point and isolated integration
     tests build a live core (`AppSession(liveCore: true)`); every other
     construction, including tests and previews, gets an inert scripted
     core. A live core owns the state under its storage root, and a test run
     that defaulted to the live environment once created
     `~/Library/Application Support/Dieter/core`, marking the legacy import
     done. That directory was removed again; the flag prevents a repeat.
   - The Mac core always runs (`SetForeground(true)`): the menu bar, Island,
     and notifications need the live feed while the app is in the
     background.
2. **Navigation and shared layout.** Deleted: `SharedNavigation` and the
   preference value types.
   - **As built.** A navigation slice carries the layout with this device's
     pending edits applied. Each Mac preference edit sends one command
     (`SetProjectOrder`, `SetPinnedProjects`, `SetPinnedChatOrder`,
     `SetProjectExpanded`, `SetChatSectionCollapsed`, `SetChatsShowAll`,
     `SetLaneDescending`, or `SetFolders`, which records only differences),
     in order. Folds from the core are not sent back. The preference value
     types stay as the views' model; the legacy `SharedKV` sync is gone from
     the Mac (iOS still uses it).
3. **Drafts, quick task, capture, and creation.** Deleted: `ComposerModel`
   draft logic, `QuickTaskFormState` choices, and the creation preferences.
   The screen capture and browser-URL intake stay native.
   - **As built.** Draft text lives in the core per machine and
     conversation: `ListDrafts` at start, `SetDraftText` in 250 ms batches
     and when the app resigns active. A composer opened before the drafts
     arrive fills in only if untouched. Creation choices are one memory in
     the core (creation slice, `RememberCreation`), shared by the quick
     task, capture, new card, and new chat surfaces; the Mac's two separate
     `UserDefaults` memories are gone.
4. **Conversation presentation.**
   - Timeline, activity grouping, live activity, turn failure, links, and
     usage come from the core.
   - Markdown rendering and the scroll controller stay native.
   - **As built.** The conversation slice carries a `ConversationState`:
     the runtime to show, whether a turn is active or working, the live
     activity (with and without the reasoning headline), the turn start,
     the responding model, the unsent task, the steerable queued message,
     review readiness, whether the card can start, and context usage. The
     core's presenter computes it from the conversation, the outbox, the
     board operations, and the workspace. The turn failure is the core's
     (summary, log, retryable). `ConversationActivityPresentation` and its
     tests are deleted.
5. **Activity surfaces and notifications.** The island counts, the menu-bar
   events, and the inbox. Notifications are posted by the core through the
   sink.
   - **As built.** The inbox and the menu-bar events read the activity
     slice; the core classifies each conversation's latest activity. The
     Mac derives menu-bar events from those rows with the core's rule.
     Notifications are posted by the core through `CoreUserNotifications`.
   - **Deviation.** The Island resolver stays in Swift: it needs local day
     boundaries, and the core has no calendar dependency yet.
6. **Files and file tree.** The NSTextView editor stays native.
   - **As built.** Files and the conversation file tree are scoped
     surfaces: a view observes `SLICE_FILES` or `SLICE_FILE_TREE` with a
     scope it chooses, which opens a core `Files` or `FileTree`, and
     addresses it with `FilesCommand` or `FileTreeCommand`. The surface
     closes with its last observer. Each command returns the surface after
     it, so the view reads its effect without waiting; an unchanged
     document is left out of updates.
   - The target names the daemon, so the project's files reach the
     checkout's machine whichever machine is attached, and a conversation's
     files stay on the machine they were opened from.
   - Folder history, revision checks, save conflicts (the edits stay), and
     stale-completion guards are the core's. The Mac keeps the editor
     buffer, sends a bind before any later command, ignores slices for a
     previous target, and refuses changes while a surface is not live (for
     example after its conversation's workspace moved).
   - Tests: `FilesCoreDouble` runs the files contract over the old RPC
     fakes for the files and conversation-content view-model tests; the
     JVM contract test covers the live surfaces.
7. **Terminals.** SwiftTerm is fed from the output slice.
   - **As built.** Terminals are scoped surfaces like files
     (`SLICE_TERMINALS`, `TerminalsCommand`): a machine's, project's, or
     conversation's terminals on the machine that runs them. Each observer
     receives every output byte once through its own replay position; a new
     epoch, or falling behind what the core retains, sends a reset with the
     retained bytes. Command results carry the surface without output. A
     surface stops streaming, and drops queued input, when its last view
     leaves; the shells keep running.
   - The account-wide overview is its own surface
     (`SLICE_TERMINAL_OVERVIEW`) with the selected machine's terminals
     inside; terminals commands under the overview's scope address them.
     The Mac's terminals model follows the overview, or binds a
     conversation's surface of its own.
   - Watch resume, input pumps (bounds, no resend of an unconfirmed write),
     resize debounce, and per-scope selection memory are the core's; the
     Mac's input forwarder, watch loop, and `UserDefaults` selections are
     deleted. The output accumulator stays native to pace redraws, fed in
     arrival order.
   - Tests: the Mac's routing, input, and selection tests moved to
     `TerminalEndToEndTest` (real shells on the disposable daemon) and the
     JVM contract test; `TerminalsCoreDouble` drives the conversation
     terminal tabs; `TerminalRoutingTests` cover the adapters.
8. **Schedules.**
   - **As built.** One schedules slice for the shown project
     (`SLICE_SCHEDULES`, `SchedulesCommand`): pages, the selection's run
     history, the editor preview, and errors. Lists come from any replica;
     definitions, history, and changes go to the schedule's owner, so the
     Mac no longer leases a data plane per owner. A save that returns after
     the project changed is dropped. The editor's preview is the core's,
     debounced there; the editor takes the owner machine's agents from its
     metadata.
   - **Deviation.** The editor's timing and template helpers stay in Swift
     until the pure helpers move (step 14); they match the core's
     `ScheduleRules`.
   - Tests: `SchedulesCoreDouble` drives the store and model tests over the
     old RPC stubs; Mac-side request coalescing gave way to the core's
     latest-request-wins loads.
9. **Workspace review, project changes, and project workspaces.** The view
   polling loops are removed; the core owns refresh.
   - **As built.** A review surface per view (`SLICE_REVIEW`,
     `ReviewCommand`) and a project changes surface per view
     (`SLICE_PROJECT_CHANGES`, `ProjectChangesCommand`), each on the machine
     that owns the conversation or checkout; an active surface refreshes
     itself. Project workspaces are one slice with load and remove.
   - Diffs travel as the core's numbered rows; the patch is not sent twice.
     The Mac's diff layout (folds, split pairs) builds from those rows, and
     comments attach to a row ID. The review carries the core's workspace
     availability, so the Mac's rule copies, its diff parser, the selection
     resolver, and operation reconciliation are deleted.
   - The merge flow, Git operations, and their reconciliation run in the
     core; the Mac sends the flow's choices and reads its outcome.
   - **Behaviour change.** When the reviewed file disappears, the core
     clears the selection instead of jumping to the first commit. The
     project changes view still opens on the first change.
   - **Found by the Mac smoke suite.** A file selected in the project
     changes follows itself to the other half when it is staged or unstaged
     (`ProjectChangesRules.follow`), as the legacy Mac did; clearing it made
     the header's "Stage file" act on whichever change the view fell back to.
     The terminal overview takes the selected machine's terminals from its
     terminals surface after a close or rename, so a closed terminal leaves
     the overview at once.
10. **Admin, projects, checkouts, boards, labels, prompts, settings, and
    conflicts.**
    - **As built.** One `AdminCommand` covers projects, checkouts, boards,
      labels, prompt settings and overrides, portable settings, shared-record
      conflicts, archives, and workspace defaults; each runs on the machine
      that holds what it changes (a project's replica, a checkout's owner, a
      conversation's owner, or the named machine), so the Mac no longer
      attaches or leases a data plane to administer another machine.
    - The same command reads a conversation's workspace, changes it before
      the first turn, lists archived chats of every online machine (chats are
      restored there), and reads a file for download.
11. **Telemetry, machine operations, and quotas.**
    - **As built.** A telemetry slice carries every machine read so far with
      its CPU and GPU history; the core reads the selected machine every 2 s
      while the popover shows it, and performs power and update operations
      with one idempotency key per confirmed action. Provider quotas are the
      core's gateway watch (`SLICE_QUOTAS`), so the Mac no longer opens its
      own gateway client or reads gateway tokens for them.
12. **Executions and search.**
    - **As built.** A conversation's processes are a scoped surface
      (`SLICE_PROCESSES`, `ProcessesCommand`) on the conversation's machine:
      the list, the selected execution's output, and stop. The command
      palette asks the core (`SearchCommand`), which indexes the workspace's
      cards and chats; the Mac's search index is deleted.
13. **Screens.**
    - The WebRTC peer, VideoToolbox, Metal, key capture, and pasteboard
      become the native media engine and clipboard.
    - Session control moves to the core.
    - **As built.** A screen view observes `SLICE_SCREEN` under its own scope
      and drives it with `ScreenCommand`. The core's `ScreenSession` owns
      signaling, trust, the lease, recovery and codec fallback, input
      sequencing and coalescing, receiver feedback and reference
      acknowledgements, clipboard sync, and resolution matching
      (`ScreenDisplays`, serial changes with restore). The slice carries the
      phase, capabilities, session state, control, clipboard, the host
      cursor (its image only when it changed), preferences, and the matching
      status.
    - The Apple façade takes a `NativeScreenMedia` and `NativeClipboard`.
      `CoreScreenMedia` creates one peer per attempt for the view whose scope
      the core names, decodes into that view's Metal renderer, and reports
      decoded and presented RTP timestamps (exact 90 kHz) and cumulative
      receiver counters; the façade turns the counters into feedback with
      the core's `ReceiverStatistics`. Each engine resets the view and takes
      its own decode path, since a renderer reset invalidates earlier ones. `CoreScreenClipboard` reads and
      writes the pasteboard on the main thread.
    - `RemoteDesktopController` keeps the API the views use and folds the
      slice. The Swift recovery, lease renewal, feedback pump, reference
      receiver, frame observer, display matching, clipboard protocol, and
      capability rules are deleted; their tests moved to the core
      (`ScreenPoliciesTest`, `ScreenDisplaysTest`) or already existed there.
    - **Behaviour change.** Like Android, the core sends input, and syncs
      the clipboard, only while the view holds focus: hovering an unfocused
      viewer shows the host's cursor and does not move it.
    - **Deviation.** The phase wording ("Live", "Checking machine…") stays
      the Mac's.
    - Test-only `NativeScreenFixture` lets an isolated core signal through
      the disposable native screen fixture; the gated native suite
      (`just mac screens-test`) runs through the core and the Mac engine:
      streaming, clipboard, input, quality soak and latency, live
      configuration, expiry and capture-helper recovery, wake, the undocked
      fullscreen viewer with resolution matching, and HEVC transport.
    - **Core fix found on the way.** A user copy, cut, or paste that arrived
      while the 250 ms background clipboard sync was mid-exchange was refused
      ("A clipboard operation is still in progress"). Exchanges now share a
      lock: user operations wait for the sync, and only a second concurrent
      user operation is refused. A session stop fails a pending exchange at
      once instead of holding the lock until it times out.
14. **Consolidation.**
    - Remove `ConnectionManager` and `DieterRPC` from `DieterMac`.
    - Delete the Mac-only `DieterCore` and `DieterClient` files.
    - Remove `FeatureCompatibility`.
    - Update the docs.
    - **As built.** The legacy feature plane (`FeaturePlane`, the attached
      machine's `rpc`, the directory and temporary data-plane leases) and the
      app's `ConnectionManager` are gone; every feature reaches its machine
      through the core. Feature surfaces rebind when the connected machine
      changes (`connectedMachineID`). The core marks a machine reached over a
      loopback plane as `local`, which decides whether workspace paths open
      in Finder or another app here.
    - UI smoke fixtures that prepare or inspect the isolated machine directly
      (start a process, create a card, read a file back) use the smoke-only
      `SmokeFixturePlane`; the app itself never does.
    - **Deviation.** `FeatureCompatibility` stays: it only forwards view
      properties to the feature models and holds no transport or rules.
      `DieterClient` stays as a module: it carries the native gRPC transport
      and WebRTC control bridge the core uses, and the iOS client.

**Exit per step:** Mac green; the affected `just e2e run --platform mac`
cases pass. At the end, the whole Mac smoke suite passes.

### M4 — Tests and verification

- **Logic tests.** Port the Mac logic tests to core tests; delete the Swift
  duplicates.
  - Screens: display matching's serial change and restore
    (`ScreenDisplaysTest`) and the reference acknowledgement window, bound,
    generation scope, and RTP wrap (`ScreenPoliciesTest`) moved to the core;
    recovery, feedback, capability, and frame-readiness rules already had
    core tests.
  - Removed in M3 without a core unit test yet (the core code has the
    guards; its end-to-end tests cover the main paths): project changes —
    latest selection wins, pagination appends once, stage locks before
    submission, a commit failure keeps the draft, a reconnect drops an old
    completion; review — a merge flow cannot clean up a newly selected
    workspace, a failed cleanup stops before moving the card to Done.
- **View and layout tests.** They run on `FakeCoreClient` fixtures.
- **Smoke runners** (`Sources/DieterMac/Testing`) drive the new adapters, and
  all ten Mac e2e cases pass.
- **Legacy import.** An integration test that seeds real legacy files, then
  checks gateways, the token, the outbox replay, navigation, drafts, and the
  client ID.
- **Performance.**
  - The board stress fixture and a long conversation.
  - Snapshot and delta apply are timed at the bytes boundary against the
    legacy baseline (plan §6.4).
  - Binary size is re-measured.

## 5. Safety

- Never stop, replace, or build over a running operator Dieter.app; builds
  already refuse.
- Mac e2e runs only when no `DieterMac` is running, using isolated gateways,
  temporary state roots, and preference suites.
- Nothing touches the operator's daemon or `~/.dieter`. The gated
  `DIETER_LIVE_*` tests stay off.
- The legacy import reads, never deletes, until M3.14.

## 6. Risks

| Risk | Mitigation |
| --- | --- |
| Byte-boundary cost for large boards and transcripts | Keyed deltas (already in place); measure against the budget; the transcript window stays bounded |
| Behaviour drift where Mac rules differ from the core | Port the Mac tests as core tests first; decide per case and note it in the stage |
| Kotlin/Native build time in the Mac loop | Freshness manifest over the core inputs; the debug framework in dev and tests, release only for release |
| iOS build coupling through the shared package | `just ios build` in every stage's exit |
| Concurrent edits by other agents | Stage-sized changes, rebuilt and tested per stage |
