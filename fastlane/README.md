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

Assertions stay in Compose/XCTest/Swift/Go tests. The catalog provides shared
selection and results, rather than replacing native tests with another language.
Shared core behavior is tested below the UI; device journeys qualify native
presentation and platform bindings.

## Setup and machine configuration

Install [mise](https://mise.jdx.dev/getting-started.html) 2026.10.2+ on macOS or
Linux. The root [mise.toml](../mise.toml) and [mise.lock](../mise.lock) provide
Ruby, Bundler, Go, Node, Python, Temurin Java 21, just, protoc, Hugo extended,
and ripgrep. Ruby reads `.ruby-version`; Go reads `go.mod`. The lockfile records
resolved versions and downloads for macOS/Linux on x86_64 and arm64.

From the repository root:

```sh
mise trust
mise install --locked
mise run setup              # bundle install and npm ci; no app builds
mise exec -- just hooks     # prepare this worktree's commit tools
mise exec -- just pipeline config_init
mise exec -- just pipeline doctor
```

`mise run setup` installs the locked project gems into ignored `tmp/bundle`
and the harness npm dependencies. A top-level `vendor/` would make plain `go`
commands assume a vendored module, so local gems stay under `tmp/`; delete a
`vendor/bundle` left by an earlier setup. It does not configure devices or run tests.
Use `mise exec -- just ...` for agent/noninteractive commands so they receive the
managed tools and `JAVA_HOME`. For ordinary terminal use, activate mise in your
shell as described in its installation guide, then use the existing `just`
commands directly. A bare shim does not export `JAVA_HOME` to its parent shell.

Mise manages these command-line tools. Install Xcode, Android Studio/SDKs,
simulator runtimes, Docker, and operating-system libraries separately for your
component. Gradle uses the checked-in wrappers; Kotlin dependencies remain in
their catalogs. Formatters remain owned by `just hooks`. CI keeps its existing
setup actions.

Gateway `deployment_integration` builds `Dockerfile.gateway` and runs the
gateway transports in containers. `just check-changed` selects it for
`deploy/gateway/`, `Dockerfile.gateway` and `tools/fixtures/turn-probe/`
changes; it needs a running Docker engine with Buildx (Docker Desktop, OrbStack
or colima). colima switches the Docker context when it starts: after
`colima stop`, restore the previous context with `docker context use`.

Keep machine-specific mise overrides in ignored `mise.local.toml`. The example
template leaves `toolchains.java_home` null, so the pipeline inherits mise's
`JAVA_HOME` (Temurin 21, as in CI) and falls back to Android Studio's bundled JBR
when none is set. Do not configure a Java path alongside mise's JDK: a differing
configured path fails with "JAVA_HOME conflicts with local configuration". Other
native paths and target identities remain in `fastlane/local.json`.

To update managed tools, review `mise.toml` and run `mise lock --bump`. Commit the
reviewed lockfile; update `.ruby-version` or `go.mod` for their language pins.
`mise install --locked` fails if its lockfile needs changes rather than silently
selecting new versions. Bundler's pin matches `Gemfile.lock`; just/protoc/Hugo pins
match existing CI setup. Node, Python, and Java resolve within their declared
major/minor series and remain fixed by the lockfile until deliberately updated.

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

| Profile                         | Target and ownership                                                                                                                                                                    |
| ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `android-emulator`              | Project-local `.android/` AOSP `Dieter_AOSP_API_35`, serial `emulator-5554`, headless automatic rendering, no snapshots; borrow a healthy running AVD or manage one launched by the run |
| `android-device`                | Disabled until an exact ADB serial is configured; phone lifecycle remains with its owner                                                                                                |
| `ios-iphone`, `ios-ipad`        | Exact runtime and device type; create and delete a recorded disposable simulator                                                                                                        |
| `ios-device`                    | Disabled until exact UDID, existing development signing and authenticated TLS fixture route are configured                                                                              |
| `mac-desktop`                   | Exclusive packaged test app on a logged-in desktop                                                                                                                                      |
| `daemon-local`, `gateway-local` | Native host OS and architecture; build output never installs over a running service                                                                                                     |

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

### Local commit checks

```sh
just hooks                  # prepare tools and install this worktree's hook
just format                 # format changed authored source/config/docs
just format-check           # check changed working-tree sources without writing
git add PATHS               # review and stage exactly what belongs in the commit
just pre-commit             # inspect staged bytes, including partial commits
just hooks-test             # isolated local hook qualification
```

Run `just hooks` once per checkout/worktree on Linux x86_64/arm64 or Apple Silicon
Mac (macOS 15+). It requires Python 3.11+ with venv/pip, Go, Git, Node 22+,
Ruby from `.ruby-version`, network access for setup, and normal Linux C/C++
runtime libraries. Kotlin formatting needs Java 11+; Android Studio's JBR works.
Hook setup does not require Bundler, Xcode, Homebrew, or native app builds.
Go's supported toolchain download supplies the exact formatter selected by
`go.mod`; setup puts that Go toolchain on PATH when
building the pinned Gitleaks hook.

The tool versions live in `fastlane/precommit-tools.json` and
`.pre-commit-config.yaml`. Setup verifies the ktfmt JAR and standalone Apple
swift-format Homebrew bottles by SHA-256. The lean additions are Prettier 3.9.9,
Ruff 0.16.10, Syntax Tree 6.3.0 (with prettier_print 1.2.1), and shfmt 3.14.1.
The Prettier package and Ruby gems have verified SHA-256 downloads; Ruff uses
the managed Python environment and shfmt builds through Go's module toolchain.
Everything stays under ignored `tmp/precommit/`, including isolated Ruby gems
and the upstream Gitleaks build. Existing app Node packages and Bundler gems
are untouched. The standalone Swift bottles include its runtime; a Linux Swift
toolchain is unnecessary.
Commits reuse prepared tools offline. After changing tool pins, hook configuration,
or the Go/Ruby version, run `just hooks` again. A missing required tool fails with a
setup instruction rather than downloading during a commit.

Installation sets `core.hooksPath=.githooks` in worktree-local Git configuration.
It preserves other worktrees' settings and refuses to hide custom hooks. Standard
pre-commit generated hooks can be replaced for this worktree; their shared files
remain untouched. The checked-in dispatcher uses pre-commit's no-stash invocation.
Its source checker reads staged Git objects into temporary files and uses staged
`.editorconfig`, Swift, Prettier, Ruff, and Syntax Tree configuration.
The index and working tree stay untouched.
An index change during checking fails and asks for review/retry. Working edits
made by another turn are retained. Ordinary pre-commit may conservatively reject
a commit if it observes concurrent working-file edits; it never rolls them back
through this dispatcher.

Checks cover staged authored Go, Kotlin and Swift, plus these lean additions:

| Tool        | Files and policy                                                                                                                             |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Prettier    | `.js`, `.mjs`, CSS, JSON, YAML, Markdown, plain HTML and `.webmanifest`; 100 columns, preserve prose wrapping, leave embedded examples alone |
| Ruff format | Python; 100 columns and Python 3.11 syntax target, without lint fixes                                                                        |
| Syntax Tree | Ruby, `Gemfile`, and `Fastfile`; 100 columns, formatting only                                                                                |
| shfmt       | `.sh` and the checked-in commit hook; four-space indentation and indented switch cases                                                       |

The gate also checks JSON/YAML/TOML syntax,
conflict markers, final newlines, trailing whitespace (Markdown hard breaks are
preserved), and newly added files over 5 MiB. Vendor/generated API sources,
generated Markdown bundles, imported WebRTC sources, and byte fixtures under
`testdata` are excluded from formatting/file-style checks. Gitleaks still scans
staged additions independently and redacts findings, including excluded source
paths. Symlinks and submodules are not dereferenced by the formatting checker.

`just format` changes only working files and never stages them. With partial
commits, review the result and use `git add -p` to select the intended content;
an intentionally unformatted staged version still fails even when the working
file has been formatted. `just format --all` / `just format-check --all` select
all authored working-tree sources. Existing Kotlin/Swift sources may need
mechanical formatting; this rollout enforces touched staged files and does not
perform a repository-wide rewrite. The same touched-file rollout applies to
the newly covered languages. Full-inventory formatting should be reviewed
as its own change. Hugo templates under `landingpage/layouts/`, XML/SVG,
producer-owned JSON lockfiles, and generated Gradle wrappers do not get a new
formatter. Their existing file-integrity checks remain. TOML still has syntax
validation only. These local commands do not change CI qualification.

`just hooks-test` uses disposable Git fixtures and cached real formatters and
Gitleaks. It checks failure exits, staged/live differences, concurrent edits,
unusual paths, configuration snapshots, excluded files, secret redaction, and
worktree-local hook installation. It never installs over operator Git hooks.

### Component checks

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
just pipeline android local action:emulator_setup # copy installed runtime/image into .android
just pipeline android local action:emulator_check # boot/readiness/owned cleanup
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
slice; existing compatible slices are retained. CI's Bundler cache in
`vendor/bundle` is not a Go vendor directory; the pipeline supplies module flags
locally and in CI without changing the operator's environment. Because those
flags would quietly rewrite untidy module files, Go tests first fail when
`go mod tidy -diff` reports a change.

Local Android Release builds require `signing.android-release.keystore_file`
and its three environment references, or the canonical signing environment
provided by the candidate workflow. Missing credentials fail before Gradle.
iOS local builds honor `configuration:debug|release` for simulator test products;
signed device archives and Apple distribution credentials belong to the trusted
candidate workflow. Fastlane's test action resolves an installed iOS simulator
even for a generic build-for-testing destination, so a build needs an installed
iOS simulator runtime. When no iOS simulator exists, the build creates an
unbooted `Dieter Pipeline build` simulator, records it in
`tmp/e2e-cache/ios-build-simulator.json`, and deletes it afterwards; other
simulators are only read.

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
just pipeline android prepare_tests suite:smoke # build APKs without starting a device
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
and cleans up. Android builds APKs and fixtures before device admission to avoid
compiler contention during emulator boot. Adapters own platform tools; they do not implement another test
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

Android emulator lifecycle is implemented in
[platforms/emulator.rb](lib/dieter/platforms/emulator.rb), shared by E2E and local
lanes. Install SDK command-line tools (`latest`), platform-tools, emulator 37.1+
and the full API 35 AOSP image (`system-images;android-35;default;arm64-v8a`
on Apple Silicon, `x86_64` on Intel/AMD) through Android Studio's SDK Manager.
The profile's `native` suffix resolves the host architecture. ATD images disable
UI drawing and cannot qualify our UI/capture tests.

Run this once after installing those packages:

```sh
just pipeline android local action:emulator_setup
```

The default `storage_dir: ".android"` keeps real copies of emulator binaries,
command-line tools, platform-tools and the selected image in the gitignored
project `.android/sdk/`, AVD definitions and userdata in `.android/avd/`, and
emulator preferences in `.android/user/`. Setup copies only missing packages
from the configured host SDK, under a runtime lease, with atomic package
publication. It never downloads or updates existing packages. App builds keep
using the host SDK. To refresh a project runtime, close its managed emulator,
remove the project cache, and run setup again. CI hardware runners need the same
one-time setup in their checkout; CI ignores `fastlane/local.json`.

Missing packages fail with their path and setup instruction. Test runs create a
missing selected AVD from the local `system_image` with a Pixel 2 hardware profile,
a 720p display and requested 4 GiB userdata (API 35 may increase it to 6 GiB).
Fresh boot requires at least 8 GiB free; existing userdata requires 4 GiB free.
Existing AVDs are never recreated, wiped or reconfigured. Android `prepare_tests`
only leases/builds cached APK products and needs no running emulator or phone.

The default boot disables snapshots, audio and boot animation and uses
`-no-window -gpu auto`, which selects an available backend without a foreground
window. GPU acceleration is used when available; software renderers remain
configurable for hosts without a GPU. It retains userdata and APK build/install caches.
Readiness polls exact AVD name and data directory, completed boot, stopped boot animation and
package-manager responsiveness, then wakes/unlocks the display and requires a focused guest window without a
system error dialog. The host emulator window stays hidden. No host-GPU log
or foreground window is required. `boot_timeout` bounds startup (default 180s).
Cold boots on software rendering can take about two minutes; the warm workflow
avoids that cost between test runs. `emulator-admission.json` records measured
startup and ownership; emulator
output and `cleanup.json` retain diagnostics. Owned process groups close even
when admission fails. Borrowed emulators and phones remain running.

To customize a local target, merge this named profile into ignored
`fastlane/local.json` (other signing/device settings remain as configured):

```json
{
  "profiles": {
    "android-emulator": {
      "avd": "Dieter_AOSP_API_35",
      "serial": "emulator-5554",
      "system_image": "system-images;android-35;default;native",
      "storage_dir": ".android",
      "visible": false,
      "renderer": "auto",
      "boot_timeout": 180,
      "lifecycle": "manage-if-started"
    }
  }
}
```

Existing local JSON keeps its old explicit values: update its AVD/renderer/
visibility/storage to adopt these defaults. `storage_dir` accepts `.android` or
a named project dot folder such as `.android-ci`. Set `storage_dir: null` in an
explicit profile to use the host SDK and existing `ANDROID_AVD_HOME` (or
`~/.android/avd`) registry; no existing global AVD is moved. Never change storage
while its warm controller runs: close it with its original profile first. `system_image: null` requires an existing
AVD; `lifecycle: borrow` also requires that exact emulator to be running.
`visible: true` opens a window. Renderers are `auto`, `host`, `software`,
`swiftshader`, `swangle` and `lavapipe`; use a renderer supported by your pinned
emulator. Borrowing validates the running guest without imposing launch flags.

For fast iteration, keep one warm emulator under Fastlane ownership:

```sh
# Terminal: keep this command running; Ctrl-C closes its owned emulator.
just pipeline android local action:emulator_run
# After "ready", run in another terminal:
just pipeline android e2e suite:smoke
just pipeline android local action:screenshot
just pipeline android local action:emulator_stop
```

Agents launch `emulator_run` through a registered background process, wait for
readiness, and run `android local action:emulator_stop` after tests/inspection
finish. Its AVD lease prevents duplicate launches while its device lease is
released after startup so sequential tests can borrow it without rebooting. Tests hold the
exact-device lease. Use `emulator_stop` only after borrowers finish; it holds the
exact-device lease, verifies the journal/controller identity, requests graceful
cleanup and waits for the journal and serial to disappear. Collect the registered
owner result.
The process Stop button force-kills jobs; use the Fastlane stop lane for cleanup.
Running `emulator_check` without a warm owner tests boot and closure in one command.
Never manually unlink locks or signal PIDs from a retained journal: an unfinished
owner requires inspection, and only an absent process plus absent serial permits stale
journal removal. A live warm owner's verified journal permits borrowing.

Software-rendered boots can leave a System UI "isn't responding" dialog that
steals test focus. Between runs on a warm emulator, tap **Wait** (for example
`adb -s emulator-5554 shell uiautomator dump`, then `input tap` on its bounds)
and force-stop only the isolated `com.dbpprt.dieter.e2e` package an interrupted
run left open. `conversation.task-capture` currently fails on the AOSP API 35
image: after "Preview screenshot.png" the attachment preview never shows "Close
preview", and the system share chooser lists the test's alternative target under
the same label and ignores taps while animating. Until it is fixed, the full
Android gate cannot pass locally; do not relax its assertions.

Performance requires the separate non-debuggable fixture APK and clean
measurements. Software rendering is suitable for functional tests; use an
explicit `renderer: host` profile when qualifying GPU-dependent performance.
Android screen cases require a macOS capture host. Required assertions,
measurements, unavailable hardware and cleanup failures still fail gates.

## Specialized screen measurements

`just pipeline check component:mac operation:privacy_native_test` verifies the
standalone macOS daemon/capture pair and separate signed `DieterPrivacyHelper.app`
with isolated state and synthetic pixels. It owns the Apple compiler lease and
does not register a privileged service or change the operator's desktop. Local
administrator approval and Input Monitoring remain required for physical input
qualification; see [macOS privacy](../native/macos-capture/privacy-mode-research.md).

`just pipeline screens_qualify manifest:PATH
profile:android-device output:tmp/screen-qualification-UNIQUE` composes the same
Mac and Android adapters for an explicit measurement/recovery manifest. Physical
Android uses the configured exact profile; no arbitrary commands or environment
hooks come from the scenario file. `baseline:PATH` compares matching hardware,
scene, clock/output endpoint, 200+ samples and cadence. Required missing cells
fail, external optical/device/quality evidence stays explicitly unavailable, and
source changes during a run fail its report. This never promotes codec defaults.

## CI and release policy

The separate Compose hosts in `apps/mobile/android` and `apps/mobile/ios` have
additional affected-change gates alongside the original apps: shared JVM
journeys, Android app/test compilation, and the iOS journey on both layouts using
one verified build. After main qualification, a separate read-only delivery job
retains the exact Debug APK and arm64 simulator app for 14 days. Compose does not
publish to TestFlight or join the shipping candidate matrix. See
[Compose CI and preview delivery](../apps/mobile/PIPELINES.md) for commands,
artifact names, qualification scope and signing limits.

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
Routine portable CI executes the typed affected check/package plan, including
reverse Go dependencies, without unrelated Go/harness/native suites. Full runs and
events with no usable change base retain complete portable qualification.
`native-e2e.yml` manually selects an iOS catalog suite and runs both iPhone and
iPad simulator profiles on one GitHub-hosted macOS worker. Android, Mac desktop,
and physical-device journeys run locally with explicit configured profiles.

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
