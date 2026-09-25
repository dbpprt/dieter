# Native tests

Run repository commands from the root. Android uses a separate
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
just e2e check  # catalog and both prepared iOS layouts; no devices
just e2e list
just e2e plan --suite functional --changed --base main
just e2e run --suite smoke
just e2e run --case machines.telemetry
just e2e run --suite functional
just e2e run --suite sync
just e2e run --suite performance
just e2e run --suite sdk --serial emulator-5554
just e2e prepare --platform ios --device ipad
# just e2e run --platform mac  # deliberately disabled; no Mac adapter yet
```

Android is executable. iOS case discovery and versioned JSON preparation are
ready, but execution intentionally fails until an XCTest adapter is qualified.
The existing iOS XCTest suite remains the native implementation to integrate.
Mac execution is disabled. Android screen journeys need a macOS capture host;
an unavailable host is reported as unavailable, never a pass. Mac companion
screen qualification is disabled with the Mac adapter.

`functional` includes focused device component cases and full-stack journeys.
`sync`, `performance`, and `screens` are explicit separate suites. All required
native methods are listed; skipped, missing, duplicate, failed, and interrupted
results fail the command. Native assertions remain native code. Ordinary journeys
are YAML, interpreted by Compose; adding a flow does not require a new APK.

Each physical device or emulator gets one lease; runs on different devices may
execute concurrently after serialized shared-build preparation. The runner validates before building, acquires the per-device lease, prepares
one pair of app/test APKs, verifies hashes before reusing builds/installations,
then runs each case in a fresh app process and fixture. Isolation takes priority
over batching mutable state. The fixture binary and installed APKs are shared,
not client caches, outbox data, identities, or conversations. Flow JSON and
credentials are transferred to the fixture app's private files and removed on
exit. No credentials are put in instrumentation argv.

Case format is version 1. One file declares a unique ID, platform, suites,
components, fixture (`none`, `gateway`, `activity`, `screen`), timeout (1s–10m),
and either `steps` or an explicit native class/method list. The host rejects
unknown fields, duplicate keys, ambiguous selectors, unsupported placeholders,
YAML anchors/aliases, and multiple documents. At most 100 steps and 256 KiB per
case. No shell, expressions, loops, arbitrary hooks, or recursive fragments.

Steps are `launch: connected`, `tap`, `type`, `press: back`, `scroll`, `expect`,
`screenshot`, and named `probe`. Targets use exactly one of `id`, `text`, or
`description`. Text entry replaces the field. `expect.value` asserts editable
text; `visible: false` currently means absent from the semantics tree. Compose
waits for conditions with bounded deadlines. Mutations dispatch once. A scroll
uses the native container's bounded test action and the case deadline.

Available variables are `fixture.endpointId`, `fixture.cardId`,
`fixture.chatId`, and `fixture.activityPrefix`. The Activity fixture arranges
real card/chat records through the API before navigation. The machine telemetry
probe asserts daemon identity, CPU, memory, and process data through the native
repository. These setup/probe operations do not replace UI actions under test.

Artifacts are in `tmp/e2e-<run>/`: `plan.json`, `results.json`, `junit.xml`,
per-case native logs and captures, flow step events, and failure evidence. Use
`--output PATH` to select a fresh directory (existing paths are refused). CI uploads
only that run’s directory, excluding build caches and prior runs. Reports
separate build, installation, setup, and execution time. Gate on results, not
the shell exit status of `am instrument`. The runner stops owned processes and
removes only owned reverses; failed cleanup also fails qualification.

`--changed` uses current tracked/untracked changes and optional merge base. Known
feature paths narrow cases; shared/unclassified Android inputs select broadly.
Renamed/deleted paths are included. Documentation and JVM-only edits need no
device execution. `just check-changed` remains the normal development entry point.

Retain native unit, codec, input, and performance assertions. Release/install/
signing tooling is outside E2E consolidation. Do not add another test launcher:
add a case and, where necessary, a reusable fixture or native probe.

The editor schema is `schema.json`; `just e2e lint` is authoritative and also
checks native source references. `build: performance` requires a native Android
case with no gateway fixture and runs non-debuggable `.e2e.performance` APKs.
It is emulator-only and does not overwrite any operator package. The `sdk` suite
runs codec/ownership/icon assertions without a macOS capture host. `manual`
contains the screenshot widget seeder and is excluded from regression gates.

Eight legacy Android launchers and the duplicate Activity/Machines native
journeys were retired. Android's emulator lifecycle, SDK build, release, signing,
and native fixture implementations remain because they serve distinct purposes.
Mac/iOS legacy tooling remains until those adapters can be qualified. New Mac
entry points and workflow examples stay commented out. The framework's iOS
contract references existing XCTest methods and supports iPhone/iPad preparation.

`just check` validates the catalog and both iOS layouts through `just e2e check`,
so CI and release use the same portable gate. `just android check` compiles the
E2E and performance apps/test drivers as well as running unit tests, debug assembly, and lint.
All device execution uses `just e2e run`; the five old Android test aliases are removed. The manual
`Native E2E` workflow requires a runner labeled `self-hosted`, `Linux`,
`dieter-android`, with Just/Go/Node/JDK21/Android SDK and the healthy visible
`Pixel_9_API_37_1` AVD already available. It does not create, cold boot, or replace
an emulator. No runner provisioning or GitHub execution is implied by the file.

Coverage exceptions are explicit: `RealDieterIntegrationTest` requires an operator
account and stays manual; `webRTCControlCarriesRPCAndReportsICEPath` needs a
separately provisioned reachable ICE/TURN fixture (see the native TURN guide).
The old `archiveVisibleFixtureAndRestoreProductionGateway` helper is not a test
case in this framework: owned fixture teardown replaces its cleanup role.
`FlowTest.runFlow` is invoked by each YAML journey, not as an independent case.
All other existing native regression methods are cataloged, including admission,
queue, offline replay, background sync, codec ownership, and frame budgets.
