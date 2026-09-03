---
name: android-emulator
description: Operate Dieter's native Android app in the visible local emulator from end to end. Use for Android app development, building or installing the debug APK, launching the Pixel_9_API_37_1 AVD, inspecting or clicking through live UI, collecting screenshots and UI hierarchy evidence, running unit or instrumentation tests, diagnosing ADB, boot, rendering, connection, crash, ANR, or process-leak failures, and gracefully closing the app or emulator.
---

# Operate the Dieter Android emulator

Run the repository's `just android` commands from the repository root. Reuse
one healthy visible `Pixel_9_API_37_1` AVD, interact from observed UI state,
preserve app data, and close the emulator when the task owns its lifecycle.

## Preserve the environment

The Android Just module selects Android Studio's JBR, the SDK-local ADB and
emulator, `emulator-5554`, and `Pixel_9_API_37_1`. Override only with
`JAVA_HOME`, `ANDROID_HOME` or `ANDROID_SDK_ROOT`, `ANDROID_SERIAL`, and
`DIETER_ANDROID_AVD` when the task requires it.

```sh
just android doctor
just android emulator-status
```

Inspect the existing ADB device and QEMU tree before launch. Reuse one healthy
AVD; never start a second one for routine testing. A large process tree can be
normal threads and helper processes, but growing `<defunct>` children indicate
a failed emulator lifecycle. Stop retries before exhausting host process slots.

Never add cold-boot, wipe-data, no-snapshot, software-GPU, or headless flags.
Do not delete snapshots, userdata, Gradle caches, or app data during routine
diagnosis.

Use the confirmed `just android gradle-stop` only when a diagnosed Gradle
daemon problem warrants stopping shared build workers. Regenerate fallback
brand assets with `just android sync-brand`.

## Start and validate the visible AVD

```sh
just android emulator-start
```

The recipe reuses the selected AVD when present or starts its normal visible
configuration. Before a new process starts, it requires at least 6 GiB of
reclaimable host memory, including headroom above the emulator's 5 GiB cutoff,
so the emulator will not select software GL while it initializes. It then
waits at most three minutes and requires completed boot, stopped boot animation,
a host renderer, a focused window, a valid UI hierarchy, and a full PNG
screenshot. Logs and the health capture go under
`apps/android/build/emulator`.

Do not install while ADB is offline or boot remains incomplete. Reject software
rendering, snapshot load errors, bad color-buffer errors, an absent focused
window, a null hierarchy, or a corrupt screenshot.

Recent emulator builds may report `lavapipe` or `llvmpipe` for a separate
Vulkan compatibility path even when GLES correctly uses the Apple GPU. Judge
the UI renderer by `gles_mode_selected:host` in the launch log and the `GLES:`
line from `SurfaceFlinger`; do not reject host GLES based only on the Vulkan
device line.

## Build, install, and launch

```sh
just android test
just android build
just android install
just android launch
```

Installation retains device-bound credentials and app data. Never use
`adb uninstall` as a build workaround. The app connects through the configured
gateway and authenticated routes; do not add `adb reverse`, expose the raw
daemon loopback service, start a fixture server, replace the operator's daemon,
or edit `DIETER_HOME`.

Release CI uses the module's `install-sdk`, `restore-release-keystore`,
`build-release`, `package-release`, and `verify-release` recipes. Keystore
restoration is CI-only and writes only to the runner's temporary directory.

## Observe and interact

Capture both semantic and visual evidence before and after each interaction:

```sh
ANDROID_EVIDENCE="$(mktemp -d /tmp/dieter-android.XXXXXX)"
just android ui-dump "$ANDROID_EVIDENCE/ui.xml"
just android screenshot "$ANDROID_EVIDENCE/screen.png"
```

Inspect the XML and PNG. Locate controls by visible text, content description,
resource ID, test semantics, and current bounds. Derive a tap or swipe from the
current hierarchy, then dump and inspect again. A dispatched gesture is not
proof of its result. Avoid reusable coordinate scripts.

Prefer read-only journeys through Spaces, projects, boards, Chats, Schedules,
Terminal, and Settings. Do not send messages, start cards, close daemon
terminals, alter schedules, archive data, or change settings without
authorization.

## Run instrumentation deliberately

```sh
just android connected-test
just android connected-test com.dbpprt.dieter.SomeTest
```

Inspect instrumentation before running it because it uses the configured real
gateway. Use a class filter while iterating and the complete connected suite
only when the requested confidence warrants it. Protect user data from test
setup and cleanup.

## Diagnose boundedly

Capture the failing screenshot and hierarchy first, then inspect process-scoped
logs:

```sh
just android logs
```

For a crash or ANR, inspect `dumpsys activity activities`, crash-buffer logcat,
`dumpsys activity lastanr`, and app `meminfo`. For install failures, rerun
`just android install` with the Gradle stack trace only if needed and inspect
`pm path` plus package version/install timestamps.

For ADB offline or protocol faults:

1. Stop automated retries.
2. Run one SDK-local `adb reconnect offline` and recheck state.
3. Inspect the owner of TCP 5037.
4. Restart ADB only after accounting for all attached devices.
5. Recycle the emulator once graceful shutdown is safe.

For snapshot, focus, rendering, or accessibility failure, read
`apps/android/agents.md` before repair. Quarantine exact snapshot and lock paths
instead of deleting them, preserve userdata, require 10 GiB free, and accept a
repair only after a normal host-GLES launch, healthy saved snapshot, normal
reload, UI dump, and screenshot. Do not improvise a cold boot.

## Close cleanly

Stop only the app while retaining the AVD:

```sh
just android app-stop
```

Close the AVD when the task launched it, the user asks, or health requires a
recycle:

```sh
just android emulator-stop
just android emulator-status
```

The stop recipe verifies the selected AVD identity, uses `adb emu kill`, and
waits for the serial to disappear so snapshot saving can finish. Never send
`SIGKILL` during normal close. If graceful shutdown is unsafe, preserve
diagnostics and ask before risking the snapshot.

Report the AVD and serial, build/install results, observed journey, evidence
paths, mutations, diagnostics, and whether the app/emulator was reused, left
healthy, or closed.

After retaining any evidence needed for the report, the confirmed
`just android clean-evidence` removes only disposable Android UI/emulator
captures and the legacy jump-to-latest evidence directory.
