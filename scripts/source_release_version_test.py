import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/source_release_version.sh"


def git(directory, *args):
    return subprocess.run(
        ["git", "-C", str(directory), *args],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


class SourceReleaseVersionTests(unittest.TestCase):
    def test_shallow_clone_fetches_history_and_tags_before_versioning(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary = pathlib.Path(temporary_directory)
            source = temporary / "source"
            source.mkdir()
            git(source, "init", "--initial-branch=main")
            git(source, "config", "user.name", "Dieter Test")
            git(source, "config", "user.email", "dieter@example.invalid")
            scripts = source / "scripts"
            scripts.mkdir()
            shutil.copy2(SCRIPT, scripts / SCRIPT.name)
            (source / "fixture.txt").write_text("stable\n", encoding="utf-8")
            git(source, "add", ".")
            git(source, "commit", "-m", "stable")
            git(source, "tag", "v0.4.324")
            (source / "fixture.txt").write_text("development\n", encoding="utf-8")
            git(source, "commit", "-am", "development")

            clone = temporary / "clone"
            subprocess.run(
                ["git", "clone", "--depth=1", "--no-tags", source.as_uri(), str(clone)],
                check=True,
                capture_output=True,
                text=True,
            )
            self.assertEqual(git(clone, "rev-parse", "--is-shallow-repository"), "true")
            self.assertEqual(git(clone, "tag", "--list"), "")

            environment = dict(os.environ)
            environment.pop("GIT_DIR", None)
            version = subprocess.run(
                [str(clone / "scripts/source_release_version.sh")],
                cwd=temporary,
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            ).stdout.strip()

            self.assertEqual(version, f"0.4.325-dev.2+{git(clone, 'rev-parse', '--short=8', 'HEAD')}")
            self.assertEqual(git(clone, "rev-parse", "--is-shallow-repository"), "false")
            self.assertEqual(git(clone, "tag", "--list"), "v0.4.324")


if __name__ == "__main__":
    unittest.main()
