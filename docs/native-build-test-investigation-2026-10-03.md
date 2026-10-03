# Native build and test investigation — 3 October 2026

The screenshot showed a real iPhone smoke run, not an idle agent. The agent was
polling a buffered log every 30 seconds. The runner kept its child output in
memory until each command ended, so there was no visible activity during simulator
setup or XCTest execution.

## Measured baseline

The live run finished without intervention: **7/7 passed in 25m 39s**. Its report
is `tmp/e2e-2324246869/results.json`. Build preparation took 69.9 seconds.

| iPhone case | Setup | XCTest execution | Total, including evidence and cleanup |
| --- | ---: | ---: | ---: |
| adapters | 71.2s | 48.8s | 124.5s |
| connecting | 89.2s | 43.7s | 137.9s |
| credentials | 87.8s | 33.4s | 125.7s |
| remote node | 82.1s | 265.1s | 352.8s |
| screen | 143.3s | 64.2s | 212.6s |
| share extension | 86.6s | 86.3s | 178.0s |
| terminal | 88.0s | 244.4s | 337.3s |

Setup includes fixture preparation, not just boot. The boot log proves that every
fresh simulator repeats first-use data migration. Setup consumed 648 seconds
across seven cases; the remaining time is real XCTest work, result export and
cleanup. Reusing a simulator cannot eliminate the entire 25-minute run.

The screenshot's earlier process exhaustion and stale lease are consistent with
orphaned disposable simulators and overlapping runs. This investigation observed
one active iOS runner and preserved it. It did not delete unrecorded simulators,
stop the operator daemon, or change another conversation.

## Implemented changes

- iOS boots one disposable, run-owned simulator per suite. Each case keeps a
  fresh authenticated fixture and removes the owned test app containers before
  XCTest reinstalls them. UI launch configuration already uses unique state and
  defaults plus an in-memory credential store. Native Keychain tests use unique
  accounts/services with teardown. No existing operator simulator is selected.
- A host simulator lease prevents simultaneous managed simulator suites. The
  checkout writes the exact simulator UUID/name to an ownership journal. A later
  leased run can clean that recorded simulator after a killed runner; identity
  changes and failed deletion preserve the journal and fail admission. Normal
  cleanup shuts down and deletes only the run's simulator. Boot is limited to
  three minutes, and XCTest destination discovery to 30 seconds.
- Mac builds, unit/core tests, iOS builds and Apple E2E share a canonical
  cross-process build lease. A test run holds it while consuming its products,
  so another direct build cannot replace the framework or XCTest plan mid-case.
- Builds and cases print elapsed-time/deadline progress every 30 seconds. iOS
  prints the selected simulator and XCTest method count. Lease conflicts include
  the recorded owner PID rather than inviting blind retries or lock deletion.
- Android verifies the AVD name for the exact selected emulator serial. Physical
  Android devices use an explicit ADB serial and isolated E2E packages. The
  launcher passes the selected console port; emulator start/stop share the same
  serial lease as tests and Gradle installation.
- `--serial` is rejected on iOS/Mac instead of being silently ignored. Physical
  iOS E2E is currently unavailable; `just ios build-device` only compiles an
  unsigned device build.
- The shared framework cache hashes production sources, authoritative schemas,
  and Java/Xcode toolchain identity. Tests and documentation no longer replace
  the binary target. Source refreshes preserve the existing configuration's
  slice superset, and local simulator builds no longer request the device slice
  on a fresh cache. A publication lease protects concurrent framework writers.
- Identical framework bytes and symlink targets preserve existing timestamps.
  Slice unions use a canonical order, and equivalent XCFramework plist ordering
  does not replace a publication.
  The comparison does not follow versioned-framework symlink loops, discovered
  during native verification. This avoids invalidating Swift compilation merely
  because the input manifest or packaging command refreshed.
- Android APK fingerprints exclude JVM-only tests, documentation and the
  Apple-only façade, while including instrumentation sources, shared production
  code, schemas, Java/toolchain options and release-version inputs. APK hashes
  still validate reuse.
- Native readiness fixes preserve assertions: Mac workspace file clicks wait for
  attached geometry, and horizontal scrolling excludes retained hidden views.
  Android folder/pin tests wait for asynchronous shared-core persistence instead
  of assuming Compose idleness means the edit has completed. Tablet fixtures
  supply the canonical shared-core activity projection. Creation-preference
  assertions respect remembered provider options, and the fixture helper waits
  for server-backed card identity before returning a card for daemon RPCs.
  Pin fixtures project navigation over their supplied projects; tablet capture
  fixtures now own and close a real isolated capture adapter. The queued-turn
  fixture waits for the owner daemon’s authoritative conversation status before
  submitting the queued draft. Changes journeys exercise the real Back control
  when the first diff is already selected. The preferences test waits for the
  tagged quick-task editor after each sheet opening and addresses its unmerged
  semantics directly, including when presentation merges it into a parent. The
  shared review controller now clears the diff without another RPC, ignores stale in-flight responses and
  preserves the file list across refreshes until the user selects a file again.
- Changed-check selection maps platform-specific runner/case edits to their
  native platform. Go test-only edits run host checks without device suites.
  Shared runner changes still validate every platform. Shared-core changes no
  longer schedule Swift bridge tests twice: `core apple-test` already invokes
  `mac core-test`.

## Verification

Regression coverage exercises simulator reuse with fresh containers, every
existing iOS cancellation/failure cleanup path, recovery of an exact recorded
simulator, refusal of a renamed simulator, Android AVD mismatch and physical
serial targeting, APK input invalidation, framework warm reuse, source/schema/
toolchain invalidation, slice preservation, concurrent publication and identical
framework timestamps including cyclic symlinks.

Completed checks:

- Go runner race tests and Apple recipe/runner lock interoperability passed.
- Changed-check selector: 40 tests passed; cache publication/equality: 6 tests
  passed; app/build lifecycle fixtures: 24 tests and schema-copy fixtures: 2
  tests passed. Release regressions and Just formatting passed.
- Mac unit checks passed: 444 app tests, 16 shared/transport tests and 13 iOS
  policy tests, plus the existing XCTest tests. The app tests took 304 seconds;
  two native transcript-scroll regressions took 58 and 101 seconds. Compiler
  work took 218 seconds on the first refresh, versus 15 seconds for the later
  core-test build using the same canonical test cache.
- Both isolated Swift-to-core integration tests initially passed (18 and 13
  seconds). After the review fix, `just core apple-test` passed completely;
  Swift compilation took 378.4 seconds, and the two live integration tests passed
  again in 11.6 and 12.1 seconds. The entire native/core/Swift invocation took
  26m 47s. This records a source-change run with substantial preparation.
- After the shared review fix, all 671 core JVM tests passed (103 suites),
  including the daemon-backed Back → refresh → reselect regression. The 611
  shared-core native macOS tests and the Apple façade test also passed. The
  JVM run took 6m 29s, with 9/24 Gradle tasks executed and 15 up-to-date.
- Android JVM tests initially passed in a 30-second Gradle invocation (41/55
  tasks already up-to-date). After the production core fix, all 28 app unit tests
  passed again; the required recompilation took 2m 20s (47/55 tasks up-to-date).
- The selected Android emulator booted from its preserved snapshot in 36
  seconds. Identity: `Pixel_9_API_37_1`, `emulator-5554`; data volume:
  `/Volumes/External/Android/avd/Pixel_9_API_37_1.avd`. Its host renderer was the
  Apple M4 translator. The launcher hierarchy and full PNG were inspected.
  The attached Samsung `RFCX10TZGNV` remained untouched.

The new iPhone run is `tmp/e2e-3388306492`: **7/7 passed in 15m 29s**, including
final simulator cleanup. This is about 10 minutes faster than the observed
baseline. All cases used `DD02E191-AC9B-4B7C-93E1-EAB2CB048317`; afterward its
UUID was absent from the simulator inventory. The iPad run also completed and its owned simulator was deleted; neither
run left an ownership journal.

| iPhone case | New setup | New total | Baseline total |
| --- | ---: | ---: | ---: |
| adapters, including one cold boot | 94.2s | 127.8s | 124.5s |
| connecting | 2.8s | 23.9s | 137.9s |
| credentials | 4.1s | 18.8s | 125.7s |
| remote node | 4.5s | 240.9s | 352.8s |
| screen, including native fixture prep | 77.3s | 98.8s | 212.6s |
| share extension | 5.8s | 63.4s | 178.0s |
| terminal | 5.0s | 225.8s | 337.3s |

Build/fixture preparation took 124 seconds for the new iPhone run and 100
seconds for the following iPad run. These are observed runs on this host, not
controlled benchmarks: source HEAD, build-tooling edits and concurrent host load
changed during the investigation. The clear reduction is repeated simulator
setup; compilation and actual UI journey costs remain separately visible.

The iPad run is `tmp/e2e-2882613578`: **6/6 passed in 13m 57s**, including
cleanup. Warm setup took 3.0–4.8 seconds except the screen fixture (69.8 seconds).
Its owned UUID `5E7ADF3B-1002-4482-92CC-829E097A5D20` is absent from the final
inventory. Connecting screenshots were compared with a pre-change iPad run;
both contain the same rotated/cropped capture presentation with a black margin.
The banner assertion passed, but this evidence does not establish clean iPad
screenshot capture or full visual qualification.

The affected-check command is `just check-changed`. Its first Mac smoke run
(`tmp/e2e-1408463589`) completed 9/10 cases in 13m 33s; workspace failed to click
a row whose recorded anchor had no window. An unmodified focused retry passed
(`tmp/e2e-3307485741`). With the row-readiness fix, file selection passed, but
horizontal scrolling failed (`tmp/e2e-1827272657`); the helper could select retained
hidden scroll views and now excludes them. Final focused verification (`tmp/e2e-2227256831`) passed every workspace
assertion, with fresh cleanup and no remaining Mac app process. The nine other
Mac cases passed in the original suite; the complete pipeline itself remains
recorded as failed, rather than rewriting its history. After the shared-core
review fix and rebuilt framework, `tmp/e2e-2817320368` passed every Mac workspace
assertion again (69.9 seconds; preparation 173.6 seconds; total 4m 4s).

The unchanged Mac retry reported 75.7 seconds of preparation and 12.1 seconds of
Swift build work, with unchanged bundle inputs/outputs. Read-only probes measured
framework input inventory/reads at 0.11/0.15 seconds, bundle input/output hashing
at 0.71/0.67 seconds, schema validation at 0.75 seconds, toolchain identity at
0.34 seconds, and signature verification at 1.29 seconds. Later bounded probes
measured signing identity lookup at 0.05 seconds, the stopped-app guard at
0.29 seconds and release identity at 0.39 seconds. The remaining warm
preparation overhead is unresolved; these measurements do not support blaming
file hashing or throwing away caches.

The Android baseline qualification (`tmp/e2e-2978594473`) finished **37/44
passed in 22m 1s**, with 40.4 seconds of build preparation and 7.3 seconds of
installation. Seven existing native test cases failed. Inspection found stale
activity/visual fixtures, missing waits for core persistence, an optimistic ID
passed to a daemon RPC, and an option toggled despite already being remembered.
The Changes screenshot showed a correctly rendered automatically selected patch
while the test waited a full minute for a file list. Exercising Back then exposed
a shared-core bug: clearing selection requested a whole-workspace diff, and
refresh selected the first file again. The controller fix preserves explicit
list mode and invalidates earlier diff requests. The queued-turn directory wait
also timed out although fixture logs proved the daemon was running the held
turn. The corrected setup polls the owner’s GetConversation status, then retains
the actual queue response and visible recall assertions.
The first focused run (`tmp/e2e-767278352`) passed the corrected preferences,
capture and visual cases. Its remaining failures identified missing fixture
project/capture dependencies, plus the known queue and Changes setup expectations.
The next focused run (`tmp/e2e-1199721973`) passed the complete navigation-folder
and tablet-workspace classes (7 and 12 methods). Queue verification
(`tmp/e2e-447961917`) passed in 38.8 seconds with 13.5 seconds of warm build
preparation. The combined final rerun (`tmp/e2e-1557599121`) also exposed a
preferences readiness race after Save: a reopened quick-task sheet was visible, but the
merged semantics had not exposed its editor. The finder now targets the tagged
editor in the unmerged tree and checks display after a bounded readiness wait,
retaining the empty-draft and persisted-options assertions. The combined run
passed 6/7 cases in 8m 50s, with 21.2 seconds of preparation and 4.0 seconds of installation. The complete workspace journey passed in
97.5 seconds, including Back, diff selection, commit, merge and project-change
assertions. Its file-list capture was inspected. The failed combined run remains
recorded. Final focused preferences verification (`tmp/e2e-3326074226`) passed
in 81.6 seconds (22.2 seconds of preparation and 2.2 seconds of installation).
All seven originally failing Android cases now have passing verification; the
37 other cases passed in the original 44-case run. There was no subsequent
complete 44-case green run.

The task-owned Android emulator was gracefully stopped with `just android
emulator-stop`. Snapshot validation passed, the serial and QEMU disappeared,
and final ADB inventory contains only the untouched physical Samsung. No
selected-emulator QEMU or screen session remains.

Final Apple client verification after the shared-core change used the affected
Mac workspace journey and iPhone adapter case. `tmp/e2e-300063423` passed all
17 adapter methods in 125.2 seconds; preparation took 142.8 seconds and total
runtime including final simulator cleanup was **4m 33s**. The runner exited zero.
Its owned simulator `CA18301E-B7FA-4A0E-8609-ECC942F5E35A` is absent from the
final inventory, as are the earlier iPhone/iPad UUIDs. No simulator ownership
journal or Mac app process remains. The full iPhone/iPad suites above predate
this final small controller fix; it also has direct JVM/Android journey coverage
and native-core/Swift integration verification.

## Remaining costs and boundaries

- XCTest startup and actual UI journeys remain expensive; remote-node and
  terminal execution alone consumed about 8.5 minutes in the baseline. Each
  case keeps its own exact test selection and report rather than hiding missing
  assertions through batching or skips.
- A production core change still requires Kotlin compilation and native links.
  The full `core apple-test` builds two native test executables and all three
  Apple framework slices; those links take minutes even when schemas/resources
  are cached. In the final production-change verification, native tests and
  three-slice framework assembly took 18m 47s (21/54 tasks executed); the
  following framework invocation took 8s (32/35 tasks up-to-date). These are
  observed host runs, not controlled comparisons. Simulator-only local iOS builds
  avoid requesting a fresh device
  slice, while the full core check intentionally assembles every Apple slice.
- SwiftPM’s filtered integration command still compiles the package’s test
  bundles before executing the two selected bridge tests. A changed shared
  framework therefore causes substantial Swift compilation as well as linking;
  a filter reduces execution, not all preparation. The app and test scratch
  paths remain separate because their compiler flags differ.
- Debug/release framework configurations still share one published binary-target
  location. Alternating them legitimately changes its bytes and relinks clients.
  Configuration-specific publications would require coordinated SwiftPM/Xcode
  package changes, not a cache purge.
- The core Gradle JVM requests 4 GiB and Android requests 3 GiB. Native verification
  observed Gradle starting another worker because the existing worker was
  incompatible. Different requests can retain two workers; they are not evidence
  that Gradle's task cache was lost. The core preparation reported 32/35 tasks
  up-to-date despite taking 59 seconds including daemon/configuration startup.
- Gradle configuration caching is not currently enabled. Android's custom WebRTC
  task actions require compatibility verification before enabling it. This change
  does not enable an unverified configuration cache.
- Mac builds, unit/core tests, iOS builds and both Apple E2E runners now share
  an Apple build lease. Direct recipes refuse an occupied cache with its owner
  PID. E2E keeps the lease while consuming its exact bundle/test products;
  nested build recipes inherit the lease. Different canonical SwiftPM scratch
  paths for app/test compilation are preserved.
- An orphan from a runner predating the ownership journal is not automatically
  reclaimed. A name prefix alone is insufficient proof that deleting it is safe.
- Device tests do not stop or replace an operator's app/daemon. Missing or leased
  devices produce unavailable results and a nonzero exit, never a passing skip.
