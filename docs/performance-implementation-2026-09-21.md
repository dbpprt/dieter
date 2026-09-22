> **Historical engineering record.** This dated investigation or implementation
> report describes the state at the time it was written. For current behavior and
> setup, use the [documentation index](README.md).

# Performance implementation — 21–22 September 2026

This implements the actionable findings in the
[investigation](performance-investigation-2026-09-21.md). The investigation is
the retained baseline; its “remaining costs” describe the state before this
implementation. Measurements use isolated fixtures and the changed binaries.
The operator's installed daemon was neither replaced nor restarted.

Pre-integration verification on 22 September passed the affected Go/Mac checks, 350 Android
unit cases, 67 default functional cases, six separately enabled live integration
cases and the production-mode navigation guard. The default Android suite has
32 explicit skips. The final frame sample is **118 ms p95 / 318 ms maximum**;
earlier failures and host variability remain part of the evidence below. This
completed that implementation verification, not physical-device energy or 60/120 Hz
display qualification. **The subsequent main integration run failed the Android
frame guard at 219 ms p95, then 206 ms on one unchanged repeat.** Functional
checks passed. The plain Android-button control also failed at 130 ms. The frame
budget remains unresolved; see the main integration record at the end of this report.

## What changed

### Commit-driven synchronization

Global sync, selected-conversation, workspace-state and portable-KV watches now
subscribe before their initial read and wake on committed changes. Each Store
uses one lazily allocated filesystem watcher, including atomic replacements
written by separate processes. Every subscriber has one coalescing slot;
slow consumers cannot accumulate an event queue. The last subscriber releases
the watcher. Notifications are hints: projections still read durable state and
retain their existing cursor, cancellation and bounded transport behavior.

The default burst coalescing interval is 25 ms. A two-second recovery check
covers filesystem notification loss, unavailable watch setup and interrupted
mutations. Explicit watch intervals still cap delivery frequency. This replaces
the previous 200/350/250/1,000 ms sync/conversation/KV/state polling loops.

A quiet selected conversation checks its own transcript revision and the
workspace metadata cursor before reconstructing anything. Token-only events in
another conversation no longer invalidate it. Comments, semantic metadata,
checkpoint replacement and pending mutations still trigger the necessary read.
Changed protobufs are compared directly instead of serialized and hashed.

Conditional all-project directory reads return immediately at an unchanged
durable cursor. Android remembers each peer's cursor and avoids reconciliation
and persistence on `notModified`; archive requests bypass that optimization.
Mac's existing conditional path now also bypasses it for archive requests.
The 15-second peer refresh remains necessary for owner-only details. Refreshes
are bounded and serialized, and account/configuration changes invalidate saved
cursors.

Remote-owned conversations remain in shared directories but are excluded before
local transcript hydration budgets and orphan scanning. They no longer generate
expected-ownership warning loops or displace local conversation tails.

### Durable streaming without publishing every token's activity timestamp

Every event is still journaled and fsynced under the central writer lock.
Only the derived card/replicated activity timestamp for `text-delta`,
`reasoning-delta` and `tool-input-delta` is coalesced, at most once per 250 ms.
Other events—including finish, error, abort, tools and runtime transitions—flush
immediately. There is no delayed worker and no delayed event acknowledgment.

A worker killed between token publications can leave the derived timestamp less
than 250 ms behind the latest event. Reopening the durable journal recovers every
acknowledged event and its timestamp. Regression tests verify journal replay and
that a finish updates both the local card and peer summary exactly.

### Chat navigation and projection work

Mac All Chats uses its live synchronized directory immediately. It fetches the
archive only when requested and retains the offline/non-live fallback. Selected
chats open from cache and start one stream requesting a complete initial
snapshot; that full snapshot preserves comment-only changes at an unchanged
transcript sequence. A unary hedge starts only if no fresh frame arrives within
500 ms. Tests check zero duplicate reads on a fast stream and one fallback read
on a stalled stream. Explicit recovery paths remain available.

Mac timeline preparation now ignores metadata-only changes; changes to messages,
plans, subagents, queued items and history still invalidate it. Duplicate watch
frames update freshness without rewriting the same snapshot cache.

Android transcript-only frames retain directory and selected-workspace objects,
update only bounded conversation/freshness caches, and use the complete
reconciliation path for workspace or optimistic-state changes. Empty outboxes
skip directory membership construction. Activity summaries reuse unchanged
snapshot projections, project ordering reuses immutable directory inputs, and
card-operation projection returns immediately when there is no applicable work.
The protobuf delta application also preserves the directory itself on
transcript-only frames; a 1,000-chat/1,000-delta regression checks identity and
confirms that metadata and conversation tombstones still apply.
Android cold chat opens also give the stream a 500 ms head start over a unary
hedge. Live covered cache opens retain their existing immediate path.
Tapping a primary navigation tab now selects the pager destination immediately;
swiping retains its normal gesture animation. Real-frame diagnostics had exposed
an expensive full-page animation phase during repeated tab navigation.
Each retained primary page also normalizes the selected destination through a
one-entry state cache. Tab selection alone preserves the page's state identity;
remote directory, detail-selection and transcript changes still invalidate it.
The regression covers 1,000 tab changes and real content changes.
The Tools menu now opens as a Material sheet in the existing activity window.
Frame traces had repeatedly caught renderer creation and window synchronization
around the former separate dialog. Opening is immediate; standard sheet dragging,
back/scrim dismissal and large-text scrolling remain available. The covered
destination leaves accessibility and keyboard-focus traversal while Tools is
open. A new gesture regression checks that dragging to the zero-height resting
position fully dismisses the modal overlay. Keyboard opening focuses Terminal,
Tab traversal remains inside the sheet, and dismissal restores the Tools control
when its navigation bar remains mounted. Nine navigation tests cover these
behaviors, ordinary destinations, disabled tools and large-text layout.

Running-chat badge animation now observes rotation and glow only while drawing.
It retains the existing pulse and status semantics without recomposing badge
text and layout on every frame. The visual regression also checks the
recomposer's change count during the animation.

### Android main-thread I/O

StrictMode exposed repeated Android Keystore decryptions in the provider-quota
watch, even though most repository calls originated on IO. Authentication and
channel setup now enforce the IO boundary themselves. Decrypted credentials
use a bounded 16-entry memory cache keyed by the exact encrypted preferences
value. A second store's replacement or sign-out invalidates that entry; failed
decryptions remain retryable. Route and endpoint identity are captured together
before preparing authentication.

Shared navigation also committed preferences on Main, including repeated
account-cache clearing during authentication changes. Its cache hydration,
projection and durable commands now use a serialized IO lane with a bounded
command queue. Publication and network delivery still follow successful durable
commits. Reorder/folder diffs read after earlier queued edits, so rapid edits do
not calculate against stale UI snapshots. Regression coverage includes ordered
writes, offline restart, sign-out and StrictMode disk checks.

### Native board and file rendering

Mac board lanes use a native view-based table that constructs rich SwiftUI rows
only as they mount. Visible row heights are measured at the actual lane width;
unmounted rows use estimates. Card changes and width changes invalidate measured
heights, and recycling retains identity by card ID. First visible rows are
measured synchronously to avoid a clipped first frame. Tests cover narrow/wide
wrapping, Unicode, labels, merged footers, dynamic height changes, 1,000-card
scrolling, and the original four-populated-lane overconstruction case.

Plain Markdown editors no longer construct a JavaScript syntax highlighter just
to obtain fonts and background colors. Code fences initialize it when needed.
Highlighting and lazy initialization are serialized, appearance changes
invalidate caches without initializing unused engines, and appearance observers
are removed on deallocation. Existing native editor/diagram behavior is retained.

## Daemon results

| Measurement | Baseline / former path | Changed build |
| --- | --- | --- |
| Matched warm unchanged conversation benchmark, median of three | 1.867 ms, 444,002 B, 2,111 allocations | 0.088 ms, 4,697 B, 39 allocations: about 21× faster and 99% fewer allocated bytes |
| Eight real, quiet projection subscriptions for 30 seconds | No comparable isolated baseline | 0.0379 CPU-seconds: **0.126% of one core**; RSS 38.6 → 34.1 MiB; no duplicate content frames |
| Commit to selected-conversation frame, five independent runs | Former timer could wait up to 350 ms | **2.04–2.53 ms**, median 2.24 ms; same-process committed-event delivery |
| 30-second large-workspace soak: acknowledged appends | 500 | **637**, about 27% more |
| Soak append latency p50 / p95 / p99 | 165 / 256 / 278 ms | **134 / 168 / 217 ms** |
| Reconnect first-projection p95, 240 reconnects | 476 ms | **420 ms** |

The soak uses eight projects, 160 chats, four 25 MiB histories, four writers and
four reconnecting clients. Its profile includes setup and recovery: total CPU
was 24.61 seconds over 51.38 wall-seconds (baseline 24.86 / 55.21). CPU samples
under append stacks fell from 5.46 to 1.68 seconds, while the workload completed
more appends. Filesystem calls still dominate the full profile. This does not
establish a large reduction in whole-process active CPU.

Cumulative profile allocations **increased** from 3,654 to 4,227 MiB in this
fixed-duration soak, which performed more work and delivered 250 rather than
224 frames. Do not confuse the unchanged-read allocation improvement with an
overall allocation reduction under load. The RSS figures above belong to the
separate idle fixture. Setup, live workload and steady idle are distinct samples.

## Verified native measurements

All latency samples below use a debug build on this Mac. Small samples describe
this fixture, not a production percentile or a release responsiveness guarantee.

| Journey | Baseline | Changed build | Interpretation |
| --- | --- | --- | --- |
| Four populated board lanes, 100 cards: hosted readiness (median of 3) | 2,245 ms; 100 mounted rows | 874 ms; 24 mounted rows | About 61% less readiness time; 76% fewer mounted rich card graphs. |
| Packaged board, 85/5/5/5 cards: click to first drawing callback (median of 3) | 1,174 ms | 1,001 ms (908 / 1,001 / 1,047) | About 15% faster; still a noticeable debug opening cost. |
| Packaged board: direct layout/display (median of 3) | 1,093–1,125 ms | 843 ms (731 / 843 / 896) | Visible card construction remains the dominant cost. |
| Packaged All Chats: click to first drawing callback (median of 3) | 340–600 ms samples | 310 ms (210 / 310 / 477) | Live-directory path avoids an extra refresh; drawing remains variable. |
| Markdown file: click to editor text ready (median of 3) | 643 ms (545 / 643 / 862) | 470 ms (363 / 470 / 724) | About 27% faster; does not yet meet an instant-open target. |

Android's real-input navigation test recorded 600 frames: p50 **30 ms**, p95
**110 ms**, p99 **334 ms**, maximum **417 ms**. Its five-second quiet sample used
16 CPU-ms / 5,175 wall-ms, or **0.31% of one core**. This is a cached/disconnected
debug emulator journey, including instrumentation and accessibility work; it is
not release frame-rate qualification. A preceding valid real-input run measured
p95 139 ms and failed the 120 ms guard; the tab animation change followed a
separate sampled trace. No budget was loosened.
The full affected-check run later failed the same guard at **127 ms p95**
(470 frames, p50 34 ms, p99 280 ms, maximum 308 ms). Its other 65 executed
connected cases passed and 31 fixture-gated cases skipped. Follow-up sampling
showed rendering waits, modal-window setup, accessibility and composition
disposal work. Sampling itself increases overhead; those diagnostic frame
durations are not used as a matched benchmark. A trial removing retained pager
neighbors did not establish an improvement (p95 167 ms, maximum 634 ms) and was
reverted. The renderer was verified as host Apple M4 GLES. The native input test
also used a full synchronous accessibility-tree traversal before every tap.
It now uses a bounded, bottom-first traversal and stops at the matching visible
control. This reduced unnecessary automation work but did not establish a
frame-budget improvement (another debug run recorded p95 154 ms, maximum 401 ms).

Frame-budget qualification therefore uses a dedicated **non-debuggable build
inheriting release settings**, rather than drawing conclusions from debug-mode
timing. The 120 ms p95 and 500 ms maximum guards are unchanged. The debug suite
explicitly skips this one performance-only case; the full `connected-test`
command then automatically runs it in production mode. This is not physical
device or release 60/120 Hz qualification. Debug failures remain documented
above and are not reclassified as passes.
The first usable production-mode run also failed: p95 **202 ms**, maximum
**516 ms**, with 8,164 CPU-ms over 22,269 wall-ms. This ruled out debug overhead
as the complete explanation and led to the in-window Tools implementation.
The first in-window run improved to p95 **129 ms**, maximum **434 ms** over
490 frames, but still failed the unchanged p95 guard. It used 11,523 CPU-ms over
20,898 wall-ms; this is not evidence of reduced active-navigation CPU. The
retained-page state projection was added after that run. Its first timing run
still failed at p95 **162 ms**, maximum **398 ms** (436 frames; 10,265 CPU-ms /
23,428 wall-ms). This does not establish a frame-time benefit for page identity
reuse, although the unit regression verifies eliminated state invalidation.

A fresh sampled trace showed renderer/buffer waits as well as page composition.
A diagnostic control replaced the Compose content with ordinary Android buttons
in the same activity, using the same native taps, selection checks and frame
aggregator. Even that control failed at p95 **185 ms**, maximum **240 ms**
(390 frames; 2,831 CPU-ms / 18,715 wall-ms). This establishes an environmental
contribution to the measured delay; it does not turn the Dieter failure into a
pass or explain away its additional CPU cost. The task-owned emulator was then
gracefully saved and restarted with its normal configuration, preserving data;
its boot, host Apple M4 GLES renderer, hierarchy and screenshot checks passed.
After that normal restart, the native control still failed at p95 **168 ms**,
maximum **327 ms** (373 frames; 2,089 CPU-ms / 17,766 wall-ms). No graphics
flags, screen resolution or numeric frame budget were changed. This control
points to the emulator/input/compositor measurement environment as a source of
variation, independently of the application fixes.

The final complete validation run on **22 September** passed the unchanged
Dieter-navigation guard: **443 frames, p50 34 ms, p95 118 ms, p99 179 ms,
maximum 318 ms**, with **7,335 CPU-ms / 18,960 wall-ms** during navigation.
The separate five-second passive window used **3 CPU-ms / 5,039 wall-ms
(0.060% of one core)**. Logs confirm `measurementMode=dieter-navigation`;
this was the actual application, not the native-button control. The full
command exited zero and restored the ordinary debug APK. Its p95 has only
2 ms of headroom against the 120 ms guard, so the preceding failures still
matter: this establishes a passing local regression run, not consistent
frame-rate qualification across host loads.

The final live fixture selected warm chat models in **17 ms initially**, then p95
**13 ms**, maximum **25 ms** across 50 switches. These times end when the expected
conversation is available in ViewModel state, not when the screen is drawn.
The test requires p95 below 250 ms, no redundant syncing indicator and an intact
connection across foreground/background transitions.

The Mac hosted idle window used **0.02% of one core** for 30 seconds with
58 chats, 25 marked running and no footprint growth. That fixture has no live
network connection; the daemon's eight-subscription test measures actual watches.

Android Live-mode attribution used two consecutive 30-second windows. The first
used 1,611 CPU-ms / 30,056 wall-ms (**5.36%**), but fixture logs showed both mock
workers producing replies and finishing inside that window. It was active work,
not steady idle, and JIT accounted for only 100 ms. The second window, after
those turns finished, used 182 CPU-ms / 30,079 wall-ms (**0.61%**). The test now
requires assistant replies and idle runtime/transcript status before measuring,
so slow worker startup cannot silently contaminate an idle result. These are
process CPU counters, including instrumentation, rather than battery estimates.
The corrected six-test run passed with zero skips. Its verified quiet windows
used **284 / 30,123 ms (0.94%)** and **205 / 30,012 ms (0.68%)** CPU/wall time.

The final board screenshot and first-layout geometry assertions both pass.
An earlier 560 ms hosted result was rejected because cells were clipped during
native height animations. Height correction is now batched and nonanimated;
measuring only the table's target row heights was insufficient. A prior native
table iteration also regressed packaged opening to 1,620 ms and was corrected.
Neither rejected iteration is used as evidence of improvement.

File signposts separate the first three successful read/await stages
(34 / 134 / 103 ms) from editor preparation (0.147 / 0.034 / 0.061 ms).
The await stage includes main-actor scheduling and is not pure network latency.
The remaining click-to-ready interval includes selection, scheduling and drawing.
The later full-validation core run recorded **936 / 1,180 / 445 ms** to editor
readiness. That run followed complete build/unit workloads rather than the
separate settled measurement sequence. The slower samples are retained here:
the earlier 27% median improvement is specific to that measured run, and file
opening remains variable and visibly expensive in debug builds.
The full-validation board run also varied: **1,543 / 1,146 / 2,148 ms** to first
drawing callback, with direct layout/display **1,322 / 1,276 / 1,302 ms**.
It still mounted only 20 of 100 rows and passed sorting, final-row scrolling,
recycled-row clicks and geometry checks; its screenshot was inspected. These
later timings do not establish a consistent packaged-board latency improvement.
The construction reduction is verified; release responsiveness remains to be
qualified under controlled host conditions.

## Measurement and regression workflow

Use one workload at a time after builds settle. Record build configuration,
route, workload, stream count and foreground/background state. A debug hosted
view, a native drawing callback, an emulator frame and a physical display are
different measurements and must not be combined into a single latency claim.

```sh
# Complete the checks selected by changed files, including native integration.
just check-changed --dry-run
GOFLAGS=-p=1 just check-changed

# Eight real in-process projection subscriptions, after cold setup.
DIETER_IDLE_SYNC=30s go test ./internal/server \
  -run '^TestIdleSubscriptionProcessCost$' -count=1 -v

# Matched large-workspace streaming/reconnect fixture; retains acknowledged data.
DIETER_SYNC_SOAK=30s go test ./internal/server \
  -run '^TestSyncLargeWorkspaceSoak$' -count=1 -timeout=3m -v \
  -cpuprofile=tmp/sync.cpu -memprofile=tmp/sync.mem -o tmp/sync.test
go tool pprof -top tmp/sync.test tmp/sync.cpu

# Warm idle path: report allocations as well as time.
go test ./internal/server -run '^$' -bench '^BenchmarkConversationIdleRead$' \
  -benchmem -count=3

# Hosted board geometry plus row-construction diagnostics.
DIETER_BOARD_PROFILE=1 just mac test boardOpeningStageDiagnostic

# Actual live Android sync against a disposable enrolled gateway.
just android sync-test

# Production-mode emulator navigation, with the same frame guards.
just android performance-test
```

`scripts/measure_process.py` records exact PID CPU-counter deltas and RSS without
restarting a process or collecting credential-bearing command arguments. Mac
signposts cover conversation application and file selection, read completion and
editor preparation. Watch debug logs report polls, snapshot builds and frames.
Android instrumentation logs navigation p50/p95/p99/max, counts above 16/33 ms,
journey CPU and passive-window CPU. It uses real touchscreen injection against
observed accessibility bounds and the ordinary Choreographer clock. The old
Compose test clock advanced entire animations inside `waitForIdle`; sampled
stacks and frame phases showed long synthetic UNKNOWN_DELAY stalls. Those
results are retained as diagnostics, not compared directly with native-tap
measurements. The native test also dismisses a visible startup connection sheet
and verifies selected destination semantics after each tap. Optional
`dieterPerformanceSample=true` instrumentation logs slow-frame phases and bounded
main-thread stack summaries. Its production-mode emulator guards require
p95 below 120 ms and no frame at or above 500 ms. For environmental diagnosis,
`ORG_GRADLE_PROJECT_android.testInstrumentationRunnerArguments.dieterPerformanceControl=true`
enables the ordinary-button control when passed through `env` to the performance
recipe. Logs label it `native-control`; those results are never Dieter navigation
qualification. Ordinary runs log `dieter-navigation`.

The performance recipe refuses physical-device serials, temporarily installs
the non-debuggable APK using the same debug signing key and application ID,
preserves emulator data, and restores the normal debug APK even after an
assertion failure. It does not alter production signing, release configuration
or any operator service.

The new `just android sync-test` recipe starts a disposable enrolled gateway on
a random loopback port, maps only that port to the selected emulator, and runs
six live/background transcript, shared-navigation, queued-edit, offline-admission and terminal checks.
It restores the emulator's connection choices, removes its reverse mapping and
reaps the fixture. Test logs and XML are retained under `tmp/performance-sync`.
The live-cache integration test enforces a 250 ms warm chat-selection budget.

## Evidence index

Evidence is retained locally rather than committing large traces or fixture
credentials. The repository documents the reproducible commands; local paths
below locate this run's raw results.

| Evidence | Local path |
| --- | --- |
| Baseline findings and original measurements | `docs/performance-investigation-2026-09-21.md` |
| Final daemon quiet subscriptions | `tmp/performance-2026-09-21/idle-subscriptions-final.log` |
| Matched soak and CPU/allocation profiles | `tmp/performance-2026-09-21/sync-after.log`, `sync-after.cpu`, `sync-after.mem`, `server-after.test` |
| Matched unchanged-read benchmark | `tmp/performance-2026-09-21/idle-benchmark-final.log` |
| Commit-to-frame regression | `tmp/performance-2026-09-21/commit-latency-final.log` |
| Mac hosted idle window | `tmp/performance-2026-09-21/mac-idle-final.log` |
| Packaged board report and screenshots | `apps/mac/.build/smoke/board-20260921-181420-bbb799d9-e676-44f7-9f1b-a229aacc4192/` |
| File report and stage signposts | `apps/mac/.build/smoke/core-20260921-172450-c6a44b8a-43fc-4fde-a515-573073f96b00/` |
| Real native-input Android navigation | `tmp/performance-2026-09-21/android-instant-tabs.log`, `android-instant-tabs-device.log` |
| Live CPU attribution and six integration results | `tmp/performance-sync/android-lk230yzc/results/` |
| Final verified steady Live CPU and six integration results | `tmp/performance-sync/android-bi6ktqqb/results/`, `tmp/performance-2026-09-21/android-live-steady.log` |
| Full-validation core report, including slower file samples | `apps/mac/.build/smoke/core-20260921-185924-5eda243c-5634-4124-8029-2eae05e4d032/` |
| Full-validation board report, screenshot and later timings | `apps/mac/.build/smoke/board-20260921-190238-2587808b-e410-4409-9c35-52b9238f23a1/` |
| Broad affected-check log and Mac smoke report index | `tmp/performance-2026-09-21/final-check-changed.log`, `final-mac-smoke-index.json` |
| Final Android unit and draw-only badge checks | `tmp/performance-2026-09-21/android-draw-only-unit.log`, `android-draw-only-badge-results/`, `android-draw-only-badge.png` |
| Final complete Android command and exact case inventory | `tmp/performance-2026-09-21/android-complete-final.log`, `android-complete-final-debug-summary.json` |
| Final Android functional and performance XML/logcat | `tmp/performance-2026-09-21/android-complete-final-debug-results/`, `android-complete-final-performance-results/` |
| Failed page-state timing and sampled attribution | `tmp/performance-2026-09-21/android-page-reuse-results/`, `android-inline-profile-results/` |
| Native-button controls before/after emulator restart | `tmp/performance-2026-09-21/android-native-control-results/`, `android-restarted-control-results/` |
| Final Tools touch, keyboard, dismissal and accessibility captures | `tmp/performance-2026-09-21/android-final-tools*.png`, `android-final-tools*.xml` |
| Graceful emulator restart and final shutdown | `tmp/performance-2026-09-21/android-renderer-restart-stop.log`, `android-renderer-restart-start.log`, `android-final-shutdown.log` |

## Validation

The affected-check selection includes all Go packages because the Go
dependency manifest changed, complete Mac/Android unit suites, all eight
packaged Mac smoke suites and the complete Android connected suite. Go race
checks and `go vet` passed. The broad run's Android unit XML recorded **348 tests,
zero failures, errors or skips**, including the protobuf directory-identity
regression. The final Android unit run on the page-state and badge changes records
**350 cases, zero failures, errors or skips**. The badge's separate instrumented
visual/recomposition regression passes, and its screenshot was inspected.

The broad `GOFLAGS=-p=1 just check-changed` run exited one on the earlier
Android debug frame assertion. Its Go and Mac checks passed; those sources were
unchanged afterward. Android changes were followed by the full unit suite and
complete unfiltered `just android connected-test` on 22 September. XML records
**99 debug cases: 67 passed, 32 explicitly skipped, zero failures/errors**, then
**one production-mode frame case passed with zero skips**. The 32 skips include
the debug-only performance exclusion plus fixture/account/screen-dependent
cases. Six relevant isolated-gateway cases were enabled and passed separately;
the other skips are not executed coverage. The final Just recipe validation
and `git diff --check` also pass.

The visible app inspection verified the Tools layout, hidden background
accessibility tree, keyboard opening on Terminal, containment after 15 Tab
presses, Back dismissal and restored Tools focus. Screenshots and hierarchies
are retained alongside the final XML. The normal debug APK was restored.

The full Mac unit command passed. Swift Testing reported groups of 660, 56, 8
and 8 tests; XCTest ran five cases. Fourteen opt-in cases were explicitly
skipped in the default command, including live-account/route and screen-media
fixtures. Those skips are not executed coverage. The board diagnostic and
30-second idle-window cases were separately enabled and passed for this task.
The six-test isolated Android Live integration run also passed with zero skips.

All eight packaged Mac smoke suites passed: core, board, conversation, machine,
sidebar, terminal, island and workspace. Explicit smoke skips were the external
AX activation check, HTML/PDF export Save-sheet acceptance and the fresh-state
bounded-history fixture. Native board clicks, scrolling, layout, cached chat
opening, streaming content, file editing, offline queueing, reconnect and terminal
restart/replay checks executed successfully. The later board screenshot was
inspected as well as its geometry assertions.

## Remaining costs and proper next steps

The measured waste addressed here is implemented with durability and recovery
coverage. There are still visible costs: roughly one-to-two-second debug board opens,
variable file readiness, and Android frames above a normal display interval.
Passing the bounded regression guards is not a claim that every interaction is
instant or that these debug samples meet a release frame-rate target.

Prioritize release qualification of the same recorded journeys, then use native
time profiles to split visible-card construction, editor selection/scheduling
and actual compositor presentation. Only pursue a new rendering change against
that matched baseline, with the wrapping, footer, scrolling and input regressions
kept intact. For streaming memory, compare equal numbers of acknowledged events
and delivered projections: the fixed-duration soak's higher throughput makes
aggregate allocated bytes unsuitable as proof of an allocation improvement.
Keep Live subscriptions silent between changes and retain the measured idle
fixtures as the regression workload; increasing refresh intervals must not be a
substitute for fixing repeated work.

## Qualification boundaries and rollout

The task-owned `Pixel_9_API_37_1` / `emulator-5554` was saved and closed
cleanly after final verification. No task-owned Mac app or integration fixture
process remains. The operator daemon is still PID **41194**, with its original
21 September startup time; the attached physical phone was not operated. No
commit, push, deployment or operator installation was performed during that
implementation verification. Subsequent main integration is recorded below.

These changes preserve one API contract; there is no schema migration or
historical protocol branch. Install the daemon and native clients through the
normal release workflow after review. Do not replace a running operator daemon
to collect benchmark evidence.

Debug/emulator measurements cannot establish release 60/120 Hz frame compliance,
physical-device energy consumption or compositor presentation latency. Keep
those as explicit release qualification: profile a release build on a physical
device with a live account, across quiet, streaming and reconnect workloads.
Screen-sharing media retains its separate qualification suite and reports.

For future regressions, collect request/build counts before adjusting timers.
Investigate UI construction separately from RPC readiness, and sample the
specific process during the observed stall. Preserve event fsync, bounded queues,
freshness checks and recovery paths when changing any performance budget.

## Main integration — 22 September 2026

At the user's request to pull and push everything to main, the implementation
was rebased onto `5ea6dd11`, retaining 26 upstream commits. Conflict resolution
preserves Android Machines navigation and telemetry, native TURN assertions,
ordered navigation persistence, the in-window Tools sheet, and performance
recipes. Machines is now the first Tools tile, so the keyboard regression
expects initial focus there; the earlier Terminal-focus evidence above predates
that upstream addition. All 72 local changed files, including the two gateway
planning documents, were included.

`just check-changed --base origin/main --dry-run` selected the checks, followed
by `just check-changed --base origin/main`. Post-integration results:

- Go race tests and vet: passed for every selected package.
- Complete Mac unit suite: passed (Swift Testing groups of 660, 55, 8 and 8;
  existing opt-in skips remain explicit).
- All eight packaged Mac smoke suites: passed, with the existing accessibility,
  export and fresh-history fixture skips recorded. Reports were inspected;
  the final-row board screenshot was inspected. Board mounted 20 of 100 rows;
  debug layout samples were 1,184.5, 1,072.6 and 1,332.0 ms.
- Android units: 352 passed, zero failures or skips.
- Android debug instrumentation: 101 cases, 68 passed, 33 explicit skips,
  zero failures. All nine navigation tests passed, including Machines-first
  focus, modal traversal, dismissal and large-text scrolling.
- Android production-mode frame guard: **failed**. Initial run recorded
  343 frames, p50 41 ms, p95 219 ms, p99 282 ms, maximum 303 ms. One unchanged
  repeat recorded 415 frames, p50 35 ms, p95 206 ms, p99 255 ms, maximum 323 ms.
  The unchanged limits are p95 below 120 ms and no frame at or above 500 ms.
- Plain native-button diagnostic control: **failed**, 451 frames, p50 34 ms,
  p95 130 ms, p99 203 ms, maximum 234 ms. This demonstrates an environment
  contribution but does not explain away the application's additional cost.
  No new quiet-CPU sample was produced: the frame assertion precedes it.

The aggregate changed-check command therefore exited unsuccessfully. The prior
118 ms sample remains historical evidence, not proof that the integrated source
passes today. No frame limit or emulator graphics setting was relaxed. The debug
APK was restored successfully after diagnostics. Release frame qualification
remains open: compare the integration parent and integrated app under matched
host load, collect main-thread and compositor traces for the same native-input
journey, and confirm the result on dedicated physical hardware before claiming
consistent frame performance. This publishing request does not deploy or
replace the operator's running daemon.

Evidence is retained in `tmp/performance-2026-09-21/`:
`post-rebase-check-changed.log`, `post-rebase-mac-smoke-index.json`,
`post-rebase-debug-results/`, `post-rebase-performance-initial-results/`,
`post-rebase-frame-control-results/`, and `post-rebase-frame-repeat-results/`.
Those generated artifacts are ignored by Git; the findings are recorded here.

A final fetch added three gateway-only commits through `54007a93`. They rebased
without conflicts and did not change the tested native sources. The 29 gateway
deployment unit tests and the TURN probe's Go build/test and vet checks passed.
The deployment container integration matrix was not rerun for this publication.
