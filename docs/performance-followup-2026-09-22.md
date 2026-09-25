# Mac board and active transcript performance — 22 September 2026

This follows the report of a board refresh when opening a Mac card. It uses
source based on `904b576c`, an isolated 100-card native fixture (85 cards in
Todo), and the canonical debug app and test caches. It does not replace or
restart the operator's daemon.

## Reproduced behavior

The unchanged packaged Mac app reproduced **four full lane reloads on each
card opening**, with **zero project reads**. The refresh is native view
recreation in this scenario, rather than a project fetch. Three actual pointer
clicks took 678.3, 1513.3, and 473.5 ms to observed selection; loaded content took
1446.7, 1513.3, and 473.5 ms. Each opening configured 15 rows and measured 72–73
heights. Board navigation reached the first drawing callback in 1347.6–1381.3 ms.

These are debug fixture measurements, not compositor presentation or production
release frame times. The original unprofiled run passed its functional smoke
checks. A second run with stack sampling disturbed navigation and failed one
navigation attempt; it is diagnostic evidence, not a timing comparison.

Baseline evidence:

- `tmp/performance-2026-09-22/mac-board-baseline.log`
- `apps/mac/.build/smoke/board-20260922-163843-ebb70739-4688-4220-a1c0-985f4471da43`
- `tmp/performance-2026-09-22/mac-board-baseline.sample.txt`

## Changes and reasons

- **Immediate single clicks.** The previous exclusive double/single recognizer
  deliberately waited for the double-click timeout before opening any card.
  Single-click activation now runs immediately. A bounded, event-driven native
  monitor preserves the original double-click target if the inspector covers it.
  Unrelated input cancels the target; the monitor expires after the system
  double-click interval. Native checks cover both leftmost and rightmost cards,
  the correct editor identity, and dismissal. Keyboard and accessibility actions
  retain their existing implementations; external AX qualification remains a skip.
- **Retained rows during pane resizing.** Opening the inspector changes lane
  widths. The previous width callback called `reloadData()` for every lane.
  Mounted rows now retain their native and SwiftUI identities while a small
  observable width value updates their layout. Offscreen heights remain estimates
  until measured during reuse. A new 1,000-row regression also reproduced a
  six-card viewport jump (row 500 to 494) during resize. Height transactions now
  retain the top row and its pixel offset; that regression passes.
- **Local selection and card updates.** Selection highlighting has its own
  small views. Rich card content no longer observes selection. Board labels and
  settings are passed to lane rows, avoiding a workspace-wide dependency in
  every card. Changed board configuration still updates the rows. Liveness
  checks observe connection/sync state directly instead of incidentally reading
  every cached card through the offline-presentation classification. Presence and
  harness-directory dependencies now live in small badge/help views, and menu
  availability owns its own observation. Periodic presence timestamps and
  online/offline transitions no longer reevaluate each rich card body.
- **Height measurement invalidation.** Repeated native layout no longer implies
  another fitting-size calculation. Measurements are invalidated by content or
  width changes. The first-draw, wrapping, footer, and long-lane tests remain.
- **Independent board canvas.** Board content observations are separate from
  conversation presentation and transcript state.
- **Adaptive metadata.** Machine names can truncate within a narrow card while
  the activity label stays on one line. The baseline screenshot showed vertically
  wrapped activity text.
- **Bounded history copying.** Selected-conversation snapshots and workspace
  hydration select their message window before copying mutable payloads. The
  Store's cache and execution APIs retain complete histories and resume state.
  Callers still receive independent mutable data. Pagination, byte budgets,
  cross-process replay, and ownership checks keep their existing semantics.
- **Bounded tool preview work.** A 160-character preview previously split,
  joined, counted, and converted an entire large result. It now stops after the
  visible prefix and one character of lookahead. A process-local FIFO cache
  retains at most 256 short previews of large immutable results, keyed by SHA-256.
  It retains no raw payloads, adds no timers, and preserves preferred JSON fields,
  payload sizes, and content-based invalidation.

## CPU investigation

The running operator daemon was PID 43786, version 0.4.270. A 30.087-second
**active** sample consumed 12.41 CPU seconds (41.247% of one core). An agent turn
and Mac build were active; this is not an idle measurement, and child-process
CPU is excluded. RSS median was 119.5 MiB and maximum 221 MiB.

A read-only stack sample was symbolicated offline using the installed binary's
Go PC/line table. JSON decoding, whitespace normalization, Unicode conversion,
allocation, and protobuf sizing appeared in the active samples. The native
sampler does not provide complete Go goroutine stacks, so this does not establish
what fraction belongs to any one function. It motivated isolated large-tool
preview and tool-heavy transcript benchmarks, rather than a speculative change
to transcript ownership or copying.

The last 250 daemon log lines included old hydration/orphan warnings from
14:37–14:38 local, before this daemon started at 14:45. They are historical and
must not be described as a current warning storm. The latest 30-minute interval
contained 12 WebRTC fallback warnings and 15 unavailable-quota warnings.

CPU evidence: `tmp/performance-2026-09-22/daemon-active.json`,
`daemon-active.sample.txt`, and `daemon-active.symbolicated.txt`.

## Verification and final measurements

The affected Go race suites passed for app, changeset, CLI, control RTC, daemon,
gateway, Git operations, scheduler, Server, Store, workspace and isolated fixtures.
Native geometry regressions pass for wrapping, merged footers, retained rows during resizing, selection-only
decoration, one-card metadata updates, live board labels, virtualization, and
reaching the final row of 1,000 cards. The viewport regression retains the same
row and pixel offset across width changes.

The complete packaged board run with the final presence isolation passed:

| Measurement | Unchanged baseline | Verified follow-up |
| --- | --- | --- |
| Full lane reloads per opening | 4 | 0 |
| Configured rows per opening | 15 | 0 |
| Project reads per opening | 0 | 0 |
| Height measurements per opening | 72–73 | 40 |
| Observed selection, three samples | 678.3 / 1513.3 / 473.5 ms | 33.9 / 35.7 / 49.2 ms |
| Loaded content, three samples | 1446.7 / 1513.3 / 473.5 ms | 476.2 / 35.7 / 49.2 ms |
| Initial layout/display, three samples | 1341.1 / 1277.7 / 1219.0 ms | 1160.6 / 1121.4 / 1094.2 ms |

Evidence: `tmp/performance-2026-09-22/check-changed-final.log` and
`apps/mac/.build/smoke/board-20260922-180343-ef5cd403-8142-406e-981b-2b5a8ae4adac`.
The open-card screenshot was inspected: borders, wrapped titles, metadata and
conversation layout remain intact. Both double-click targets opened their own
editor and dismissed successfully. The Conversation suite also passed pane
resize/maximize/restore and transcript behaviors; its resized-pane screenshot
was inspected.

Timing varies between runs: earlier intermediate selections were 26–33 ms in
one run and 269–324 ms in another. The latter exposed the rightmost double-click
regression fixed by the native tracker. Another intermediate run failed editor
dismissal because the fixture could not locate Cancel; its later navigation and
idle sample are invalid. None of these values establish consistently low
release/compositor latency. The stable regression result is removal of full lane
reloads and row reconstruction, with project reads remaining at zero. Final native Board-tab
draw samples were **1186.4, 2345.9 and 1659.0 ms**; cold mounting is still slow and
variable, and these samples do not demonstrate an improvement over the baseline
1347.6–1381.3 ms. All Chats drew in 206.3–337.1 ms; the other measured destinations
ranged from 44.8 to 275.3 ms. Raw samples and main-loop gaps remain in the report JSON.

An earlier passing Mac run consumed 0.233 CPU seconds over 10.008 wall seconds
(**2.33% of one core**). It had zero row configuration, layout measurements,
height transactions, overlay updates or reloads, but 40 rich card-body evaluations.
Tracing their dependencies led to the final presence badge/help/menu isolation.
The new regression initially reproduced six body evaluations across three cards
and two presence transitions; it now records zero body evaluations, configured
rows and reloads. All five board geometry/update tests pass. The final native
rerun consumed **0.118 CPU seconds over 10.165 wall seconds (1.16% of one core)**
with **zero card-body evaluations, reloads, row configurations, height measurements,
height transactions and overlay updates** during that interval. Card openings also
evaluated zero rich card bodies. This is a short debug sample, not an energy
qualification or a claim that process CPU is always below that figure.

### Cold board construction diagnostic

The opt-in `boardOpeningStageDiagnostic` passed all nine measured fixtures after
the full suites, without another task build running. A 100-card single lane
mounted six rows and required 135.7–152.8 ms for initial layout plus 16.9–18.2 ms
for bitmap drawing. Four lanes of 25 cards mounted 24 rows and required
437.7–571.6 ms for layout plus 39.5–53.3 ms for drawing. After process warm-up,
fixture/store projection took 4.0–7.4 ms; the first sample included 107.1 ms of
initialization and 301.6 ms of layout. That first sample is retained, not discarded.

This confirms that virtualization limits work to mounted rows and that visible
view construction/layout remains significant. It does not account for all
packaged navigation latency: the fixture omits parts of the running app shell
and live transport. The earlier sampled native stack also contained substantial
SwiftUI sizing and AttributeGraph update work. These observations support
profiling cold mounting and containment next; they do not prove one particular
modifier or framework is responsible. Evidence:
`tmp/performance-2026-09-22/board-stage-final.log` and
`apps/mac/.build/board-profile.png` (visually inspected).

### Isolated daemon measurements

Three repeated runs without task builds:

| Workload | Previous/uncached | New |
| --- | --- | --- |
| 30-message window, 300-message tool-heavy history | 10,182,826 B/op | 680,611–680,750 B/op; 2.64–3.05 ms/op |
| Same window, 30-message history | 1,185,788 B/op | 680,978–681,155 B/op; 2.48–2.67 ms/op |
| 1 MiB tool preview | 6,382,386–6,382,388 B/op; 11.25–11.81 ms/op decoding | 0 B/op; 0 allocations; 0.724–0.756 ms/op cached |
| 1.2 MB whitespace-normalized truncation | 9,208,162–9,208,166 B/op; 11.90–12.39 ms/op | 2,464 B/op; 3.24–3.44 µs/op |

The history-window change removes about **93% of allocations** for the longer
history. Warm copying now depends on the selected window rather than old tool
payloads. Cold replay, cache admission, execution and mutations still process
complete histories. Large-preview cache hits still hash the input; a cold miss
still decodes it. These limits matter for active workloads.

Eight isolated idle subscriptions consumed **0.018199 CPU seconds over 30.0007
wall seconds (0.061% of one core)**. RSS went from 37.42 to 38.12 MiB. This is an
isolated subscription-process measurement, not the active operator daemon or
whole-machine energy. Evidence: `tmp/performance-2026-09-22/bench-final.log` and
`tmp/performance-2026-09-22/idle-final.log`.

### Full affected checks

`just check-changed --dry-run` selected the affected Go race/vet packages, the
complete Mac unit suite, and all eight packaged Mac smoke suites. Go race and
vet pass. Complete Mac unit runs pass (reported suites: 666, 55, 8 and 8 tests,
including explicit opt-in/fixture skips). All eight packaged native suites pass:
Core, Board, Conversation, Machine, Sidebar, Terminal, Island and Workspace.
Every retained phase report was checked; no reported failures remain. The four
native smoke skips are external card accessibility activation, HTML/PDF export
acceptance through the external UI driver, and the fresh renderer fixture's
bounded-history case. Store/Server pagination and history-window regressions run
separately and pass. Skips are not counted as passes.

`tmp/performance-2026-09-22/native-verification.json` indexes each suite and phase
report. The complete command exited successfully; its log is
`tmp/performance-2026-09-22/check-changed-final.log`. Formatting checks report no
Go formatting changes or whitespace errors.

## Qualification limits and next measurements

- The locally installed `/Applications/Dieter.app` reports 0.4.152. Measurements
  in this report use the current source fixture, not that installed application.
- No Android changes or new Android qualification are included in this pass.
  The prior integrated production frame guard remains unresolved: 219 ms p95,
  206 ms on repeat, against a 120 ms limit; the native-button control also failed
  at 130 ms. See `performance-implementation-2026-09-21.md`.
- A durable tool-heavy history benchmark covers 30 and 300 messages while
  requesting the same 30-message window. This exposes costs hidden by the
  earlier small text-only fixture, including copying old payloads.
- Debug drawing callbacks and observed state changes are useful regressions.
  Release compositor/frame and physical energy qualification require separate
  controlled measurements. The operator service is preserved throughout.

## Remaining work, in priority order

1. **Qualify the current release build on the affected machine.** Record the
   actual running bundle/version, cold versus warm state, board size and refresh
   rate. Repeat at least 30 native clicks and tab switches without concurrent
   compilation; measure compositor/frame presentation with Instruments alongside
   signposts. Debug state observations cannot establish release frame pacing.
2. **Reduce cold board mounting.** The retained-row fix addresses opening a
   conversation, but returning to Board still constructs its mounted rich views.
   Use the measured `boardOpeningStageDiagnostic` as the bounded control and
   correlate the app shell with Time Profiler separately, then target
   initial SwiftUI view construction, layout and accessibility work with evidence.
   Preserve variable-height cards, menus, drag/drop, focus, labels and editor
   behavior. Do not trade the measured viewport/correctness fixes for guessed
   fixed heights or keep every offscreen card alive.
3. **Qualify sustained active transcripts.** Replay large real-shaped tool
   histories against disposable daemons, recording CPU, allocations, tail
   latency, queue bounds and durable replay. The changes bound warm client reads;
   cold journal replay, first-time JSON decoding and execution-side copies remain.
   The live daemon's 41% active sample cannot establish the new process-wide CPU
   result because that binary is deliberately preserved.
4. **Resolve the existing Android frame gate.** Compare the parent and integrated
   builds under the same controlled load, including the native-button control,
   then use a dedicated device for frame qualification. Keep the 120 ms threshold
   unchanged. This pass does not convert the previous failure into a pass.

## Delivery and lifecycle

Changes are local and uncommitted on `main`, based on `904b576c`; this follow-up
has not been pushed, installed or deployed. A read-only fetch found `origin/main`
at `069bc814` (16 commits ahead); those unrelated commits were not integrated in
this verification. The earlier performance publishing request was completed in
the previous pass.

The tested debug bundle is `apps/mac/build/Dieter.app`, built with the canonical
`dieter-local` cache; unit tests use `dieter-tests`. The smoke drivers own and
clean up their exact app and fixture processes. Post-suite inventory shows no
DieterMac, isolated-gateway, screens-fixture or emulator process. The operator
daemon remains PID 43786 with its original 14:45:32 start time. The installed
operator application and physical Android device were untouched.

## Repeatable diagnostics

Use the canonical caches and one packaged app process. Never profile by
restarting the operator daemon or by running simultaneous native smoke suites.

```sh
just check-changed --dry-run
just check-changed
just e2e run --platform mac --case mac.board
DIETER_BOARD_PROFILE=1 just mac test boardOpeningStageDiagnostic
DIETER_IDLE_SYNC=30s go test ./internal/server -run '^TestIdleSubscriptionProcessCost$' -count=1 -v
go test ./internal/server -run '^$' -bench 'BenchmarkLarge|BenchmarkToolHeavyConversationSnapshot' -benchmem -count=3
```

`just e2e run --platform mac --case mac.board` records actual pointer selection/content timing, lane
reload and row/body/height counts, project-read counts, viewport/virtualization
checks, and process CPU during a quiet interval. Rendering counters are opt-in
and debug-only. They retain no views, cards, transcripts, or credentials.

Existing macOS Instruments signposts under `com.dbpprt.dieter.mac` cover sync,
conversation projections, attachments, and editor work. Capture stacks against
an exact verified task-owned PID; sampling can significantly perturb latency,
so take timing samples in a separate unprofiled run. `scripts/measure_process.py`
measures CPU/RSS for exact PIDs and excludes children. Whole-machine energy and
release compositor timing are different measurements.
