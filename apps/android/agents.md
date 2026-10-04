# Android agent development cycle

The Android app is presentation only: Compose UI plus thin Android adapters
(the transport's TLS providers, Keystore credentials, WebRTC/MediaCodec screen
media, the Termux renderer, notifications, widgets, the sideload updater, and
the background service).
Every rule (wording, counts, enablement, ordering, decisions, defaults, and
parsing), the client logic, and the OkHttp transport live in the shared Kotlin
core under [`apps/core`](../core/README.md), which this build includes from
source. Call the core's Kotlin domain APIs directly; the `client/rules/*Exports`
objects exist for Swift. Add or change a rule in the core with core tests, then
render it here. View mechanics (layout, animation, focus, and the conversation
scroll policy), gesture geometry, locale formatting, colours, and icons stay in
the app.

Use Fastlane for builds, local operations and isolated native tests. Read
[`fastlane/README.md`](../../fastlane/README.md) for named local profiles,
headless emulator provisioning, the warm-emulator workflow and ownership rules.
The default test AVD is separate from operator AVDs and uses no snapshots.
No Android-specific skill or manual graphics/snapshot ritual is required.

Android emulator E2E is currently flaky and is actively being worked on. Known
software-rendered startup failures can leave a System UI ANR dialog that steals
Espresso focus. Automatic headless rendering and system-error admission checks
are being qualified; preserve failed evidence and keep the native assertions.

```sh
just pipeline android local action:emulator_setup # once: project-local runtime/image
just pipeline android local action:emulator_check
just pipeline android e2e suite:smoke
```

For repeated tests or manual app inspection, run
`just pipeline android local action:emulator_run` as a registered background
process. Wait for its ready message before running local operations or tests.
Run `just pipeline android local action:emulator_stop` after borrowers finish
to close the owned emulator.
For a window, set `visible: true` in the named local emulator profile. PNG/XML
inspection works headlessly too. Preserve existing AVDs, userdata, borrowed
emulators, exact-device/build leases and the running operator daemon.

## Start and connect

1. Reuse the enrolled running daemon for authorized manual product checks.
   For integration tests, use isolated real daemons with disposable identity and
   `DIETER_HOME`; never restart or replace the operator service. Screen tests use
   `just pipeline android e2e suite:screens` and the owned native input target.
2. Confirm the emulator serial with `adb devices -l`. The usual serial is
   `emulator-5554`; pass `-s <serial>` to every command when multiple devices
   are attached.
3. Sign in to the configured gateway. The app combines shared projects from account replicas and routes execution
   requests to the conversation or checkout owner automatically.
   Never map the live raw API through `adb reverse`. A temporary reverse of an
   authenticated isolated fixture port is allowed and removed by its test script. Route
   discovery, authenticated direct probing, and relay fallback are automatic.
4. Build, install, and launch the current app:

   ```sh
   just pipeline android local action:install
   just pipeline android local action:launch
   ```

   Keep `ANDROID_SERIAL=emulator-5554` on every Gradle install or
   instrumentation task. Gradle does not inherit the serial embedded in
   separate ADB commands and can otherwise choose an attached physical phone.

The Fastlane pipeline detects Android Studio's JDK and the local SDK when the
shell environment does not already expose them.

## Reproduce and verify

Capture a semantic UI dump and screenshot before changing code, interact with
the running app, then capture the same evidence after installing the fix:

```sh
adb -s emulator-5554 shell uiautomator dump /sdcard/board-screen.xml
adb -s emulator-5554 pull /sdcard/board-screen.xml /tmp/board-screen.xml
adb -s emulator-5554 shell screencap -p /sdcard/board-screen.png
adb -s emulator-5554 pull /sdcard/board-screen.png /tmp/board-screen.png
```

Inspect the pulled PNG and use the UI dump's text, content descriptions, test
tags, and bounds to choose interactions. Do not rely on an unobserved,
hard-coded coordinate script as an end-to-end result. Verify the complete user
journey against the real local Dieter process, including the final server-backed
state, not just the presence of a composable.

For gesture-driven UI, perform the real gesture with `adb shell input swipe`,
then dump and screenshot the revealed state before tapping its action. Derive
the swipe and tap coordinates from the current UI dump so the check still
validates the visible control instead of merely replaying stale coordinates.

Use dedicated non-destructive test data when an interaction starts an agent.
Never launch an existing user's queued card merely to test the UI. Create test
cards through the app or `board` CLI, give the agent an explicitly read-only
task, and archive the test card after verification.

## Checks before handoff

`just check-changed --dry-run` lists the checks a change needs. Run the narrow
unit tests while iterating. When the change touches the shared core (a rule,
client logic, sync, the outbox, routing, or the OkHttp transport), run its JVM
unit and isolated end-to-end tests, and on macOS its native tests, because the
Mac app links the same core:

```sh
just pipeline core_test
just pipeline core_apple_test
```

Then run the Android unit suite, lint, and debug build before installing the
final APK:

```sh
just pipeline android test_unit
just pipeline ci action:check component:android
just pipeline android build
```

Run the affected device cases against disposable daemon/gateway fixtures through
the shared runner. `--changed` selects every case of the suite for a core
change. Changes to the Android connection adapters (`sharedcore/`, the
background service) also need the separate sync suite:

```sh
just pipeline android e2e suite:functional changed:true
just pipeline android e2e suite:sync
```

After reinstalling, repeat the original interaction in the selected emulator,
inspect the final screenshot, and confirm the expected Dieter state through the
app. Keep emulator screenshots and UI dumps outside the repository unless they
are intentional design references.

## Shared native test framework

Use `just pipeline android e2e` and `tests/e2e/cases/android/*.yaml` for device tests. Read
`tests/e2e/README.md`. The runner owns only `.e2e`/`.e2e.performance` test packages,
per-device leases, fixtures, reverse mappings, builds, and result collection.
Do not add bespoke orchestration scripts. `functional`, `sync`, `screens`, and
non-debuggable `performance` are separate suites. Missing/skipped tests fail.
The same runner executes Mac and iOS cases with explicit platform selection;
see `tests/e2e/README.md` for their desktop and simulator prerequisites.
