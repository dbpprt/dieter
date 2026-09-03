set default-list
set shell := ["bash", "-euo", "pipefail", "-c"]
set working-directory := '..'

app_root := "apps/android"
sdk := env_var_or_default("ANDROID_HOME", env_var_or_default("ANDROID_SDK_ROOT", home_directory() / "Library/Android/sdk"))
java := env_var_or_default("JAVA_HOME", "/Applications/Android Studio.app/Contents/jbr/Contents/Home")
adb := sdk / "platform-tools/adb"
emulator := sdk / "emulator/emulator"
serial := env_var_or_default("ANDROID_SERIAL", "emulator-5554")
avd := env_var_or_default("DIETER_ANDROID_AVD", "Pixel_9_API_37_1")
screen_session := "dieter-android-" + replace(serial, ":", "-")

# List the Android commands.
default:
    @just --justfile just/android.just --list

# Verify the Android SDK, Android Studio JBR, and selected AVD.
doctor:
    test -x "{{ adb }}"
    test -x "{{ emulator }}"
    test -x "{{ java }}/bin/java"
    command -v screen
    command -v rg
    command -v vm_stat
    "{{ adb }}" version
    "{{ emulator }}" -version
    "{{ emulator }}" -list-avds | rg -x "{{ avd }}"

# Regenerate Android's fallback brand assets from the canonical masters.
sync-brand:
    {{ app_root }}/scripts/sync-brand-assets.sh

# Stop Gradle daemons only for exceptional Android build troubleshooting.
[confirm]
gradle-stop:
    ANDROID_HOME="{{ sdk }}" JAVA_HOME="{{ java }}" {{ app_root }}/gradlew --project-dir "{{ app_root }}" --stop

# Show ADB devices and the exact emulator process tree.
emulator-status:
    "{{ adb }}" devices -l
    screen -ls | rg '[.]{{ screen_session }}[[:space:]]' || true
    ps -axo pid=,ppid=,stat=,etime=,command= | rg 'qemu-system|emulator.*{{ avd }}|<defunct>' || true

# Start or reuse the visible AVD and require a complete healthy boot.
emulator-start:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "{{ app_root }}/build/emulator"
    launched=false
    emulator_dir="$PWD/{{ app_root }}/build/emulator"
    emulator_log="$emulator_dir/screenlog.0"
    log_start="$(stat -f '%z' "$emulator_log" 2>/dev/null || echo 0)"
    state="$("{{ adb }}" -s "{{ serial }}" get-state 2>/dev/null || true)"
    if [[ "$state" == device ]]; then
        running_avd="$("{{ adb }}" -s "{{ serial }}" emu avd name 2>/dev/null | tr -d '\r' | head -n 1)"
        [[ "$running_avd" == "{{ avd }}" ]] || { echo "{{ serial }} is $running_avd, not {{ avd }}" >&2; exit 1; }
        echo "Reusing healthy candidate {{ serial }} ($running_avd)."
    elif [[ -n "$state" ]]; then
        echo "{{ serial }} is $state; refusing to start a second emulator." >&2
        exit 1
    else
        if screen -ls | rg -q '[.]{{ screen_session }}[[:space:]]'; then
            echo "The {{ screen_session }} launcher exists without a healthy ADB device; refusing another launch." >&2
            exit 1
        fi
        if pgrep -f '[e]mulator.*@{{ avd }}|[q]emu-system.*{{ avd }}' >/dev/null; then
            echo "An unaccounted-for {{ avd }} process exists without {{ serial }}; refusing another launch." >&2
            exit 1
        fi
        available_pages="$(vm_stat | awk \
            '/Pages (free|inactive|speculative|purgeable):/ { gsub(/[.]/, "", $3); total += $3 } END { print total + 0 }')"
        available_mb=$((available_pages * $(sysctl -n hw.pagesize) / 1024 / 1024))
        if (( available_mb < 6144 )); then
            echo "Host renderer preflight found about ${available_mb} MiB reclaimable; {{ avd }} requires a 6144 MiB safety margin." >&2
            echo "Free memory before launch so the emulator does not fall back to software GL." >&2
            exit 1
        fi
        (
            cd "$emulator_dir"
            screen -L -dmS "{{ screen_session }}" "{{ emulator }}" @"{{ avd }}"
        )
        launched=true
    fi
    for _ in {1..90}; do
        if [[ "$("{{ adb }}" -s "{{ serial }}" get-state 2>/dev/null || true)" == device ]] && \
           [[ "$("{{ adb }}" -s "{{ serial }}" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]] && \
           [[ "$("{{ adb }}" -s "{{ serial }}" shell getprop init.svc.bootanim 2>/dev/null | tr -d '\r')" == stopped ]]; then
            sleep 3
            loaded_snapshot="$("{{ adb }}" -s "{{ serial }}" emu avd snapshot get 2>/dev/null | tr -d '\r' | head -n 1)"
            if [[ "$loaded_snapshot" != default_boot ]]; then
                echo "{{ serial }} did not load default_boot (reported: ${loaded_snapshot:-none})." >&2
                exit 1
            fi
            if [[ "$launched" == true ]]; then
                launch_log="$(tail -c "+$((log_start + 1))" "$emulator_log")"
                if rg -qi \
                    'software GL rendering|gles_mode_selected:swangle|failed to load snapshot|different renderer configured|failed to find ColorBuffer|bad color buffer handle' \
                    <<<"$launch_log"; then
                    echo "{{ serial }} booted with an unsafe renderer or snapshot; see $emulator_log." >&2
                    exit 1
                fi
                if ! rg -q 'gles_mode_selected:host' <<<"$launch_log" || \
                   ! rg -q 'Graphics Adapter .*Apple|OpenGL ES Translator \(Apple' <<<"$launch_log"; then
                    echo "{{ serial }} launch log does not prove Apple host GLES; see $emulator_log." >&2
                    exit 1
                fi
            fi
            renderer_dump="$("{{ adb }}" -s "{{ serial }}" shell dumpsys SurfaceFlinger 2>/dev/null | \
                rg '^GLES:' | head -n 1 || true)"
            if [[ -z "$renderer_dump" ]] || rg -qi 'SwiftShader|llvmpipe|lavapipe' <<<"$renderer_dump"; then
                echo "{{ serial }} is not using a healthy host renderer:" >&2
                printf '%s\n' "$renderer_dump" >&2
                exit 1
            fi
            focus_dump="$("{{ adb }}" -s "{{ serial }}" shell dumpsys window 2>/dev/null | \
                rg 'mCurrentFocus|mFocusedApp|topResumedActivity' || true)"
            if ! rg -q 'Window\{|ActivityRecord\{' <<<"$focus_dump"; then
                echo "{{ serial }} has no focused Android window:" >&2
                printf '%s\n' "$focus_dump" >&2
                exit 1
            fi
            dump_output="$("{{ adb }}" -s "{{ serial }}" shell \
                uiautomator dump /sdcard/dieter-avd-health.xml 2>&1 || true)"
            hierarchy="$("{{ adb }}" -s "{{ serial }}" exec-out \
                cat /sdcard/dieter-avd-health.xml 2>/dev/null || true)"
            if ! rg -q '<hierarchy' <<<"$hierarchy"; then
                echo "{{ serial }} did not provide a usable accessibility hierarchy:" >&2
                printf '%s\n' "$dump_output" >&2
                exit 1
            fi
            "{{ adb }}" -s "{{ serial }}" exec-out screencap -p >"{{ app_root }}/build/emulator/health.png"
            file "{{ app_root }}/build/emulator/health.png" | rg 'PNG image data'
            echo "{{ serial }} is ready."
            exit 0
        fi
        sleep 2
    done
    echo "{{ serial }} did not complete boot in three minutes." >&2
    exit 1

# Gracefully close the selected AVD and wait for its serial to disappear.
emulator-stop:
    #!/usr/bin/env bash
    set -euo pipefail
    state="$("{{ adb }}" -s "{{ serial }}" get-state 2>/dev/null || true)"
    if [[ -z "$state" ]]; then echo "{{ serial }} is not running."; exit 0; fi
    [[ "$state" == device ]] || { echo "{{ serial }} is $state; not safe to snapshot and stop." >&2; exit 1; }
    running_avd="$("{{ adb }}" -s "{{ serial }}" emu avd name | tr -d '\r' | head -n 1)"
    [[ "$running_avd" == "{{ avd }}" ]] || { echo "Refusing to stop unexpected AVD $running_avd." >&2; exit 1; }
    [[ "$("{{ adb }}" -s "{{ serial }}" shell getprop sys.boot_completed | tr -d '\r')" == 1 ]] || \
        { echo "{{ serial }} has not completed boot; refusing to save its snapshot." >&2; exit 1; }
    [[ "$("{{ adb }}" -s "{{ serial }}" shell getprop init.svc.bootanim | tr -d '\r')" == stopped ]] || \
        { echo "{{ serial }} is still animating; refusing to save its snapshot." >&2; exit 1; }
    renderer_dump="$("{{ adb }}" -s "{{ serial }}" shell dumpsys SurfaceFlinger 2>/dev/null | \
        rg '^GLES:' | head -n 1 || true)"
    if [[ -z "$renderer_dump" ]] || rg -qi 'SwiftShader|llvmpipe|lavapipe' <<<"$renderer_dump"; then
        echo "{{ serial }} is not using a healthy host renderer; refusing to save its snapshot." >&2
        exit 1
    fi
    focus_dump="$("{{ adb }}" -s "{{ serial }}" shell dumpsys window 2>/dev/null | \
        rg 'mCurrentFocus|mFocusedApp|topResumedActivity' || true)"
    rg -q 'Window\{|ActivityRecord\{' <<<"$focus_dump" || \
        { echo "{{ serial }} has no focused window; refusing to save its snapshot." >&2; exit 1; }
    "{{ adb }}" -s "{{ serial }}" emu kill
    for _ in {1..60}; do
        if [[ -z "$("{{ adb }}" -s "{{ serial }}" get-state 2>/dev/null || true)" ]]; then
            screen -S "{{ screen_session }}" -X quit 2>/dev/null || true
            echo "{{ avd }} stopped cleanly."
            exit 0
        fi
        sleep 1
    done
    echo "{{ serial }} remained visible after graceful shutdown." >&2
    exit 1

# Build the debug APK and run Android unit tests.
build:
    ANDROID_HOME="{{ sdk }}" JAVA_HOME="{{ java }}" {{ app_root }}/gradlew --project-dir "{{ app_root }}" :app:testDebugUnitTest :app:assembleDebug

# Run Android unit tests.
test:
    ANDROID_HOME="{{ sdk }}" JAVA_HOME="{{ java }}" {{ app_root }}/gradlew --project-dir "{{ app_root }}" :app:testDebugUnitTest

# Run Android lint against the debug application.
lint:
    ANDROID_HOME="{{ sdk }}" JAVA_HOME="{{ java }}" {{ app_root }}/gradlew --project-dir "{{ app_root }}" :app:lintDebug

# Run tests, assemble the debug APK, and lint the application.
check:
    just android build
    just android lint

# Build the signed release APK using the release environment.
build-release:
    ANDROID_HOME="{{ sdk }}" JAVA_HOME="{{ java }}" {{ app_root }}/gradlew --project-dir "{{ app_root }}" --no-daemon :app:assembleRelease

# Install the pinned Android SDK packages on the GitHub runner.
install-sdk:
    [[ "${GITHUB_ACTIONS:-}" == true ]] || { echo "Android SDK installation is CI-only." >&2; exit 1; }
    sdkmanager "platforms;android-37.1" "build-tools;37.0.0"

# Restore the Android release keystore into the runner's temporary directory.
restore-release-keystore:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "${GITHUB_ACTIONS:-}" == true ]] || { echo "Keystore restoration is CI-only." >&2; exit 1; }
    : "${ANDROID_KEYSTORE_BASE64:?ANDROID_KEYSTORE_BASE64 is required}"
    : "${RUNNER_TEMP:?RUNNER_TEMP is required}"
    printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 --decode >"$RUNNER_TEMP/dieter-android-release.jks"
    chmod 600 "$RUNNER_TEMP/dieter-android-release.jks"

# Copy the signed release APK into the shared release directory.
package-release:
    #!/usr/bin/env bash
    set -euo pipefail
    source_apk="{{ app_root }}/app/build/outputs/apk/release/app-release.apk"
    archive="dist/Dieter-Android.apk"
    test -f "$source_apk"
    [[ ! -e "$archive" ]] || { echo "$archive already exists." >&2; exit 1; }
    mkdir -p dist
    cp "$source_apk" "$archive"
    echo "$archive"

# Verify the packaged Android release signature.
verify-release:
    "{{ sdk }}/build-tools/37.0.0/apksigner" verify --verbose --print-certs dist/Dieter-Android.apk

# Remove only the packaged Android release APK and temporary CI keystore.
[confirm]
clean-release:
    rm -f dist/Dieter-Android.apk "${RUNNER_TEMP:-/tmp}/dieter-android-release.jks"

# Install the current debug APK without clearing app data.
install:
    ANDROID_HOME="{{ sdk }}" JAVA_HOME="{{ java }}" {{ app_root }}/gradlew --project-dir "{{ app_root }}" :app:installDebug

# Launch Dieter and require a running app process.
launch:
    "{{ adb }}" -s "{{ serial }}" shell am force-stop com.dbpprt.dieter
    "{{ adb }}" -s "{{ serial }}" shell am start -W -n com.dbpprt.dieter/.MainActivity
    "{{ adb }}" -s "{{ serial }}" shell pidof com.dbpprt.dieter

# Stop only the Dieter app and retain the emulator and its data.
app-stop:
    "{{ adb }}" -s "{{ serial }}" shell am force-stop com.dbpprt.dieter
    test -z "$("{{ adb }}" -s "{{ serial }}" shell pidof com.dbpprt.dieter | tr -d '\r')"

# Run all connected tests, or one fully qualified test class.
connected-test class="":
    #!/usr/bin/env bash
    set -euo pipefail
    arguments=(--project-dir "{{ app_root }}" connectedDebugAndroidTest)
    if [[ -n "{{ class }}" ]]; then
        arguments+=("-Pandroid.testInstrumentationRunnerArguments.class={{ class }}")
    fi
    ANDROID_SERIAL="{{ serial }}" ANDROID_HOME="{{ sdk }}" JAVA_HOME="{{ java }}" \
        "{{ app_root }}/gradlew" "${arguments[@]}"

# Save the current Android UI hierarchy.
ui-dump output="apps/android/build/evidence/ui.xml":
    mkdir -p "$(dirname "{{ output }}")"
    "{{ adb }}" -s "{{ serial }}" shell uiautomator dump /sdcard/dieter-ui.xml
    "{{ adb }}" -s "{{ serial }}" pull /sdcard/dieter-ui.xml "{{ output }}"

# Save the current emulator screen.
screenshot output="apps/android/build/evidence/screen.png":
    mkdir -p "$(dirname "{{ output }}")"
    "{{ adb }}" -s "{{ serial }}" exec-out screencap -p >"{{ output }}"
    file "{{ output }}" | rg 'PNG image data'

# Print the most recent process-scoped Dieter logs.
logs:
    #!/usr/bin/env bash
    set -euo pipefail
    pid="$("{{ adb }}" -s "{{ serial }}" shell pidof -s com.dbpprt.dieter | tr -d '\r')"
    [[ -n "$pid" ]] || { echo "Dieter is not running on {{ serial }}." >&2; exit 1; }
    "{{ adb }}" -s "{{ serial }}" logcat --pid="$pid" -d -v threadtime -t 500

# Remove disposable Android UI and emulator evidence without touching Gradle caches.
[confirm]
clean-evidence:
    rm -rf {{ app_root }}/.build/jump-to-latest-e2e {{ app_root }}/build/emulator {{ app_root }}/build/evidence
