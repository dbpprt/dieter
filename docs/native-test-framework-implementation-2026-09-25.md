# Native test framework implementation

Dieter now has one Android E2E entry point: `just e2e`. Cases live under
`tests/e2e/cases/`, with a strict versioned YAML format, editor schema, and
source-reference validation. The command supports discovery, planning,
change selection, preparation, execution, and JSON/JUnit reports.

```sh
just e2e run --suite smoke
just e2e run --case machines.telemetry
just e2e run --suite functional --changed --base main
just e2e run --suite sync
just e2e run --suite performance
just e2e prepare --platform ios --device ipad
# just e2e run --platform mac  # disabled until an adapter can be qualified
```

Android executes through a small Compose interpreter for ordinary journeys and
explicit class/method lists for specialized native assertions. The catalog
contains 44 Android cases and four prepared iOS cases. Activity navigation and
Machines telemetry/operation journeys are YAML. Native component, codec, queue,
background sync, admission, workspace, and performance assertions are retained.
Configured-account and externally provisioned ICE/TURN tests are documented
exceptions, checked by a native-coverage inventory test.

Eight bespoke Android launcher/lease scripts and the duplicate Activity/Machines
native journey classes and all five Android Just test aliases were removed.
Device execution uses `just e2e run --suite NAME` or `--case ID`. The Gradle wrapper participates in the same Go-managed device
lease. Emulator lifecycle, fixture implementations, release/signing, and native
assertions remain separate because they have distinct responsibilities. Existing
Mac/iOS tooling remains available until those adapters can be qualified.

Each case gets fresh app data in `com.dbpprt.dieter.e2e` and disposable real
server/gateway fixtures. Performance uses non-debuggable
`com.dbpprt.dieter.e2e.performance`. Neither build replaces the operator app.
Credential-bearing plans travel through private app files and are removed after
use; disposable server state is deleted during teardown.
The runner owns exact child processes and reverse mappings, refuses concurrent
device owners, and records cleanup failures separately. Missing, skipped,
interrupted, duplicate, or failed native method results fail qualification.

Execution avoids repeated Gradle startup and installation by validating source,
toolchain, APK, and installed-package hashes. YAML edits do not rebuild the APK.
Shared preparation is serialized; different leased devices can execute
concurrently. `functional`, `sync`, `screens`, `sdk`, and `performance` remain
separate suites. No historical speedup percentage is claimed: an old/new baseline
with equal coverage was not measured.

Migration exposed stale tests that depended on retained navigation, immediate
preference hydration, or the wrong dialog/root. Those tests now arrange and await
the state they assert. It also exposed an application bug: card opening caused
pager focus/layout scrolling to overwrite the selected route. The pager now
separates real drags and accessibility navigation from automatic movement,
retains its selected route, and realigns the page. The draft/queue regression
covers swipes, accessibility actions, navigation, Activity recreation, and
server-backed queued-message recall. The worktree journey exercises
that behavior before reviewing a diff, committing, merging, and checking
project-level stage/commit/discard operations. The offline-start test now waits
for catalog hydration and selects the deterministic mock harness; its durability
and replay assertions remain intact.

Mac execution in this framework is disabled and its entry-point/workflow examples
are commented out. iOS discovery/preparation references existing XCTest methods
and supports iPhone/iPad layouts; execution intentionally fails until an adapter
is implemented. Android screen capture journeys require a macOS capture host and
remain explicitly unavailable on this Linux host. Physical decoder/display,
real-host input, and forced-TURN qualification are not established by emulator
functional results.

`just check` validates the catalog and both prepared iOS layouts; CI and release
share this gate. `just android check` compiles the isolated E2E and performance app/test APKs
alongside unit tests, debug assembly, and lint. Workflow validation always runs
pinned actionlint. Android release verification rejects test IDs, debugging,
and instrumentation after validating the APK signature. A separate manual Android
workflow targets a provisioned `dieter-android` self-hosted runner with the
existing visible host-GPU AVD. It does not create or cold boot emulators. The
workflow was authored and checked locally; it was not executed on GitHub.

Validation on Linux with the visible host-GPU `Pixel_9_API_37_1` emulator,
serial `emulator-5554`:

| Check | Result |
| --- | --- |
| Catalog | 48 validated cases: 44 Android, four prepared iOS |
| Runner | Go race tests and vet passed |
| Tooling | 37 change-selector tests, five screen-report tests, Just formatting, and workflow validation passed |
| Android debug | 369 unit tests, APK assembly, and lint passed (lint: zero errors, 96 warnings) |
| Functional | 36/36 cases passed: 81 native methods plus two YAML journeys; 313.075 seconds including preparation |
| Warm smoke | 2/2 YAML journeys passed in 10.273 seconds; no Gradle invocation or APK installation |
| Sync | Eight methods passed across the background-sync and gateway cases; two 30-second idle windows retained |
| Performance | Both cases passed (three methods), including the non-debuggable frame test; 599 frames, p95 17 ms, max 34 ms |
| Decoder SDK subset | All 16 exact codec/surface/icon methods passed; zero skips |
| Android screen capture | Three unavailable cases: macOS capture host required; JSON/JUnit record failures |
| iOS | All four cases prepared and validated for both iPhone and iPad; no execution |

`just check-changed --dry-run` and `just check-changed` were run. All available
checks passed; the latter exits nonzero for the three unavailable screen-capture
cases. No Mac app was launched. Functional evidence is in
`tmp/e2e-1441548263/`; unavailable screen evidence is in `tmp/e2e-280273293/`.
The two YAML journeys produced 41 passed step events, seven screenshots, and
seven semantics snapshots. Sync evidence is in `tmp/e2e-211909389/` (background
case passed; gateway setup failed) and `tmp/e2e-2795576901/` (all six gateway
methods passed after the setup fix). Performance evidence is in
`tmp/e2e-4164131032/`; its first variant preparation took 45.192 seconds and
the frame test took 23.013 seconds. Idle measurements are process CPU evidence,
not physical battery qualification. Reports include per-case setup/execution/cleanup
status and aggregate preparation timings.

Warm-run evidence is in `tmp/e2e-3185477708/`. Preparation/hash verification took
131 ms, installed-package verification took 194 ms, and the journeys took 4.922
and 4.996 seconds including setup and cleanup. These are current-run measurements,
not an old/new speedup comparison. No owned fixture processes, test app processes,
or ADB reverse mappings remained after execution. The owned emulator saved
its snapshot and stopped cleanly with `just android emulator-stop`.

See [the authoring and execution guide](../tests/e2e/README.md) and
[the original design](native-test-framework-plan-2026-09-25.md).

## CI and release follow-up audit

Removed the five compatibility test aliases and updated the active guides and
skills to use case IDs and suites. Dated reports retain their original evidence
with a migration notice. `just e2e` lists the supported commands;
`just e2e run --help` documents selection and execution options.
`just android build` assembles the debug APK, `just android test` runs JVM tests,
and `just android check` runs unit tests and lint and compiles debug, E2E,
and performance APKs plus both instrumentation APKs without a device.

The normal CI Android job and the release Android job use that same check.
Both portable jobs use `just check`, which includes catalog validation and
preparation of both iOS layouts. Release now also runs the packaging/signing
regressions. Workflow validation always runs actionlint v1.7.12 instead of
silently skipping it when no binary is installed. The manual native workflow
uses an exclusive output directory per run/attempt and uploads only that run,
excluding APK caches and older evidence. No GitHub workflow or production
signing/publishing operation was executed from this workspace.

The Android release command fails before Gradle if any signing credential is
missing. Verification requires a valid signature, the production application ID,
no debugging, and no instrumentation/test manifest entries. Packaging accepts
an explicit staging path and refuses to overwrite an existing artifact.
The release regression suite exercises these rejection paths without real keys.

Follow-up verification on this Linux host:

| Check | Result |
| --- | --- |
| Android CI command | Passed: JVM test gate, lint, debug APK, E2E app/test APKs, performance app/test APKs |
| Workflows | All workflows passed pinned actionlint and the Just entry-point check |
| Release regressions | Assembly test and 86 Python tests passed; one native pkgbuild test requires macOS |
| Signed Android release | Actual assemble/package/verify passed using a disposable RSA key; production ID, version propagation, no debugging, no test driver in DEX, and overwrite refusal verified |
| Catalog/iOS preparation | 48 cases validated; both iPhone and iPad prepared |
| Runner | Go race tests and vet passed, including exclusive artifact directory coverage |
| Final functional rerun | 36/36 cases passed in 282.890 seconds; `tmp/e2e-3435763509/` |
| Release rejection checks | Actual debug, E2E, and performance APKs correctly rejected by `just android verify-release` |

The disposable signing key was deleted after verification. Its deliberately
fixture-signed APK and machine-readable report are under `tmp/e2e-ci-audit/`;
this artifact was neither installed nor published. Production credentials and
macOS/iOS signing remain unverified on this host.

The final `just check-changed --dry-run` and `just check-changed` selected and
ran catalog/iOS preparation, 37 selector tests, five screen-report tests, Just
formatting, actionlint, release regressions, runner race tests/vet, Android JVM
tests, and all 36 functional cases successfully. The command then exited nonzero
for the three screen cases requiring a macOS capture host; their explicit
unavailable results are in `tmp/e2e-2627209685/`. They remain unqualified.

The CI-style smoke command, `just e2e run --suite smoke --output
tmp/native-e2e-ci-audit`, passed both journeys in 11.477 seconds with verified
APK/install reuse and no Gradle invocation. Its JSON and JUnit reports contain
two passes and zero failures; its directory contains no APKs or signing keys.
No fixture processes remained. The owned emulator saved its snapshot and
stopped cleanly after verification. Final Just formatting and `git diff --check`
passed; unrelated existing work was preserved.
