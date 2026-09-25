> **Historical engineering record.** This dated investigation or implementation

> Historical record: Android launcher scripts and test aliases referenced below
> have been retired. Use the [current native test guide](../tests/e2e/README.md)
> for supported commands and selectors.
> report describes the state at the time it was written. For current behavior and
> setup, use the [documentation index](README.md).

# Dieter performance investigation — 21 September 2026

The findings below are the retained baseline. The subsequent
[implementation and validation report](performance-implementation-2026-09-21.md)
documents the end-to-end fixes and supersedes this report's remaining-work list.

This sweep covers daemon CPU/allocation costs, durable streaming writes,
synchronization cadence, conversation refreshes, and the Mac and Android UI
paths. It found avoidable repeated work and adds measurements and regressions
alongside targeted fixes. It does **not** establish that every interaction now
meets a frame budget. The installed daemon was observed without replacing or
restarting it; implementation measurements use disposable fixtures.

## Measured results

Machine: Apple M4, macOS 27.0. The installed daemon reports 0.4.230, PID 41194.
No DieterMac app or Android emulator was running at the initial inventory. The
Pixel_9_API_37_1 emulator was subsequently started on emulator-5554 with verified
Apple M4 host GLES. The attached physical Android phone was not targeted.

| Workload | Measurement | Interpretation |
| --- | --- | --- |
| Warm selected-chat idle read, 30 × 8 KB messages, three benchmark repetitions | Former snapshot path median **6.810 ms**, **443,487 B**, **2,111 allocations** per poll; revision check **0.274 ms**, **4,618 B**, **39 allocations** | About **25× faster**, **99% less allocation** for an unchanged poll. This is a matched microbenchmark, not total app CPU. The former-path benchmark includes serialization but omits hashing, so it slightly understates the original work. |
| Four streaming writers, four reconnecting sync clients, 8 projects/160 chats, four 25 MiB histories, 30-second workload | 500 acknowledged appends; append p50 **165.2 ms**, p95 **255.6 ms**, p99 **277.8 ms**; first non-transport frame p95 **476.0 ms**; maximum frame **1,062,283 bytes** | A baseline showing real write/lock pressure. Reconnect first-frame latency is not chat click latency. Every acknowledged event was verified after reopening the store. |
| Same load-test CPU profile, including fixture construction and recovery | **24.86 CPU-seconds / 55.21 wall-seconds**; **3.57 GB** cumulative allocations | Setup dominates the full profile. Do not attribute all of it to steady-state sync or divide these totals by the 30-second workload. |
| Mac debug hosted board, corrected fixture, 100 cards across four lanes | Median **2,245 ms** until real rows mounted; **100 rows mounted**; drawing median **227 ms** | Clear construction cost in this debug fixture. It includes native window setup and is not physical click-to-display latency. Builds/emulator activity were present. |
| Packaged Mac debug app, isolated core journey, three small Markdown file opens | Click-to-selection **45.7 / 538.8 / 191.6 ms**; click-to-loaded-editor **643.1 / 862.3 / 545.0 ms** | Includes target lookup, RPC/loading and native editor construction. The readiness check observes the editor's text, not compositor presentation. Three samples are diagnostic, not a percentile estimate. |
| Android debug warm navigation, Pixel_9_API_37_1 emulator, 506 recorded frames | **p50 32 ms, p95 69 ms, p99 435 ms**; 484 frames over 16 ms and 225 over 33 ms; 13,159 CPU-ms / 13,113 wall-ms | Includes UI test runner and connection work; exceeds smooth frame budgets despite passing the existing severe-stall guard. |
| Android debug passive window after navigation | **19 CPU-ms / 5,049 wall-ms ≈ 0.38%** of one core | A short emulator sample, not a physical-device battery estimate. |
| Mac debug chat window plus activity island, 58 chats / 25 running indicators, 30 seconds after settling | **0.02% CPU**, **0.0 MiB** physical-footprint growth | Isolated UI fixture with no live network streams. This does not include daemon/provider work or prove whole-app idle CPU. |
| Installed daemon, 30-second process counter capture during this agent task and concurrent validation | **9.32% of one CPU core**, RSS median **131.1 MiB**, maximum **138.2 MiB** | Active development workload, not a clean idle baseline or a measurement of the changed daemon. Child compiler/agent CPU is excluded. |

A second Android navigation run inside the complete connected suite recorded
450 frames: **p50 27 ms, p95 87 ms, p99 262 ms**, 445 over 16 ms and 135 over
33 ms; 9,272 CPU-ms over 9,876 wall-ms. Its passive sample was 25 CPU-ms over
5,032 ms (**0.50%** of one core). Both runs pass the severe-stall guard while
remaining outside smooth frame budgets. The final manual launch showed cached
data and a disconnected isolated-test gateway; these are UI/emulator results,
not a qualification of live account synchronization. That one cold activity
launch reported 3,052 ms from Android's activity manager. The final UI hierarchy
and screenshot are retained as `android-final-ui.xml` / `android-final-ui.png`.

Raw evidence is retained in `tmp/performance-2026-09-21/` (ignored local output):
`idle-benchmark.log`, `sync-before.log`, `sync-before.cpu`, `sync-before.mem`,
`server-before.test`, `daemon-active.json`, `daemon.sample.txt`, and
`daemon-baseline.log`, `mac-native-measurements.log`, `android-tests.log` and
`android-frame-metrics.log`. The process sample of the stripped installed executable
has mostly unresolved Go symbols; the isolated Go profile supplies attribution.

The original Mac board diagnostic ran without a window and reported **zero
mounted card rows**. Its timing is retained as `mac-board-baseline.log` but is
not valid evidence of card rendering. The diagnostic now attaches a native
window, waits for actual rows, fails if none mount, and separately reports
initial layout, time until rows exist, and drawing. Its 10 ms readiness probe
and bitmap drawing still do not measure compositor presentation.

The packaged debug board journey also measured real native click dispatch and
the destination's first drawing callback, with no forced layout or accessibility
traversal inside the wait. It uses 100 cards, including 85 in the largest lane;
20 rows were mounted. Each destination was sampled three times:

| Destination | Median click invocation → first draw | Observed range | Largest main-loop gap |
| --- | ---: | ---: | ---: |
| Board | **1,173.9 ms** | 1,137.6–1,946.0 ms | **1,972.7 ms** |
| All Chats | **347.5 ms** | 339.8–599.6 ms | **613.1 ms** |
| Files | 125.2 ms | 115.6–163.5 ms | 170.9 ms |
| Changes | 109.2 ms | 101.0–194.8 ms | 201.7 ms |
| Schedules | 223.8 ms | 213.4–275.6 ms | 319.5 ms |
| Terminals | 71.0 ms | 68.2–75.2 ms | 112.3 ms |
| Settings | 217.0 ms | 213.7–286.2 ms | 303.3 ms |
| Screens | 94.0 ms | 92.1–100.0 ms | 106.5 ms |

These intervals include target lookup and event delivery, not compositor
presentation or complete data readiness. The loop probe targets 8 ms and runs
for another 150 ms after the destination draws. In a separate direct-open probe,
board selection took 0.3–2.4 ms while layout/display took 1,093–1,125 ms. This
supports prioritizing view construction over selection state mutation. The
fixtures differ from the four-equal-lane hosted test, so their absolute timings
are not a before/after comparison. Screenshots of the board, All Chats and the
scrolled final card were inspected. Full evidence:
`apps/mac/.build/smoke/board-20260921-160443-dc0189de-9d4e-48be-83aa-e13cd5730248/report.json`.

## Confirmed problems and changes

### 1. Idle conversation watches repeatedly reconstructed the same transcript

`watchConversation` ran every 350 ms by default. Each tick resolved card,
project, board, comments and transcript data, built a bounded protobuf snapshot,
updated snapshot history, serialized the snapshot and hashed it before deciding
that nothing needed sending. Quiet network traffic concealed repeated server
work. More open clients multiplied that work.

The watcher now checks the committed global cursor, transcript file revision,
and pending-mutation marker first. Unchanged ticks skip reconstruction entirely.
Metadata changes, cross-process commits, checkpoint replacement and incomplete
mutations still invalidate the read. The checkpoint is sampled **before** the
snapshot so a concurrent commit forces a later refresh. When a read is necessary,
protobuf equality avoids serializing a second copy just to hash it.

Debug logs summarize watch duration, poll count, snapshot-build count and frame
count once the watch ends. A quiet watch should show many polls, one build and
at most one frame. Tests verify this as well as comment-only changes and a
transcript written through a separate Store instance.

This retains the polling interval and conservative global invalidation. A busy
unrelated conversation can still invalidate an otherwise quiet selected chat.

### 2. Shared remote conversations entered local-only work

The live daemon log showed repeated `sync conversation hydration failed`
warnings for conversations owned by another machine, sometimes multiple batches
per second. Orphan maintenance also logged an ownership failure every ten
seconds. Remote directory rows are expected in the shared project model; their
transcripts and execution lifecycle remain on the owner.

Sync now filters hydration candidates by immutable owner **before** applying
the active/recent budget. Remote cards stay visible in the directory, stop
consuming local hydration slots and no longer trigger normal-path failures.
Orphan scanning skips remote-owned rows before looking at their local status.
Regression fixtures include both local and replicated remote running cards.

### 3. Android rebuilt the whole workspace for transcript-only frames

Even when a global delta contained only conversation tails, Android applied the
full workspace snapshot: it merged projects, boards and cards, rebuilt owner
maps, sorted chats, reconciled optimistic state and reconstructed selected
project state. That also gave the UI a new selected-state object and triggered
its downstream projection path.

A transcript-only path now updates conversation/freshness maps while retaining
the original workspace objects. It evicts old uncovered entries above the
24-entry cache target, preserving all conversations covered by active sync;
that coverage can exceed 24 during many simultaneous runs. Metadata, tombstones and pending
optimistic/outbox changes retain the complete reconciliation path. Empty outboxes
skip constructing full directory membership sets. Tests replay 1,000 transcript
updates against a 1,000-chat directory, check reference preservation, reject
older tails and verify bounded cache eviction and coverage changes.

This does not eliminate all ViewModel work: activity summaries and pending card
operation projection still run on connection-state emissions.
It also does not optimize every streaming frame. The daemon reuses directory
metadata for text-only events, which can take this path; usage/finish and other
workspace changes still require full reconciliation. Separately,
`AppendConversationEvent` continues to persist card activity timestamps and
publish peer summaries. The regression proves the transcript-only case; it is
not an end-to-end streaming CPU reduction measurement.

### 4. Mac conversation metadata caused unnecessary timeline work

The timeline revision advanced on any conversation snapshot change, including
comment counts and sequence-only metadata. Duplicate or stale watch frames also
scheduled cache persistence even when the visible snapshot was unchanged.

Timeline preparation now runs for message changes or changes to task plans,
subagents and queued messages that affect its contents. History mode still
invalidates the timeline. Duplicate accepted snapshots avoid another cache
write. Tests exercise 1,000 metadata-only changes, auxiliary timeline content,
duplicate frames and a genuinely newer update. Signposts cover conversation
update application, and projection signposts have individual IDs so nested
measurements remain distinguishable in Instruments.

## Remaining costs, in priority order

**Mac board construction is the largest UI stall found.** The corrected native
fixture mounted 27 rows for a single 100-card lane (median 414 ms until rows
mounted), but all 100 rows for four 25-card lanes (median 2,245 ms). Native List
prefetch/automatic sizing now builds far more rich card graphs than the former
custom table described in the September 8 report. Those historical timings are
not a matched comparison: the implementation, OS and host workload differ.
The next UI optimization should bound rich row construction while preserving
measured wrapping, accessibility, merge footers, drag/drop and scrolling to the
last card. Blindly restoring estimated heights risks the layout regressions
covered by `BoardLaneListLayoutTests`. The bitmap was inspected and contains
the expected populated four-lane board. Evidence: `mac-native-measurements.log`
and `apps/mac/.build/board-profile.png`.

**File opening also remains visibly expensive.** The packaged core journey
loaded tiny Markdown documents in 545–862 ms, and selection feedback itself
took up to 539 ms. Its correctness assertions passed, but those timings need a
main-thread trace separating selection, RPC completion, Markdown parsing and
editor mounting. Do not attribute the whole interval to networking. Evidence:
`apps/mac/.build/smoke/core-20260921-160134-352da161-cc4c-4daf-9f53-9f810fe485ee/report.json`.

1. **Durable writes and peer summary publication on every streamed event.** The
   CPU profile filtered to streaming append stacks attributes 5.46 CPU-seconds
   to appends, with 2.39 cumulative seconds in `writeCard`, 2.28 in `publishCard`
   and 1.94 in peer database publication. These are overlapping stacks, not
   additive totals. The p95 append delay includes lock/I/O waiting; CPU samples
   alone cannot explain that wait. The event journal must remain durable. A
   future optimization should coalesce replicated activity summaries while
   flushing semantic transitions immediately, with crash/restart and
   cross-machine freshness tests. Removing fsync or the central writer lock is
   not an acceptable shortcut.
2. **Polling introduces latency and wakeups.** Global sync checks every 200 ms;
   selected conversations default to 350 ms (allowed 100 ms–5 s); KV watches
   poll every 250 ms. A change that just misses a poll can wait nearly a full
   interval before work even starts. Commit notifications with a bounded
   cross-process recovery poll would improve both latency and idle CPU. Merely
   shortening all timers would increase cost.
3. **Repeated chat-directory reads and duplicate cold-open reads.** Mac
   `openChats()` always awaits `refreshChats(includeArchived: true)`, even when
   active sync already supplies the current directory. It raises the
   "Refreshing chats" indicator and waits for that RPC before restoring the
   last selected chat. The native navigation capture still showed that
   indicator at first draw. Make live-directory navigation immediate and load
   archived data on demand, with freshness/offline tests before removing the
   fallback. The existing loading-churn smoke checks navigation stability, not
   a request-count or latency budget. Separately, Mac fetches a conversation and then opens a
   watch that reads the current snapshot again. Android starts the cold-open
   watch and unary fallback together. A delayed hedge and stream-first initial
   snapshot could reduce work, but must retain comments, history, reconnect and
   freshness behavior. No blanket cache-based suppression was introduced.
4. **Other-machine directory polling.** Mac and Android skip the actively
   synchronized machine but still fetch online peer directories every 15 s,
   with concurrency bounds of three and four respectively. This remains useful
   for owner-only details; shared metadata replication alone is insufficient
   to remove it. Measure and narrow these responses before replacing the loop.
5. **UI frame budgets remain to be qualified.** Existing Android navigation
   guards allowed p95 below 500 ms and no frame at or above 750 ms. They detect
   severe stalls, not a 60/120 Hz experience. The test now emits p50/p95/p99,
   counts over 16/33 ms, navigation CPU time and a separate passive-window CPU
   sample. Release profiling on a physical device is still needed before
   selecting enforceable frame/energy budgets.

Screen media has its own qualification suite and recent reports in
`docs/screenshare-performance-investigation-2026-09-18.md` and
`docs/screenshare-performance-implementation-2026-09-18.md`. This investigation
does not substitute chat timing or CPU samples for physical glass-to-glass
screen-sharing latency, GPU usage or battery measurements.

## Repeatable measurement workflow

Run one workload at a time on a settled host. Record build configuration,
transport route, directory/history size, active streams, display refresh rate
and whether windows are foreground/background. Separate cold launch, warm
navigation, quiet window, streaming and reconnect tests.

```sh
# Exact process inventory; never replace the operator daemon to profile it.
dieter daemon status
just mac status
dieter daemon logs --lines 200

# Capture counter deltas, not ps's smoothed lifetime CPU estimate.
# Use a new output name for every capture. 100% means one busy CPU core.
python3 scripts/measure_process.py --pid VERIFIED_PID --duration 30 \
  --label 'release; idle chat; direct TLS; no builds' \
  --output tmp/performance/idle.json

# Warm matched read costs; setup is outside benchmark timers.
go test ./internal/server -run '^$' -bench '^BenchmarkConversationIdleRead$' \
  -benchmem -count=5

# Bounded sync workload, disposable state only. Profile includes setup/recovery.
mkdir -p tmp/performance
DIETER_SYNC_SOAK=30s go test ./internal/server \
  -run '^TestSyncLargeWorkspaceSoak$' -count=1 -timeout=3m -v \
  -cpuprofile=tmp/performance/sync.cpu -memprofile=tmp/performance/sync.mem \
  -o tmp/performance/server.test
go tool pprof -top -cum -focus=AppendConversationEvent tmp/performance/sync.cpu
go tool pprof -top -alloc_space tmp/performance/sync.mem

# Canonical Mac test cache; run sequentially, never alongside another Mac test.
DIETER_BOARD_PROFILE=1 just mac test boardOpeningStageDiagnostic
DIETER_RUN_LIVE_WINDOW_SMOKE=1 DIETER_LIVE_WINDOW_SMOKE_SECONDS=30 \
  just mac test productionChatListLiveWindowSmokeTest

# Visible pinned emulator only. This does not choose the attached phone.
just android connected-test com.dbpprt.dieter.ui.MainActivityFramePerformanceTest
"$HOME/Library/Android/sdk/platform-tools/adb" -s emulator-5554 \
  logcat -d -s DieterPerformance:I
```

Inside a Dieter agent conversation, start long measurements through registered
background processes / `dieter remote exec --card CARD --detach -- ...` and read
bounded retained output. Do not launch detached shell jobs. The harness relay
intermittently rejected tool requests as unauthorized; the documented Dieter
CLI equivalent successfully registered processes and retrieved their output.

For a deeper Mac trace, attach Instruments Time Profiler and Points of Interest
to the verified app PID and correlate `Projection`, `Sync` and `Conversation`
signposts with main-thread stalls. On Android, capture a System Trace/Perfetto
trace around the same navigation journey; correlate frame deadlines, main-thread
work, Binder/network activity and GC. Neither profiler should log message text
or credentials. RSS is not a leak verdict; compare retained memory after
repeated open/close cycles and a settled period.

## Validation and lifecycle

The targeted Go performance regressions and three benchmark repetitions
passed. All selected Go race suites and `go vet` passed with
`GOFLAGS=-p=1 just check-changed`. The first run hit
two unchanged scheduler completion deadlines while native compilation and
emulator startup were concurrent. Both tests passed separately and in the
bounded-concurrency run; the original failures remain recorded.

The complete Mac test command passed: Swift Testing reported groups of 656, 56,
8 and 8 tests, plus five XCTest cases. Fourteen explicitly opt-in tests were
skipped in this default run, including live-account/transport and screen-media
fixtures. The corrected board and 30-second idle-window diagnostics were run
separately and passed. Android unit tests: **345 passed**, zero failures/skips;
the targeted navigation instrumentation passed with the percentile/CPU results
above. The complete Android connected run passed: the XML contains **94 cases,
64 passed and 30 skipped**, with no failures/errors. Gradle's console double-counted
skipped notifications and printed 124; the XML case records are authoritative.
The skipped cases require explicit account/isolated-gateway or screen fixtures.

All eight packaged Mac suites completed successfully: core, board,
conversation, machine, sidebar, terminal, island and workspace. The conversation
suite passed on its corrected rerun, and the two focused refresh regressions
passed again. Board accessibility action invocation requires an external AX
driver and was skipped; conversation HTML/PDF export acceptance requires an
external Save-sheet driver, and bounded history was skipped in the fresh-state
renderer fixture. No skipped case is counted as a pass. The initial aggregate
`check-changed` command stopped at the smoke failure; remaining components and
the corrected conversation suite were then completed separately.

Reports are under `apps/mac/.build/smoke/` with run prefixes
`core-20260921-160134`, `board-20260921-160443`,
`conversation-20260921-161626`, `machine-20260921-161003`,
`sidebar-20260921-161024`, `terminal-20260921-161054`,
`island-20260921-161123` and `workspace-20260921-161147`.
All reports were read and relevant screenshots inspected. Registered execution
output is also retained under `tmp/performance-2026-09-21/`.

The first conversation smoke run exposed a fixture dependency on duplicate
cache writes: it treated `onSnapshot` as a watch-arrival callback and timed out
after unchanged frames stopped persisting. The fixture now checks the existing
watch freshness timestamp instead, including when the initial frame arrives
before the wait begins. The duplicate-frame regression also checks that
freshness still advances. The same smoke run exposed a missing `Machine` entry
in its expected hover-label map; the product already supplied that label.
Both smoke assertions were corrected without weakening their checks.

Native raster captures have limits: the activity-island bitmap did not show its
rendered controls, despite passing its structure/interaction assertions. It is
not used as visual proof. Some AppKit layer-backed surfaces also appear black
in bitmap captures. The board and conversation captures are used only for the
content and layout that is actually visible, not as compositor timing evidence.

Unrelated edits already present in the shared checkout were preserved. Native
builds used the canonical `dieter-tests` and `dieter-local` caches; the packaged
Mac app was a debug build. Final inventory found **zero DieterMac processes**.
The task-owned Pixel_9_API_37_1 emulator was closed with the standard snapshot
save/shutdown recipe, which exited successfully; emulator-5554 and its QEMU
process were absent afterward. The attached physical phone was untouched.
The operator daemon remained PID 41194 throughout. No changes have been
published or installed over it. `git diff --check` and Go formatting checks
passed after the final changes.
