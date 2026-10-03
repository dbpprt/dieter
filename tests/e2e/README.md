# Native tests

Run repository commands from the root. macOS, iOS and Android share case selection, deadlines, JSON/JUnit reporting and
required-result qualification. Android uses a separate
`com.dbpprt.dieter.e2e` app, disposable authenticated daemon/gateway fixtures,
and the existing visible `Pixel_9_API_37_1` emulator. No live account or operator
app data is used.

| Task | Command |
| --- | --- |
| Discover commands | `just e2e` |
| Check affected code locally | `just check-changed` |
| Portable CI/release gate | `just check` |
| Build Android debug APK | `just android build` |
| Android JVM tests | `just android test` |
| Android build/test/lint gate, including both test APK variants | `just android check` |
| Execute device journeys | `just e2e run --suite NAME` or `--case ID` |
| Packaging/signing regressions | `just release test` |

```sh
just e2e check  # catalog and both iOS plans; no devices
just e2e list
just e2e plan --suite functional --changed --base main
just e2e run --suite smoke
just e2e run --case machines.telemetry
just e2e run --suite functional
just e2e run --suite sync
just e2e run --suite performance
just e2e run --suite sdk --serial emulator-5554
just e2e run --platform ios --device iphone --suite smoke
just e2e run --platform ios --device ipad --suite smoke
just e2e run --platform mac --suite smoke
just e2e run --platform mac --case mac.navigation,mac.sidebar
```

iOS requires macOS, Xcode, and an installed iOS Simulator runtime. `--device
iphone` selects iPhone 17 Pro; `--device ipad` selects iPad Pro 11-inch (M5).
The runner builds once, holds the shared Apple build lease while consuming the
Xcode products, boots one owned simulator per run and creates fresh fixtures and
app containers per case. It deletes that exact simulator at the end. The checkout records its
UUID and name; the next leased run recovers only that recorded simulator if a
previous runner was killed. A host simulator lease prevents overlapping managed
runs. Boot is bounded to three minutes; device discovery and XCTest retain
separate deadlines. Existing operator simulators are preserved. It selects
exact XCTest methods and qualifies the structured xcresult test tree. Missing,
skipped, duplicate, failed or interrupted methods fail the run. `--serial`
selects Android only; physical iOS test execution is unavailable and is rejected
explicitly. `just ios build-device` compiles an unsigned device app;
it does not install, launch or manage a physical iPhone/iPad. No simulator
runtime is installed automatically. Missing prerequisites produce unavailable
results and a nonzero exit.

Both layouts cover the remote-node, terminal, screen, connection-state, native
Keychain, and shared-core adapter (`ios.adapters`) tests. The adapter tests live
in `apps/mac/Tests/DieterIOSTests` and compile into the app-hosted
`DieterIOSNativeTests` target. `ios.share-extension` declares `devices: [iphone]` because its
Photos share-sheet journey is phone-specific; it is excluded from iPad plans,
not counted as a passing skip. Explicitly requesting it on iPad is an error.
The `manual` case `ios.https-auth` requires `DIETER_IOS_TEST_HTTPS_GATEWAY` and
performs only the existing invalid-session HTTPS probe. Credentials are injected
through a private xctestrun file, never command arguments. Only sanitized test
reports, console output and exported attachments are retained; private launch
configuration and raw xcresult bundles are removed on cleanup.

Mac execution requires a logged-in macOS desktop and refuses any existing
DieterMac process before packaging. It uses the canonical SwiftPM app cache,
isolated preferences/state, disposable gateways, and a desktop lease. Android screen journeys need a macOS capture host;
an unavailable host is reported as unavailable, never a pass. Mac companion screen qualification remains separate from this catalog.

`functional` includes focused device component cases and full-stack journeys.
`sync`, `performance`, and `screens` are explicit separate suites. All required
native methods are listed; skipped, missing, duplicate, failed, and interrupted
results fail the command. Native assertions remain native code. Ordinary journeys
are YAML, interpreted by Compose; adding a flow does not require a new APK.

Android's default target is `emulator-5554` running `Pixel_9_API_37_1`.
Override both `--serial`/`ANDROID_SERIAL` and `DIETER_ANDROID_AVD` deliberately
when choosing another emulator. The runner verifies its reported AVD name;
physical devices use their exact ADB serial and are never auto-selected. Start
and stop recipes use the same serial lease as tests and installation. The
launcher passes the selected console port rather than relying on automatic
port allocation. Tests reuse the device and leave its lifecycle with its owner.

Each physical device or emulator gets one lease; runs on different devices may
execute concurrently after serialized shared-build preparation. The runner validates before building, acquires the per-device lease, prepares
one pair of app/test APKs, verifies hashes before reusing builds/installations,
then runs each case in a fresh app process and fixture. Isolation takes priority
over batching mutable state. The fixture binary and installed APKs are shared,
not client caches, outbox data, identities, or conversations. Flow JSON and
credentials are transferred to the fixture app's private files and removed on
exit. No credentials are put in instrumentation argv.

Case format is version 1. One file declares a unique ID, platform, suites,
components, fixture (`none`, `gateway`, `activity`, `screen`), timeout (1s–10m;
iOS allows up to 20m including fresh simulator and XCTest setup),
and either `steps`, an explicit native class/method list, or a Mac native
`suite` with explicit phase-qualified `checks`. Missing or non-passing Mac
assertions fail, including incomplete multi-launch suites. The host rejects
unknown fields, duplicate keys, ambiguous selectors, unsupported placeholders,
YAML anchors/aliases, and multiple documents. At most 100 steps and 256 KiB per
case. No shell, expressions, loops, arbitrary hooks, or recursive fragments.

Steps are `launch: connected`, `tap`, `type`, `press: back`, `scroll`, `expect`,
`screenshot`, and named `probe`. Targets use exactly one of `id`, `text`, or
`description`. Text entry replaces the field. `expect.value` asserts editable
text; `visible: false` currently means absent from the semantics tree. Mac navigation flows currently support `launch`, `tap`, `expect`, and
`screenshot` through native accessibility; unsupported actions fail catalog
validation. Advanced Mac interactions remain in native suites. Compose
waits for conditions with bounded deadlines. Mutations dispatch once. A scroll
uses the native container's bounded test action and the case deadline.

Available variables are `fixture.endpointId`, `fixture.cardId`,
`fixture.chatId`, and `fixture.activityPrefix`. The Activity fixture arranges
real card/chat records through the API before navigation. The machine telemetry
probe asserts daemon identity, CPU, memory, and process data through the native
repository. Activity probes verify that completed card/chat replies need attention
before opening them, and that viewing each reply synchronizes its read receipt
and clears attention. These setup/probe operations do not replace UI actions under test.

Artifacts are in `tmp/e2e-<run>/`: `plan.json`, `results.json`, `junit.xml`,
per-case native logs and captures, flow step events, and failure evidence. Use
`--output PATH` to select a fresh directory (existing paths are refused). CI uploads
only that run’s directory, excluding build caches and prior runs. Reports
separate build, installation, setup, and execution time. Builds and running cases
emit credential-free elapsed/deadline progress every 30 seconds; this proves the
runner is active, not that its assertions have passed. Gate on results, not
the shell exit status of `am instrument`. The runner stops owned processes and
removes only owned reverses; failed cleanup also fails qualification.

`--changed` uses current tracked/untracked changes and optional merge base. Known
feature paths narrow cases; shared/unclassified Android inputs select broadly.
A change to the shared core's sources (`apps/core`, outside its tests and
`testing`) selects every Mac case and, unless it is Apple-only, every Android
case. Renamed/deleted paths are included. Documentation and JVM-only edits need
no device execution. `just check-changed` remains the normal development entry point.

Retain native unit, codec, input, and performance assertions. Release/install/
signing tooling is outside E2E consolidation. Do not add another test launcher:
add a case and, where necessary, a reusable fixture or native probe.

The editor schema is `schema.json`; `just e2e lint` is authoritative and also
checks native source references. `build: performance` requires a native Android
case with no gateway fixture and runs non-debuggable `.e2e.performance` APKs.
It is emulator-only and does not overwrite any operator package. The `sdk` suite
runs codec/ownership/icon assertions without a macOS capture host. `manual`
contains the screenshot widget seeder and is excluded from regression gates.

All native journey orchestration uses `just e2e run`. The separate iOS Python
launcher, Mac Swift driver, old smoke aliases, and cleanup recipes for retired
evidence paths are removed. Native assertions, app/emulator lifecycle commands,
SDK builds, signing, releases and specialized capture/codec fixtures remain.
Retain the selected run's evidence until reviewed; cleanup does not require a
platform-specific script.

`just check` validates the catalog and both iOS layouts through `just e2e check`,
so CI and release use the same portable gate. `just android check` compiles the
E2E and performance apps/test drivers as well as running unit tests, debug assembly, and lint.
All device execution uses `just e2e run`. The Android job in the manual
`Native E2E` workflow requires a runner labeled `self-hosted`, `Linux`,
`dieter-android`, with Just/Go/Node/JDK21/Android SDK and the healthy visible
`Pixel_9_API_37_1` AVD already available. It does not create, cold boot, or replace
an emulator. The Mac job uses a provisioned desktop; the iOS job uses the hosted macOS iPhone/iPad matrix. No runner provisioning or GitHub execution is implied by the file.

Android client logic (sign-in, routing, sync, the outbox, navigation,
terminals, workspace review) lives in the shared KMP core and is covered by its
JVM end-to-end tests against the same isolated gateway (`just core test`). The
Android cases exercise the app's native surfaces and platform bindings on top.
The obsolete production-gateway restoration test was removed; owned fixture
teardown replaces its cleanup role.
`FlowTest.runFlow` is invoked by each YAML journey, not as an independent case.
All other existing native regression methods are cataloged, including admission,
queue, offline replay, background sync, codec ownership, and frame budgets.

## iOS adapter qualification

The adapter's host-side lifecycle, configuration, redaction, catalog and result
qualification tests run through `go test ./tools/e2e`. Build-only verification is
`just ios build`. These checks do not establish simulator UI correctness. After
pulling, colleagues should run both iOS smoke commands above and review each
run's `results.json`, `junit.xml`, screenshots and failure console. The migration
was prepared on a host without an installed iOS runtime; device execution remains
to be qualified on those hosts.
