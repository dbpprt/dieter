#!/usr/bin/env bash
# Native, isolated Android -> WebRTC -> macOS capture/input integration.
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
adb="$sdk/platform-tools/adb"
serial="${ANDROID_SERIAL:-emulator-5554}"
[[ "$serial" == emulator-* ]] || { echo 'Screen tests require the explicitly selected emulator.' >&2; exit 1; }
[[ "$($adb -s "$serial" get-state)" == device ]]
root=$(mktemp -d /tmp/dieter-android-screens.XXXXXX)
fixture_pid=""; target_pid=""; port=""
cleanup() {
    [[ -z "$fixture_pid" ]] || kill "$fixture_pid" 2>/dev/null || true
    [[ -z "$target_pid" ]] || kill "$target_pid" 2>/dev/null || true
    [[ -z "$fixture_pid" ]] || wait "$fixture_pid" 2>/dev/null || true
    [[ -z "$target_pid" ]] || wait "$target_pid" 2>/dev/null || true
    [[ -z "$port" ]] || "$adb" -s "$serial" reverse --remove "tcp:$port" >/dev/null 2>&1 || true
}
trap cleanup EXIT
native/macos-capture/build.sh "$root/dieter-capture"
go build -o "$root/screens-fixture" ./scripts/screens-fixture
mkdir -p "$root/InputTarget.app/Contents/MacOS"
cat > "$root/InputTarget.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>InputTarget</string><key>CFBundleIdentifier</key><string>com.dbpprt.dieter.screen-input-fixture</string><key>CFBundleName</key><string>Dieter Input Fixture</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
xcrun swiftc -parse-as-library -O -framework AppKit native/macos-capture/tests/InputTarget.swift -o "$root/InputTarget.app/Contents/MacOS/InputTarget"
codesign --force --sign - "$root/InputTarget.app"
"$root/InputTarget.app/Contents/MacOS/InputTarget" "$root/input.json" $$ >"$root/input.log" 2>&1 &
target_pid=$!
"$root/screens-fixture" --helper "$root/dieter-capture" --source "${DIETER_SCREEN_TEST_SOURCE:-native-synthetic}" --authenticate --ready "$root/ready.json" >"$root/fixture.log" 2>&1 &
fixture_pid=$!
for _ in {1..60}; do [[ -s "$root/ready.json" && -s "$root/input.json" ]] && break; sleep 1; done
port=$(python3 - "$root" "${DIETER_SCREEN_TEST_SOURCE:-native-synthetic}" <<'PY'
import json,sys,urllib.parse
from pathlib import Path
root=Path(sys.argv[1]); ready=json.loads((root/'ready.json').read_text()); target=json.loads((root/'input.json').read_text())
assert target['active'], 'Owned input target must have focus'
ready.update(real=sys.argv[2] == "screen", port=urllib.parse.urlparse(ready['url']).port, targetX=target['x'], targetY=target['y'])
(root/'test.json').write_text(json.dumps(ready)); print(ready['port'])
PY
)
"$adb" -s "$serial" reverse "tcp:$port" "tcp:$port"
argument=$(base64 < "$root/test.json" | tr -d '\n')
ANDROID_SERIAL="$serial" ANDROID_HOME="$sdk" JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export ANDROID_SERIAL ANDROID_HOME JAVA_HOME
apps/android/gradlew --project-dir apps/android connectedDebugAndroidTest \
    -Pandroid.testInstrumentationRunnerArguments.class=com.dbpprt.dieter.screens.ScreenEndToEndTest \
    "-Pandroid.testInstrumentationRunnerArguments.screenFixture=$argument"
python3 - "$root/input.json" "${DIETER_SCREEN_TEST_SOURCE:-native-synthetic}" <<'PY'
import json,sys
if sys.argv[2] != 'screen':
    print('Synthetic native video, canvas gestures and dry-run input acknowledgments passed.')
    raise SystemExit(0)
value=json.load(open(sys.argv[1]))
assert value['ups'] >= 1, value
assert 'Android écran 世界' in value['text'], value
assert 'temporary' not in value['text'], value
assert value['scrolls'] > 0, value
assert '0:up' in value['keys'], value
print('Native host received relative click, committed Unicode, special keys, three-finger scroll, and held-key release.')
PY
"$adb" -s "$serial" pull /sdcard/Android/data/com.dbpprt.dieter/files/screen-e2e.png "$root/viewer.png"
"$adb" -s "$serial" pull /sdcard/Android/data/com.dbpprt.dieter/files/screen-e2e-stats.json "$root/stats.json"
echo "Screen integration evidence: $root"
