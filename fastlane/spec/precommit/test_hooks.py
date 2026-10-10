"""Isolated Git fixtures qualify staged checks without touching operator checkouts."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
RUNNER = ROOT / "fastlane/lib/dieter/precommit.py"
CACHE = ROOT / "tmp/precommit"


class PrecommitTest(unittest.TestCase):
    def setUp(self):
        parent = ROOT / "tmp/precommit-tests"
        parent.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=parent)
        self.repo = Path(self.temporary.name)
        spec = importlib.util.spec_from_file_location("dieter_precommit", RUNNER)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.module.ROOT = self.repo
        self.module.CACHE = CACHE
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        for name in (
            *self.module.CONFIGS,
            ".ruby-version",
            ".pre-commit-config.yaml",
            "go.mod",
            "fastlane/precommit-tools.json",
            "fastlane/lib/dieter/precommit.py",
            ".githooks/pre-commit",
        ):
            self.put(name, (ROOT / name).read_bytes())
        self.put("base.go", b"package fixture\n\nvar Base = 1\n")
        self.git("add", ".")
        self.git(
            "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "commit", "-qm", "base"
        )
        (self.repo / "tmp").mkdir()
        (self.repo / "tmp/precommit").symlink_to(CACHE, target_is_directory=True)

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True).stdout

    def put(self, name, data):
        target = self.repo / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)

    def staged(self, name, data):
        self.put(name, data)
        self.git("add", "--", name)

    def index_bytes(self):
        return (self.repo / ".git/index").read_bytes()

    def check_unchanged(self, failing=False):
        before = self.index_bytes()
        source = (self.repo / "base.go").read_bytes()
        if failing:
            with self.assertRaises(RuntimeError):
                self.module.check()
        else:
            self.module.check()
        self.assertEqual(before, self.index_bytes())
        self.assertEqual(source, (self.repo / "base.go").read_bytes())

    def test_unformatted_staged_bytes_fail_even_when_working_file_is_formatted(self):
        self.staged("base.go", b"package fixture\n\nvar Base=2\n")
        self.put("base.go", b"package fixture\n\nvar Base = 3\n")
        self.check_unchanged(failing=True)

    def test_formatted_staged_bytes_pass_even_when_working_file_is_unformatted(self):
        self.staged("base.go", b"package fixture\n\nvar Base = 2\n")
        self.put("base.go", b"package fixture\n\nvar Base=3\n")
        self.check_unchanged()

    def test_edit_arriving_during_checks_survives(self):
        self.staged("base.go", b"package fixture\n\nvar Base = 2\n")
        original = self.module.format_sources

        def during(*args, **kwargs):
            self.put("base.go", b"package fixture\n\nvar Base=99\n")
            return original(*args, **kwargs)

        before = self.index_bytes()
        with patch.object(self.module, "format_sources", side_effect=during):
            self.module.check()
        self.assertEqual(before, self.index_bytes())
        self.assertEqual(b"package fixture\n\nvar Base=99\n", (self.repo / "base.go").read_bytes())

    def test_index_change_during_checks_fails(self):
        self.staged("base.go", b"package fixture\n\nvar Base = 2\n")
        original = self.module.format_sources

        def during(*args, **kwargs):
            self.staged("base.go", b"package fixture\n\nvar Base = 3\n")
            return original(*args, **kwargs)

        with patch.object(self.module, "format_sources", side_effect=during):
            with self.assertRaisesRegex(RuntimeError, "index changed"):
                self.module.check()

    def test_initial_commit_rename_delete_and_unusual_names(self):
        self.git("update-ref", "-d", "HEAD")
        self.module.check()
        self.git(
            "-c",
            "core.hooksPath=/dev/null",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "-qm",
            "initial",
        )
        self.git("mv", "base.go", "space and\nnewline.go")
        self.module.check()
        self.git("rm", "-f", "--", "space and\nnewline.go")
        self.module.check()

    def test_symlinks_generated_vendor_and_byte_fixtures_are_not_formatted(self):
        (self.repo / "link.go").symlink_to("base.go")
        self.git("add", "link.go")
        for name in (
            "internal/gen/test.go",
            "apps/mac/Vendor/test.swift",
            "apps/mac/Sources/DieterAPI/Generated/test.swift",
            "some/testdata/test.go",
            "testdata/root.go",
        ):
            self.staged(name, b"not valid source")
        self.module.check()

    def test_malformed_file_syntax_conflicts_and_large_additions_fail(self):
        cases = {
            "bad.json": b"{\n",
            "bad.yaml": b"a: [\n",
            "bad.toml": b"x = [\n",
            "conflict.txt": b"<<<<<<< branch\na\n=======\nb\n>>>>>>> other\n",
        }
        for name, data in cases.items():
            with self.subTest(name=name):
                self.staged(name, data)
                with self.assertRaises(RuntimeError):
                    self.module.check()
                self.git("reset", "-q", "HEAD", "--", name)
        self.staged("build-output.bin", b"\0" * (self.module.MAX_FILE + 1))
        with self.assertRaisesRegex(RuntimeError, "exceeds 5 MiB"):
            self.module.check()

    def test_markdown_hard_breaks_are_preserved(self):
        self.staged("guide.md", b"First line  \nSecond line\n")
        self.module.check()
        self.staged("guide.md", b"First line   \nSecond line\n")
        with self.assertRaisesRegex(RuntimeError, "trailing whitespace"):
            self.module.check()

    def test_swift_uses_staged_configuration_and_includes_share_and_native_sources(self):
        config = json.loads((ROOT / "apps/mac/.swift-format").read_text())
        config["indentation"] = {"spaces": 2}
        self.staged("apps/mac/.swift-format", (json.dumps(config) + "\n").encode())
        # Keep a different configuration in the live checkout.
        self.put("apps/mac/.swift-format", (ROOT / "apps/mac/.swift-format").read_bytes())
        source = b"struct Example {\n  let value: Int\n}\n"
        for name in ("apps/ios/App/Example.swift", "native/macos-capture/Example.swift"):
            self.staged(name, source)
        self.module.check()
        self.assertEqual(
            (ROOT / "apps/mac/.swift-format").read_bytes(),
            (self.repo / "apps/mac/.swift-format").read_bytes(),
        )

    def test_kotlin_and_gradle_scripts_are_checked(self):
        self.staged("apps/core/Example.kt", b"class Example {val value=1}\n")
        self.staged("apps/core/build.gradle.kts", b'plugins { kotlin("jvm") }\n')
        with self.assertRaisesRegex(RuntimeError, "kotlin formatting"):
            self.module.check()
        self.module.format_working()
        self.git("add", "apps/core")
        self.module.check()

    def test_additional_formatters_reject_bad_staged_bytes_and_preserve_working_edits(self):
        sources = {
            "web script.mjs": b"const value={answer:42};\n",
            "module.js": b"let value=[1,2];\n",
            "theme.css": b"body{color:red}\n",
            "data.json": b'{"value":1}\n',
            "config.yaml": b"items: [one,two]\n",
            "config.yml": b"items: [one,two]\n",
            "guide.md": b"#Heading\n\n-   one\n",
            "page.html": b"<div   id = 'page' >hello</div>\n",
            "manifest.webmanifest": b'{"name":"Example"}\n',
            "example.py": b"value={'answer':42}\n",
            "example.rb": b"value={answer:42}\n",
            "Gemfile": b"source('https://rubygems.org')\n",
            "fastlane/Fastfile": b"lane(:demo){puts 'hello'}\n",
            "check.sh": b"#!/bin/sh\nif true;then echo hello;fi\n",
        }
        for name, source in sources.items():
            with self.subTest(name=name):
                self.staged(name, source)
                before = self.index_bytes()
                with self.assertRaisesRegex(RuntimeError, "formatting"):
                    self.module.check()
                self.assertEqual(before, self.index_bytes())
                self.assertEqual(source, (self.repo / name).read_bytes())
                self.module.format_working()
                formatted = (self.repo / name).read_bytes()
                self.assertNotEqual(source, formatted)
                self.module.format_working(check_only=True)
                self.git("add", "--", name)
                self.put(name, source)
                self.module.check()
                self.assertEqual(source, (self.repo / name).read_bytes())
                self.git("reset", "-q", "HEAD", "--", name)
                (self.repo / name).unlink()

    def test_new_formatters_use_staged_configuration(self):
        prettier = json.loads((ROOT / ".prettierrc.json").read_text())
        prettier["semi"] = False
        self.staged(".prettierrc.json", (json.dumps(prettier, indent=2) + "\n").encode())
        self.staged("ruff.toml", b'line-length = 100\ntarget-version = "py311"\nindent-width = 2\n')
        self.staged(".streerc", b"--print-width=20\n")
        self.staged("module.js", b"const answer = 42\n")
        self.staged("example.py", b"def example():\n  return 42\n")
        self.staged(
            "example.rb",
            b"values = [\n  1,\n  2,\n  3,\n  4,\n  5,\n  6,\n  7,\n  8,\n  9,\n  10\n]\n",
        )
        for name in (".prettierrc.json", "ruff.toml", ".streerc"):
            self.put(name, (ROOT / name).read_bytes())
        self.module.check()

    def test_templates_xml_lockfiles_and_generated_wrappers_are_not_formatted(self):
        for name in (
            "landingpage/layouts/partials/example.html",
            "apps/android/gradlew",
            "apps/android/app/src/main/res/values/example.xml",
            "apps/android/gradlew.bat",
            "package-lock.json",
        ):
            self.assertIsNone(self.module.language(name))
        self.staged("landingpage/layouts/partials/example.html", b"{{- arbitrary template -}}\n")
        self.staged("package-lock.json", b'{"lockfileVersion":3}\n')
        self.staged("apps/android/gradlew", b"#!/bin/sh\nif true;then echo hello;fi\n")
        self.module.check()

    def test_explicit_formatting_refuses_to_overwrite_concurrent_working_edit(self):
        self.staged("example.py", b"value={'answer':42}\n")
        original = self.module.format_sources

        def during(*args, **kwargs):
            result = original(*args, **kwargs)
            self.put("example.py", b"value = 'concurrent edit'\n")
            return result

        before = self.index_bytes()
        with patch.object(self.module, "format_sources", side_effect=during):
            with self.assertRaisesRegex(RuntimeError, "changed while formatting"):
                self.module.format_working()
        self.assertEqual(before, self.index_bytes())
        self.assertEqual(b"value = 'concurrent edit'\n", (self.repo / "example.py").read_bytes())

    def test_missing_prepared_tools_fail_without_bootstrapping(self):
        self.staged("base.go", b"package fixture\n\nvar Base = 2\n")
        with patch.object(self.module, "CACHE", self.repo / "missing-tools"):
            with self.assertRaisesRegex(RuntimeError, "just hooks"):
                self.module.check()

    def test_incomplete_scanner_cache_fails_before_launching_framework(self):
        cache = self.repo / "incomplete-cache"
        cache.mkdir()
        (cache / "tools.json").write_bytes((CACHE / "tools.json").read_bytes())
        with (
            patch.object(self.module, "CACHE", cache),
            patch.object(self.module.subprocess, "run") as launch,
        ):
            with self.assertRaisesRegex(RuntimeError, "cache is incomplete.*just hooks"):
                self.module.run()
            launch.assert_not_called()

    def run_framework(self):
        env = os.environ.copy()
        env["HTTP_PROXY"] = env["HTTPS_PROXY"] = "http://127.0.0.1:9"
        return subprocess.run(
            ["python3", "fastlane/lib/dieter/precommit.py", "run"],
            cwd=self.repo,
            env=env,
            capture_output=True,
            timeout=60,
        )

    def test_cached_framework_is_offline_and_does_not_stash(self):
        self.staged("base.go", b"package fixture\n\nvar Base = 2\n")
        for name, source in {
            "module.js": b"const answer = 42;\n",
            "example.py": b"answer = 42\n",
            "example.rb": b"answer = 42\n",
            "check.sh": b"#!/bin/sh\necho hello\n",
        }.items():
            self.staged(name, source)
        self.put("base.go", b"package fixture\n\nvar Base=3\n")
        before = self.index_bytes()
        result = self.run_framework()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertNotIn(b"Stashing", result.stdout + result.stderr)
        self.assertEqual(before, self.index_bytes())
        self.assertEqual(b"package fixture\n\nvar Base=3\n", (self.repo / "base.go").read_bytes())

    def test_installed_git_hook_blocks_bad_staged_source_and_preserves_unstaged_edits(self):
        with patch.object(self.module, "prepare"):
            self.module.install()
        head = self.git("rev-parse", "HEAD")
        self.staged("base.go", b"package fixture\n\nvar Base=2\n")
        rejected = subprocess.run(
            ["git", "-c", "commit.gpgsign=false", "commit", "-m", "bad"],
            cwd=self.repo,
            capture_output=True,
        )
        self.assertNotEqual(0, rejected.returncode)
        self.assertEqual(head, self.git("rev-parse", "HEAD"))
        self.staged("base.go", b"package fixture\n\nvar Base = 2\n")
        self.put("base.go", b"package fixture\n\nvar Base=3\n")
        committed = subprocess.run(
            ["git", "-c", "commit.gpgsign=false", "commit", "-m", "good"],
            cwd=self.repo,
            capture_output=True,
        )
        self.assertEqual(0, committed.returncode, committed.stdout + committed.stderr)
        self.assertEqual(b"package fixture\n\nvar Base = 2\n", self.git("show", "HEAD:base.go"))
        self.assertEqual(b"package fixture\n\nvar Base=3\n", (self.repo / "base.go").read_bytes())

    def test_secret_scan_fails_and_redacts_fixture_token(self):
        token = b"ghp_" + b"aB3dE5fG7hI9jK1lM3nO5pQ7rS9tU1vW3xY5"
        self.staged("fixture.env", b"GITHUB_TOKEN=" + token + b"\n")
        before = self.index_bytes()
        result = self.run_framework()
        self.assertNotEqual(0, result.returncode)
        self.assertIn(b"Detect hardcoded secrets", result.stdout + result.stderr)
        self.assertIn(b"github-pat", result.stdout + result.stderr)
        self.assertIn(b"REDACTED", result.stdout + result.stderr)
        self.assertNotIn(token, result.stdout + result.stderr)
        self.assertEqual(before, self.index_bytes())

    def test_installer_preserves_custom_hooks_and_other_worktree_configuration(self):
        self.git("config", "core.hooksPath", "operator-hooks")
        with patch.object(self.module, "prepare") as prepare:
            with self.assertRaisesRegex(RuntimeError, "Preserving existing"):
                self.module.install()
            prepare.assert_not_called()
        self.git("config", "--unset", "core.hooksPath")
        other = self.repo.parent / (self.repo.name + "-other")
        try:
            self.git("worktree", "add", "-qb", "other", str(other))
            with patch.object(self.module, "prepare"):
                self.module.install()
            self.assertEqual(b".githooks\n", self.git("config", "--get", "core.hooksPath"))
            result = subprocess.run(
                ["git", "config", "--get", "core.hooksPath"], cwd=other, capture_output=True
            )
            self.assertEqual(1, result.returncode)
        finally:
            self.git("worktree", "remove", "--force", str(other))


if __name__ == "__main__":
    unittest.main()
