# Refactor implementation and qualification

All eight accepted refactors are implemented in this checkout. The affected
checks and required device journeys passed, including the final native host
regressions.

## Device results

All 65 platform-specific cases below have passing results across the recorded
runs. Failed cases were corrected and rerun; the evidence section names each run.

| Platform | Passing cases | Coverage |
| --- | ---: | --- |
| macOS | 10/10 | Packaged native smoke journeys |
| iPhone | 6/6 | Simulator smoke journeys, including share extension |
| iPad | 5/5 | Simulator smoke journeys in tablet layouts |
| Android | 41/41 | Selected functional journeys and component cases |
| Android screens | 3/3 | Codec, interaction, H.264/HEVC loss recovery |

## Ownership changes

- Android terminal input now admits at most 256 KiB across pending and in-flight
  writes and eight retained writers. Admission is atomic, input is copied into
  bounded chunks, canceled in-flight bytes remain charged until completion, and
  ambiguous writes are never replayed. Captured authenticated clients cannot
  retarget writes after machine selection changes.
- Android terminal, schedule and administration controllers own feature snapshots,
  read/mutation lifetimes and binding checks. Shared request ownership checks both
  token identity and current binding before publishing or reporting errors.
  DieterViewModel composes the snapshots and retires owners on selection changes.
- Mac fleet telemetry, terminal overview and shared Apple provider quotas have
  separate state and request owners. ConnectionEffects owns transport and sync
  task lifecycle and independent directory, presence and liveness loops.
  Terminal consumers access TerminalsModel; ten writable compatibility accessors
  were removed. Board and Chats components now live in focused files with their
  existing state and accessibility behavior.
  Retired fleet and terminal-creation requests cannot publish obsolete failures
  or start a mutation after a delayed route acquisition. Fleet telemetry refresh
  does not invalidate the current machine operation.
- iOS uses the shared quota owner, retaining its foreground gateway lifetime.
  Pausing and changing accounts retire pending quota reads and mutations.
- CaptureEncoderSession owns compression and pixel-conversion resources and their
  invalidation on the existing state queue. CaptureSessionOwner owns native stream
  identity and shared-display membership. Frame credits, bounded mailboxes and
  callback generation checks remain in CaptureRunner.
- Go turn admission, recovery, execution, conversation construction and prompt
  preparation are separated within package app. Storage files group projects,
  boards, cards, labels, placement and materialized state. Lock and transaction
  boundaries are unchanged. Settings projection and watch interval policy moved
  out of the Connect adapter.

## Build and test changes

Mac packaging now uses one source/destination manifest, content inventories,
path-safe traversal, complete staging and atomic bundle exchange. It verifies
before activation, rechecks process ownership, removes obsolete resources, and
avoids copying/signing an unchanged build. Version, signing identity and packaging
implementation participate in freshness.

The synthetic native capture source uses a strict display-cadence timer. The
ordinary background timer was being coalesced to single-digit frame rates on
this host, affecting both the original and refactored helper. The original
HEVC, high-refresh, backpressure and reference-recovery assertions all pass with
the strict timer; the diagnostic run measured 58.1 fps at 1080p60 and 118.0 fps
at 1080p120. Production display callbacks are unchanged.

The Metal UI-stall probe also uses an independent strict-cadence producer and
waits for startup readiness. It verifies that both producer and actual hardware
presentations advance while the UI is blocked for the original 250 ms interval;
the presentation threshold is unchanged. This separates producer scheduling
from the renderer behavior being asserted.

One schema-copy transform serves both generation entry points. Swift generation
freshness includes its invocation script and copy implementation. Shared clocks
use a saturating conversion and retain injectable timers and cancellation.

The E2E runner gives each build command a separate process group and waits for
canceled descendants before returning to lease owners. Native smoke startup waits
for an app-side PID readiness file, then activates the owned app through Launch
Services before starting UI interactions.

Compatible isolated daemons now advertise the same canonical build release.
Machine power-control smoke checks require the exact daemon ID emitted by the
owned fixture and its loopback gateway origin; release labels no longer serve
as fixture identity. A focused regression rejects missing or mismatched identity,
gateway ports and remote origins.

Qualification also exposed and corrected managed Bun path validation under a
symlinked installation parent (including macOS `/var`). Both installation and
executable are resolved before the containment check; an executable outside the
installation is still rejected. The brand wiring test now follows the Python
packaging manifest.

## Qualification evidence

- Android unit suite passed: 386 tests across 92 suites, including the final
  centralized selection hook and superseded-resize regression.
- 36 changed-check selection tests passed.
- 20 Mac lifecycle/packaging tests and the schema-copy regression passed.
- All affected Go race tests and `go vet` passed after the mechanical separation
  and managed Bun fix.
- Brand packaging and managed Bun race tests passed after these qualification fixes.
- The official handwritten Swift formatting check passed.
- E2E runner tests passed, including nested child cancellation. The final fixture
  catalog regression and three sync tests pass under the race detector after
  rerunning without simulator activity; their earlier failures were request
  deadlines during concurrent native load. Final server/fixture/runner vet passes.
- Swift generation refreshed successfully with the new manifest contract.
- Swift compiled all four targets and the suite passed: 812 tests with 14 explicit
  fixture/live-route skips. Both late-added Fleet regressions passed in their
  targeted run; the terminal overview races were included in the full suite.
- Native capture compiled and signed; physical-key state, independent Shift
  sides, drag bounds, release and display-generation checks passed. The isolated
  timer diagnostic passed all four previously failing hardware/transport tests.
  The complete `just mac screens-native-test` rerun also passed, including
  the Go race suite against the signed native helper. The final rerun after
  the signaling/recovery fixes also passed (74.507 seconds for the Go suite).
- `just mac screens-test` passed: 30 Mac tests and seven iOS policy tests,
  including the authenticated native viewer, HEVC transport, detached windows,
  clipboard and pixel alignment. Three declared opt-in companion/recovery cases
  were skipped. The saved redocking and pixel-alignment images were inspected;
  copies are retained in `tmp/refactor-tools/native-viewer-evidence`.
  The final rerun after the host fixes and deterministic UI-stall producer passed
  all 30 Mac tests and seven iOS policy tests, retaining the same three declared
  opt-in skips. Final redocking/pixel-alignment captures were inspected and saved
  under `tmp/refactor-tools/final-native-viewer-evidence`.
  The first packaged Mac run passed eight of ten cases (`tmp/e2e-3413606641`).
  Machine and terminal exposed the obsolete fixture identity/version assumptions
  above; both pass after correction (`tmp/e2e-2144994391`), giving passing
  results for all ten smoke cases across the two runs. Terminal checks include
  route ownership, machine-home creation, copy/paste, resize and restoration
  after client and daemon restart. The machine and restored-terminal screenshots
  were inspected. Fixture and runner Go race tests and the Mac identity regression
  also pass. Existing optional Mac accessibility/export limitations remain as
  declared in the first run's reports.
- iOS 27.0 arm64 Simulator runtime installation and `just ios build` passed.
  All six iPhone smoke cases have passing results across `tmp/e2e-2888555384`
  and the final remote-node rerun `tmp/e2e-564110545`. Coverage includes first
  sign-in, message/follow-up delivery, Markdown, offline recovery, file edit and
  readback, relaunch persistence, draft start, foreground reconnect, provider
  quota presentation, machine telemetry, screen rotation, terminal input,
  Keychain and Photos sharing. Final draft/reconnect/quota images were inspected.
  All five iPad cases also pass across `tmp/e2e-1867873097` and the final
  remote-node rerun `tmp/e2e-3837158014`. The first-sign-in test now honors
  the plan's landscape orientation so it checks the visible sidebar. Both
  first-sign-in and the full tablet task journey pass in that final run.
  Full simulator captures are retained alongside XCTest attachments because
  Xcode crops some rotated app screenshots.
- iPhone qualification exposed an empty provider catalog in disposable fixtures:
  live OMP/DSH discovery could exceed the client's request deadline. Fixtures now
  inject the checked-in catalog through an optional server seam shared by
  GetHarnesses and GetSettingsOptions; production discovery is unchanged.
  The creation helper targets its actual form, and model settings retains its
  toolbar slot while loading so Start cannot move into a different control's
  position. The journey waits for draft navigation/catalog readiness.
  Xcode's optional whole-simulator diagnostic archive is disabled because it
  consumed failed-case deadlines; structured results, console and attachments
  remain retained.
- All 41 selected Android functional cases have passing results across
  `tmp/e2e-991191120`, `tmp/e2e-3998690125` and the final terminal test
  `tmp/e2e-3384988827`. The new terminal journey sends one 82 KiB IME event
  through the actual Activity, view model, input controller, authenticated
  gateway and PTY. A raw-mode fixture receiver verifies exact length and SHA-256
  across the 64 KiB chunk boundary; ordinary shell input then verifies DEL
  editing and persisted terminal state. This avoids an interactive shell's
  canonical input queue dropping a large multiline command paste. The backend
  diagnostic reproduced that shell limitation independently of Android.
- Widget qualification now checks monochrome against the device's actual light
  or dark appearance. Its simulated other-device mutation uses an independent
  fixture client, since APP_ONLY deliberately closes the app's own channel.
  The full widget journey passes, including live updates, read receipts,
  background refresh and return to the app. Final widget images were inspected.
- Android screen codec qualification passed in `tmp/e2e-584415625`.
  The interaction and recovery cases exposed two host-side gaps. Signaling
  resubscription replayed obsolete session snapshots; it now replays negotiation
  and sends one current snapshot. Phase transitions retain complete metadata.
  Reference recovery now includes fresh decoder and jitter-buffer timing in its
  acknowledgment budget, independently of packet retransmission retention and
  still capped at 250 ms. The full remote-desktop Go race suite passes with
  regressions for snapshot replay, timing expiry and bounded acknowledgment;
  final `go vet ./internal/remotedesktop` also passed.
  The full interaction journey passes in `tmp/e2e-3844363318`, including
  clipboard, gestures, keyboard, credential renewal and reconnects.
  Recovery passes for H.264 and HEVC in `tmp/e2e-1212327209`. This case now
  requests 1080p15 to stay within the emulator decoder's sustained throughput,
  waits for a stable decoded baseline, and isolates FEC recovery from earlier
  random-loss dependencies with a fresh decoded anchor. It proves the exact
  protected RTP frame reached the hardware decoder while the original packet
  and retransmissions were dropped, then requires 16 continuous decoded frames.
  Performing that continuity check afterward respects FEC's intentional
  two-second clean-network expiry. All original recovery/continuity assertions
  remain, and the checked-in evidence validator accepts both codec records.
  Viewer, gesture and recovery screenshots were inspected. These are functional
  recovery checks, not 60 fps or input-to-photon latency qualification.
- The cancellation regression publishes child readiness only after recording
  its sleeper PID. This removes a test-fixture race exposed under native load;
  ten consecutive race runs and the full E2E runner race suite pass.
- The task-owned visible Pixel_9_API_37_1 emulator (`emulator-5554`) saved its
  validated snapshot and stopped cleanly through `just android emulator-stop`
  after final Android qualification. The attached physical phone was never
  selected. iOS runners cleaned their owned simulators and fixtures. The operator
  daemon was not restarted, replaced or installed over.

## Scope and retained limits

Device journeys use disposable authenticated fixtures. Screen transport coverage
uses native synthetic capture and hardware codecs; real desktop capture/input,
physical-device power measurements, and optional companion/performance matrices
are separate opt-in qualification. The declared unit/integration skips above
are retained and are not counted as passing required device cases.

Final lifecycle checks confirm no DieterMac process, booted iOS simulator,
Android emulator, or final owned native fixture process remains. The attached
physical Android device and operator daemon were preserved. Final formatting
and whitespace checks passed.
