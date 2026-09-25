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
configuration. The AVD registry entry may point to a data directory on an
external volume. The launcher resolves that pointer, requires readable AVD
configuration and 10 GiB free on the resolved volume, and reports the path it
will use. Keep that volume mounted until a graceful emulator shutdown finishes.
If `default_boot` has deliberately been quarantined during repair, the same
recipe identifies the missing snapshot and permits exactly that normal recovery
boot from preserved userdata; it still rejects an unexpected snapshot-load
failure.

The launcher uses `-no-snapshot-save`: it still restores `default_boot`, but it
does not let an arbitrary active GPU surface overwrite that snapshot during
exit. `just android emulator-stop` returns to the launcher, stops the Dieter and
Chrome processes used by this workflow, explicitly saves `default_boot`, checks
its RAM/metadata/texture artifacts and save log, and then closes the emulator.

The 6 GiB `vm_stat` memory estimate is advisory, not a test prohibition.
The recipe explicitly selects `-gpu host` on the supported Apple GPU: emulator
37.1's `auto` mode otherwise silently switches to software rendering below its
5 GiB estimate even when hardware rendering works. Do not kill unrelated apps
to satisfy that estimate. Check the actual renderer and Android responsiveness.
A renderer change can invalidate an older snapshot; preserve it in quarantine
and follow the recovery cycle below without wiping userdata. The
launcher then waits at most three minutes and requires completed boot, stopped
boot animation, a host renderer, an unlocked launcher window, a launcher-owned
UI hierarchy, and a full PNG screenshot. Logs and the health capture go under
`apps/android/build/emulator`.

Do not install while ADB is offline or boot remains incomplete. Reject software
rendering, snapshot load errors, bad color-buffer errors, an absent focused
window, a null hierarchy, or a corrupt screenshot.

Emulator 37.1 on API 37 may report `lavapipe` for its Vulkan compatibility path
and an ANGLE/SwiftShader-backed `GLES:` line from the guest `SurfaceFlinger`
even when emulator GLES correctly uses the Apple GPU. Judge host acceleration
by the latest `gles_mode_selected:host` and `OpenGL ES Translator (Apple ...)`
lines in the emulator launch log. Use `SurfaceFlinger` only as a guest-renderer
responsiveness check; do not treat its API 37 ANGLE string as the emulator's
host GLES selection.

## Build, install, and launch

```sh
just android test
just android build
just android install
just android launch
```

Installation and connected tests retain device-bound credentials and app data.
`gradle.properties` pins `android.injected.androidTest.leaveApksInstalledAfterRun=true`
and disables uninstalling incompatible APKs; do not override these safeguards. Never use
`adb uninstall` as a build workaround. The app connects through the configured
gateway and authenticated routes. Never expose or replace the operator's raw
loopback service or edit `DIETER_HOME`. Isolated integration fixtures are allowed
and preferred for input, transport, and lifecycle tests. `just e2e run` uses the separate `com.dbpprt.dieter.e2e` application with
fresh app data per case and disposable authenticated fixtures. It refuses an
already-running fixture package and holds a shared serial lease. The operator's
normal app is not replaced or stopped. Temporary ADB reverses expose only the
fixture's random authenticated port and are removed on exit.

`just e2e run --suite screens` requires a macOS capture host. The default uses
native synthetic video and hardware H.264 with dry-run input. Set
`DIETER_SCREEN_TEST_SOURCE=screen` for real capture and input into the owned
input target. Mac companion execution is disabled; iOS supports preparation
only. Unavailable prerequisites fail required cases and are never green skips.

The install recipe and E2E runner select `ANDROID_SERIAL=emulator-5554` by
default. Keep an explicit serial on every Gradle task which can select a device; otherwise
Gradle may silently choose an attached physical phone even when every separate
ADB command is correctly pinned.

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
just e2e lint
just e2e plan --suite functional --changed
just e2e run --suite smoke
just e2e run --case machines.telemetry
just e2e run --suite functional
just e2e run --suite sync
just e2e run --suite performance
```

Read `tests/e2e/README.md` for the catalog and driver contract. All ordinary
journeys are YAML; native component, codec, sync, and performance assertions
remain native tests with exact methods listed in the catalog. Legacy Android
Just test recipes only delegate here. Do not add another script launcher.

The runner builds/installs once per variant, verifies APK hashes for warm reuse,
starts fresh fixture/app state per case, and writes JSON/JUnit plus screenshots
and semantic step evidence under `tmp/e2e-<run>`. Missing, skipped, duplicate,
interrupted, and failed native methods fail qualification, as does failed cleanup.

Sync retains the real live/background, queue, offline, and idle-sampling checks.
Performance is explicit, emulator-only, and uses a separate non-debuggable
`com.dbpprt.dieter.e2e.performance` app. Never substitute debug timings for frame
qualification. Physical-device energy/display checks remain separate. Set
`arguments: {dieterPerformanceFrames: "true"}` in the performance case for
bounded frame diagnostics; keep tracing separate from clean measurements.

Inspect new catalog cases before running them. Fixtures and probes must remain
isolated from the operator's account and daemon. Full functional runs no longer
implicitly launch performance or Mac-host screen qualification.

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

If startup stops before QEMU or ADB appears, inspect the new section of the
emulator log and verify that the resolved AVD `config.ini` can be read promptly.
For an external AVD, a mounted but stalled volume can block the emulator before
it emits a useful error. Stop the single launcher attempt, leave userdata and
snapshots untouched, restore volume responsiveness, and retry once. Do not
create a replacement AVD on the internal disk as a shortcut.

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

The stop recipe verifies the selected AVD identity, explicitly saves and
validates `default_boot`, uses `adb emu kill`, and waits for both the serial and
QEMU process to disappear. Never send `SIGKILL` during normal close. If
graceful shutdown is unsafe, preserve diagnostics and ask before risking the
snapshot.

Report the AVD and serial, build/install results, observed journey, evidence
paths, mutations, diagnostics, and whether the app/emulator was reused, left
healthy, or closed.

After retaining any evidence needed for the report, the confirmed
`just android clean-evidence` removes only disposable Android UI/emulator
captures and the legacy jump-to-latest evidence directory.
