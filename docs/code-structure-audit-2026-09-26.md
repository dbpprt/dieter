# Code structure, native clients, helpers, and build tooling

Review baseline: `e34a7492`, 26 September 2026. The checkout was clean before
this work. The audit below records the original findings. The subsequently accepted
refactors and their current qualification status are tracked in the
[implementation record](refactor-implementation-2026-09-26.md).

Dieter already has useful subsystem boundaries. The biggest return comes from
finishing ownership boundaries inside the native clients and making build
orchestration reliable enough to support that work. A repository-wide rename,
generic helpers package, or replacement of native UI frameworks would add
migration work without addressing the concrete problems found here.

## Scope and evidence

The review covered the tracked source inventory, Go composition and persistence
boundaries, RPC adapters and CLI contracts, harness worker dispatch, Swift
package structure and feature composition, Android state/transport ownership,
iOS store ownership, capture helpers, Just modules, generation/packaging scripts,
CI selection, and the shared native test runner. Large files were traced through
representative state transitions and call sites. Generated clients, vendored
dependencies, and build artifacts were excluded from handwritten-code metrics.
This is not a claim that every line or every production race was exercised.

The validation section distinguishes executed checks from static findings.
The original audit inspected Android and iOS behavior in source. The linked
implementation record tracks subsequent runtime changes and device verification.

| Area | Existing boundary | Assessment |
| --- | --- | --- |
| Daemon/gateway | Separate binaries and packages; gateway control plane separated from daemon data | Preserve deployment and trust boundaries |
| RPC/CLI | Authoritative proto, explicit `grpcAPI`, Connect adapter, CLI parity tests | Strong contract; some core helpers live in adapter files |
| Harness | Go lifecycle/admission, Node SDK adapters, separate provider helpers | Preserve worker protocol and runtime pinning |
| Apple | API, shared core policies, shared transport, native app targets | Useful compile-time separation; app composition needs attention |
| Android | Repository, connection manager, view model, feature UI | Central owners carry many unrelated lifetimes |
| Capture | Separate process, bounded command/frame flow, platform services | Preserve isolation; clarify queue ownership |
| Build/test | Just entry points, Python release helpers, Go E2E runner | Good direction; lifecycle and dependency selection had gaps |

The largest handwritten production files included Android `DieterViewModel.kt`
(4,132 lines), `DieterConnectionManager.kt` (2,319), Mac `BoardView.swift` (2,005),
`ChatsView.swift` (1,799), Go `store/domain.go` (1,930), `server/grpc.go` (1,765),
and `app/app.go` (1,764). File length is a navigation signal, not evidence of a
bug by itself. More tellingly, Mac `AppSession`, `FeatureCompatibility`, and the
eight `DieterStore+…` files total 6,073 lines under one shared owner.

## Findings and priorities

### 1. Mac launch mutated the bundle before checking ownership — fixed

Previously, [`just/mac.just`](../just/mac.just) declared `run: build`. Just
completed packaging before executing the launch recipe's process checks.
Even a launch that ultimately refused a conflicting process had already built
and potentially replaced/re-signed the canonical app. Activating an existing
canonical app also took that path. The standalone
[`build.sh`](../apps/mac/scripts/build.sh) had no process guard.

The new [`mac_app_lifecycle.py`](../scripts/mac_app_lifecycle.py) owns launch and
graceful quit policy. It inventories exact executable paths, rejects ambiguous
inventory failures and foreign bundles, and activates an existing canonical
process without building. A stopped app is built, rechecked, launched, and
verified. Direct builds check before compilation and again before packaging.
Quit uses an application quit event, waits for exit, and never escalates
to a signal automatically.

`just mac status` also recognizes the `swift-build` and `swift-test` process
names used by current SwiftPM. Compiler inventory shows executable paths
instead of dumping every source and object argument for each frontend.

Fifteen regressions include real build/test entry-point tests in a temporary tree,
paths containing spaces, duplicate/foreign processes, failed inventory, failed
builds, optional compiler controls, an app appearing during build, and quit timeout. Process inspection
remains a preflight, not a kernel-enforced exclusion of arbitrary external
`open` commands between the final check and file replacement.

### 2. Validation selection missed real dependencies — fixed

| Input | Previous plan | Updated plan |
| --- | --- | --- |
| Swift lockfile or vendored transport | Mac only | Mac and iOS |
| iOS sources/tests in the Swift package | Source edits skipped portable policy tests; test edits selected only Mac | Portable `DieterIOSTests` plus iOS build and phone/tablet smoke |
| Shared Swift core/client tests | Mac only | Mac and iOS |
| Linux installer script and its regression files | No local checks | Release regression suite |
| Shared `ScreenClipboardContent.swift` | Apple app checks only | Capture and screen qualification as well |

[`check_changed.py`](../scripts/check_changed.py) now names shared Swift,
iOS-only, lifecycle, and directly compiled capture inputs explicitly. Local and
CI selection still use the same planner. Selector regressions cover these
paths without invoking compilers or devices.

This is still a conservative planner, not a complete build graph. A useful
next step is a tracked-helper inventory test requiring each executable helper
to declare its validation, instead of letting a new script select no check.

### 3. Android terminal input lacks bounded admission — next highest priority

[`DieterViewModel.sendTerminalInput`](../apps/android/app/src/main/java/com/dbpprt/dieter/ui/DieterViewModel.kt)
appends using `terminalPendingInput[id]?.plus(data)`. There is no admitted-byte
budget across queued and in-flight input. While an RPC is stalled, repeated
typing or pastes retain more input and repeatedly copy the accumulated array.
Chunking the removed array bounds individual writes, not the queue. Repository
unary deadlines exist; they are not an admission limit.

The pump's `finally` removes its job by terminal ID and may start another pump
for remaining input. It does not compare the retiring pump's identity with a
replacement. Together with the repository's mutable active route, this warrants
explicit endpoint/client ownership. The unbounded queue is directly visible
in code; replacement-route behavior needs delayed-completion tests before
claiming a reproduced race.

Mac already has a useful counterpart:
[`TerminalInputForwarder`](../apps/mac/Sources/DieterMac/Features/Terminals/TerminalInputForwarder.swift)
accounts for pending and in-flight bytes, bounds sessions, captures the client,
checks pump identity, and refuses to replay ambiguous input.

Extract an Android input owner with synchronous admission, a chunk deque, a
total byte budget, a session bound, and route/pump identity. Keep RPC deadlines
and report rejected input at the terminal surface. Retire an original pump
without removing a successor or replaying uncertain bytes. Test stalled writes,
oversized paste, concurrent terminals, failure after delivery, and route
replacement, then run the isolated native terminal journey.

### 4. Android feature reads apply inconsistent ownership rules — next

The same view model shows both the desired pattern and its absence:

- `loadSchedules` captures project and request generation, checks both before
  publishing success/failure, and rethrows cancellation.
- `listDirectories` also tracks request generation.
- `loadTerminals` starts independent reads without corresponding request
  generation and publishes into current terminal state.
- `previewSchedule` does not correlate completion with the current preview
  request. An older request completing last can replace a newer preview.
- `loadAdministration` reads current selection again after suspension and
  publishes combined results without a captured binding.
- Preview, administration, and some terminal mutation handlers catch
  `Throwable` without first rethrowing `CancellationException`.

These are source-level findings, not measured UI incidents. Extract terminal,
schedule, and administration controllers behind narrow repository capabilities.
Give each a binding containing account, endpoint, project/surface identity, and
generation. Capture it before suspension; success, failure, and cleanup must
check the same owner. Distinguish transport cancellation from cancellation of
daemon-owned work. Moving the whole view model into extension files would not
change who can mutate state.

### 5. Mac's previous feature extraction is real; composition has grown again

The [September 9 refactor](mac-refactoring-implementation-2026-09-09.md) introduced
feature models, narrow RPC protocols, a durable outbox, and window state. Retain
those. [`ProjectChangesModel`](../apps/mac/Sources/DieterMac/Model/ProjectChangesModel.swift)
owns binding generation, read tasks, operation observation, and a bounded cache.
[`ConversationContext`](../apps/mac/Sources/DieterMac/Features/Conversation/ConversationContext.swift)
keeps the conversation surface away from transport internals.

However, [`AppSession`](../apps/mac/Sources/DieterMac/Services/AppSession.swift)
still contains fleet telemetry, quotas, navigation persistence, terminal
overview, board projections, transport/sync ownership, and feature rebinding.
[`FeatureCompatibility`](../apps/mac/Sources/DieterMac/Services/FeatureCompatibility.swift)
exposes broad writable forwarding accessors with side effects. The `DieterStore`
alias is not a second implementation, but obscures the breadth of this owner.

Extract fleet/quotas presentation and terminal overview first, then move
connection/sync effects behind an app-lifetime coordinator. Let `AppSession`
compose owners and route explicit commands. Migrate one consumer family and
remove its forwarding accessors in the same change. Avoid another compatibility
layer. Split board/chats/root panels along state and accessibility boundaries.
Acceptance includes selection retention, no duplicate watches, window
close/reopen, accessibility identifiers, and existing native journeys.

### 6. Shared Apple code is useful; its physical placement is misleading

[`Package.swift`](../apps/mac/Package.swift) contains Mac, iOS, shared policy,
transport, and generated API targets. iOS lives partly under `apps/ios` and
partly under `apps/mac`. The missed iOS check selection above is one consequence
of inferring ownership from directory names.

Keep the target graph. After feature ownership is stable, consider an explicit
Apple package directory. Update Xcode/SwiftPM consumers, generation paths,
release scripts, test discovery, cache keys, and documentation together. Make
this a mechanical change with no simultaneous transport rewrite.

[`IOSStore`](../apps/mac/Sources/DieterIOS/Model/IOSStore.swift) already uses
connection/selection identities and cancellation. It still combines auth,
directory, conversation, quota, and mutation state. Extract those owners when
working on related behavior. Share pure policy and transport capabilities while
retaining platform-specific UI and foreground/background behavior.

### 7. Time and cancellation helpers need one maintained contract

[`DieterTaskSleep`](../apps/mac/Sources/DieterCore/DieterTaskSleep.swift) documents
a workaround for duration-based `Task.sleep`, but
[`HedgedRoute`](../apps/mac/Sources/DieterClient/HedgedRoute.swift) still uses that
overload. [`ClientClock`](../apps/mac/Sources/DieterCore/ClientClock.swift) contains
another duration-to-nanoseconds conversion.

`DieterTaskSleep.seconds` also clamps to `Double(UInt64.max)`, which rounds to
2^64; converting that value to `UInt64` traps. Ordinary delays do not approach
this boundary, so this is helper robustness work, not an observed crash.

Use one saturating conversion with explicit non-finite handling and one sleep
capability for route timers. Keep injectable clocks. Reassess the documented
compiler workaround against supported toolchains before removing it. Test
cancellation, late callbacks, zero/negative delay, and saturation.

Validation exposed a related, concrete test problem: the terminal output burst
test assumed 100 cross-actor enqueues finished within 20 milliseconds. The full
suite exceeded that interval and correctly published more than once, failing
the test. This change adds an injectable sleep to `TerminalOutputAccumulator`
while preserving its production interval. The test now controls one frame
interval, proves nothing publishes before advancing it, and waits for the
actual publication. The old test-only task-wait helper was removed.

### 8. Packaging and generation need a second, focused refactor

The Mac shell packager repeats output inventories three times and uses
`find | sort | xargs stat`, which splits whitespace-containing paths. It copies
palette PNGs over the existing directory, so removing an input does not remove
the old packaged icon. It updates the release plist and signs on every call,
even when copy inputs match. Its input manifest omits the packaging script.

Move packaging policy into a tested module with one manifest definition,
path-safe traversal, explicit version/signing inputs, and a complete staged
resource tree. Verify the stage before activation. Preserve canonical caches
and privacy/signing behavior. Test spaces in checkout paths, removed resources,
interruption, changed release identity, and an unchanged second build.

This change also adds opt-in `DIETER_SWIFT_JOBS` to Mac app and test builds,
inherited by E2E. Verification encountered heavy memory compression while
multiple native compilers were active. Limiting this host to two compiler jobs
provides a supported way to reduce contention without deleting caches or
changing the default on larger development machines.

The optional job limit has real app/test entry-point coverage using an
argv-recording fixture and does not change the default invocation.

Cancellation also exposed a build-lifecycle gap: Swift frontend children
continued running after the registered build was canceled and their immediate
parent exited. The E2E runner's [`command`](../tools/e2e/process.go) cancellation
signals its immediate child, which is not proof that a compiler tree has
finished. Build cancellation should own and await those descendants before
releasing its build lease; test this with a nested child fixture. Avoid broad
process-name kills or terminating another task's compiler.

[`generate-swift-proto.sh`](../apps/mac/scripts/generate-swift-proto.sh) hashes
lockfile, schemas, config, and outputs but not its generator invocation. A flag
change can leave `--check` accepting an old manifest. Schema-copy/import
rewriting is duplicated in [`generate-proto.sh`](../scripts/generate-proto.sh)
and [`sync-proto.sh`](../apps/mac/scripts/sync-proto.sh). Centralize that transform
and include the generator implementation in the freshness contract.

### 9. Go needs local separation more than a new architecture

Packages already distinguish storage, turns, workspace, Git operations,
terminal, remote execution, scheduler, gateway, and transports. `remoteexec`
explicitly bounds processes, retained sessions, input frames, and output; these
limits should not become global agent-turn caps.

- Split [`app.go`](../internal/app/app.go) into admission, recovery, execution,
  and conversation construction. Keep the turn mutex, lease identity, durable
  dispatch, and finalization order under one owner.
- Split [`domain.go`](../internal/store/cards.go) by project, board/labels,
  placement, and materialized state. Document central-lock requirements before
  extraction; retain recovery and journal transaction boundaries.
- Move conversion helpers and `boundedInterval` out of
  [`connect.go`](../internal/server/connect.go): core behavior currently lives
  in the adapter file. Preserve the already-thin unary adapter.
- Keep CLI commands explicit and preserve proto/core/Connect/help coverage.
  A reflection-driven dispatcher would obscure operation-specific semantics,
  confirmations, output, and streaming recovery.

Share helpers only when semantics match. Git subprocesses, harness workers,
terminals, capture, and remote execution have different output, termination,
replay, and persistence contracts. A universal process manager would make these
differences harder to enforce.

### 10. Capture and emulator logic need explicit state ownership

[`CaptureRunner`](../native/macos-capture/DieterCapture.swift) spans roughly
1,200 lines inside an `@unchecked Sendable` class with state, output, input,
mailbox, and stop synchronization. Services already separate clipboard,
display modes, input injection, credits, and liveness. Extend that approach to
capture-session and encoder/output ownership while preserving bounded mailboxes
and generations. Document each field's queue/lock first. Do not broadly replace
queues with actors without measuring callback, backpressure, and frame behavior.

[`android.just`](../just/android.just) embeds an emulator state machine:
identity, external-volume discovery, boot/render/focus checks, and snapshot
validation. Extract pure parsing/decision functions for fixture-based tests of
bad snapshots, offline ADB, wrong serials, and unreadable volumes. Keep Just as
the entry point and the shared E2E runner as journey owner. Preserve the visible
AVD, app data, and graceful snapshot lifecycle; do not add another launcher.

## Recommended implementation sequence

| Step | Deliverable | Exit evidence |
| --- | --- | --- |
| 1 — this change | Guarded Mac lifecycle, check selection, deterministic frame test, current developer instructions | Selector/lifecycle regressions, Just validation, Mac unit/packaged smoke |
| 2 | Android bounded terminal input owner | Stalled/failing/replaced writer tests and native terminal journey |
| 3 | Android terminal, preview, administration read ownership | Delayed A→B→A success/error/cancellation tests and related journeys |
| 4 | Mac fleet/quotas and terminal-overview owners; remove migrated forwarding APIs | Model tests and machine/sidebar/terminal/window journeys |
| 5 | Path-safe staged packaging, one generation manifest contract | Packaging fixtures, clean/unchanged builds, signature verification |
| 6 | Go domain separation, capture ownership extraction | Affected Go race tests, local/direct/relay contracts, capture qualification |
| 7 | Optional Apple package relocation and remaining UI decomposition | Affected Apple builds/journeys with unchanged behavior and cache policy |

Each step should have one ownership or behavior change, regression evidence,
and a reviewable diff. Avoid combining formatting sweeps, dependency upgrades,
file moves, and behavioral fixes. Keep canonical release identity,
authenticated routing, central storage, durable conversations, and
non-replayed mutations as fixed constraints.

## Validation of this change

Initially no `DieterMac` process was running. Validation uses the existing
`dieter-tests` and `dieter-local` caches, debug packaged app, and shared runner's
isolated fixtures. The local toolchain is Xcode 27.0 / Apple Swift 6.4; CI pins
Xcode 26.5. No daemon restart or replacement is part of these checks.

Completed checks:

- Check-selection regressions: 36 passed.
- Mac lifecycle regressions: 15 passed, including the actual shell build guard
  and compiler-option forwarding through app/test entry points.
- All Justfile formatting, handwritten Swift formatting, shell syntax, and
  `git diff --check`: passed.
- Full `DIETER_SWIFT_JOBS=2 just mac test`: passed. The four test products
  reported 807 tests in total: 793 passed and 14 explicit fixture/live-route
  skips. The corrected terminal accumulator regression passed in 0.006 seconds.
  The complete log is `tmp/code-audit-2026-09-26/mac-unit.log`.

The initial affected-check run reached the Mac suite and exposed the terminal
frame test's timing assumption described above. Its corrected unit suite now
passes. Concurrent Android UI changes in this shared checkout belong to
separate work and are not claimed as validated by this audit.

The packaged smoke build and signature verification passed after the recovery
below. The UI run in `tmp/e2e-3329394524` did **not** pass: `mac.board` failed
its permission-onboarding check because the rendered “Skip for Now” control's
window remained inactive (`active=false`, `key=false`). The conversation
progress report also recorded an inactive-window failure for the full-message
action. The desktop was unlocked. Activating the task-owned app with
`just mac run` preserved its PID and brought it forward without rebuilding,
but that intervention is not unattended qualification. The run was canceled
after these repeated focus failures; the remaining cases are interrupted,
not passes. No `DieterMac` process remained after cleanup.

The permission screenshot was inspected: the control was visibly rendered.
The runner still needs reliable foreground activation, or a controlled desktop
run that establishes it, before native acceptance can be called green. This
evidence does not establish whether platform activation policy or competing
desktop activity caused the loss of focus. No system privacy permissions were
changed to obtain a pass.

The card remains in Running because packaged UI qualification is incomplete.
The next acceptance step is a passing `DIETER_SWIFT_JOBS=2 just e2e run
--platform mac --suite smoke` on a desktop where each test-owned window can
acquire and retain focus. Retain the current reports/screenshots when comparing
that run; neither the failed nor the interrupted cases count as passed.

The resumed app build encountered an obsolete Metal compiler mount path in
Swift Build's cached descriptions. `xcrun metal --version` confirmed that the
current compiler was installed and executable. A standalone build and bundle
signature verification passed, but SwiftPM's manifest-cache flag did not
reliably invalidate Swift Build's separate descriptions in Xcode 27. After
verifying no Swift compiler/build was active, six description directories
whose Metal executable no longer existed were moved to
`tmp/code-audit-2026-09-26/stale-build-descriptions` for inspection. Compiled
objects, dependencies, and the canonical cache paths were retained. No
toolchain was installed or replaced. This environment recovery is separate
from the repository changes; no unreliable cache-recovery switch was retained.

Xcode 27 emitted existing warnings outside the changed code: nested weak
captures in `BoardCardMergeDrop`/`DieterRootView`, unmutated variables in
`DieterStore+Connection`, a raw-pointer conversion in `RemoteDesktopHEVCDecoder`,
optional interpolation/deprecated activation in smoke helpers, and a SwiftTerm
resource-bundle build-graph warning. These are diagnostic
observations, not reproduced runtime failures or fixes made in this change.
