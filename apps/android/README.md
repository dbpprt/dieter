# Dieter for Android

A Material 3 shell hosting [the shared Compose UI](../core/mobile/README.md),
which the iOS app also uses. Like every Dieter client, it is a presentation-only
client of [the shared Kotlin core](../core/README.md): the core owns sessions,
authenticated routing, synchronization, the outbox, commands and rules. Put
domain behavior in the core, screens in `apps/core/mobile`, and Android
platform mechanics here. No daemon runs on the phone.

## What lives here

The Gradle build has its own wrapper, includes `../core` from source and imports
the core's version catalog as `coreLibs`. The app module depends on the
`:mobile` project. Kotlin sources are in
`app/src/main/kotlin/com/dbpprt/dieter`:

- `MainActivity`: the single Activity, edge-to-edge window, OAuth callback and
  update dialog.
- `DieterSession`: an `AndroidViewModel` that owns the core runtime, the shared
  `MobileStore`, preferences and screen media across Activity recreation.
- `data/DieterCredentialStore`: session tokens encrypted with a device-bound
  Android Keystore key, keyed by gateway origin.
- `sharedcore/ControlRTCBridge`: the WebRTC control channel the core routes
  requests over.
- `screens/` and `ComposeScreenSurface`: WebRTC/MediaCodec screen media, the
  GPU canvas, IME input and the clipboard provider. The decoder adapter in
  `app/src/main/java/org/webrtc` is described in [webrtc-adapter.md](webrtc-adapter.md).
- `update/`: the sideload updater.

The Termux terminal view and attachment helpers live in the shared module's
`androidMain`.

## Development

Use [Fastlane pipelines](../../fastlane/README.md) from the repository root.
Prepare the shared tools with mise, and install Android Studio and the Android
SDK (platform 37.1, build-tools 37.0.0). The pipeline uses mise's `JAVA_HOME`
and falls back to Android Studio's JBR.

```sh
mise exec -- just pipeline config_init
mise exec -- just pipeline doctor
mise exec -- just pipeline core_test          # core and shared UI JVM tests
mise exec -- just pipeline android test_unit  # Android lint
mise exec -- just pipeline android build      # configuration:release for a signed APK
mise exec -- just pipeline ci action:check component:android
```

The component check runs lint, the debug build and compilation of the `e2e`
app and journey test APKs; it does not start a device. Debug output is
`app/build/outputs/apk/debug/app-debug.apk`; build manifests are printed under
`tmp/app-pipelines/UUID`.

Build types are `debug`, `release` and `e2e`. The `e2e` type uses the
`com.dbpprt.dieter.e2e` application ID so journeys never touch the operator's
app or session.

## Emulator and physical devices

The default profile selects headless `Dieter_AOSP_API_35` at `emulator-5554`,
automatic rendering and no snapshots. Its emulator, image and userdata live in
ignored `.android/`. Fastlane creates a missing AVD from the installed API 35
image, borrows healthy running emulators, and closes only its own processes,
including failed boots. It preserves existing AVDs and userdata. Use
`android local action:emulator_run` as a registered background process to keep
an emulator warm for repeated tests and manual operations; run
`android local action:emulator_stop` after borrowers finish. Set
`visible: true` for a window. Read the canonical
[Fastlane configuration/lifecycle guide](../../fastlane/README.md).

```sh
mise exec -- just pipeline android local action:status
mise exec -- just pipeline android local action:emulator_setup # once: project-local runtime/image
mise exec -- just pipeline android local action:emulator_check
mise exec -- just pipeline android e2e profile:android-emulator
```

`android e2e` runs the catalog cases `android.journey` and `android.share`
(`JourneyTest` in `app/src/androidTest`). It installs the `e2e` app and its test APK, starts a
disposable authenticated gateway, enrolled daemon and mock harness, and walks
Inbox, Projects, a board, task creation with live replies, Review, Chats,
Tools, Machines, Files, Schedules and dark appearance. The fixture offers WebRTC
control channels like production, so the app reaches it over that route. The
Activity is recreated before submitting the task and before the follow-up.
`android.share` sends text and a screenshot to the app as
another app's share would, and checks that they prefill one new task that
survives recreation and starts a conversation with the attachment. Screenshots
and the instrumentation log are retained in the printed evidence directory.

Set the exact ADB serial and enable `android-device` in ignored
`fastlane/local.json`, then pass `profile:android-device` explicitly. A physical
phone is never auto-selected, rebooted or wiped. Device/build leases prevent
concurrent installation/reset of the same target.

```sh
mise exec -- just pipeline android e2e profile:android-device
mise exec -- just pipeline android local action:install profile:android-device
mise exec -- just pipeline android local action:launch profile:android-device
mise exec -- just pipeline android local action:screenshot profile:android-device
mise exec -- just pipeline android local action:ui_dump profile:android-device
mise exec -- just pipeline android local action:app_stop profile:android-device
```

Local install/launch operations use the development app (`com.dbpprt.dieter`)
and retain its data. Screenshot and hierarchy evidence go to the printed fresh
directory. Skipped, missing, unavailable and failed assertions or cleanup fail
qualification.

## Identity, sign-in and updates

The application ID is `com.dbpprt.dieter` (Android 8+). Releases are signed
with the existing release keystore and published as `Dieter-Android.apk`, so
installs of earlier releases upgrade in place. The core keeps its preferences
(`dieter_core`), state directory (`core` under no-backup files) and credential
store, so saved sessions carry over.

Sign-in opens the gateway's sign-in page in the browser and returns through
`dieter-android://oauth/callback`. Debug builds also accept an isolated fixture
session for journeys; release builds do not.

Release builds check the latest public GitHub release when the app starts. When
it is newer, the app downloads `Dieter-Android.apk`, verifies the SHA-256 digest
GitHub publishes for that asset, and hands it to the system installer
(`REQUEST_INSTALL_PACKAGES`); you still confirm each installation. Dev
prereleases are never offered. WebRTC's network monitor requires
`ACCESS_NETWORK_STATE`.

Dieter appears in the system share sheet for text and files. A share opens a
new task with the shared text as its prompt and the files attached.

The app observes the workspace only while it is open. It has no background sync
service, notifications, home-screen widgets or palette-following launcher
icons. Agents keep running on their hosts regardless.

## Distribution

Main prepares a signed APK using an explicitly supplied Android keystore and
Gradle signing configuration. Fastlane manages keystore restoration, build,
package verification and retention; Android's signing tools verify the result.
The same reserved SemVer is used by all Dieter components and the integer build
counter is the Android versionCode. Main publishes **dev** prereleases without
advancing stable updater/Latest channels. Stable promotion reuses retained bytes.

Release keys belong in protected external files or CI secrets. Never commit the
keystore or plaintext passwords; local JSON holds only file/environment references.
