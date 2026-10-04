# Native tests

Run repository commands from the root. macOS, iOS and Android share case selection, deadlines, JSON/JUnit reporting and
required-result qualification. Android uses a separate
`com.dbpprt.dieter.e2e` app, disposable authenticated daemon/gateway fixtures,
and the existing visible `Pixel_9_API_37_1` emulator. No live account or operator
app data is used.

See [the pipeline guide](../../fastlane/README.md) for setup, ignored local
configuration, exact target profiles, command discovery and release policy.

```sh
just pipeline catalog action:lint
just pipeline catalog action:list
just pipeline catalog action:plan platform:android suite:functional changed:true base:main
just pipeline android e2e profile:android-emulator suite:smoke
just pipeline android e2e profile:android-device suite:functional
just pipeline android e2e cases:machines.telemetry
just pipeline android e2e suite:sync
just pipeline android e2e suite:performance
just pipeline android e2e suite:sdk
just pipeline ios e2e profile:ios-iphone suite:functional
just pipeline ios e2e profile:ios-ipad suite:functional
just pipeline mac e2e suite:functional
just pipeline mac e2e cases:mac.navigation,mac.sidebar
```

iOS requires macOS/Xcode and a configured exact installed runtime. Named iPhone
and iPad profiles select layout and device type. One shared Fastlane stage loop
builds once, holds the Apple build lease while consuming test products, boots one
owned simulator per run and creates fresh fixture/app state per case. UUID/name
journaling permits recovery of only that simulator after interruption. The run
deletes it on exit and preserves existing operator simulators. Exact XCTest
methods are qualified from structured xcresult; missing, skipped, duplicate,
failed and interrupted methods fail. Physical `ios-device` execution additionally
requires existing development signing, separate E2E identities and reachable TLS
fixtures; unavailable prerequisites fail admission. Physical Share qualification
needs owned media setup and is currently unavailable. Hosted CI prepares its
pinned runtime explicitly; local tests never install a runtime automatically.

Both layouts cover the remote-node, terminal, screen, connection-state, native
Keychain, and shared-core adapter (`ios.adapters`) tests. The adapter tests live
in `apps/mac/Tests/DieterIOSTests` and compile into the app-hosted
`DieterIOSNativeTests` target. `ios.share-extension` declares `devices: [iphone]` because its
Files share-sheet journey is phone-specific; it is excluded from iPad plans,
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

Android's default profile pins `emulator-5554` and `Pixel_9_API_37_1`.
Named profiles in ignored local JSON replace ambient serial/AVD selection.
Physical devices require an explicit exact-serial profile. The pipeline verifies
AVD identity, normal snapshot/host-GLES health and device boot before use.
It borrows existing healthy targets and closes only emulators it launched, after
healthy snapshot save. `android local action:emulator_check` verifies normal
launch/save/close; repeat it to verify snapshot reload. Phones are never shut down.

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

Artifacts are in `tmp/app-pipelines/<run>/`: `plan.json`, `results.json`, `junit.xml`,
per-case native logs and captures, flow step events, and failure evidence. Use
`output:PATH` to select a fresh directory (existing paths are refused). CI uploads
only that run’s directory, excluding build caches and prior runs. Reports
separate build, installation, setup, and execution time. Builds and running cases
emit credential-free elapsed/deadline progress every 30 seconds; this proves the
runner is active, not that its assertions have passed. Gate on results, not
the shell exit status of `am instrument`. The runner stops owned processes and
removes only owned reverses; failed cleanup also fails qualification.

`changed:true` uses current tracked/untracked changes and optional merge base. Known
feature paths narrow cases; shared/unclassified Android inputs select broadly.
A change to the shared core's sources (`apps/core`, outside its tests and
`testing`) selects every Mac case and, unless it is Apple-only, every Android
case. Renamed/deleted paths are included. Documentation and JVM-only edits need
no device execution. `just check-changed` remains the normal development entry point.

Retain native unit, codec, input, and performance assertions. Candidate signing and distribution share the pipeline foundation while retaining
their own artifact/destination contracts. Do not add another test launcher:
add a case and, where necessary, a reusable fixture or native probe.

The editor schema is `schema.json`; `just pipeline catalog action:lint` is authoritative and also
checks native source references. `build: performance` requires a native Android
case with no gateway fixture and runs non-debuggable `.e2e.performance` APKs.
It is emulator-only and does not overwrite any operator package. The `sdk` suite
runs codec/ownership/icon assertions without a macOS capture host. `manual`
contains the screenshot widget seeder and is excluded from regression gates.

All native journey orchestration uses `just pipeline android e2e`. The separate iOS Python
launcher, Mac Swift driver, old smoke aliases, and cleanup recipes for retired
evidence paths are removed. Native assertions, app/emulator lifecycle commands,
SDK builds, signing, releases and specialized capture/codec fixtures remain.
Retain the selected run's evidence until reviewed; cleanup does not require a
platform-specific script.

`just check` validates the catalog and both iOS layouts through `just pipeline check component:portable operation:contracts`,
so CI and release use the same portable gate. `just pipeline ci action:check component:android` compiles the
E2E and performance apps/test drivers as well as running unit tests, debug assembly, and lint.
All device execution uses `just pipeline android e2e`. The Android job in the manual
`Native E2E` workflow uses `self-hosted`, `macOS`, `dieter-android` for the visible
Pixel emulator and all Android screen suites. Other physical Android suites use
`self-hosted`, `Linux`, `dieter-android`. Install Just/Go/Node/JDK21/Android SDK and
qualify the configured visible `Pixel_9_API_37_1` AVD with host GLES first. The
pipeline does not create, cold boot, or replace an emulator. The Mac job uses a
provisioned desktop; iOS virtual jobs use hosted macOS iPhone/iPad simulators.
Runner provisioning is an explicit prerequisite for hardware dispatches.

Android client logic (sign-in, routing, sync, the outbox, navigation,
terminals, workspace review) lives in the shared KMP core and is covered by its
JVM end-to-end tests against the same isolated gateway (`just pipeline core_test`). The
Android cases exercise the app's native surfaces and platform bindings on top.
The obsolete production-gateway restoration test was removed; owned fixture
teardown replaces its cleanup role.
`FlowTest.runFlow` is invoked by each YAML journey, not as an independent case.
All other existing native regression methods are cataloged, including admission,
queue, offline replay, background sync, codec ownership, and frame budgets.

## iOS adapter qualification

The adapter's host-side lifecycle, configuration, redaction, catalog and result
qualification tests run through `go test ./internal/pipeline ./tools/pipeline-contract ./tools/pipeline-support`. Build-only verification is
`just pipeline ios build`. These checks do not establish simulator UI correctness. After
pulling, colleagues should run both iOS smoke commands above and review each
run's `results.json`, `junit.xml`, screenshots and failure console. Physical iOS
needs its exact development-signed E2E profile and authenticated TLS fixture
route. Share tests on a phone use only the named file staged in the owned E2E
Documents container; `ios.share-owned-file` exercises that Files path on a
disposable simulator. The default simulator share case uses the same owned Files fixture.
