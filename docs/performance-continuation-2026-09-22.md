# Board return and Android frame investigation — 22 September 2026

Continuation of [the card-opening investigation](performance-followup-2026-09-22.md).
The Mac return fix is implemented and verified: native-click first draw is now
233–271 ms, versus 1.19–2.35 seconds. Android's production frame gate still
fails, with a final clean p95 of 239 ms against 120 ms. All affected checks pass
except that frame assertion, with explicit skips detailed below. Results
distinguish clean timing runs from diagnostics; changes are local, not deployed.

## Android baseline and attribution

All runs use the existing visible `Pixel_9_API_37_1`, explicitly pinned to
`emulator-5554`, normal saved userdata, host Apple M4 GLES, and the non-debuggable
performance variant. No display, animation, resolution, renderer or frame-budget
settings were changed. No competing Mac compilation ran during these samples.
The attached physical phone was not used. The normal debug APK was restored after
each run without uninstalling or clearing data.

| Run | Frames | p50 | p95 | Maximum | Process CPU / wall time |
| --- | ---: | ---: | ---: | ---: | ---: |
| Unchanged Dieter baseline | 303 | 50 ms | 207 ms | 323 ms | 4,381 / 20,696 ms |
| Native-button control | 356 | 27 ms | 188 ms | 334 ms | 2,394 / 18,045 ms |
| Dieter with off-main frame-phase diagnostics | 396 | 33 ms | 131 ms | 281 ms | 4,880 / 18,159 ms |

All three fail the unchanged p95 <120 ms requirement. All stay below the 500 ms
severe-frame limit. The native control replaces the activity content with ordinary buttons while
keeping the same activity, input driver and renderer. Its failure, together with
the system trace, identifies a presentation-path contribution; it does not
qualify Dieter or explain away its additional work. The diagnostic
run is not an improved-build comparison: production app code was unchanged.

Phase p95 in the diagnostic run: input 0.004 ms, animation 4.93 ms, layout
0.064 ms, draw 14.29 ms, render synchronization 0.67 ms, command issue 5.54 ms,
buffer swap 79.76 ms, unknown delay 56.00 ms, GPU 106.00 ms. Phase distributions
are not additive. Some slow frames contain less than 1 ms of UI work while
waiting over 100 ms in graphics. The worst 281 ms frame also contains 53.7 ms of
animation work, so CPU-side outliers still need investigation.

Diagnostics are opt-in, bounded to 4,096 samples, use a dedicated callback
thread, and log after navigation. Drops/truncation are reported. The idle CPU
measurement is now retained even when the subsequent navigation assertion fails.
These additions do not filter frames or change thresholds.

Evidence: `tmp/performance-continuation-2026-09-22/android-baseline*`,
`android-native-control*`, `android-frame-phase*`.

## Mac navigation implementation and verification

Leaving Board switched the root destination and destroyed its native tables.
Retaining only the controller did not preserve the detached SwiftUI graph; the
regression test rejected that approach. The implementation now keeps one board
attached per window after its first visit, hides it from drawing/input/accessibility,
clears the hosted conversation, and defers native row updates until reactivation.

All 12 focused Mac tests pass, including hidden metadata updates with zero rich
card bodies/configurations/measurements, preserving table and unchanged-cell
identity, changed-row refresh on return, row/pixel scroll anchoring, switching
boards while away, and releasing native rows when window content is released.
The standalone packaged debug board suite passed, followed by the board suite
in the complete affected run. The final run gives the like-for-like comparison:

| Measurement | Previous follow-up | Final continuation |
| --- | --- | --- |
| Native Board-tab click to first drawing callback | 1,186.4 / 2,345.9 / 1,659.0 ms | 270.5 / 232.9 / 239.8 ms |
| Separate synchronous Board layout/display | 1,160.6 / 1,121.4 / 1,094.2 ms | 126.1 / 114.6 / 105.5 ms |
| Board selection in that layout test | — | 8.4 / 1.8 / 0.7 ms |
| Tables created / full lane reloads per return | Reconstructed on return | 0 / 0 |
| Row configurations / height measurements / rich-card bodies per return | — | 0 / 0 / 0 |

All four original native lane tables remain attached. The native-click measurement
includes target lookup and mouse delivery; the layout measurement begins after
selection. They are distinct metrics and neither measures compositor presentation.
The earlier standalone continuation independently measured native drawing callbacks
at 263.1 / 260.6 / 268.4 ms and layout/display at 126.3 / 113.0 / 113.5 ms.

Final card selection remained 36.3 / 34.7 / 48.6 ms; cold conversation content
took 381.9 ms, then 34.7 / 48.6 ms warm. Each opening made zero project reads,
created zero tables, reloaded zero lanes and configured zero rows. Inspector
width changes still required 40 height measurements. Two rich-card body
evaluations per opening were observed in this final fixture, versus zero in the
standalone run; complete removal of all body work is not claimed.

Final quiet CPU was 0.121 CPU-seconds over 10.019 wall-seconds (1.20% of one
core), with every board rendering counter zero. The standalone quiet sample was
0.079 / 10.620 seconds (0.74%). These short samples do not establish always-idle
CPU or whole-device energy. Sorting, scrolling, double-click editing, inspector
interactions and all other board checks passed. External AX activation remains
an explicit skip because the in-process bridge does not expose that SwiftUI
action. The board and Screens screenshots were inspected.

Evidence:
- Standalone: `apps/mac/.build/smoke/board-20260922-185303-c1dc6b7f-0c93-4eb2-bcd0-252267ad7e0c/`.
- Final: `apps/mac/.build/smoke/board-20260922-194130-b180885a-0636-4a56-a075-24e0a0b260c4/`.

## Android system trace

The first Perfetto attempt could not write its output path; no system trace was
captured for that run. Its clean timing still recorded p95 193 ms, max 383 ms,
and 2 CPU-ms over 5,090 idle wall-ms. The subsequent capture used the supported
Perfetto trace directory and produced a 25.95 MB trace with no reported trace
errors. It recorded p95 188 ms, max 398 ms, and 3 CPU-ms over 5,072 idle wall-ms.

During the repeated navigation interval, `eglSwapBuffersWithDamageKHR` covered
5,308 ms, including 4,393 ms in `waitForBufferRelease` (192 waits, maximum
207 ms). Main-thread `postAndWait` covered 1,333 ms, maximum 207 ms. These nested
wall-time slices are not additive and are not GPU execution time. FrameTimeline
also records SurfaceFlinger scheduling/deadline failures and buffer stuffing.

There is real app work too: repeated `AndroidOwner:measureAndLayout` calls of
92–117 ms after returning from Terminal to Chats, and 61–96 ms on Boards. One
117 ms layout contained 114 ms of scheduled CPU, with multiple lazy
subcompositions. Inspection found release optimization disabled in Gradle. The R8 experiment
below did not improve the failing tail latency and has been removed. These
CPU-side layout outliers remain real app work; the native-control results do
not establish that all remaining latency is outside Dieter.

Trace and reproducible SQL: `tmp/performance-continuation-2026-09-22/`:
`android-navigation.perfetto-trace`, `navigation.pbtxt`,
`android-trace-queries.sql`, `android-trace-attribution.sql`,
`android-trace-attribution.txt`, `android-layout-outliers.txt`.
The original unoptimized APK is retained there with SHA-256
`72c014b547a49e7955cf03b8b6c82b96fe636cfcfa29ae2d646ef926fffdc727`
and size 69,641,030 bytes.

## Rejected optimization and window-state experiments

The initial aggressive R8 shrinking experiment did not reach timing: optional
SDK dependencies first needed rules, then shared tracing and Kotlin APIs used
by the separately compiled instrumentation runner were removed. An optimization-only
candidate retained APIs and names in both release and performance variants.
It ran successfully, but did not improve the frame gate.

A matched comparison alternated the two saved app APKs against the **same original
test APK**, with no Gradle work during the measured journeys. Both were signed
with the same debug key, non-debuggable, and installed with `-r`, preserving data.
The driver, navigation, warm-up, frame population and assertions were unchanged.

| App / order | Frames | p50 | p95 | Maximum | Process CPU / wall time |
| --- | ---: | ---: | ---: | ---: | ---: |
| R8 optimization only / 1 | 239 | 66 ms | 288 ms | 389 ms | 2,774 / 20,712 ms |
| Original / 2 | 261 | 51 ms | 213 ms | 376 ms | 3,098 / 21,582 ms |
| R8 optimization only / 3 | 271 | 52 ms | 216 ms | 397 ms | 2,948 / 21,256 ms |
| Original / 4 | 288 | 47 ms | 245 ms | 375 ms | 3,300 / 21,418 ms |

CPU declined about 10–11% in this small sample, but there was no consistent
frame-tail benefit. All four failed p95. The R8 changes and experiment-only
functional/sync command extensions were reverted; release configuration is
unchanged. There is no unqualified optimizer or SDK keep-rule policy in this
change. No optimized functional/transport qualification is claimed.

Evidence: `paired-results.json`, `paired-*.log`, `compare-android-apks.py`.
The candidate APK was 67,101,526 bytes, SHA-256
`33aaf10834b0ff1623b400c908c6b0fdb32b1df79aea513cbb3dbfa268a31432`.
The identical test APK was SHA-256
`cfe7f1a86883c2ebed9509da043387d3c414221ebc750c5feee4ce9703ebb025`.

The emulator's host window was visible but inactive during those comparisons.
After they completed, its existing window was brought to the foreground through
System Events. AppKit confirmed `active=true`, `hidden=false`, and the emulator
as frontmost, both before and after these measurements. No window dimensions,
renderer, display or Android settings changed. The original saved app/test APKs
were used; debug was restored afterward.

| Foreground run | Frames | p50 | p95 | Maximum | Process CPU / wall time |
| --- | ---: | ---: | ---: | ---: | ---: |
| Dieter / 1 | 259 | 52 ms | 228 ms | 393 ms | 3,216 / 21,144 ms |
| Native-button control / 2 | 296 | 34 ms | 196 ms | 354 ms | 1,564 / 18,174 ms |
| Dieter / 3 | 286 | 43 ms | 183 ms | 462 ms | 3,374 / 19,875 ms |

All fail p95, with no frame at or above 500 ms. Host window inactivity is not
the sole cause. Quiet process CPU was 5/5,081, 11/5,025 and 7/5,087 ms
(0.10%, 0.22% and 0.14% of one core). This is a five-second passive-window
sample, not physical-device energy or live-sync qualification.

Evidence: `foreground-*.log`, `foreground-android-apks.py`,
`emulator-host-state.swift`. All named Android artifacts are under
`tmp/performance-continuation-2026-09-22/`.

## Acceptance and remaining work

The Mac return change preserves one mounted board per window, not an unbounded
cache of visited boards. Native row release and hidden-update tests cover its
lifecycle cost. Cold first mount and compositor-presented latency are separate
from the verified return measurements.

Android's production frame gate remains **open**. A valid acceptance run must
still satisfy p95 <120 ms and no frame >=500 ms, using the existing real-input
journey. No samples, thresholds, rendering quality, or navigation behavior have
been weakened. The reproducible failures in the native-button control mean that this AVD
is not yet a reliable app-only acceptance environment for this absolute frame
limit; the gate must still remain failing. The trace additionally identifies app layout outliers, so it
would be incorrect to declare the app qualified based on the control failure.

The next useful qualification is the same Dieter/control pair and FrameTimeline
capture on a dedicated physical test device or an independently validated
emulator environment whose control passes. Keep the shipped APK, driver, device
configuration and host-load record fixed, and compare multiple matched runs.
The attached operator phone has not been used.

For app-side follow-up, profile the Terminal-to-Chats primary-pager reconstruction
specifically. Any retention change must preserve current data on return, cancel
hidden conversation work, exclude hidden content from touch/accessibility/focus,
retain scroll positions, and release the retained tree with the activity. An
untested retained-page cache has not been added merely to chase this noisy gate.

## Affected regression checks

`just check-changed --dry-run` selected Go race/vet, full native unit suites,
eight packaged Mac smoke suites, and Android connected tests.

- Affected Go race and vet checks passed.
- Swift package runs succeeded (reported groups: 668, 55, 8 and 8 tests).
  Fourteen explicit opt-in/live-fixture skips are retained in the log, including
  the board-stage diagnostic covered separately in the preceding report. Skips are not counted as passes.
- Android: 353 unit tests, zero failures/errors/skips.
- All eight packaged Mac suites passed: Core, Board, Conversation, Machine,
  Sidebar, Terminal, Island and Workspace. Four explicit smoke skips remain:
  external card AX activation, HTML/PDF export acceptance, and the fresh renderer
  fixture's bounded-history case. Pagination/window tests run separately.
  Every suite/phase report was read; the report index is `native-verification.json`.
  Relevant screenshots were inspected, including retained-board navigation,
  conversation resizing, sidebar restoration, terminal resizing and project
  split diffs. Island's offline fixture capture includes the connection overlay;
  it is not an unobstructed visual qualification of its settings page.
- Android debug connected: 101 cases, **68 passed, 33 explicit skips**, zero
  failures/errors. Skips cover configured-account and opt-in fixture cases and
  the production-only frame test.
- Android production frame test: **failed**, p95 **239 ms**, p50 46 ms, maximum
  342 ms across 288 frames. Navigation CPU was 3,906 / 20,151 ms; quiet CPU was
  4 / 5,074 ms (0.079% of one core). No >=500 ms frame occurred. This was a clean
  run without phase tracing after the Mac suites had exited.

The complete `just check-changed` command exited **1** solely for that unchanged
Android frame assertion. It is not an all-green validation. Clean Android results
are preserved in `final-clean-debug-results/` and `final-clean-performance-results/`
in the evidence directory before the separate diagnostic run.

Check log: `tmp/performance-continuation-2026-09-22/check-changed.log`.
## Final diagnostic verification

After preserving the clean test outputs, the final opt-in callback was exercised
once on the original release configuration. It captured **271 frames, zero
dropped and zero truncated samples**. Navigation p50/p95/max were 39/210/358 ms;
the unchanged assertion still failed. CPU was 3,694 / 20,124 ms during navigation
and 5 / 5,003 ms while quiet. Phase p95 included swap 141.48 ms, unknown delay
103.29 ms, draw 13.69 ms and layout 0.062 ms; as above these are non-additive
wall-time distributions, not GPU execution attribution.

The diagnostic completed and removed its listener/worker; the performance recipe
restored the normal debuggable APK successfully. Its process exited 1 because of
the frame assertion, not a diagnostic/runner crash. This run verifies the new
reporting branch; it does not replace the clean p95 239 ms acceptance result.
Evidence: `final-frame-diagnostics.log`, `final-frame-diagnostics-metrics.log`,
`final-diagnostic-results/` under the evidence directory.

## Delivery and lifecycle

Changes remain local, uncommitted and unpublished on `main`, based on
`904b576c`. The packaged debug Mac app used the canonical `dieter-local` cache;
unit tests used `dieter-tests`. The installed `/Applications/Dieter.app` was not
replaced. No release deployment or physical-device qualification is claimed.
Go formatting and Git whitespace checks are clean.

The operator daemon remains PID 43786, started at 14:45:32 local time. The Mac
smoke drivers reaped their app/fixture processes; post-suite Mac inventory shows
zero DieterMac processes. All Android installs/tests used `emulator-5554` and
preserved application data. The physical phone was untouched. The owned
`Pixel_9_API_37_1` saved its snapshot and closed cleanly through the normal
recipe (exit 0). Final inventory confirms no emulator/QEMU or DieterMac
process; the attached phone remains present and was not targeted. Cleanup
evidence is `emulator-stop.log`.

The card remains **Running** because Android's performance gate is still failing.
The exact remaining acceptance work is the matched device/control qualification
and targeted primary-pager layout investigation described above. No separate
follow-up card has been created.
