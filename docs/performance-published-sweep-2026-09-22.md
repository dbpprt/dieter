# Performance sweep after publishing the Board fixes

> Historical record: Android launcher scripts and test aliases referenced below
> have been retired. Use the [current native test guide](../tests/e2e/README.md)
> for supported commands and selectors.

This sweep starts from `bc3cc0d9dd912285f70299feb4d365a51719b3cb`, which
contains all 28 previously local files rebased unchanged over 17 newer main
commits. That commit was pushed and verified on `origin/main`. This report
extends, rather than replaces, the evidence and rejected experiments in
[the previous continuation](performance-continuation-2026-09-22.md).

The latest follow-up is **Mac only**. All Chats now retains its directory across
navigation, selection no longer rebuilds rich directory rows, and the initial
transcript mounts a small tail that expands to fill the viewport. Board updates
preserve native row identity instead of reloading the table. In the final
populated debug fixture, all 35 chat open/return checks reached positioned
transcripts below one second, with no directory refreshes. Warm switches took
662 ms median, restored-chat returns 738 ms, and Board returns 362 ms to draw.
The reproduced multi-second transcript stalls no longer occur in this workload,
and Board opening preserves existing rows; this does not establish
instantaneous interaction or a 60/120 Hz frame budget. The installed application
(`/Applications/Dieter.app`, version 0.4.152) and operator daemon have not been
replaced. The tested app is the repository's packaged debug build at
`apps/mac/build/Dieter.app`.

## Findings and changes

* Mac Board navigation retains its four native lanes and card rows. Opening a
  card causes no full reload, row configuration, rich card-body evaluation or
  project read in the new baseline. Inspector resizing still measures 40 row
  heights. Repeated navigation still has substantial debug layout latency.
* Returning to Mac Chats performs no directory refresh while Live. The initial
  baseline has an empty chat directory; it must not be described as a large-chat
  benchmark. The extended fixture separately seeds 40 chats, including two
  pinned 300-message histories with Markdown and approximately 19 KiB tool
  results per message. Thirty alternating native clicks distinguish the first
  two opens from 28 warm switches.
* Android's neighboring primary pages were receiving the active conversation
  selection and transcript. Both Chats and Inbox can consequently compose the
  same detail UI while offscreen. `PrimaryPageState` now projects conversation,
  history and composer state only into its owning destination. Neighboring
  directories still receive current shared data. Regression tests cover live
  transcript updates, directory updates and switching the owning destination.
* Android's production navigation test still used the obsolete “Boards” label.
  It now drives the merged “Projects” UI. The 120 ms p95 and 500 ms severe-frame
  limits remain unchanged.
* A daemon conversation watch used the account metadata cursor as a transcript
  invalidation. Unrelated card comments/status changes therefore rebuilt an
  unchanged selected transcript. The watch now compares selected-card detail
  first when its transcript revision is unchanged. Filesystem events can arrive
  before the writer finishes publishing; the watch crosses that writer boundary
  with cancellation before rechecking its revision. It still checks project,
  board, workspace and comments, and does not take the comparison shortcut while
  another mutation remains pending. A cross-store notification regression checks that unrelated writes
  do not build another snapshot while selected-card comments still arrive.

## Measurements

All timings below are local evidence on the Apple M4 host. Timed workloads run
sequentially, without another task-owned compilation. The operator daemon and
installed Mac app are unchanged. Fixture daemon results describe the source
under test, not the operator's older running binary. No physical phone was used.

### Published Mac baseline

Packaged debug app; 100 cards, 85 in Todo; 15 native sidebar clicks per route,
returning from Screens. Timing includes target lookup through the first
destination drawing callback. It is neither compositor presentation nor data
readiness. The p95 uses the same discrete index convention as the Android test;
with 15 samples it is the maximum, not a stable population-tail estimate.

| Route | Median | p95 / maximum | Range | Directory generation changes |
| --- | ---: | ---: | ---: | ---: |
| Board | 382.2 ms | 464.8 ms | 258.3–464.8 ms | 0 |
| Chats, empty directory | 333.6 ms | 501.8 ms | 283.5–501.8 ms | 0 |

Card selection: 36.5 / 32.0 / 26.9 ms. First snapshot readiness: 371.4 ms;
the two warm opens matched selection time. All three retained the lane rows.
These measurements use the same definitions as the previous report, but are
not a controlled before/after trial against its smaller three-sample run.

Quiet Board after navigation used 0.309 CPU seconds / 10.040 wall seconds
(3.075% of one core). Quiet empty Chats used 0.188 / 10.171 seconds (1.853%).
Both had zero rendering counters and zero directory-generation changes. An
earlier Board quiet window in the same run used 4.04%, with two card-body
evaluations. This is higher than the earlier report's 0.74–1.20%; idle CPU is
not consistently negligible. The metric includes the app's other services and
the smoke driver, and is not a physical energy measurement.

Process physical footprint fluctuated around 134–195 MiB during Board returns
and 138–140 MiB during Chats returns, without monotonic growth in this short
run. This does not establish long-session leak freedom. Raw samples and quiet
windows retain exact byte counts.

Baseline evidence:
`apps/mac/.build/smoke/board-20260922-203753-d588a2b4-847e-476b-87eb-636292142f89/`.
The report and computed summaries are also copied into
`tmp/performance-published-sweep-2026-09-22/`.

### Populated Mac diagnostic and focused fixes

The populated run seeded 40 chats and two 300-message histories. Before the
latest Mac fixes, All Chats first-draw median was **637.5 ms**, maximum
**1,088.4 ms** across 15 returns. Board median was 422.9 ms, maximum 609.3 ms.
Neither route changed project/chat request generations. Warm chat selection
was much worse: median 1,266.7 ms, maximum 6,210.5 ms over 28 revisits. All
snapshot checks eventually passed. A live stack sample overlapped those chat
switches, so their timing is diagnostic, not a clean benchmark. The app was
observed with a blank, preparing transcript and roughly one core in use; it
recovered without restart. The small stack sample showed native/SwiftUI layout
work and does not establish an indefinite AttributeGraph loop.

The run also failed both board double-click checks under layout load. A
wall-clock expiry could discard a valid second click before AppKit delivered
it. The tracker now validates native input timestamps and keeps at most one
action until subsequent input or window deactivation, with a delayed-delivery
regression. It does not delay normal single-click opening.

On the user's Mac-only follow-up, investigation and fixes focus on:

* Retaining the All Chats native directory across destination changes, with a
  hidden native host while away and preserved scroll position. Its detail
  pane releases when leaving, so it does not display a board's conversation.
* Keeping conversation selection out of the directory's observation boundary.
  Chat rows compare displayed content, while selection decoration and machine
  presence update in smaller child views. This removes the observed full-list
  and rich-row work on every selection and presence heartbeat.
* Making a repeated click on the current All Chats destination a no-op instead
  of closing and reopening the same transcript.
* Applying board row identity changes with native insert/remove transactions,
  and metadata updates into existing cells. The old `reloadData` paths could
  discard visible rows during a live update. New regressions combine card
  selection, insertion, removal and summary changes and assert stable cells.

The follow-up instrumentation separately records event dispatch, selected
snapshot readiness and the timeline's prepared/positioned state. None is a
compositor-presentation measurement. Final measurements and validation appear
below.

### Mac retained-directory diagnostic

The retained-directory run completed all 30 switches and all five All Chats
returns. Every warm switch had **zero directory and rich-row body evaluations**,
and no chat/project directory generation changed. Both native board double-click
checks now passed; the board opening checks retained all lane tables and cells,
with zero rich-card bodies or full/row reloads. One external accessibility action
remained explicitly skipped by the in-process bridge.

The additional readiness metric exposed the remaining problem: warm selection
median was **60.4 ms**, but prepared/positioned timeline median was **2,374.6 ms**
(maximum 4,621.0 ms). Returning to All Chats with the last chat restored drew the
destination in **255.7 ms median**, but the timeline took **1,500.4 ms median**.
The separate directory-only All Chats returns measured 254.7 ms median over 15
clicks. Faster selection alone does not fix the visible wait.

A three-second stack sample during chat switching captured only 14 main-thread
samples. Eleven were in SwiftUI graph transactions; seven followed root size
calculation through the composer inset's minimum-size probe into transcript
stacks. Native message-view creation/update also appeared there. This supports
investigating repeated layout, not network refresh. The next implementation
puts the timeline behind a geometry boundary: ancestors size the viewport, while
rich rows receive the viewport's actual allocation instead of participating in
its minimum-size negotiation. The subsequent measurements and native scroll,
history and text-selection regressions are recorded below.

Sampling and one desktop screenshot overlapped the chat-switch phase, so this is
a diagnostic run. The desktop capture also showed an unrelated ChatGPT/Finder
consent dialog; it was not acted on. It confirmed the chat directory's normal
glass background and header, which the in-process bitmap capture renders black.
Quiet CPU was 1.40% of one core for Board, 1.79% for the directory, and 6.63% for
a selected chat, with zero rendering counters and directory generations in each
window. These values describe this debug fixture and host state.

Evidence: `board-20260922-221030-b6047f35-51e1-406a-9c93-75b75c085d30` under the
Mac smoke root; report and samples copied as `mac-retained-diagnostic-*` into the
sweep evidence directory, along with `mac-retained-chat.sample.txt`. The desktop
capture contains unrelated windows and is not intended for publication.

### Adaptive initial transcript window

The geometry-only repeat passed the package units and packaged Board smoke, but
still took 1,814.1 ms median / 2,264.7 ms maximum to prepare and position a chat
(30 switches), and 1,418.9 / 1,705.5 ms for five All Chats returns. It was not
accepted as resolving the visible wait. Its full smoke report is recovered in
`mac-viewport-report.json`; raw switch/return samples and the original smoke
directory were removed by a separate cleanup before they could be copied.
The measured summary was captured before removal. Compiler caches survived.

The next implementation starts at eight messages, growing the initial window
only when the native laid-out rows do not fill the viewport. The original text,
part and maximum-message bounds still apply. The model retains its complete
loaded page, and scrolling extends the mounted window through the existing
history controller. Initial readiness waits for native row placement, then
reveals the positioned timeline. Empty conversations do not wait for row layout.

The first regression run found three scroll failures with the smaller window:
initial placement could briefly detach from the tail, and the old full-viewport
preload distance could encompass nearly all available scrolling space. The
controller now distinguishes initial placement from input and bounds preload
reach to half the available scrolling distance. The rerun passed all 674 Mac
Swift Testing tests, the other 75 package Swift Testing tests and 5 XCTest tests,
including the same three scroll assertions, history anchor/frame checks, and
new long/short-row native viewport cases. No assertion was relaxed to accept
scroll reversal or position displacement. The fixture's old 1,000-point content
lookup now checks actual native scrollability, since rendering a smaller initial
window is the behavior being tested.

The first clean adaptive-window run completed all 30 switches, five restored-chat returns
and 15 directory-only returns without profiling or parallel task-owned tests.

| Journey | Median | p95 | Maximum |
| --- | ---: | ---: | ---: |
| Warm selected ID / cached snapshot, 28 switches | 22.0 ms | 310.6 ms | 405.8 ms |
| Warm prepared/positioned transcript, 28 switches | 639.6 ms | 823.1 ms | 898.6 ms |
| All 30 prepared/positioned transcripts | 642.0 ms | 856.7 ms | 898.6 ms |
| All Chats return: destination draw, 5 samples | 265.5 ms | 302.6 ms | 302.6 ms |
| All Chats return: restored transcript ready, 5 samples | 643.8 ms | 682.7 ms | 682.7 ms |
| All Chats directory-only destination draw, 15 samples | 240.8 ms | 470.0 ms | 470.0 ms |

Every selected snapshot and prepared timeline completed. Every warm switch had
zero directory and rich-row evaluations; all selected/return chat and project
request-generation deltas were zero. Quiet Board, directory and selected-chat
CPU were **1.62%, 1.82% and 2.16% of one core**, respectively, over roughly ten
seconds each, with zero rendering counters and directory generations. Selected
chat physical footprint stayed between 155.9 and 157.8 MB across the 30 samples;
this is a short run, not a long-session leak test.

Board opening retained all native tables and cells: zero full/row reloads,
configuration calls, rich-card bodies or project reads in all three samples.
Both double-click editing cases passed. Inspector opening still measured 40 row
heights; selected-state latency varied from 54.6 to 614.3 ms. Board returns still
have substantial debug rendering cost: 566.4 ms median and 1,105.4 ms maximum
across 15 samples. The no-reload fix must not be described as frame-budget
qualification. One in-process accessibility-action check is explicitly skipped.

The earlier source and this run differ in host state, including reclaimed disk
space. The measurements show the observed improvement and eliminated work;
they are not a controlled percentage-speedup or production 60/120 Hz claim.
The final report, raw samples, summary, logs and inspected images are preserved
under `tmp/performance-published-sweep-2026-09-22/mac-final-board/`, independently
of the disposable smoke root. Its original run ID is
`board-20260922-224113-71817973-af3c-43ca-a84d-b05b7ed1c1f2`.

### Final corrected-source repeat, September 23

After the titlebar correction and completed Mac/Go validation, the populated
suite passed again. The process inventories immediately before and after this
run contained no other app, compiler or test process. No profiling, screenshots
from an external driver or task-owned parallel tests overlapped the timed run.
Its ordinary fixture screenshots were taken by the existing smoke driver.

| Journey | Samples | Median | p95 | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Warm selected ID / cached snapshot | 28 | 23.1 ms | 292.1 ms | 330.0 ms |
| Warm positioned transcript | 28 | 661.6 ms | 856.7 ms | 859.7 ms |
| Positioned transcript, including first two selections | 30 | 674.6 ms | 876.0 ms | 946.3 ms |
| All Chats return: destination draw | 5 | 336.4 ms | 425.0 ms | 425.0 ms |
| All Chats return: restored transcript ready | 5 | 738.0 ms | 845.5 ms | 845.5 ms |
| Directory-only All Chats draw, including first visit | 15 | 263.4 ms | 936.7 ms | 936.7 ms |
| Directory-only All Chats draw, after first visit | 14 | 260.2 ms | 383.7 ms | 383.7 ms |
| Board return: destination draw | 15 | 362.4 ms | 435.1 ms | 435.1 ms |

All 35 positioned-transcript checks passed. Project/chat directory generations
stayed at zero, and all 28 warm switches had zero rich-row/list body evaluations.
The 936.7 ms first directory visit is retained in the overall distribution;
excluding it is explicitly labeled, not presented as the complete workload.

Quiet Board, Chats directory and selected conversation consumed **1.224%,
1.686% and 2.126% of one core**, respectively, over 10.2–10.5 second windows.
Every quiet render counter and directory generation stayed at zero. Selected
chat footprint ranged from **148.5 to 151.4 MB** across the 30 samples. These
remain short debug-process measurements, not physical energy or leak proofs.

All three native Board card openings retained tables and cells, with zero
full/row reloads, row configurations, rich-card body evaluations or project
reads. Selection took 405.4, 460.3 and 49.2 ms; loaded-snapshot readiness took
692.7, 460.3 and 49.2 ms. Inspector opening still remeasured 40 row heights.
Both native double-click checks passed. The suite's external AX action remains
explicitly skipped; it is not counted as a verified external accessibility path.

Evidence is preserved under
`tmp/performance-published-sweep-2026-09-22/mac-final-board-corrected/`, including
the report, raw switch/return JSON, computed summary and inspected Board/chat
images. Original run:
`board-20260923-000134-8df60925-4281-4fa0-a134-52d0f5b4d588`.

### Daemon

Eight actual projection subscriptions over 30.000 seconds used 0.045454 CPU
seconds, **0.152% of one core**. RSS was 37.94 → 38.28 MiB. The test also
asserted that all eight subscriptions remained active and emitted no additional
content snapshot while quiet. It excludes network transport and operator load.

Five matched warm benchmark repetitions confirm bounded history copies:
30-message snapshots allocate approximately 681 KB whether the underlying
tool-heavy history has 30 or 300 messages. The unchanged revision path allocates
4,698 bytes versus approximately 431 KB for the text fixture's full snapshot
and serialization. See `go-bench.log` for every sample, including cold/cached
preview and truncation comparisons. These are operation costs, not click latency.

The selected-detail comparison allocates approximately **112 KB** versus
approximately **680 KB** for the tool-heavy snapshot, an 84% reduction for that
part of an unrelated-metadata notification. It still reads selected metadata;
this is not zero-cost invalidation. Five matched comparison samples are in
`go-metadata-comparison.log`; timing varied substantially and should not be
treated as a stable end-user latency improvement. The initial regression failed
before writer-boundary handling was added; the corrected race-enabled selected
watch regressions passed, including comments and cross-process messages.

### Android integrated clean run

Normal visible `Pixel_9_API_37_1`, `emulator-5554`, host Apple M4 GLES, production
mode. Real taps drove Chats → Projects → Tools → Terminal four times after
warming routes. This uses the existing saved workspace; it is not a synthetic
fixed-card-count comparison with the Mac fixture.

**The gate failed:** 503 frames, p50 38 ms, p95 222 ms, p99 577 ms, maximum
5,298 ms. Six frames exceeded 500 ms. Navigation used 20,039 CPU-ms over
32,489 wall-ms; quiet used 7 CPU-ms / 5,104 wall-ms (**0.137% of one core**).
Low quiet CPU does not imply responsive interaction. Neither budget was changed,
and the debug APK was restored without uninstalling data.

The worst frame is substantially worse than the previous continuation's clean
342 ms maximum. This remains a failure requiring attribution, not proof that
the neighboring-detail change improved navigation. A post-test host sample,
during debug APK restoration, reported 3.93 GiB swap used and 37% system-wide
memory free; it was not captured during the stalled frame and cannot establish
its cause. The separate trace uses explicit warmup/measured navigation markers
so startup and build time can be excluded from attribution.

Evidence: `android-navigation.log`, `android-first-metrics.log`,
`android-first-results/`, `host-memory-after-android.json`, all under the sweep
evidence directory. A first attempt to prebuild the trace APK failed because
`ANDROID_HOME` was absent; no trace was captured by that attempt. Its error is
preserved in `android-trace-build.log`; the subsequent command supplies the SDK
path explicitly.

### Android clean run after disk recovery

The repeat retained the same APK and unchanged limits, with recovered disk
headroom and no parallel task-owned compilation. It still failed p95: **404
frames, p50 35 ms, p95 135 ms, p99 189 ms, maximum 408 ms**. Navigation consumed
8,143 CPU-ms / 19,861 wall-ms; quiet consumed 6 / 5,089 ms (**0.118% of one
core**). No frame exceeded 500 ms in this run. This is improved observed
behavior, but neither a controlled attribution to disk space nor a passing
interaction result. The debug APK was restored successfully. Exact logs and
results are in `android-after-space-metrics.log` and
`android-after-space-results/`.

### Android trace attribution

The 33.54 MB Perfetto capture contains all **12 measured journeys spanning
19.761 seconds**, separately marked from warmup, and no nonzero trace error
counters. Queries identify the actual test PID from its navigation markers:
the initial process scan retained a stale `zygote64` name for this subsequently
forked app. Selecting by the initial process name would have incorrectly
reported zero measured journeys.

During those measured journeys, RenderThread spent 7,292 ms inside swap calls,
including **5,281 ms across 339 buffer-release waits**, maximum 200.48 ms. These
are nested wall intervals, not additive CPU totals. Main-thread `postAndWait`
totaled 1,141 ms, maximum 65.94 ms. SurfaceFlinger scheduling and frame-deadline
misses remain present.

There is also substantial application work. Projects layout outliers were
135–189 ms wall, including **129–149 ms of scheduled main-thread CPU**. Chats
had 107–165 ms layouts with **107–156 ms scheduled CPU**. The largest measured
layout contained 16 subcomposition/recomposition operations and 35 text
measurements; inclusive child totals must not be added as if disjoint. The
largest layout across all phases was 586 ms and is kept separately from the
measured navigation analysis.

The traced run happened to pass the existing regression gate: 468 frames,
p50 27 ms, p95 117 ms, maximum 277 ms; navigation CPU 7,996 / 19,761 ms and quiet
CPU 4 / 5,071 ms. **A traced passing run does not erase the clean failure** or
establish reliable 60/120 Hz interaction. The measured layouts alone exceed a
16.7 ms frame several times over.

Evidence includes `android-navigation.perfetto-trace`, `trace-attribution.sql`,
`trace-attribution.txt`, `layout-detail.sql`, `layout-detail.txt`, and
`layout-all-phases-detail.txt`. The saved Perfetto launcher is a Python script;
invoke it with `python3`, not as an executable when its execute bit is absent.

### Host disk exhaustion

Two attempts to sign the newly compiled Mac smoke app failed. The signing
system log establishes the cause: writing the 137 MB `.cstemp` file failed with
`errno=28` (no space). The system volume had only about 159 MiB available.
This directly explains the build failure. It is a material qualification limit
on timing evidence collected near that point, but does not prove the cause of
the Android 5.3-second frame.

Recovery archived 98 completed, inactive smoke fixture homes losslessly within
their existing run directories. Every regular file is compared by SHA-256
against its gzip/tar archive before the expanded disposable fixture is removed.
At that point reports, screenshots and logs remained at their original paths;
compiler caches, operator data and running services were untouched. The audit is
`fixture-archives.jsonl`, with progress in `fixture-archive.log`. To inspect an
archived fixture later, extract its `fixture-home.tar.gz` inside that run
directory. The archive job completed successfully with 10.21 GB free; a later
`df` check showed 11 GiB available. The next Mac build signed successfully
without clearing either compiler cache. Much of the duplicated fixture data
was a 162 MB `.omp/natives` binary per fixture; retained evidence needs a
bounded archival policy, including that cache as well as Dieter runtimes.

A later external cleanup removed the older `apps/mac/.build/smoke` directories,
including their archives. Historical original paths in this report are therefore
not guaranteed to exist. Evidence already copied into
`tmp/performance-published-sweep-2026-09-22/` survived; final Board and other Mac
suite evidence is preserved there independently of the smoke build tree. Both
canonical Swift compiler caches survived the cleanup.

## Reproduction and interpretation

```sh
# Safe, disposable packaged-app fixture; opt-in counters never publish state.
DIETER_PERFORMANCE_SWEEP=1 just e2e run --platform mac --case mac.board

# Fixture setup is excluded from these measurements.
DIETER_IDLE_SYNC=30s go test ./internal/server -run TestIdleSubscriptionProcessCost -count=1 -v
go test ./internal/server -run '^$' -bench Benchmark -benchmem -count=5

# Normal visible AVD, production-mode app, real native input.
just android performance-test
```

`DIETER_PERFORMANCE_SWEEP` adds bounded measurements to the debug smoke app and
seeds only the disposable gateway fixture. It is not a production telemetry
switch. Native generation deltas include invalidation as well as RPC admission:
zero establishes neither happened, while a positive delta is not an exact RPC
count. Process footprint is measured after settling, not retained-object count.

## Verification and remaining work

The complete Swift package run passed **749 Swift Testing cases and 5 XCTest
cases**, including 674 Mac cases. This was repeated successfully after the
titlebar correction (`mac-final-units.log`, Mac cases 134.622 seconds).
New regressions cover retained directory
identity and scroll position, warm selection without rich-row evaluation,
live Board insertion/removal/metadata updates, delayed double-click dispatch,
and adaptive transcript mounting with correct history and scroll following.
The Core (95 report entries), Conversation (120), Machine (14), Sidebar (17
prepare + 13 relaunch), Terminal (13), Island (24) and Workspace (42) packaged
suites passed. Machine preceded the titlebar-only correction; the other six
completed on the corrected source. Report entries include measurements and
fixture metadata, so these counts are not asserted as independent test counts.
Conversation explicitly skips fresh-state history pagination and PDF/HTML export
acceptance; native Save sheets were verified, and separate unit regressions
cover pagination/scroll behavior. Its image-attachment check reports an
accessibility-action fallback pass. The final Board suite passed all functional
checks with its one explicit external-AX skip (65 report entries); the corrected
source measurements appear above. Affected Go race tests and vet both passed for
`cmd/dieter`, `cmd/dieter-gateway`, `internal/cli`, `internal/controlrtc`,
`internal/daemon`, `internal/gateway`, `internal/server`, and both isolated fixture
packages. The two command packages contain no tests; race tests in the CLI and
server packages took 180.261 and 170.409 seconds. The registered combined
verification execution exited successfully; logs are `go-final-race.log` and
`go-final-vet.log` (empty on successful vet).

The first conversation smoke failed its native Copy Link action. Its driver
used the existence of text storage as input readiness immediately after changing
the transcript. It now reacquires the visible link and waits for stable glyph
geometry before each native right click. The original window-event log confirms
the race: the failed first click went to **(-270, -157)** in window coordinates,
outside the window; the succeeding second action went to **(1035.8, 608)**.
The app was active and the window key for both. A stricter intermediate diagnostic
incorrectly required the root hit test to return `MessageTextView` itself:
the captured glyph was visible, but SwiftUI returned its owning
`HostingScrollView.PlatformGroupContainer`. The corrected readiness check
accepts the text view or its owning container, retains the real posted mouse
events and menu assertions, and reports geometry/hit-target details on failure.
No production menu behavior was changed or skipped to accommodate this check.

The Sidebar suite also caught a real retained-host layout regression: the chat
divider stopped 52 points below the window top. The host occupied only the safe
content area, preventing the existing titlebar-spanning background/divider from
extending above it. The root now gives the native host the full pane while the
hosted controls keep the window safe-area inset. The original edge-to-edge
boundary assertion is unchanged and passed in both the prepare and relaunch
phases. The complete Sidebar suite passed (17 prepare and 13 verify report
entries), including companion-pane chat switching and persisted widths/folders.
Its inspected evidence is preserved in `mac-final-suites/` under run
`sidebar-20260922-233725-4c4f094e-5f9d-4029-985c-1d81b03bf93e`.

During final verification the host became heavily loaded by an unrelated C++
build and Spotlight indexing (one-minute load about 40–44). The snapshot is saved
as `host-load-during-final-verification.json`. No unrelated process was stopped;
subsequent functional runs under that load must not be interpreted as clean
performance measurements. Read-only checks reported low memory pressure and no
recorded thermal/performance warning.
The first titlebar-verification attempt exhausted its 15-minute **execution**
allowance during compilation, before running any Sidebar assertion. Its compiler
children exited after termination; canonical caches were preserved. The retry
uses a longer execution allowance with unchanged test and interaction limits.

The remaining performance work is specific:

* Board returns took 312–435 ms in the final debug run; earlier repeats reached
  1.105 seconds. Opening the inspector still remeasures 40 mounted row heights. Profile
  these layout transactions next while retaining width/wrapping, final-row and
  scroll-anchor correctness checks.
* Chat timeline preparation is now bounded and below one second in the final
  fixture, but roughly 660–740 ms remains visible. Qualify an optimized build with the same
  large histories and native input before setting a tighter end-user budget;
  do not substitute cached snapshot readiness for displayed transcript readiness.
* Quiet app CPU is about 1.2–2.2% of one core in short local windows. A longer
  quiet/streaming session and physical energy measurements are still needed for
  energy or leak claims. Keep generation and render counters alongside CPU.
* Earlier Android buffer/renderer stalls and Terminal-to-Chats layout costs
  remain open. The latest user scope is Mac only, so this follow-up does not
  restart Android work or repeat the rejected R8/neighbor-removal experiments.

The repository's affected-check planner also selects Android and iOS integrations
because earlier local changes and the shared fixture remain in the checkout.
Those integrations are not rerun for the Mac-only follow-up; this report does
not claim a completed repository-wide `just check-changed` run.

Native bitmap captures have limits: Chats' glass directory appears black in
`cacheDisplay` captures despite the earlier desktop confirmation, and the final
expanded Island bitmaps contain only colored blocks. The Island settings image
renders normally and its 24 functional/geometry report entries passed, but those
expanded bitmaps are not accepted as evidence of the composited Island's visual
appearance. No compositor-level visual or frame-rate qualification is claimed.

## Delivery state

The Mac follow-up is implemented and its relevant functional checks pass, with
the explicit skips and measurement limits above. Swift formatting, Go formatting
and `git diff --check` pass. No test-owned Mac app or isolated gateway process
remains. The operator daemon remains PID 43786 (started September 22 at 14:45),
and the installed Mac app remains version 0.4.152. Both canonical Swift caches
were reused. No physical Android device or emulator was used in this Mac-only
follow-up.

These 29 changed/untracked paths remain local on top of `bc3cc0d9`; no new commit,
push, installation or deployment occurred during this follow-up. The previously
requested push of `bc3cc0d9` remains separate from these new fixes. The packaged
repository app is ready for review at `apps/mac/build/Dieter.app`.
