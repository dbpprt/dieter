# Dieter for Android

The Compose app is a presentation-only client of [the shared Kotlin core](../core/README.md).
The core owns sessions, authenticated routing, synchronization, commands and rules.
Android adapters provide Keystore credentials, WebRTC/MediaCodec, the Termux
terminal renderer, background service, notifications, widgets and the sideload updater.
Put domain behavior in the core and view mechanics here.

## Development

Use [Fastlane pipelines](../../fastlane/README.md) from the repository root.
Install Ruby from `.ruby-version`, Bundler 2.6.9, Android Studio, the Android SDK
(platform 37.1/build-tools 37.0.0), Go and Node for isolated fixtures.
The adapter discovers Android Studio's JBR when JAVA_HOME is absent or removed.

```sh
bundle install
npm --prefix internal/harness/runtime ci
just pipeline config_init
just pipeline doctor
just pipeline android test_unit
just pipeline android build
just pipeline ci action:check component:android
```

The complete component check runs JVM tests, debug build/lint and compilation of
isolated E2E and non-debuggable performance variants. Compilation is distinct from
executing device tests. Debug output is `app/build/outputs/apk/debug/app-debug.apk`;
build/evidence manifests are printed under `tmp/app-pipelines/UUID`.

## Emulator and physical devices

The default profile selects headless `Dieter_AOSP_API_35` at `emulator-5554`,
automatic rendering and no snapshots. Its emulator, image and userdata
live in ignored `.android/`. Fastlane creates a missing AVD from the installed
API 35 image, borrows healthy running emulators, and closes only its
own processes, including failed boots. It preserves existing AVDs and userdata.
Use `android local action:emulator_run` as a registered background process to
keep an emulator warm for repeated tests and manual operations; run
`android local action:emulator_stop` after
borrowers finish. Set `visible: true` for a window. Read the canonical
[Fastlane configuration/lifecycle guide](../../fastlane/README.md).

```sh
just pipeline android local action:status
just pipeline android local action:emulator_setup # once: project-local runtime/image
just pipeline android local action:emulator_check
just pipeline android e2e profile:android-emulator suite:smoke
just pipeline android e2e suite:functional
just pipeline android e2e suite:sync
just pipeline android e2e suite:sdk
just pipeline android e2e suite:performance
just pipeline android e2e suite:screens
```

Set the exact ADB serial and enable `android-device` in ignored
`fastlane/local.json`, then pass `profile:android-device` explicitly. A physical
phone is never auto-selected, rebooted or wiped. Tests use `com.dbpprt.dieter.e2e`
and fresh private app/daemon/gateway state; the operator's Dieter app is preserved.
Device/build leases prevent concurrent installation/reset of the same target.
Screens need a macOS capture host; performance needs the separate emulator APK.

```sh
just pipeline android e2e profile:android-device suite:functional
just pipeline android local action:install profile:android-device
just pipeline android local action:launch profile:android-device
just pipeline android local action:screenshot profile:android-device
just pipeline android local action:ui_dump profile:android-device
just pipeline android local action:app_stop profile:android-device
```

Local install/launch operations use the development app and retain its data.
Screenshot and hierarchy evidence go to the printed fresh directory. Native test
methods and [YAML journeys](../../tests/e2e/README.md) remain authoritative; skipped,
missing, duplicate, unavailable and failed assertions or cleanup fail qualification.

## Distribution

Main prepares a signed APK using an explicitly supplied Android keystore and
Gradle signing configuration. Fastlane manages keystore restoration, build,
package verification and retention; Android's signing tools verify the result.
The same reserved SemVer is used by all Dieter components and the integer build
counter is the Android versionCode. Main publishes **dev** prereleases without
advancing stable updater/Latest channels. Stable promotion reuses retained bytes.

Release keys belong in protected external files or CI secrets. Never commit the
keystore or plaintext passwords; local JSON holds only file/environment references.
