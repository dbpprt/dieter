# Fastlane: native builds, device tests and releases

Fastlane runs everything that needs Xcode, Gradle, a device or signing
material. `just pipeline ARGS` (alias `just app`) runs `bundle exec fastlane
ARGS`; `just mac|ios|android ARGS` forward to the platform lanes (`just mac
build`). Go, docs and site work never need Fastlane: see the root `justfile`.

```text
fastlane/
  Fastfile             lanes: Fastlane actions + plain toolchain commands
  helpers/dieter.rb    config/profiles, versions, owned processes, leases, journals
  helpers/e2e.rb       Maestro flows, the isolated gateway fixture, results
  helpers/emulator.rb  exact-AVD borrow/own lifecycle
  helpers/swift.rb     count-guarded `swift test`
  helpers/release.rb   release identity, notes, Homebrew, retention, pkg scripts
  helpers/changes.rb   `just check-changed` (matches .github/filters.yml)
  helpers/format.rb    `just fmt` / `just lint` formatter dispatcher
  helpers/mac_ci_desktop.swift  resizes a hosted macOS runner's desktop
  test/                minitest specs (`just pipeline-test`)
  config.json          target profiles and Swift test minimums
  local.example.json   template of the ignored local.json
  release-policy.json  release line and dev retention
```

## Setup

```sh
mise install --locked      # every pinned tool, including Maestro and xcbeautify
just setup                 # + Fastlane gems (into mise's Ruby) and harness deps
just pipeline config_init  # optional: ignored fastlane/local.json (mode 0600)
```

Install Xcode 26.5+ with an iOS simulator runtime, and the Android SDK
(`ANDROID_HOME`, else `~/Library/Android/sdk`) yourself. `JAVA_HOME` comes from
mise (Temurin 21).

## Lanes

| Command                                                                                                                       | What it does                                                                                                                                     |
| ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `just pipeline framework [configuration:debug\|release] [slices:macos,ios-simulator,ios-device]`                              | Gradle links the Kotlin core; `create_xcframework` assembles `apps/apple/Frameworks/DieterCore.xcframework` (kept when its inputs are unchanged) |
| `just pipeline core_test [e2e:true]`                                                                                          | Kotlin core + shared UI JVM tests (`:core:e2e:test` against the fixture gateway)                                                                 |
| `just pipeline core_apple_test`                                                                                               | Kotlin core tests on macOS                                                                                                                       |
| `just pipeline maestro_lint`                                                                                                  | Parses every flow and subflow without a device                                                                                                   |
| `just pipeline android build [configuration:release]`                                                                         | `gradle` → `apps/kotlin/android/build/outputs/apk/…`                                                                                             |
| `just pipeline android test_unit`                                                                                             | Android lint and unit tests                                                                                                                      |
| `just pipeline ios build`                                                                                                     | `build_app`: simulator app with the E2E identity                                                                                                 |
| `just pipeline mac build [configuration:release]`                                                                             | `build_mac_app` through `apps/apple/mac/Dieter.xcodeproj` (ad-hoc signed)                                                                        |
| `just pipeline mac launch`                                                                                                    | Opens the debug `Dieter.app` (builds it unless that bundle already runs; refuses while another Dieter app runs)                                  |
| `just pipeline mac test_unit [packages:kit,native,mac] [filter:REGEX]`                                                        | `swift test` per package; fails below `swift_test_minimums`                                                                                      |
| `just pipeline mac privacy_test`                                                                                              | Packages the development privacy helper and runs its Go smoke test                                                                               |
| `just pipeline <android\|ios\|mac> e2e [tags:smoke\|full] [flows:a,b] [profile:NAME]`                                         | Maestro flows (below)                                                                                                                            |
| `just pipeline android local action:emulator_run\|emulator_stop\|emulator_check\|emulator_setup\|status\|screenshot\|ui_dump` | Emulator lifecycle and inspection                                                                                                                |

Release lanes run only in CI (`release.yml`): `version`, `server`,
`mac release`, `mac harness_runtime`, `mac daemon`, `ios release`,
`android release`, `publish`, `ios beta` (TestFlight), `promote`, `prune`.

## Profiles and safety

`config.json` names the targets; the ignored `local.json` overrides fields of
named profiles (CI ignores it). A profile with `"enabled": false` is refused.

| Profile                            | Target                                                                                                                                                          |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `android-emulator` (default)       | AVD `Dieter_AOSP_API_35` on `emulator-5554` in the project `.android/` storage; borrowed when it already runs, otherwise owned by the run (`manage-if-started`) |
| `android-ci`                       | CI only: the AVD the emulator runner action boots; always borrowed                                                                                              |
| `android-device`                   | A physical phone; needs an exact `serial` in `local.json` **and** an explicit `profile:android-device` on every run                                             |
| `ios-iphone` (default), `ios-ipad` | A disposable simulator of that device type; `runtime` defaults to the SDK's runtime                                                                             |

- Physical devices are never a default; there is no physical-iPhone E2E.
- Exclusive leases (flock in the temp directory) guard each exact device serial,
  AVD, the simulator slot, the Mac desktop and Apple/Android builds. A busy
  lease names its owner PID. Never delete a lease file to bypass it.
- Ownership journals in `tmp/e2e-cache/` record emulators and simulators a run
  started. An interrupted run's simulator is deleted on the next run only while
  its recorded identity still matches; an emulator journal whose process is gone
  and whose serial is free is dropped; anything else stops for inspection.
- Only processes a run started are signalled (their own process groups). The
  apps under test have their own identities: `com.getdieter.android.e2e`,
  `com.getdieter.ios.e2e`, and on the Mac `DieterE2E.app`
  (`com.getdieter.mac.e2e`, URL scheme `dieter-mac-e2e`), so an installed
  Dieter app, its data and its OAuth callback are never touched. The Mac flows
  focus the test window while they run.
- Missing results, failed or interrupted flows and cleanup failures fail the run.

## Device tests (Maestro)

Each `e2e` run builds the app it tests, starts one isolated gateway fixture
(`go build ./tools/fixtures/gateway`, `-e2e-fixture`, KEY=VALUE lines then
`READY`) shared by its flows, and records evidence in `tmp/pipeline/<run>/`:
`results.json`, Maestro's `junit.xml`, logs and screenshots. The fixture token
is redacted from evidence.

- **Android** compiles `:android:assembleE2e` before admitting the device, then
  borrows or boots the exact emulator, installs the E2E app (skipped when the
  installed APK has the same hash), and reaches the fixture through an owned
  `adb reverse` port.
- **iOS** creates and journals a simulator, boots it while the app builds, and
  deletes it afterwards. It defaults to Debug; pass `configuration:release`
  to exercise optimized Kotlin/Native code (as CI does), for example
  `just e2e ios flows:markdown configuration:release` for fenced-code rendering.
- **macOS** builds `DieterE2E.app` (Debug, `DIETER_E2E`); the app interprets each
  flow as a JSON plan in-process (`--e2e-flow`). Commands outside
  `launchApp tapOn assertVisible assertNotVisible inputText extendedWaitUntil
takeScreenshot pressKey` fail the lint and the flow.

Warm emulator for repeated local runs (run it as its own background process;
runs borrow it; the device lease is held only while it boots):

```sh
just pipeline android local action:emulator_run   # keeps running; Ctrl-C closes it
just pipeline android e2e flows:task
just pipeline android local action:emulator_stop  # asks the verified owner to close it
```

A software-rendered boot can leave a System UI "isn't responding" dialog; the
run refuses it. Tap **Wait** (`uiautomator dump`, then `input tap`) and
force-stop only `com.getdieter.android.e2e`. Never relax assertions.

Specialized screen and capture qualification lives with the helpers:
`native/macos/scripts/test-remote-desktop.sh` and the env-gated Swift suites.

## Versions

One SemVer for every component: `<release_line>.<counter>` (`release-policy.json`),
where the counter is the next free `v<line>.N` tag. The `version` lane reserves it
by pushing that tag (serialized by the `release-version` concurrency group).
Android's `versionCode` is the counter; Apple's `CFBundleVersion` encodes it
monotonically (1 → `1.0.0`, 413 → `1.4.12`, 10 001 → `2.0.0`). Local builds use
`<next patch>-dev.<commits>+<sha>`.

## Releases

1. `nightly.yml` (cron + dispatch, identity repository only): skips an already
   released main on schedule, runs `ci.yml` with `full: true` (every component,
   every flow, iPad), then calls `release.yml`, then `prune`.
2. `release.yml` `version` reserves the version tag. Builders run in parallel with
   `contents: read`, each in its signing domain:
   `_build-server.yml` (Linux daemon + gateway tarballs on amd64/arm64 runners,
   TURN probes), `_build-apple.yml` (environment `apple-signing`: notarized Mac
   app zip, App Store IPA, notarized darwin daemon tarball and pkg; the darwin
   harness runtime archive is built first in a job without secrets),
   `_build-android.yml` (environment `android-signing`: signed APK). Jobs with
   an environment or a write token pass `cache-scope: release` to the setup
   action, so they never restore a cache that CI wrote.
3. `publish` pushes the multi-arch gateway image (Buildx, SBOM, provenance),
   signs it with cosign, packs/signs/pushes the gateway deployment bundle,
   writes `SHA256SUMS`, signs it (`SHA256SUMS.sigstore.json`), attests every
   asset, and creates the prerelease with generated notes.
4. `testflight` (environment `apple-signing`) uploads the IPA and delivers it to
   the identity's internal TestFlight groups.
5. Stable: dispatch `release.yml` with `channel: stable` and `tag: vX.Y.Z`. In
   environment `stable-release`, `promote` verifies the cosign signature and every
   attestation, requires a `CHANGELOG.md` section for the version, updates the
   Homebrew formula and cask, and marks those exact bytes Latest. Nothing is rebuilt.

The signer of every release artifact is
`https://github.com/<repository>/.github/workflows/release.yml@refs/heads/main`.

### Operator configuration

| Environment          | Secrets                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `apple-signing`      | `MACOS_DEVELOPER_ID_CERTIFICATE_BASE64`, `MACOS_DEVELOPER_ID_CERTIFICATE_PASSWORD`, `MACOS_DEVELOPER_ID_INSTALLER_CERTIFICATE_BASE64`, `MACOS_DEVELOPER_ID_INSTALLER_CERTIFICATE_PASSWORD`, `MACOS_NOTARY_KEY_BASE64`, `MACOS_NOTARY_KEY_ID`, `MACOS_NOTARY_ISSUER_ID`, `IOS_DISTRIBUTION_CERTIFICATE_BASE64`, `IOS_DISTRIBUTION_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `IOS_SHARE_PROVISIONING_PROFILE_BASE64`, `IOS_APP_STORE_CONNECT_KEY_BASE64`, `IOS_APP_STORE_CONNECT_KEY_ID`, `IOS_APP_STORE_CONNECT_ISSUER_ID` |
| `android-signing`    | `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `stable-release`     | `HOMEBREW_TAP_TOKEN` (contents write on the identity's tap); required reviewers                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `gateway-production` | none; required reviewers                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `github-pages`       | Pages deployment                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |

Restrict every environment to the `main` branch and keep signing secrets out
of repository secrets. Branch protection requires the `ci-ok` check and a code
owner's approval of the latest push. Enable immutable releases. Bundle IDs, team, repository, tap,
registry and TestFlight groups come from `config/identity.json`.
