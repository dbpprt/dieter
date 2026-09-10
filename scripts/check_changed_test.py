import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from check_changed import affected_go_packages, changed_paths, main, plan_checks


class CheckChangedTests(unittest.TestCase):
    root = Path("/repo")

    def plan(self, *paths):
        return plan_checks(self.root, paths, packages=[])

    def test_no_changes_or_docs_need_no_checks(self):
        self.assertEqual(self.plan(), [])
        self.assertEqual(self.plan("README.md", "apps/mac/README.md", "AGENTS.md"), [])

    def test_mac_change_runs_only_mac_unit_and_integration_tests(self):
        self.assertEqual(self.plan("apps/mac/Sources/DieterMac/UI/ConversationView.swift"),
                         [["just", "mac", "test"], ["just", "mac", "smoke-all"]])

    def test_android_change_runs_only_android_unit_and_integration_tests(self):
        self.assertEqual(self.plan("apps/android/app/src/main/java/Conversation.kt"),
                         [["just", "android", "test"], ["just", "android", "connected-test"]])

    def test_unit_tests_do_not_trigger_device_suites(self):
        self.assertEqual(self.plan("apps/mac/Tests/DieterMacTests/SelectionTests.swift"), [["just", "mac", "test"]])
        self.assertEqual(self.plan("apps/android/app/src/test/java/SelectionTest.kt"), [["just", "android", "test"]])

    def test_integration_tests_and_build_configuration_do_trigger_suites(self):
        for path in ["apps/mac/Package.resolved", "apps/mac/Tools/DieterMacSmokeDriver/main.swift"]:
            self.assertIn(["just", "mac", "smoke-all"], self.plan(path))
        for path in ["apps/android/build.gradle.kts", "apps/android/app/src/androidTest/java/Example.kt"]:
            self.assertIn(["just", "android", "connected-test"], self.plan(path))

    def test_shared_schema_and_fixture_validate_both_clients(self):
        for path in ["api/proto/dieter/v1/dieter.proto", "scripts/isolated-gateway/main.go"]:
            plan = self.plan(path)
            self.assertIn(["just", "mac", "smoke-all"], plan)
            self.assertIn(["just", "android", "connected-test"], plan)
        self.assertIn(["just", "proto"], self.plan("api/proto/dieter/v1/dieter.proto"))

    def test_harness_does_not_run_unrelated_native_tests(self):
        self.assertEqual(self.plan("internal/harness/runtime/runner.mjs"), [["just", "harness", "test"]])

    def test_graph_includes_reverse_and_test_only_dependencies(self):
        packages = [
            {"ImportPath": "dieter/a", "Dir": "/repo/a", "EmbedFiles": ["data.json"]},
            {"ImportPath": "dieter/b", "Dir": "/repo/b", "Imports": ["dieter/a"]},
            {"ImportPath": "dieter/c", "Dir": "/repo/c", "XTestImports": ["dieter/b"]},
            {"ImportPath": "dieter/other", "Dir": "/repo/other"},
        ]
        for path in ["a/a.go", "a/deleted_test.go", "a/data.json", "a/testdata/nested/input.txt"]:
            self.assertEqual(affected_go_packages(self.root, [path], packages), ["dieter/a", "dieter/b", "dieter/c"])
        self.assertEqual(len(affected_go_packages(self.root, ["go.sum"], packages)), 4)

    def test_planning_does_not_load_go_for_native_or_docs_changes(self):
        with patch("check_changed.go_packages", side_effect=AssertionError("Unexpected Go toolchain use")):
            plan_checks(self.root, ["apps/mac/Sources/View.swift"])
            plan_checks(self.root, ["README.md"])

    def test_git_detection_includes_staged_unstaged_untracked_deleted_and_renamed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, stderr=subprocess.DEVNULL)

            git("init")
            git("config", "user.email", "test@example.invalid")
            git("config", "user.name", "Test")
            for name in ["staged", "unstaged", "deleted", "old"]:
                (root / name).write_text("original")
            git("add", ".")
            git("commit", "-m", "fixture")
            git("tag", "base")
            (root / "staged").write_text("staged")
            git("add", "staged")
            (root / "unstaged").write_text("unstaged")
            (root / "deleted").unlink()
            git("mv", "old", "new name")
            (root / "untracked\nfile").write_text("new")
            self.assertEqual(set(changed_paths(root)),
                             {"staged", "unstaged", "deleted", "old", "new name", "untracked\nfile"})
            git("add", ".")
            git("commit", "-m", "changes")
            self.assertEqual(changed_paths(root), [])
            self.assertIn("deleted", changed_paths(root, "base"))

    def test_dry_run_does_not_execute_and_failures_stop_the_run(self):
        commands = [["just", "mac", "test"], ["just", "mac", "smoke-all"]]
        with patch("check_changed.output", return_value="/repo"), \
             patch("sys.stdout", new=io.StringIO()), patch("sys.stderr", new=io.StringIO()), \
             patch("check_changed.changed_paths", return_value=["apps/mac/Sources/View.swift"]), \
             patch("check_changed.plan_checks", return_value=commands), \
             patch("check_changed.subprocess.run") as run:
            with patch("sys.argv", ["check_changed.py", "--dry-run"]):
                self.assertEqual(main(), 0)
                run.assert_not_called()
            run.return_value.returncode = 7
            with patch("sys.argv", ["check_changed.py"]):
                self.assertEqual(main(), 7)
                run.assert_called_once_with(commands[0], cwd=self.root)

    def test_running_mac_app_blocks_integration_before_packaging(self):
        with patch("check_changed.output", return_value="/repo"), \
             patch("sys.stdout", new=io.StringIO()), patch("sys.stderr", new=io.StringIO()), \
             patch("check_changed.changed_paths", return_value=[]), \
             patch("check_changed.plan_checks", return_value=[["just", "mac", "smoke-all"]]), \
             patch("sys.argv", ["check_changed.py"]), \
             patch("check_changed.subprocess.run") as run:
            run.return_value.returncode = 0
            run.return_value.stdout = "123\n456\n"
            self.assertEqual(main(), 1)
            run.assert_called_once_with(["pgrep", "-x", "DieterMac"], capture_output=True, text=True)


if __name__ == "__main__":
    unittest.main()
