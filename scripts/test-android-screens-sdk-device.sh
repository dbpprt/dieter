#!/usr/bin/env bash
# Codec/ownership checks in the separate physical-device fixture application.
set -euo pipefail
cd "$(dirname "$0")/.."
serial="${1:?an explicit physical device serial is required}"
[[ "$serial" != emulator-* && "$serial" != -* ]] || { echo 'A physical serial is required.' >&2; exit 2; }
if [[ "${DIETER_SCREEN_DEVICE_LEASE_V2:-}" != "$serial" ]]; then
    exec python3 scripts/with-android-device-lease.py "$serial" bash "$0" "$@"
fi
sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
adb="$sdk/platform-tools/adb"
[[ "$("$adb" -s "$serial" get-state)" == device ]]
root=$(mktemp -d "${TMPDIR:-/tmp}/dieter-android-screen-sdk.XXXXXX")
touch "$root/started"
trap '"$adb" -s "$serial" shell am force-stop com.dbpprt.dieter.screenfixture >/dev/null 2>&1 || true' EXIT
export ANDROID_SERIAL="$serial" ANDROID_HOME="$sdk"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
apps/android/gradlew --project-dir apps/android :app:connectedScreenFixtureAndroidTest \
    -Pdieter.screenTestBuildType=screenFixture \
    -Pandroid.testInstrumentationRunnerArguments.class=org.webrtc.DieterSurfaceOutputTest,org.webrtc.DieterLowLatencyCodecTest,com.dbpprt.dieter.settings.DieterLauncherIconTest
python3 - "$root" "$serial" <<'PY'
import json, sys
from pathlib import Path
import xml.etree.ElementTree as ET

expected = {
    'org.webrtc.DieterSurfaceOutputTest',
    'org.webrtc.DieterLowLatencyCodecTest',
    'com.dbpprt.dieter.settings.DieterLauncherIconTest',
}
reports = list(Path('apps/android/app/build/outputs/androidTest-results/connected/screenFixture').glob('TEST-*.xml'))
started = (Path(sys.argv[1]) / 'started').stat().st_mtime_ns
reports = [p for p in reports if p.stat().st_mtime_ns >= started]
cases = [c for path in reports for c in ET.parse(path).getroot().iter('testcase')]
assert len(cases) >= 16 and {c.get('classname') for c in cases} == expected, 'Missing required physical SDK tests'
assert all(c.find('failure') is None and c.find('error') is None and c.find('skipped') is None for c in cases), 'SDK tests failed or skipped'
result = {'schemaVersion': 1, 'serial': sys.argv[2], 'tests': len(cases), 'failures': 0, 'skipped': 0,
          'cases': [{'class': c.get('classname'), 'name': c.get('name')} for c in cases]}
(Path(sys.argv[1]) / 'decoder-sdk.json').write_text(json.dumps(result, indent=2) + '\n')
PY
echo "Decoder SDK evidence: $root"
