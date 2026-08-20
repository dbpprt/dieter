# Android agent development cycle

Use the real native app in the visible local Android emulator for every Android
change. The standard AVD is `Pixel_9_API_37_1`; reuse it when it is already
running instead of starting a headless or disposable emulator. Keep this as the
only Nauclio AVD; do not create another API-level-specific AVD for routine tests.

Launch it with its checked, working graphics configuration and saved snapshot:

```sh
$ANDROID_HOME/emulator/emulator @Pixel_9_API_37_1
```

Do not add `-gpu host`, `-gpu swiftshader*`, `-no-snapshot-load`, `-no-snapshot`,
or cold-boot flags. Those overrides bypass the AVD's working graphics and
snapshot configuration and can leave Android system services unresponsive. If
the saved snapshot fails to load, stop and diagnose the AVD instead of silently
continuing with a cold boot. Before launching, avoid CPU starvation from stale
browser-automation sessions and confirm that another emulator is not already
running.

## Start and connect

1. Run an enrolled `nauclio daemon start` normally so it uses the real
   `NAUCLIO_HOME`. Do not start a fixture server, mock Nauclio, or edit Nauclio's
   central storage directly.
2. Confirm the emulator serial with `adb devices -l`. The usual serial is
   `emulator-5554`; pass `-s <serial>` to every command when multiple devices
   are attached.
3. Sign in to the configured gateway in the app and select the enrolled daemon.
   Do not use `adb reverse` or enter the raw loopback API as an endpoint. Route
   discovery, authenticated direct probing, and relay fallback are automatic.
4. Build, install, and launch the current app:

   ```sh
   ./apps/android/gradlew --project-dir apps/android installDebug
   adb -s emulator-5554 shell am force-stop com.dbpprt.nauclio
   adb -s emulator-5554 shell am start -n com.dbpprt.nauclio/.MainActivity
   ```

`./apps/android/scripts/build.sh` detects Android Studio's JDK and the local SDK
when the shell environment does not already expose them.

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
journey against the real local Nauclio process, including the final server-backed
state, not just the presence of a composable.

For gesture-driven UI, perform the real gesture with `adb shell input swipe`,
then dump and screenshot the revealed state before tapping its action. Derive
the swipe and tap coordinates from the current UI dump so the check still
validates the visible control instead of merely replaying stale coordinates.

Use dedicated non-destructive test data when an interaction starts an agent.
Never launch an existing user's queued card merely to test the UI. Create test
cards through the app or `board` CLI, give the agent an explicitly read-only
task, and archive the test card after verification. Nauclio card comments do not
start or approve work.

## Checks before handoff

Run the narrow unit tests while iterating, then the Android unit suite and debug
build before installing the final APK:

```sh
./apps/android/gradlew --project-dir apps/android testDebugUnitTest
./apps/android/gradlew --project-dir apps/android assembleDebug
```

When the change touches transport behavior, also run the real-process
instrumentation check through the configured gateway while the enrolled daemon
is active:

```sh
ANDROID_SERIAL=emulator-5554 ./apps/android/gradlew \
  --project-dir apps/android connectedDebugAndroidTest
```

After reinstalling, repeat the original interaction in the visible emulator,
inspect the final screenshot, and confirm the expected Nauclio state through the
app. Keep emulator screenshots and UI dumps outside the repository unless they
are intentional design references.
