# Android agent development cycle

Use the real native app in the visible local Android emulator for every Android
change. The standard AVD is `Pixel_9_API_37_1`; reuse it when it is already
running instead of starting a headless or disposable emulator. Keep this as the
only Dieter AVD; do not create another API-level-specific AVD for routine tests.

Launch it with its checked, working graphics configuration and saved snapshot:

```sh
just android emulator-start
```

The recipe selects `-gpu host` to prevent automatic memory-based software fallback.
Do not add `-gpu swiftshader*`, `-no-snapshot-load`, `-no-snapshot`,
or cold-boot flags. Those overrides bypass the AVD's working graphics and
snapshot configuration and can leave Android system services unresponsive. If
the saved snapshot fails to load, stop and diagnose the AVD instead of silently
continuing with a cold boot. Before launching, avoid CPU starvation from stale
browser-automation sessions and confirm that another emulator is not already
running. Leave the AVD's `hw.gpu.mode` set to `auto`. Stop leftover Gradle
daemons before a snapshot repair and make enough host memory available for the
emulator's host GLES renderer:

```sh
just android gradle-stop
vm_stat
```

The launcher reports a 6 GiB reclaimable-memory estimate as advice. It must not
block testing solely on that estimate: emulator auto-selection can choose
software GL unnecessarily below 5 GiB. The supported Apple GPU is selected
explicitly, and renderer, boot, focus, UI hierarchy and screenshot checks decide
whether it is usable. Never kill unrelated operator apps to free memory or
reduce the guest below the API image's supported RAM minimum.

The AVD registry entry under `~/.android/avd` may point to its data directory on
an external APFS volume. Resolve the `path=` value instead of assuming userdata
is on the internal disk. Free-space checks, snapshot diagnosis, and lock-file
inspection apply to that resolved volume. Keep it mounted through graceful
shutdown and snapshot saving. If ordinary reads of its `config.ini` stall, stop
the launcher attempt and restore volume responsiveness before retrying; do not
copy, recreate, or cold-boot the AVD on another volume as a workaround.

The startup log must report `gles_mode_selected:host` and identify the Apple
GPU. If it instead says that software GL will be used due to system memory
pressure, free memory and restart the emulator before using or saving its
state. Emulator 37.1 on API 37 can still select `lavapipe` for its separate
Vulkan compatibility path, while the guest `SurfaceFlinger` reports an
ANGLE/SwiftShader `GLES:` string. Treat the latest `gles_mode_selected:host`
and `OpenGL ES Translator (Apple ...)` launch-log lines as authoritative; use
the `SurfaceFlinger` dump only to prove guest renderer responsiveness. A launch
whose selected emulator GLES mode is `swangle` remains unhealthy.

Never stop or snapshot the emulator while ADB is offline, boot animation is
running, or Android has no focused window. The launcher uses
`-no-snapshot-save`; the stop recipe returns to the launcher, stops the Dieter
and Chrome processes used by this workflow, explicitly saves `default_boot`,
checks its required artifacts and save log, and only then closes the emulator.
Stopping an incomplete fallback boot can still replace a missing snapshot with
a corrupt one. The start and stop recipes wake and dismiss the keyguard before
requiring the real launcher; a wallpaper-only or black health image is not an
acceptable focused state. Before a deliberate shutdown require all of the
following:

```sh
adb -s emulator-5554 shell getprop sys.boot_completed        # 1
adb -s emulator-5554 shell getprop init.svc.bootanim          # stopped
adb -s emulator-5554 shell dumpsys window | rg 'mCurrentFocus|mFocusedApp'
adb -s emulator-5554 shell uiautomator dump /sdcard/avd-health.xml
adb -s emulator-5554 shell screencap -p /sdcard/avd-health.png
```

`mCurrentFocus` must name a real window rather than `null`, the UI dump must
complete without a null-root error, and the screenshot must be a valid full-size
PNG. Also reject a boot if emulator output contains `Failed to find
ColorBuffer`, `bad color buffer handle`, or snapshot restore errors. Keep the
healthy emulator running between test passes when practical.

## Recover a missing or corrupt snapshot

Snapshot repair is exceptional maintenance, not a routine test launch. Confirm
that no emulator process or ADB device remains and that the data volume has at
least 10 GiB free after quarantining the old snapshot. Quarantine, rather than
immediately delete, only the broken `snapshots/default_boot` directory and
stale `hardware-qemu.ini.lock` or `multiinstance.lock` files. Preserve the AVD
userdata images. If retaining a known-bad quarantine would leave insufficient
working space, it may be deleted only after confirming its replacement is not
needed for user-data recovery.

Launch once with the standard command above and no override flags. Because the
bad snapshot has been quarantined, the launcher identifies the missing
`default_boot` and this one recovery launch intentionally boots from preserved
userdata. Let it reach every health condition above; do not interrupt the
fallback boot. Once Android is responsive and screenshots plus accessibility
work, shut it down gracefully with `just android emulator-stop` and wait for
snapshot saving and the emulator process to finish.

Relaunch with the same standard command. A repaired AVD is not accepted until
the emulator reports that `default_boot` loaded successfully and the second
boot again selects host GLES and passes every focus, accessibility, and
screenshot check without color-buffer errors. Confirm that the saved
`textures.bin` is nonempty. If that verification fails, quarantine the new
snapshot and recreate the one standard AVD in Android Studio instead of
repeatedly loading or overwriting broken graphics state.

## Start and connect

1. Reuse the enrolled running daemon for authorized manual product checks.
   For integration tests, use isolated real daemons with disposable identity and
   `DIETER_HOME`; never restart or replace the operator service. Screen tests use
   `just e2e run --suite screens` and the owned native input target.
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
   just android install
   just android launch
   ```

   Keep `ANDROID_SERIAL=emulator-5554` on every Gradle install or
   instrumentation task. Gradle does not inherit the serial embedded in
   separate ADB commands and can otherwise choose an attached physical phone.

The Android Just module detects Android Studio's JDK and the local SDK when the
shell environment does not already expose them.

## Reproduce and verify visibly

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
task, and archive the test card after verification. Dieter card comments do not
start or approve work.

## Checks before handoff

Run the narrow unit tests while iterating, then the Android unit suite and debug
build before installing the final APK:

```sh
just android test
just android build
```

When the change touches transport behavior, also run the isolated real-process
instrumentation suite against disposable daemon/gateway fixtures:

```sh
just e2e run --suite functional
```

After reinstalling, repeat the original interaction in the visible emulator,
inspect the final screenshot, and confirm the expected Dieter state through the
app. Keep emulator screenshots and UI dumps outside the repository unless they
are intentional design references.

## Shared native test framework

Use `just e2e` and `tests/e2e/cases/android/*.yaml` for device tests. Read
`tests/e2e/README.md`. The runner owns only `.e2e`/`.e2e.performance` test packages,
per-device leases, fixtures, reverse mappings, builds, and result collection.
Do not add bespoke orchestration scripts. `functional`, `sync`, `screens`, and
non-debuggable `performance` are separate suites. Missing/skipped tests fail.
Mac execution is disabled in this framework; iOS is prepared but not executable.
