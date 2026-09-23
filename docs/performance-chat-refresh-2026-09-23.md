# Long conversations and refresh latency, 23 September 2026

The requested initial local changes were committed and pushed as `233eeb25`.
This follow-up investigates the remaining Mac rendering and Mac/Android refresh
latency. Conversation and UI tests use disposable fixtures; the operator daemon was not restarted
or replaced. Production deployment is separate from source verification.

## Reproduction and causes

The current task transcript contains individual assistant messages with
471–683 parts. The previous performance fixture covered 300-message conversations,
but each message had only a few parts. Both clients bounded the message window
while mounting every section inside each visible assistant message.

A new fixture retains the 300-message history and gives the final assistant turn
680 alternating prose/tool parts. Before the fix, the first native Mac row click reached positioned timeline
readiness at 10,654 ms. The second still was not positioned when the deadline
check returned at 10,594 ms. Quiet selected-chat CPU was 7.58% of one core. The ordinary
small-message baseline passed: 30 opens had median 735 ms and maximum 936 ms;
five restored-chat returns had median 763 ms and maximum 902 ms.

Other independent refresh problems were found:

- Android canceled and resubscribed to a slow first snapshot every 4.5 seconds.
  The unary recovery read had only 3.5 seconds. Large or delayed responses could
  repeatedly lose their progress.
- A Mac recovery read could fail after the watch delivered fresh content and
  start another recovery cycle or show an obsolete error.
- Resuming a watch at the current transcript sequence produced no initial frame.
  Idle connections could not acknowledge freshness; comments can also change
  independently of the transcript sequence.
- Native route selection awaited the WebRTC negotiation stages before trying
  authenticated relay. A stalled preferred route could delay usable relay by
  tens of seconds.

Live bounded CLI reads of the roughly 2 MB conversation window were 496–583 ms
locally and 820–855 ms through authenticated targeting of this machine. These
measurements do not reproduce the full native rendering/refresh journey.
Daemon diagnostics separately showed gateway TCP refusals and 15-second peer
health failures. Source fixes cannot establish that a remote gateway outage has
been repaired.

## Measured Mac result

The same 680-part fixture now passes all six alternating native opens. Each
open has both fresh data and a positioned timeline, with no directory requests
or list/table reconstruction during selection.

| Metric | Before | After |
| --- | --- | --- |
| Long-turn open | First positioned at 10,654 ms; next missed deadline | Median 569 ms; range 478–876 ms, 6/6 fresh and positioned |
| Return to selected long chat | Not used for comparison | Median 620 ms; maximum 703 ms, 5/5 passed |
| Quiet selected-chat CPU | 7.58% of one core | 1.92% of one core |
| Quiet board CPU | — | 1.71% of one core; zero row/layout updates |

The packaged debug build's complete board sweep passed, with one explicitly
skipped external Accessibility action check. The final screenshot was inspected:
the latest prose and “Show earlier in this message” control are visible.
Measurements ran without competing task-owned builds or tests.

Evidence directories:

- Before: `apps/mac/.build/smoke/board-20260923-002347-8ff57bbf-b4db-44ce-a585-ddbd3e3f42a2`
- Final: `apps/mac/.build/smoke/board-20260923-080114-9542ff57-4624-4ed1-a6c8-15a09b3076a5`
- Earlier successful repeat: `apps/mac/.build/smoke/board-20260923-012117-916fd820-5326-4c47-b72f-286f19a04501` (median 525 ms; range 463–855 ms; quiet chat 1.80%)
- Android captures: `tmp/chat-refresh-20260923/android-long`

## Changes

Both clients initially mount the last 12 grouped sections of a long assistant
message. “Show earlier in this message” reveals another 12; copying/exporting
still uses the complete message. The mounted boundary stays stable as streamed
parts arrive, and resets to a valid visible section if a refreshed message becomes
shorter. Mac markdown preparation also limits its initial work to the
sections that can be shown immediately.

Android retains one watch and makes at most one concurrent bounded recovery
read for a cold open. Fresh watch data cancels that read. A read timeout reports
an actionable refresh error without tearing down the still-useful watch. Mac
also cancels the redundant read and ignores an obsolete failure after freshness
has already been established.

An up-to-date resumed watch now emits a metadata acknowledgment without
resending unchanged messages. It includes current comments and counts toward
CLI `--count`. The existing RPC and wire fields remain unchanged.

Verified direct TLS remains preferred. When it is unavailable, native WebRTC
gets a one-second head start.
If it is still connecting, authenticated relay health is checked concurrently.
The first healthy transport wins; the other attempt is canceled and closed.
Only connection setup races. Application requests are never replayed.

## Verification

Completed checks:

- Swift: 676 Mac, 59 Core, 8 iOS model, and 13 client Swift Testing cases
  passed, plus all 5 XCTest cases.
- Android: all 368 unit tests passed after the final UI change. Concurrency
  regressions use explicit
  handshakes rather than timing assumptions under host load.
- Shared iOS simulator build passed for both architectures. All 15 smoke-runner
  unit tests passed. iPhone/iPad UI smoke execution is unavailable: `xcrun simctl
  list runtimes` reports no installed runtime.
- Native WebRTC fixture: authenticated health, state/watch, navigation KV,
  and reconnect passed; healthy WebRTC still wins the connection race.
- Native Android 680-part rendering: latest content and earlier-section reveal
  passed using native input. Both final captures were inspected. The regression
  also verifies that an
  expanded tool disclosure remains expanded after earlier sections are prepended,
  and a shorter replacement remains visible.
- CLI resumed-watch acknowledgment passed on local, verified direct TLS,
  and authenticated relay routes. Affected Go vet passed.

The broad Go run exposed two existing Connect tests invoking installed provider
model discovery. They now use an isolated mock catalog and temporary storage;
live provider discovery retains its own opt-in integration test. The complete
server race suite and server vet both passed in a clean run. Gradle's Android
device launcher initially failed to
reach Maven for launcher dependencies; the already-built fixture APKs passed
through Android's native instrumentation runner instead. The final full debug
connected run used Gradle successfully after launcher access recovered.

The six-case native Android sync matrix passed across the initial five successful
cases and a clean repeat of the warm-cache case. The initial warm-cache timing
failed during concurrent cold iOS compilation (p95 323 ms, limit 250 ms). With no
competing build, 50 warm selections measured p95 7 ms and maximum 13 ms. These
are model-selection timings, not composed-frame readiness. Two quiet 30-second
windows used 153 CPU-ms / 30,113 ms and 121 CPU-ms / 30,026 ms: 0.51% and 0.40%
of one core. Evidence: `tmp/performance-sync/android-native-bd1x6zea`.

All eight packaged Mac functional suites passed on the final code (core, board,
conversation, machine, sidebar, terminal, island, workspace). Reports and relevant
screenshots were reviewed. Explicit skips: system screen-shortcut Accessibility
permission, external board AX action, native HTML/PDF export acceptance, and the
fresh-state fixture's bounded-history check. The compact activity-window PNGs
captured only an effect layer; its functional assertions passed, but those PNGs
are not visual qualification.

Final smoke evidence is under `apps/mac/.build/smoke`, from
`core-20260923-074508-b7e48e04-064a-4d50-bad3-a52d17941ecf` through
`workspace-20260923-075756-a5e61676-9756-4399-b397-4c64d7ae09a5`.
The final long-message timing repeat passed. Android debug device instrumentation
passed: 105 cases, 69 passed and 36 explicit skips. The XML is authoritative;
Gradle's console progress double-counted skipped callbacks. Skips require a
configured account, a dedicated fixture, or the production performance build.
The long-message, live-sync, and native WebRTC fixture cases passed separately.
The release-style navigation gate still fails: p95 173 ms versus the unchanged
120 ms limit, maximum 335 ms (no frame reached the 500 ms severe-frame limit).
Quiet process CPU was 5 ms / 5,107 ms, or 0.10% of one core. A matched run using
ordinary native Android buttons also failed at p95 170 ms, maximum 268 ms.
That control used 2,369 CPU-ms during navigation versus Dieter's 6,999 CPU-ms;
similar total-frame tails do not imply equal application CPU cost. This reproduces
the previously documented emulator/display qualification limitation. It is not
proof of smooth 60/120 Hz navigation, and the frame threshold was not changed.
The normal debug application and instrumentation APK were restored afterward.
Evidence: `tmp/chat-refresh-20260923/final-checks/android-connected.log`,
`android-performance-metrics.log`, `android-native-control.log`, and
`android-native-control-metrics.log`.

The requested long-chat and refresh regressions are fixed and pass. The broader
Android navigation frame gate remains open; the card stays Running with that
limitation, rather than claiming an entirely green performance qualification.
The required next verification is a controlled renderer/device baseline and
unchanged-budget application run. No separate follow-up card was created.

Timing definitions: the smoke's `presentation_ms` is observed prepared/positioned
timeline readiness, not compositor presentation. `fresh_and_positioned_ms` is a
combined completion upper bound, not an independent server response latency.
Timing runs are separate from compilation and other test suites.

## Delivery and lifecycle

The repository debug Mac app used the canonical SwiftPM caches. Test-owned Mac
apps and disposable gateway fixtures were reaped by their drivers. The owned
`Pixel_9_API_37_1` / `emulator-5554` was saved and closed successfully.
No task-owned Mac app or Android emulator remains.
The physical phone was untouched. Operator daemon PID 43786, v0.4.270, remains
unchanged; source changes do not update an installed app or running daemon.
Mac/Android clients and the daemon need a release containing these changes to
receive all improvements in normal use.
