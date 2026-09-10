import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from check_changed import (MAC_SMOKE_SUITES, affected_go_packages, affected_mac_smoke_suites,
                           changed_paths, main, plan_checks)


class CheckChangedTests(unittest.TestCase):
    root = Path("/repo")

    def plan(self, *paths):
        return plan_checks(self.root, paths, packages=[])

    def test_no_changes_or_docs_need_no_checks(self):
        self.assertEqual(self.plan(), [])
        self.assertEqual(self.plan("README.md", "apps/mac/README.md", "AGENTS.md"), [])

    def test_mac_change_runs_only_mac_unit_and_integration_tests(self):
        self.assertEqual(self.plan("apps/mac/Sources/DieterMac/Features/Conversation/ConversationView.swift"),
                         [["just", "mac", "test"],
                          ["just", "mac", "smoke-suites", "core", "board", "conversation", "workspace"]])

    def test_mac_components_select_related_smokes(self):
        for path, suites in {
            "UI/DieterIslandWindow.swift": ("island",),
            "Model/DieterIslandPreferences.swift": ("island",),
            "UI/BoardView.swift": ("core", "board", "conversation", "workspace"),
            "Features/Forms/HarnessFields.swift": ("core", "board", "conversation"),
            "Features/Files/FilesView.swift": ("core", "workspace"),
            "Features/Changes/WorkspaceChangesView.swift": ("workspace",),
            "Features/Terminals/TerminalInputForwarder.swift": ("terminal",),
            "Model/SidebarProjectNavigationPreferences.swift": ("core", "sidebar"),
            "UI/MachinesView.swift": ("core", "machine", "sidebar"),
        }.items():
            with self.subTest(path=path):
                self.assertEqual(affected_mac_smoke_suites(["apps/mac/Sources/DieterMac/" + path]), suites)

    def test_board_panel_hosts_cover_resize_maximize_and_workspace_tabs(self):
        # BoardView wires maximize state; both hosts own the panel used by the
        # conversation and workspace suites. Board smoke alone misses that flow.
        for path in ["UI/BoardView.swift", "UI/BoardConversationOverlay.swift",
                     "Features/Conversation/ConversationView.swift"]:
            with self.subTest(path=path):
                self.assertEqual(self.plan("apps/mac/Sources/DieterMac/" + path),
                                 [["just", "mac", "test"],
                                  ["just", "mac", "smoke-suites", "core", "board", "conversation", "workspace"]])

    def test_mac_recipe_changes_run_selector_and_recipe_contract_tests(self):
        self.assertEqual(self.plan("just/mac.just"),
                         [["python3", "-m", "unittest", "discover", "-s", "scripts", "-p", "check_changed_test.py"],
                          ["just", "justfile-check"], ["just", "mac", "test"], ["just", "mac", "smoke-all"]])

    def test_changed_smoke_runners_always_run_their_suite(self):
        for runner, suites in {
            "Native": ("core", "board"),
            "Conversation": ("conversation",),
            "Machine": ("machine",),
            "SidebarNavigation": ("sidebar",),
            "Terminal": ("terminal",),
            "Island": ("island",),
            "Workspace": ("workspace",),
        }.items():
            with self.subTest(runner=runner):
                self.assertEqual(self.plan(f"apps/mac/Sources/DieterMac/Testing/{runner}UISmokeRunner.swift"),
                                 [["just", "mac", "test"], ["just", "mac", "smoke-suites", *suites]])

    def test_shared_and_unknown_mac_paths_fall_back_to_full_smokes(self):
        for path in [
            "apps/mac/Sources/DieterMac/DieterMacApp.swift",
            "apps/mac/Sources/DieterMac/UI/DieterRootView.swift",
            "apps/mac/Sources/DieterMac/UI/DieterTheme.swift",
            "apps/mac/Sources/DieterMac/Model/DieterStore+Conversation.swift",
            "apps/mac/Sources/DieterMac/Testing/NativeUIAccessibility.swift",
            "apps/mac/Sources/DieterMac/Testing/NativeUISmokeTarget.swift",
            "apps/mac/Sources/DieterMac/Testing/NativeUINavigationProbe.swift",
            "apps/mac/Sources/DieterMac/Features/NewFeature/View.swift",
            "apps/mac/Sources/DieterMac/Testing/NewUISmokeRunner.swift",
            "apps/mac/Sources/DieterAPI/Generated.swift",
            "apps/mac/Resources/asset.png", "apps/mac/Package.swift", "just/mac.just",
        ]:
            with self.subTest(path=path):
                self.assertIn(["just", "mac", "smoke-all"], self.plan(path))

    def test_mixed_mac_changes_union_suites_once_in_canonical_order(self):
        paths = [
            "apps/mac/Sources/DieterMac/UI/DieterIslandView.swift",
            "apps/mac/Sources/DieterMac/Features/Conversation/ConversationComposer.swift",
            "apps/mac/Sources/DieterMac/Testing/NativeUISmokeRunner.swift",
            "apps/mac/Sources/DieterMac/UI/BoardView.swift",
            "apps/mac/Tests/DieterMacTests/DieterIslandTests.swift",
            "README.md",
        ]
        expected = [["just", "mac", "test"],
                    ["just", "mac", "smoke-suites", "core", "board", "conversation", "island", "workspace"]]
        self.assertEqual(self.plan(*paths), expected)
        self.assertEqual(self.plan(*reversed(paths), *paths), expected)
        self.assertEqual(self.plan(*paths, "apps/mac/Sources/DieterMac/UI/DieterRootView.swift"),
                         [["just", "mac", "test"], ["just", "mac", "smoke-all"]])

    def test_subset_for_each_suite_collapses_to_full_run(self):
        paths = [f"apps/mac/Sources/DieterMac/Testing/{name}UISmokeRunner.swift"
                 for name in ["Native", "Conversation", "Machine", "SidebarNavigation", "Terminal", "Island", "Workspace"]]
        self.assertEqual(self.plan(*paths), [["just", "mac", "test"], ["just", "mac", "smoke-all"]])

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
        for path in ["api/proto/dieter/v1/dieter.proto", "scripts/generate-proto.sh",
                     "scripts/isolated-gateway/main.go", "assets/brand/icon.png"]:
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

    def test_deleted_and_moved_mac_sources_validate_both_components(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, stderr=subprocess.DEVNULL)

            git("init")
            git("config", "user.email", "test@example.invalid")
            git("config", "user.name", "Test")
            old = "apps/mac/Sources/DieterMac/UI/DieterIslandView.swift"
            deleted = "apps/mac/Sources/DieterMac/Features/Terminals/TerminalInputForwarder.swift"
            for path in [old, deleted]:
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                (root / path).write_text("fixture")
            git("add", ".")
            git("commit", "-m", "fixture")
            new = "apps/mac/Sources/DieterMac/Features/Conversation/MovedView.swift"
            (root / new).parent.mkdir(parents=True)
            git("mv", old, new)
            (root / deleted).unlink()
            self.assertEqual(plan_checks(root, changed_paths(root), packages=[]),
                             [["just", "mac", "test"],
                              ["just", "mac", "smoke-suites", "core", "board", "conversation", "terminal", "island", "workspace"]])

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
        for recipe in [["smoke-all"], ["smoke-suites", "island"]]:
            with self.subTest(recipe=recipe), \
                 patch("check_changed.output", return_value="/repo"), \
                 patch("sys.stdout", new=io.StringIO()), patch("sys.stderr", new=io.StringIO()), \
                 patch("check_changed.changed_paths", return_value=[]), \
                 patch("check_changed.plan_checks", return_value=[["just", "mac", *recipe]]), \
                 patch("sys.argv", ["check_changed.py"]), \
                 patch("check_changed.subprocess.run") as run:
                run.return_value.returncode = 0
                run.return_value.stdout = "123\n456\n"
                self.assertEqual(main(), 1)
                run.assert_called_once_with(["pgrep", "-x", "DieterMac"], capture_output=True, text=True)


@unittest.skipUnless(shutil.which("just"), "Just is needed to verify the smoke recipe")
class SelectedSmokeRecipeTests(unittest.TestCase):
    # Execute the actual recipe with stubbed Just/pgrep children. This checks
    # ordering, failure handling, and guards without compiling or launching apps.
    def invoke(self, *suites, running=1, fail=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "commands"
            (root / "just").write_text(
                '#!/bin/bash\nprintf "%s\\n" "$*" >> "$SMOKE_TEST_COMMAND_LOG"\n'
                '[[ "$*" != "$SMOKE_TEST_FAIL_COMMAND" ]]\n')
            (root / "pgrep").write_text('#!/bin/bash\nexit "$SMOKE_TEST_PGREP_EXIT"\n')
            for command in ["just", "pgrep"]:
                (root / command).chmod(0o755)
            environment = dict(os.environ, PATH=str(root) + os.pathsep + os.defpath,
                               SMOKE_TEST_COMMAND_LOG=str(log), SMOKE_TEST_FAIL_COMMAND=fail,
                               SMOKE_TEST_PGREP_EXIT=str(running))
            result = subprocess.run(
                [shutil.which("just"), "--justfile", str(Path(__file__).resolve().parents[1] / "just/mac.just"),
                 "smoke-suites", *suites], env=environment, capture_output=True, text=True, timeout=10)
            return result, log.read_text().splitlines() if log.exists() else []

    def test_builds_once_and_runs_each_selected_suite_once_in_canonical_order(self):
        result, commands = self.invoke(*reversed(MAC_SMOKE_SUITES), "island", "board")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(commands, ["mac build"] + ["mac _smoke " + suite for suite in MAC_SMOKE_SUITES])

    def test_build_and_smoke_failures_stop_remaining_suites(self):
        for failure, expected in [("mac build", ["mac build"]),
                                  ("mac _smoke board", ["mac build", "mac _smoke board"])]:
            with self.subTest(failure=failure):
                result, commands = self.invoke("island", "board", fail=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(commands, expected)

    def test_invalid_or_missing_suites_do_not_build(self):
        for suites in [(), ("island", "unknown"), ("$(exit 99)",)]:
            with self.subTest(suites=suites):
                result, commands = self.invoke(*suites)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(commands, [])

    def test_live_app_and_failed_process_check_do_not_build(self):
        for status in [0, 2]:
            with self.subTest(status=status):
                result, commands = self.invoke("island", running=status)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(commands, [])


if __name__ == "__main__":
    unittest.main()
