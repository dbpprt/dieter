import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


class SharedFrameworkCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        source = Path(__file__).resolve().parents[1]
        for path in ('apps/mac/scripts/shared-framework.sh', 'scripts/native_build_lock.py'):
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(source / path, target)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        JAVA_HOME=str(self.bin), DIETER_CACHE_TEST_ROOT=str(self.root))
        (self.bin / 'bin').mkdir()
        self.executable(self.bin / 'bin/java', '#!/bin/sh\necho java-test-version >&2\n')
        self.executable(self.bin / 'xcodebuild', '''#!/bin/sh
if [ "$1" = -version ]; then cat "$DIETER_CACHE_TEST_ROOT/toolchain"; exit; fi
while [ "$1" != -output ]; do shift; done
mkdir -p "$2"
cat "$DIETER_CACHE_TEST_ROOT/apps/core/shared/src/commonMain/Core.kt" > "$2/content"
echo assembled >> "$DIETER_CACHE_TEST_ROOT/builds"
''')
        core = self.root / 'apps/core'
        core.mkdir(parents=True)
        self.executable(core / 'gradlew', '#!/bin/sh\necho "$*" >> "$DIETER_CACHE_TEST_ROOT/gradle-calls"\nif [ "${DIETER_CACHE_TEST_DELAY:-}" = 1 ]; then sleep 1; fi\n')
        for path in ('apps/core/shared/src/commonMain/Core.kt',
                     'apps/core/shared/src/commonTest/CoreTest.kt',
                     'apps/core/README.md', 'api/proto/dieter.proto', 'toolchain'):
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('initial')
        subprocess.run(['git', 'init', '-q', self.root], check=True)

    def executable(self, path, body):
        path.write_text(body)
        path.chmod(0o755)

    def build(self, platform='macos'):
        result = subprocess.run([self.root / 'apps/mac/scripts/shared-framework.sh', 'debug', platform],
                       cwd=self.root, env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def count(self):
        return len((self.root / 'builds').read_text().splitlines())

    def test_warm_cache_ignores_test_docs_but_tracks_schema_sources_and_toolchain(self):
        self.build()
        self.build()
        self.assertEqual(self.count(), 1)
        for path in ('apps/core/shared/src/commonTest/CoreTest.kt', 'apps/core/README.md'):
            (self.root / path).write_text('edited test or documentation')
        self.build()
        self.assertEqual(self.count(), 1)
        for expected, path in enumerate(('apps/core/shared/src/commonMain/Core.kt',
                                         'api/proto/dieter.proto', 'toolchain'), 2):
            (self.root / path).write_text('changed production input')
            self.build()
            self.assertEqual(self.count(), expected)

    def test_mac_refresh_preserves_simulator_slice_and_does_not_build_device_slice(self):
        self.build('ios-simulator')
        calls = (self.root / 'gradle-calls').read_text()
        self.assertIn('linkDebugFrameworkIosSimulatorArm64', calls)
        self.assertNotIn('linkDebugFrameworkIosArm64', calls)
        (self.root / 'apps/core/shared/src/commonMain/Core.kt').write_text('changed')
        self.build('macos')
        self.assertIn('slice IosSimulatorArm64', (self.root / 'apps/mac/Frameworks/.DieterShared.inputs').read_text())
        self.build('ios-simulator')
        self.assertEqual(self.count(), 2)

    def test_concurrent_publication_fails_with_owner_and_releases_after_exit(self):
        argv = [self.root / 'apps/mac/scripts/shared-framework.sh', 'debug', 'macos']
        process = subprocess.Popen(argv, cwd=self.root, env=dict(self.env, DIETER_CACHE_TEST_DELAY='1'),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 10
            while not (self.root / 'gradle-calls').exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((self.root / 'gradle-calls').exists())
            conflict = subprocess.run(argv, cwd=self.root, env=self.env, capture_output=True, text=True)
            self.assertNotEqual(conflict.returncode, 0)
            self.assertIn('Native build resource busy: apple-build', conflict.stderr)
            self.assertIn('"pid":', conflict.stderr)
        finally:
            stdout, stderr = process.communicate(timeout=15)
        self.assertEqual(process.returncode, 0, stdout + stderr)
        self.build()
        self.assertEqual(self.count(), 1)

    def test_identical_refresh_preserves_binary_timestamp(self):
        self.build()
        binary = self.root / 'apps/mac/Frameworks/DieterShared.xcframework/content'
        # Versioned frameworks may have cyclic links; equality never follows them.
        framework = binary.parent
        (framework / 'loop').symlink_to('.')
        xcode = self.bin / 'xcodebuild'
        xcode.write_text(xcode.read_text().replace('mkdir -p "$2"', 'mkdir -p "$2"\nln -s . "$2/loop"'))
        before = binary.stat().st_mtime_ns
        (self.root / 'toolchain').write_text('new toolchain')
        self.build()
        self.assertEqual(self.count(), 2)
        self.assertEqual(binary.stat().st_mtime_ns, before)

    def test_xcframework_ordering_is_equivalent_but_library_changes_are_not(self):
        first, second = self.root / 'first', self.root / 'second'
        first.mkdir()
        second.mkdir()
        libraries = [{"LibraryIdentifier": "macos-arm64", "LibraryPath": "DieterShared.framework"},
                     {"LibraryIdentifier": "ios-arm64-simulator", "LibraryPath": "DieterShared.framework"}]
        def metadata(path, entries):
            (path / 'Info.plist').write_bytes(plistlib.dumps({"AvailableLibraries": entries}))
        metadata(first, libraries)
        metadata(second, list(reversed(libraries)))
        argv = ['python3', self.root / 'scripts/native_build_lock.py', '--same-tree', first, second]
        self.assertEqual(subprocess.run(argv).returncode, 0)
        libraries[0]["LibraryPath"] = 'Different.framework'
        metadata(second, libraries)
        self.assertEqual(subprocess.run(argv).returncode, 1)

    def test_slice_union_uses_canonical_order(self):
        self.build('all')
        (self.root / 'toolchain').write_text('changed toolchain')
        self.build('ios-simulator')
        commands = (self.root / 'gradle-calls').read_text().splitlines()
        self.assertEqual(commands[0], commands[1])


if __name__ == '__main__':
    unittest.main()
