import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import mac_app_lifecycle as lifecycle


def result(code=0, stdout="", stderr=""):
    return subprocess.CompletedProcess([], code, stdout, stderr)


class MacAppLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.owned = lifecycle.AppProcess(101, lifecycle.EXECUTABLE.resolve())
        self.other = lifecycle.AppProcess(202, Path("/Applications/Dieter.app/Contents/MacOS/DieterMac"))

    def test_inventory_preserves_paths_with_spaces_and_ignores_exited_processes(self):
        with patch.object(lifecycle.subprocess, "run", side_effect=[
            result(stdout="101\n102\n"), result(stdout="/Some Project/Dieter.app/Contents/MacOS/DieterMac\n"),
            result(1),
        ]) as run:
            self.assertEqual(lifecycle.app_processes(), [
                lifecycle.AppProcess(101, Path("/Some Project/Dieter.app/Contents/MacOS/DieterMac")),
            ])
        self.assertEqual(run.call_args_list[1].args[0], ["ps", "-p", "101", "-o", "comm="])

    def test_failed_or_ambiguous_inventory_is_never_treated_as_stopped(self):
        for responses in [[result(2, stderr="failed")], [result()], [result(stdout="invalid")],
                          [result(stdout="101"), result(stdout="DieterMac")],
                          [result(stdout="101"), result(2)]]:
            with self.subTest(responses=responses), \
                 patch.object(lifecycle.subprocess, "run", side_effect=responses):
                with self.assertRaises((RuntimeError, ValueError)):
                    lifecycle.assert_stopped()

    def test_no_matching_process_is_stopped(self):
        with patch.object(lifecycle.subprocess, "run", return_value=result(1)):
            lifecycle.assert_stopped()

    def test_build_guard_preserves_any_running_app(self):
        for process in [self.owned, self.other]:
            with self.subTest(process=process), patch.object(lifecycle, "app_processes", return_value=[process]):
                with self.assertRaisesRegex(RuntimeError, "bundle was not changed"):
                    lifecycle.assert_stopped()

    def test_running_canonical_app_is_activated_without_building(self):
        with patch.object(lifecycle, "app_processes", return_value=[self.owned]), \
             patch.object(lifecycle.subprocess, "run") as run, contextlib.redirect_stdout(io.StringIO()):
            lifecycle.run_app()
        run.assert_called_once_with(["open", str(lifecycle.BUNDLE)], check=True)

    def test_conflicting_or_duplicate_apps_prevent_build_and_launch(self):
        sibling = lifecycle.AppProcess(303, Path(str(lifecycle.EXECUTABLE) + "-other"))
        for processes in [[self.other], [self.owned, self.other], [self.owned, self.owned], [sibling]]:
            with self.subTest(processes=processes), \
                 patch.object(lifecycle, "app_processes", return_value=processes), \
                 patch.object(lifecycle.subprocess, "run") as run:
                with self.assertRaises(RuntimeError):
                    lifecycle.run_app()
                run.assert_not_called()

    def test_stopped_app_is_built_then_launched_and_verified(self):
        with patch.object(lifecycle, "app_processes", side_effect=[[], [], [self.owned]]), \
             patch.object(lifecycle.subprocess, "run") as run, contextlib.redirect_stdout(io.StringIO()):
            lifecycle.run_app()
        self.assertEqual([call.args[0] for call in run.call_args_list], [
            ["just", "mac", "build"], ["open", str(lifecycle.BUNDLE)],
        ])

    def test_app_started_during_build_prevents_launch(self):
        with patch.object(lifecycle, "app_processes", side_effect=[[], [self.other]]), \
             patch.object(lifecycle.subprocess, "run") as run:
            with self.assertRaises(RuntimeError):
                lifecycle.run_app()
        run.assert_called_once_with(["just", "mac", "build"], cwd=lifecycle.ROOT, check=True)

    def test_failed_build_never_launches(self):
        with patch.object(lifecycle, "app_processes", return_value=[]), \
             patch.object(lifecycle.subprocess, "run", side_effect=subprocess.CalledProcessError(3, ["just"])) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                lifecycle.run_app()
        self.assertEqual(run.call_count, 1)

    def test_quit_refuses_foreign_bundles_without_sending_events(self):
        with patch.object(lifecycle, "app_processes", return_value=[self.owned, self.other]), \
             patch.object(lifecycle.subprocess, "run") as run:
            with self.assertRaises(RuntimeError):
                lifecycle.quit_app()
        run.assert_not_called()

    def test_quit_passes_bundle_as_data_and_waits_for_exit(self):
        with patch.object(lifecycle, "app_processes", side_effect=[[self.owned], []]), \
             patch.object(lifecycle.subprocess, "run") as run, contextlib.redirect_stdout(io.StringIO()):
            lifecycle.quit_app()
        command = run.call_args.args[0]
        self.assertEqual(command[0], "osascript")
        self.assertEqual(command[-1], str(lifecycle.BUNDLE))
        self.assertNotIn(str(lifecycle.BUNDLE), command[2])

    def test_stopped_app_quit_has_no_side_effects(self):
        with patch.object(lifecycle, "app_processes", return_value=[]), \
             patch.object(lifecycle.subprocess, "run") as run, contextlib.redirect_stdout(io.StringIO()):
            lifecycle.quit_app()
        run.assert_not_called()

    def test_quit_timeout_preserves_process_without_escalating(self):
        with patch.object(lifecycle, "app_processes", return_value=[self.owned]), \
             patch.object(lifecycle.time, "monotonic", side_effect=[0, 11]), \
             patch.object(lifecycle.subprocess, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "Preserving processes"):
                lifecycle.quit_app()
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.args[0][0], "osascript")

    def test_direct_build_script_refuses_before_compiling_or_writing_bundle(self):
        # Execute the actual entry point in an isolated tree with fake process
        # tools. No Swift toolchain, desktop, or operator process is touched.
        with tempfile.TemporaryDirectory(prefix="dieter lifecycle ") as directory:
            root = Path(directory)
            script = root / "apps/mac/scripts/build.sh"
            helper = root / "scripts/mac_app_lifecycle.py"
            script.parent.mkdir(parents=True)
            helper.parent.mkdir(parents=True)
            shutil.copy(lifecycle.ROOT / "apps/mac/scripts/build.sh", script)
            shutil.copy(lifecycle.ROOT / "scripts/mac_app_lifecycle.py", helper)
            commands = root / "bin"
            commands.mkdir()
            for name, body in {
                "pgrep": "printf '101\\n'",
                "ps": "printf '/Applications/Dieter.app/Contents/MacOS/DieterMac\\n'",
            }.items():
                executable = commands / name
                executable.write_text("#!/bin/sh\n" + body + "\n")
                executable.chmod(0o755)
            completed = subprocess.run(["/bin/sh", str(script)], capture_output=True, text=True,
                                       env={**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"]})
            self.assertEqual(completed.returncode, 1, completed.stderr)
            self.assertIn("bundle was not changed", completed.stderr)
            self.assertFalse((root / "apps/mac/build").exists())

    def test_build_and_test_entry_points_forward_optional_job_limit(self):
        # Exercise the actual entry points, but stop at an argv-recording Swift
        # fixture. Neither a compiler nor the desktop is involved.
        with tempfile.TemporaryDirectory(prefix="dieter compiler controls ") as directory:
            root = Path(directory)
            for relative in ["apps/mac/scripts/build.sh", "scripts/mac_app_lifecycle.py", "just/mac.just"]:
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(lifecycle.ROOT / relative, target)
            (root / "justfile").write_text("mod mac 'just/mac.just'\n")
            sync = root / "apps/mac/scripts/sync-proto.sh"
            sync.write_text("#!/bin/sh\nexit 0\n")
            sync.chmod(0o755)
            commands = root / "bin"
            commands.mkdir()
            for name, body in {
                "pgrep": "exit 1",
                "swift": 'printf \'%s\\n\' "$@" > "$DIETER_TEST_SWIFT_ARGUMENTS"\nexit 77',
            }.items():
                executable = commands / name
                executable.write_text("#!/bin/sh\n" + body + "\n")
                executable.chmod(0o755)
            recorded = root / "swift-arguments"
            environment = {key: value for key, value in os.environ.items()
                           if key != "DIETER_SWIFT_JOBS"}
            environment.update(PATH=str(commands) + os.pathsep + environment["PATH"],
                               DIETER_TEST_SWIFT_ARGUMENTS=str(recorded))
            for command in [["/bin/sh", "apps/mac/scripts/build.sh"], ["just", "mac", "test"]]:
                for configured in [False, True]:
                    with self.subTest(command=command, configured=configured):
                        recorded.unlink(missing_ok=True)
                        options = {"DIETER_SWIFT_JOBS": "2"} if configured else {}
                        completed = subprocess.run(command, cwd=root, env={**environment, **options},
                                                   capture_output=True, text=True)
                        self.assertNotEqual(completed.returncode, 0)
                        self.assertTrue(recorded.exists(), completed.stderr)
                        arguments = recorded.read_text().splitlines()
                        self.assertEqual("--jobs" in arguments, configured)
                        if configured:
                            self.assertEqual(arguments[arguments.index("--jobs") + 1], "2")


if __name__ == "__main__":
    unittest.main()
