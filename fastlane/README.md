# Dieter pipelines

Fastlane owns the compositions for local builds, native tests, CI checks,
immutable candidates and release distribution. `just pipeline` and `just app`
forward arguments to the same pinned `bundle exec fastlane`. Go, Gradle,
SwiftPM, Xcode, Docker Buildx and the gateway deployment controller remain the
tools that do their component work. Just contains no native lifecycle or
release implementation.

## Architecture and verification cost

`pipeline/action.rb` runs Fastlane `run_tests` and `build_app` in owned subprocesses
with private JSON input, redacted live output and Dieter deadlines. Fastlane builds
the Apple commands; Dieter retains exact-device leases, isolated fixtures and
qualification from structured native results. Adapters consume shared process,
product, input-hash and evidence modules instead of implementing them.
Apple builds use locked package versions; execution of verified xctestrun products
skips package resolution, avoiding repeated network work for each native case.
The pinned `xcpretty` formatter keeps Apple progress compact. Build-settings
discovery has one 120-second deadline rather than repeated three-second queries.

Inspect `just check-changed --dry-run` before testing. The default executes fast
affected checks and lists related device/desktop checks separately. Use `--native`
to execute those, or select specific catalog cases. During implementation, rerun
only a failed or newly affected check; run affected contracts once after changes
are integrated. Shared orchestration edits do not select every local native build.
Full repository/device suites belong to explicit full checks and release gates.
[The refactor record](../docs/pipeline-refactor.md) contains measured causes,
research and verification scope.

Assertions stay in Compose/XCTest/Swift/Go tests. The catalog provides shared
selection and results, rather than replacing native tests with another language.
Shared core behavior is tested below the UI; device journeys qualify native
presentation and platform bindings.

## Setup and machine configuration

Install Ruby from `.ruby-version`, Bundler 2.6.9, just 1.58+, Go from `go.mod`,
Python 3, Node 22 and the native toolchains you use. Then run:

```sh
bundle install
npm --prefix internal/harness/runtime ci
just pipeline config_init
just pipeline doctor
just pipeline doctor profile:ios-iphone
just pipeline lanes
```

`config_init` copies [local.example.json](local.example.json) to
`fastlane/local.json`, atomically with mode 0600. It refuses an existing file.
On a Mac with multiple installed iOS runtimes, pass `runtime:IDENTIFIER` from
`xcrun simctl list runtimes -j`. The default and example configurations are
tracked; the local override is gitignored and ignored in CI.

Configuration is validated against [config.schema.json](config.schema.json).
Objects merge by name; unknown fields, duplicate keys, executable hooks and
local release-policy overrides fail. Use environment references or external
private files for signing material. Never store passwords or private keys in
JSON. Conflicting configured and inherited toolchain paths fail explicitly.
Android Studio's bundled JBR and the local Android SDK are discovered when their
environment variables are absent; a missing/removed `JAVA_HOME` falls back to JBR.

Profiles select exact targets:

| Profile | Target and ownership |
| --- | --- |
| `android-emulator` | Visible `Pixel_9_API_37_1`, serial `emulator-5554`, host GLES; borrow a healthy running AVD or manage one launched by the run |
| `android-device` | Disabled until an exact ADB serial is configured; phone lifecycle remains with its owner |
| `ios-iphone`, `ios-ipad` | Exact runtime and device type; create and delete a recorded disposable simulator |
| `ios-device` | Disabled until exact UDID, existing development signing and authenticated TLS fixture route are configured |
| `mac-desktop` | Exclusive packaged test app on a logged-in desktop |
| `daemon-local`, `gateway-local` | Native host OS and architecture; build output never installs over a running service |

To use an attached Android phone, set only this override and pass its profile
explicitly on every operation:

```json
{"profiles":{"android-device":{"enabled":true,"serial":"EXACT_ADB_SERIAL"}}}
```

Physical iOS uses separate `.e2e` app, Share extension, runner and app-group
identities. Configure an existing development team and profiles that cover the
exact UDID and share one available Apple Development private key. No Apple
account resources are created automatically. The fixture route uses a reachable
local-network host address and existing certificate/key; USB pairing controls
the device and does not itself expose host loopback to it. Credentials and
offline controls cross that route through authenticated TLS. Share tests on
simulators and physical devices stage an exact PNG in the isolated E2E app's
Documents container and share it through Files. Only Debug `.e2e` apps expose
that container as `Dieter E2E`;
package cleanup removes the owned media. No Share fixture imports media into
Photos. `ios.share-owned-file` also qualifies the same Files path in isolation.
Physical hardware remains unqualified until its
configured native plan actually passes; unavailable cells fail.

## Local checks and app work

```sh
just check-changed --dry-run
just check-changed
just check-changed --base origin/main
just check-changed --native        # include related device/desktop checks explicitly
just check                         # portable Go/harness/pipeline/release checks
just check-all                     # all component unit/build checks on a Mac
just pipeline core_test
just pipeline core_apple_test
just pipeline android test_unit
just pipeline android build
just pipeline android local action:emulator_check # run twice for snapshot reload
just pipeline ios test_unit
just pipeline ios_qualify profiles:ios-iphone,ios-ipad suite:smoke
just pipeline ios build
just pipeline mac test_unit
just pipeline mac build configuration:release
just pipeline component component:daemon operation:build
just pipeline component component:gateway operation:test_unit
```

Build lanes publish an `artifacts.json` manifest in their printed evidence
directory. `just pipeline PLATFORM verify artifact:PATH` verifies those exact
bytes without rebuilding. Relative file options, including `artifact:`,
`identity:`, `products:` and `output:`, resolve from the repository root even
when Fastlane changes its working directory. Mac app and test caches remain
`apps/mac/.build/dieter-local` and `apps/mac/.build/dieter-tests`; the shared
framework cache hashes production inputs, toolchains and published bytes,
preserves unchanged products/timestamps and retains existing compatible slices.
The configured `toolchains.swift_jobs` limit applies to SwiftPM and Xcode builds;
`DIETER_SWIFT_JOBS` may select an explicit limit from 1 to 64.
Portable iOS tests use `apps/mac/.build/dieter-ios-policy` and the small policy
graph selected by `DIETER_SWIFT_TEST_SCOPE=ios-policy`. It compiles production
attachment/scroll policies, real Kotlin rules and protobuf messages without the
Mac app, WebRTC or gRPC transport. The full Mac package graph is unchanged.
Framework requests select only their needed `macos`, `ios-simulator` or `ios-device`
slice; existing compatible slices are retained. Bundler's `vendor/bundle` is not a
Go vendor directory; the pipeline supplies module flags locally and in CI without
changing the operator's environment.

Local Android Release builds require `signing.android-release.keystore_file`
and its three environment references, or the canonical signing environment
provided by the candidate workflow. Missing credentials fail before Gradle.
iOS local builds honor `configuration:debug|release` for simulator test products;
signed device archives and Apple distribution credentials belong to the trusted
candidate workflow.

```sh
just pipeline framework configuration:debug platforms:ios-simulator
just pipeline mac local action:status
just pipeline mac local action:run
just pipeline mac local action:quit
just pipeline mac local action:format
just pipeline mac local action:format_check
just pipeline mac local action:proto_check
just pipeline android local action:status profile:android-device
just pipeline android local action:install profile:android-device
just pipeline android local action:launch profile:android-device
just pipeline android local action:screenshot profile:android-device
just pipeline android local action:ui_dump profile:android-device
just pipeline android local action:app_stop profile:android-device
just proto
```

Local install/launch commands target the development app and retain its data.
Tests use separate fixture apps. Never restart, replace or install over the
operator daemon. Mac builds and tests refuse a running DieterMac; local `run`
activates one existing canonical process without rebuilding. Shared build,
desktop, signing and exact-device leases reject contention with the owner's PID.
Never delete locks or use broad process kills to bypass them.

## Native end-to-end tests

```sh
just pipeline catalog action:lint
just pipeline catalog action:plan platform:android suite:functional changed:true base:main
just pipeline android e2e profile:android-emulator suite:smoke
just pipeline android e2e profile:android-device suite:functional
just pipeline android e2e cases:machines.telemetry
just pipeline android e2e suite:sync
just pipeline android e2e suite:sdk
just pipeline android e2e suite:performance
just pipeline android e2e suite:screens
just pipeline ios e2e profile:ios-iphone suite:functional
just pipeline ios e2e profile:ios-ipad suite:functional
just pipeline ios_qualify profiles:ios-iphone,ios-ipad suite:functional
just pipeline ios e2e profile:ios-device cases:ios.remote-node
just pipeline ios e2e profile:ios-iphone cases:ios.share-owned-file
just pipeline mac e2e suite:functional
just pipeline mac e2e cases:mac.navigation,mac.sidebar
just pipeline ios prepare_tests profile:ios-iphone suite:smoke
just pipeline check component:mac operation:screens_native_test
just pipeline check component:mac operation:screens_test
just pipeline check component:mac operation:screens_hevc_test
```

The [existing catalog](../tests/e2e/README.md) and its native assertions remain
authoritative. One shared stage loop plans, admits, prepares, executes, qualifies
and cleans up. Adapters own platform tools; they do not implement another test
loop. Every case gets fresh private client/daemon/gateway state. Exact native
methods and phase assertions must pass once; missing, skipped, duplicate,
failed, interrupted, unavailable and failed-cleanup results fail required gates.
Changed-only selections with no affected cases report `not-required` explicitly.

`ios_qualify` prepares one `DieterIOSE2E` simulator build and verifies source inputs,
Xcode identity, configuration and full product hashes before each layout. Both
layouts execute on the same worker with fresh simulators and per-case state. The
parent holds the build lease while child runs clean up their own resources. Test
assertion failures still qualify the other layout; interruption or cleanup failure
stops the group. Phones use `ios e2e` with existing development signing; simulator
products cannot be reused on physical devices.

Evidence is printed as `tmp/app-pipelines/UUID`: plan, stage events, JSON/JUnit,
native result trees, sanitized logs, screenshots and cleanup results. `output:PATH`
must select a fresh directory. Private credentials, xctestrun launch environments
and raw credential-bearing results are removed on successful cleanup. Preserve
failed ownership journals and diagnostics until recovery is understood.

The emulator uses normal `default_boot` loading and saving with `-gpu host`.
No cold boot, wipe, headless, software-renderer or `-no-snapshot-save` shortcut is
allowed. Before use it checks exact AVD identity, external-volume space, boot,
renderer, focused launcher, XML and PNG. A run closes only its own emulator,
saves a healthy snapshot and verifies that the serial/process disappear. It
leaves borrowed emulators and phones running. Performance requires the separate
non-debuggable fixture APK and clean measurements; Android screen cases require
a macOS capture host. Hardware availability is an explicit gate.

## Specialized screen measurements

`just pipeline screens_qualify manifest:docs/screenshare-qualification-local.json
profile:android-device output:tmp/screen-qualification-UNIQUE` composes the same
Mac and Android adapters for the tracked measurement/recovery matrix. Physical
Android uses the configured exact profile; no arbitrary commands or environment
hooks come from the scenario file. `baseline:PATH` compares matching hardware,
scene, clock/output endpoint, 200+ samples and cadence. Required missing cells
fail, external optical/device/quality evidence stays explicitly unavailable, and
source changes during a run fail its report. This never promotes codec defaults.

## CI and release policy

CI calls the same lanes through pinned reusable workflows. `qualification.yml`
selects affected PR/main components and requires all components on scheduled and
manual full runs. Routine iOS checks run portable policies and `ios.connecting`
on both layouts; full runs retain both complete functional catalogs. Mac core/board cases remain required, with
full Mac functional qualification on scheduled and manual runs. Android
routine checks compile E2E drivers; full runs also compile the performance variant.
The Kotlin Apple job runs only its Mac-target assertions. The Mac job owns Swift
fixture integration; the iOS job owns portable iOS policies, avoiding duplicate
assertions and unnecessary all-slice assembly across the Apple jobs.
Hosted Apple qualification restores compiler/dependency state keyed by runner
architecture, pinned Xcode/JDK, component and dependency locks. Earlier compatible
revisions supply incremental state; toolchains rebuild changed inputs and framework
manifests verify source/toolchain/product hashes. Successful jobs populate the
Actions cache in their GitHub ref scope. Simulator products, test launch credentials,
fixture state and logs are excluded from the Xcode cache. Mac qualification uses
one SwiftPM scratch graph for tests and app packaging. Local/self-hosted builds
keep their existing paths. Release producers do not restore qualification caches.
The first cache fill is still cold; cache transfer has a measurable cost and these
changes alone do not promise a ten-minute complete functional catalog.
`native-e2e.yml` selects the explicit
hardware matrix; Android and Mac desktop hardware runs need registered runners.
No untrusted PR runs on an owned physical device.

Main CI calls reusable `release.yml` after qualification; Release does not repeat
those checks. Manual Release dispatch performs full qualification first. Main
runs survive newer revisions; superseded PR runs are canceled. The aggregate
branch-protection check is **Qualification / Required checks**; update an existing
rule naming retired reporter jobs when adopting these workflows.

Build/test output streams with redaction and stream identity. Runs retain elapsed
heartbeats, `timings.json` and per-case setup/execution/cleanup evidence. CI writes
a case/target summary and uploads an explicit diagnostic manifest: 64 MiB total;
logs 4 MiB, JSON/XML 1 MiB, images 8 MiB and failure videos 16 MiB per file. Omissions
are recorded. Passing iOS cases do not export bulk attachments. Diagnostics exclude
archives, app bundles, caches and producer copies. Diagnostic upload outages do
not rerun passed gates. Evidence collection, required assertions, cleanup and
immutable producer retention remain mandatory. Producer checkpoints avoid extra
compression of signed archives.

Unsigned Android variant checks on disposable hosted runners retain bounded
Gradle thread/heap and host resource diagnostics after five minutes without new
build output. They keep the same build deadline and failure gate. Local and
self-hosted runs never inspect operator JVMs.

For self-hosted main device runs only, repository variables
`DIETER_ANDROID_CI_CONFIG` and `DIETER_IOS_CI_CONFIG` may hold a bounded JSON
override for `profiles.android-device`/`profiles.ios-device`, existing
`signing.ios-development`, and TLS fixture routes. All schema checks still apply.
They cannot change defaults, toolchains, release policy or distribution signing.
Runner labels are `dieter-android` (Linux for physical Android suites;
macOS for the visible Android emulator and every Android screen suite),
`dieter-ios` (macOS), and `dieter-mac` (macOS). The Android macOS runner needs the
configured Pixel AVD, host GLES and, for screens, capture/input permissions.
Register/configure runners before dispatching those cells. Self-hosted runners
must use Actions runner 2.327.1 or newer for the pinned Node 24 actions.

Every push to main reserves one numeric SemVer and monotonically increasing
native build counter before producing candidates. All gateway, daemon/CLI and
native clients use that same SemVer. Main publishes **dev** GitHub prereleases;
manual release dispatch may retain a draft. Dev does not change GitHub Latest,
Homebrew, stable updater channels, or production services.

Android uses the raw integer counter. Apple encodes the same counter into its
valid three-component build number: 1 → `1.0.0`, 10,000 → `1.99.99`, 10,001 →
`2.0.0`, 413 → `1.4.12`; maximum 99,990,000 → `9999.99.99`. The canonical app
release version is unchanged by this platform-specific build encoding.

Nine required candidates cover daemon Linux amd64/arm64 and Darwin arm64,
gateway Linux amd64/arm64 and signed OCI deployment, Android, Mac and iOS.
Build/sign/package/verification happens once per reservation. A 90-day immutable
producer checkpoint precedes release asset uploads. Reruns recover those bytes;
an unrecoverable partially consumed identity fails instead of rebuilding.
Producer startup is recorded before building; a stopped producer without a
recoverable checkpoint requires a new source revision.
Assembly signs the exact candidate hashes. Numeric OCI aliases refuse a
conflicting existing digest. Floating stable aliases are never advanced on main.

GitHub publication invokes TestFlight distribution explicitly because a release
created with `GITHUB_TOKEN` does not trigger another workflow. The release-event
and manual TestFlight workflows use the same idempotent destination: download
the exact retained IPA, check its hash and identity, reconcile upload/processing,
and confirm real internal group membership. Accepted/uncertain uploads retain
receipts and are not blindly uploaded again. One existing internal group may be
inferred; multiple groups require tracked selection in `release-policy.json`.

`release-promote.yml` is a separate protected `stable-release` operation. It
verifies signed retained qualification, live TestFlight readiness and delivery,
updates the Homebrew tap, signs a promotion receipt and advances Latest without
rebuilding. Configure GitHub environment reviewers/branch restrictions before
using it. Main never dispatches production activation; the existing restricted
gateway controller remains responsible for backups, deployment, authenticated
readiness and rollback. Protected `gateway-deploy.yml` prepares only a promoted
stable candidate, verifies its signed promotion and gateway digests, pins its
retention and retains an operator-admission plan. It does not activate services.

```sh
# Trusted CI/manual release workflows provide GH_TOKEN and destination secrets.
just pipeline release action:verify tag:v0.4.413
just pipeline release action:distribute tag:v0.4.413
just pipeline release action:pin tag:v0.4.413
```

Retention prunes only completed, unpinned, expired dev releases according to the
tracked policy. Stable/promoted and pinned releases survive. Distribution
receipts, pending claims and uncertain uploads prevent unsafe pruning. Keep
release mutations inside the declared workflows; signing credentials belong to
the destination jobs that need them, and logs redact supplied credential bytes.
