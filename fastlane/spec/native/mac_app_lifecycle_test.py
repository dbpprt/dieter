import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from fastlane.lib.dieter.native import mac_lifecycle as lifecycle


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
            ["just", "pipeline", "mac", "build"], ["open", str(lifecycle.BUNDLE)],
        ])

    def test_app_started_during_build_prevents_launch(self):
        with patch.object(lifecycle, "app_processes", side_effect=[[], [self.other]]), \
             patch.object(lifecycle.subprocess, "run") as run:
            with self.assertRaises(RuntimeError):
                lifecycle.run_app()
        run.assert_called_once_with(["just", "pipeline", "mac", "build"], cwd=lifecycle.ROOT, check=True)

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




if __name__ == "__main__":
    unittest.main()
