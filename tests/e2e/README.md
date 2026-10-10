# Native tests

Run repository commands from the root. macOS, iOS and Android share case selection, deadlines, JSON/JUnit reporting and
required-result qualification. Android uses a separate
`com.dbpprt.dieter.e2e` app, disposable authenticated daemon/gateway fixtures,
and the headless `Dieter_AOSP_API_35` emulator. No live account or operator
app data is used.

See [the pipeline guide](../../fastlane/README.md) for setup, ignored local
configuration, exact target profiles, command discovery and release policy.

Inspect `just check-changed --dry-run` and run affected fast checks first. Device
work is listed separately and selected with `--native` or specific cases. Run
only related cases during implementation; complete catalogs remain release gates.
Native test formats share selection, qualification, timing and evidence contracts.

```sh
just pipeline catalog action:lint
just pipeline catalog action:list
just pipeline catalog action:plan platform:android suite:functional changed:true base:main
just pipeline android e2e profile:android-emulator
just pipeline android e2e profile:android-device
just pipeline ios e2e profile:ios-iphone
just pipeline ios e2e profile:ios-ipad
just pipeline ios_qualify profiles:ios-iphone,ios-ipad
just pipeline mac e2e suite:functional
just pipeline mac e2e cases:mac.navigation,mac.sidebar
```

The Android and iOS apps share one Compose UI, and each catalog holds one native
journey through it: `android.journey` (`com.dbpprt.dieter.JourneyTest`) and
`ios.journey` (`DieterUITests/JourneyUITests`). Both are in the `smoke` and
`functional` suites. Each starts a disposable gateway, enrolled daemon and mock
harness, then walks Inbox, Projects, a board, a seeded task and its subagents,
task creation with live first and follow-up replies, Review, Chats, Tools,
Machines, Files, Markdown preview, Schedules and dark appearance, capturing a
screenshot of each view. The fixture's `mobile` suite seeds that workspace and
offers WebRTC control channels like production daemons.

iOS requires macOS/Xcode and a configured exact installed runtime. Named iPhone
and iPad profiles select layout and device type. One shared Fastlane stage loop
builds once, holds the Apple build lease while consuming test products, boots one
owned simulator per run and creates fresh fixture/app state per case. UUID/name
journaling permits recovery of only that simulator after interruption. The run
deletes it on exit and preserves existing operator simulators. Exact XCTest
methods are qualified from structured xcresult; missing, skipped, duplicate,
failed and interrupted methods fail. Physical `ios-device` execution additionally
requires existing development signing, separate E2E identities and reachable TLS
fixtures; unavailable prerequisites fail admission. Hosted CI prepares its
pinned runtime explicitly; local tests never install a runtime automatically.

An iOS case may declare `devices: [iphone]` or `[ipad]`; it is then excluded from
the other layout's plan, not counted as a passing skip, and explicitly requesting
it there is an error. The fixture session reaches the app through a private
xctestrun file, never command arguments. Only sanitized test reports, console
output and failure attachments are retained; private launch configuration and
raw xcresult bundles are removed on cleanup.

Mac execution requires a logged-in macOS desktop and refuses any existing
DieterMac process before packaging. It uses the canonical SwiftPM app cache,
isolated preferences/state, disposable gateways, and a desktop lease. Mac
companion screen qualification remains separate from this catalog.

All required native methods are listed; skipped, missing, duplicate, failed, and
interrupted results fail the command. Native assertions remain native code.
Android and iOS cases are native journeys; Mac cases are native suites or YAML
navigation flows.

Android's default profile pins `emulator-5554` and `Dieter_AOSP_API_35`, with
headless automatic rendering and snapshots disabled. Runtime/image and
AVD userdata live in ignored project `.android/`. Named profiles in ignored local JSON select exact targets; physical devices require an explicit serial.
Fastlane creates a missing test AVD from the installed API 35 image, checks exact
AVD identity, boot and package services, and closes only processes it launched.
`android local action:emulator_check` verifies startup/readiness/closure.
`android local action:emulator_run` keeps an owned emulator warm for subsequent
borrowers; run `android local action:emulator_stop` after borrowers finish.
Borrowed emulators
and phones remain running. See [Fastlane configuration and lifecycle](../../fastlane/README.md).

Each physical device or emulator gets one lease; runs on different devices may
execute concurrently after serialized shared-build preparation. The runner validates before building, acquires the per-device lease, prepares
one pair of app/test APKs, verifies hashes before reusing builds/installations,
then runs each case in a fresh app process and fixture. Isolation takes priority
over batching mutable state. The fixture binary and installed APKs are shared,
not client caches, outbox data, identities, or conversations. On Android the
isolated gateway's port and disposable session token are written to the E2E
app's private files with `run-as`, never passed as instrumentation arguments;
the token is valid only for that run's fixture.

Case format is version 1. One file declares a unique ID, platform, suites,
components, fixture (`none` or `gateway`), timeout (1s–10m;
iOS allows up to 20m including fresh simulator and XCTest setup),
and either an explicit native class/method list (iOS also names
`target: DieterUITests`), a Mac native `suite` with explicit phase-qualified
`checks`, or Mac navigation `steps`. Missing or non-passing Mac
assertions fail, including incomplete multi-launch suites. The host rejects
unknown fields, duplicate keys, ambiguous selectors, unsupported placeholders,
YAML anchors/aliases, and multiple documents. At most 100 steps and 256 KiB per
case. No shell, expressions, loops, arbitrary hooks, or recursive fragments.

Mac navigation flows use the `gateway` fixture and support `launch: connected`,
`tap`, `expect`, and `screenshot` through native accessibility. Targets use
exactly one of `id`, `text`, or `description`. `expect.value` asserts editable
text; `visible: false` currently means absent from the accessibility tree.
Advanced Mac interactions remain in native suites.

Artifacts are in `tmp/app-pipelines/<run>/`: `plan.json`, `results.json`, `junit.xml`,
per-case native logs and captures, flow step events, and failure evidence. Use
`output:PATH` to select a fresh directory (existing paths are refused). CI uploads
an explicit diagnostic allowlist capped at 64 MiB, with per-file limits and an
omission manifest. Archives, caches, raw xcresult bundles and producer checkpoints
are excluded. Checkpoint retention is mandatory; diagnostic upload outages do
not invalidate a passing test gate. Reports separate build, installation, setup,
and execution time. Logged compiler/test commands stream sanitized stdout/stderr;
builds and running cases also emit elapsed/deadline progress every 30 seconds. This proves the
runner is active, not that its assertions have passed. Gate on results, not
the shell exit status of `am instrument`. The runner stops owned processes and
removes only owned reverses; failed cleanup also fails qualification.

`changed:true` uses current tracked/untracked changes and optional merge base.
App paths narrow cases: `apps/android` and `native/android-webrtc` select
Android; `apps/ios` and `apps/mac/Sources/DieterIOS` select iOS; other Mac
sources select Mac, and `SharedCore`, `DieterTransport`, `DieterAPI` and the
package manifest select Mac and iOS. Mock-harness changes select both mobile
journeys. A change to the shared core's sources (`apps/core`, outside its tests
and `testing`) selects the apps that compile it: the shared mobile UI reaches
Android and iOS, Apple-only code reaches Mac and iOS, and common code reaches
all three. Shared pipeline, fixture and schema paths select every case.
Renamed/deleted paths are included. Documentation and JVM-only edits need no
device execution. `just check-changed` remains the normal development entry
point.

Candidate signing and distribution share the pipeline foundation while retaining
their own artifact/destination contracts. Do not add another test launcher:
add a case and, where necessary, a reusable fixture or native probe.

The editor schema is `schema.json`; `just pipeline catalog action:lint` is
authoritative and also checks native source references. All native journey
orchestration uses `just pipeline PLATFORM e2e`. Native assertions, app/emulator
lifecycle commands, signing, releases and specialized capture fixtures remain
in their own lanes. Retain the selected run's evidence until reviewed; cleanup
does not require a platform-specific script.

`just check` validates the catalog and both iOS layouts through `just pipeline check component:portable operation:contracts`,
so CI and release use the same portable gate. `just pipeline ci action:check component:android`
runs lint and the debug build and compiles the journey's `e2e` app and test
APKs. Android device execution uses `just pipeline android e2e` with an explicit
local profile; hosted CI runs no emulator. Install Just/Go/Node/JDK21/Android SDK
and the API 35 AOSP system image for the host architecture, then run
`android local action:emulator_setup` once. Fastlane keeps its runtime/image and
AVD in ignored project `.android/`, creates a missing selected test AVD and boots
without snapshots. Existing AVDs are never replaced or wiped. Mac journeys use
the configured local desktop. The manual `Native qualification` workflow runs
iPhone and iPad simulator profiles sequentially on one GitHub-hosted macOS
worker, using one verified simulator build.

Client logic (sign-in, routing, sync, the outbox, navigation, terminals,
workspace review) lives in the shared KMP core. Its JVM end-to-end tests and the
shared mobile UI's JVM journey (`MobileJourneyTest`) run against the same
isolated gateway (`just pipeline core_test`). The device journeys exercise the
native shells and platform bindings on top.

## iOS adapter qualification

The adapter's host-side lifecycle, configuration, redaction, catalog and result
qualification tests run through `go test ./internal/pipeline ./tools/pipeline-contract ./tools/pipeline-support`. Build-only verification is
`just pipeline ios build`. These checks do not establish simulator UI correctness. After
pulling, colleagues should run both iOS layout commands above and review each
run's `results.json`, `junit.xml`, screenshots and failure console. Physical iOS
needs its exact development-signed E2E profile and authenticated TLS fixture
route.
