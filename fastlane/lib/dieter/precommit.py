#!/usr/bin/env python3
"""Local, read-only index checks. Setup is explicit; commits never download tools."""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

if sys.version_info < (3, 11):
    raise SystemExit("Local pre-commit checks require Python 3.11+.")
import tarfile
import tempfile
import tomllib
import urllib.request
import venv

ROOT = Path(__file__).resolve().parents[3]
CACHE = ROOT / "tmp/precommit"
PINS = ROOT / "fastlane/precommit-tools.json"
MAX_FILE = 5 * 1024 * 1024
EXCLUDED = (
    "apps/mac/Vendor/",
    "apps/mac/Sources/DieterAPI/Generated/",
    "internal/gen/",
    "apps/mac/Sources/DieterMac/Resources/MarkdownPreview/",
    "native/android-webrtc/",
)
CONFIGS = (".editorconfig", "apps/mac/.swift-format", ".prettierrc.json", "ruff.toml", ".streerc")
LANGUAGES = ("go", "kotlin", "swift", "prettier", "python", "ruby", "shell")


def command(argv, *, cwd=None, data=None, env=None, check=True):
    result = subprocess.run(
        argv, cwd=cwd or ROOT, input=data, capture_output=True, env=env, timeout=300
    )
    if check and result.returncode:
        raise RuntimeError(
            result.stderr.decode(errors="replace") or result.stdout.decode(errors="replace")
        )
    return result


def git(*args):
    return command(["git", *args]).stdout


def names(data):
    return [os.fsdecode(p) for p in data.split(b"\0") if p]


def index():
    raw = git("ls-files", "--stage", "-z")
    entries = {}
    for record in raw.split(b"\0"):
        if not record:
            continue
        metadata, name = record.split(b"\t", 1)
        mode, oid, stage = metadata.decode().split()
        if stage != "0":
            raise RuntimeError("Resolve merge conflicts before running pre-commit.")
        if mode in ("100644", "100755"):
            entries[os.fsdecode(name)] = oid
    return raw, entries


def authored(path):
    return (
        not path.startswith(EXCLUDED)
        and not path.startswith("testdata/")
        and "/testdata/" not in path
    )


def language(path):
    if not authored(path):
        return None
    name = Path(path).name
    if name in (
        "package-lock.json",
        "npm-shrinkwrap.json",
        "gradlew",
        "gradlew.bat",
    ) or path.startswith("landingpage/layouts/"):
        return None  # Producer-owned locks/wrappers and Hugo templates need separate handling.
    if name in ("Gemfile", "Fastfile"):
        return "ruby"
    if path == ".githooks/pre-commit":
        return "shell"
    return {
        ".go": "go",
        ".kt": "kotlin",
        ".kts": "kotlin",
        ".swift": "swift",
        ".js": "prettier",
        ".mjs": "prettier",
        ".css": "prettier",
        ".json": "prettier",
        ".yaml": "prettier",
        ".yml": "prettier",
        ".md": "prettier",
        ".html": "prettier",
        ".webmanifest": "prettier",
        ".py": "python",
        ".rb": "ruby",
        ".sh": "shell",
    }.get(Path(path).suffix)


def blob(oid):
    return git("cat-file", "blob", oid)


@contextlib.contextmanager
def snapshot(*, staged=True, all_files=False, formats_only=False):
    before, entries = index()
    if staged:
        selected = names(git("diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z", "--"))
    elif all_files:
        selected = names(git("ls-files", "--cached", "--others", "--exclude-standard", "-z"))
    else:
        selected = names(git("diff", "--name-only", "-z", "--"))
        selected += names(git("diff", "--cached", "--name-only", "-z", "--"))
        selected += names(git("ls-files", "--others", "--exclude-standard", "-z"))
    added = set(names(git("diff", "--cached", "--name-only", "--diff-filter=A", "-z", "--")))
    selected = sorted(set(selected))
    if formats_only:
        selected = [p for p in selected if language(p)]
    CACHE.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="source-", dir=CACHE) as directory:
        destination, contents, errors = Path(directory), {}, []
        for path in sorted(set(selected) | set(CONFIGS)):
            if staged:
                if path not in entries:
                    continue  # Deletions, symlinks and submodules are never dereferenced.
                size = int(git("cat-file", "-s", entries[path]))
                if size > MAX_FILE:
                    if path in selected and (path in added or language(path)):
                        errors.append(
                            f"{path!r}: {'added file' if path in added else 'source file'} exceeds 5 MiB; keep build output out of Git."
                        )
                    continue
                data = blob(entries[path])
            else:
                source = ROOT / path
                if source.is_symlink() or not source.is_file():
                    continue
                data = source.read_bytes()
            if path in selected:
                contents[path] = data
            target = destination / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        try:
            yield destination, contents, errors
        finally:
            if staged and index()[0] != before:
                raise RuntimeError(
                    "The staged index changed during checking. Review it and retry the commit."
                )


def pins():
    return json.loads(PINS.read_text())


def tools():
    state = CACHE / "tools.json"
    if not state.exists():
        raise RuntimeError("Local hook tools are missing. Run `just hooks` once on this checkout.")
    value = json.loads(state.read_text())
    if value["pins_sha256"] != hashlib.sha256(PINS.read_bytes()).hexdigest():
        raise RuntimeError("Local tool pins changed. Run `just hooks` to prepare the pinned tools.")
    if (
        value["config_sha256"]
        != hashlib.sha256((ROOT / ".pre-commit-config.yaml").read_bytes()).hexdigest()
        or value["go_version"] != go_version()
    ):
        raise RuntimeError(
            "Hook configuration or Go toolchain changed. Run `just hooks` before committing."
        )
    if value.get("ruby_version") != (ROOT / ".ruby-version").read_text().strip():
        raise RuntimeError("Ruby toolchain changed. Run `just hooks` before committing.")
    if not value.get("framework_ready") or any(
        not (CACHE / path).is_file() for path in value["framework_ready"]
    ):
        raise RuntimeError(
            "The prepared pre-commit/Gitleaks cache is incomplete. Run `just hooks` before committing."
        )
    if not value.get("formatter_ready") or any(
        not Path(path).is_file() for path in value["formatter_ready"]
    ):
        raise RuntimeError(
            "The prepared formatter cache is incomplete. Run `just hooks` before committing."
        )
    return value


def go_version():
    return re.search(r"(?m)^go (\S+)$", (ROOT / "go.mod").read_text()).group(1)


def tool_env(value):
    env = os.environ.copy()
    env["PATH"] = os.pathsep.join(
        [str(CACHE / "venv/bin"), str(Path(value["gofmt"]).parent), env.get("PATH", "")]
    )
    env["PRE_COMMIT_HOME"] = str(CACHE / "framework")
    env["GOTOOLCHAIN"] = "local"
    env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
    return env


def format_sources(directory, contents, *, write=False):
    groups = {key: [p for p in contents if language(p) == key] for key in LANGUAGES}
    if not any(groups.values()):
        return []
    value, errors = tools(), []
    for key, paths in groups.items():
        if not paths:
            continue
        executable = value[
            {
                "go": "gofmt",
                "kotlin": "ktfmt",
                "swift": "swift_format",
                "prettier": "prettier",
                "python": "ruff",
                "ruby": "stree",
                "shell": "shfmt",
            }[key]
        ]
        if not Path(executable).is_file():
            raise RuntimeError(
                f"The cached {key} formatter is missing. Run `just hooks` to prepare it again."
            )
        files = [str(directory / p) for p in paths]
        if key == "go":
            argv = [value["gofmt"], "-w" if write else "-l", *files]
        elif key == "kotlin":
            if not shutil.which("java"):
                raise RuntimeError(
                    "Kotlin changes require Java 11+ (Android Studio's JBR or a JDK)."
                )
            argv = [
                "java",
                "-Xmx1g",
                "-jar",
                value["ktfmt"],
                "--kotlinlang-style",
                "--enable-editorconfig",
            ]
            argv += [] if write else ["--dry-run", "--set-exit-if-changed"]
            argv += files
        elif key == "swift":
            config = directory / "apps/mac/.swift-format"
            if not config.exists():
                raise RuntimeError(
                    "Stage apps/mac/.swift-format alongside Swift sources when adding the configuration."
                )
            argv = [
                value["swift_format"],
                *(["format", "--in-place"] if write else ["lint", "--strict"]),
                "--configuration",
                str(config),
                *files,
            ]
        else:
            config_name = {
                "prettier": ".prettierrc.json",
                "python": "ruff.toml",
                "ruby": ".streerc",
            }.get(key)
            config = directory / config_name if config_name else None
            if config and not config.exists():
                raise RuntimeError(
                    f"Stage {config_name} alongside {key} sources when adding the configuration."
                )
            if key == "prettier":
                argv = [
                    value["node"],
                    value["prettier"],
                    "--write" if write else "--check",
                    "--config",
                    str(config),
                    "--ignore-path",
                    os.devnull,
                    *files,
                ]
            elif key == "python":
                argv = [
                    value["ruff"],
                    "format",
                    "--config",
                    str(config),
                    *([] if write else ["--check"]),
                    *files,
                ]
            elif key == "ruby":
                argv = [
                    value["ruby"],
                    value["stree"],
                    "write" if write else "check",
                    "--config=" + str(config),
                    *files,
                ]
            else:
                argv = [value["shfmt"], "-w" if write else "-d", "-i", "4", "-ci", *files]
        env = tool_env(value)
        if key == "ruby":
            env["GEM_HOME"] = env["GEM_PATH"] = value["ruby_gems"]
            env.pop("RUBYOPT", None)
            env.pop("RUBYLIB", None)
        # Run inside the snapshot so formatters cannot find live configuration.
        result = command(argv, cwd=directory, env=env, check=False)
        if result.returncode or (key == "go" and result.stdout):
            detail = (
                (result.stdout + result.stderr)
                .decode(errors="replace")
                .replace(str(directory) + "/", "")
            )
            errors.append(
                f"{key} formatting:\n{detail[:8000]}\nRun `just format`, review changes, and stage the result."
            )
    return errors


def integrity(contents):
    import yaml  # Supplied by the pinned pre-commit environment.

    errors = []
    for path, data in contents.items():
        if not authored(path) or "\0" in data[:8192].decode(errors="replace"):
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            continue  # Images, fonts, wrapper JARs, and other binary assets.
        try:
            suffix = Path(path).suffix
            if suffix == ".json":
                json.loads(text)
            elif suffix in (".yaml", ".yml"):
                list(yaml.safe_load_all(text))
            elif suffix == ".toml":
                tomllib.loads(text)
            if re.search(r"(?m)^(?:<{7}(?: .*)?|={7}|>{7}(?: .*)?)$", text):
                raise ValueError("merge conflict marker")
            if text and not text.endswith("\n"):
                raise ValueError("missing final newline")
            if not language(path) or suffix == ".md":
                for line in text.splitlines():
                    trailing = line[len(line.rstrip(" \t")) :]
                    if trailing and not (suffix == ".md" and trailing == "  "):
                        raise ValueError("trailing whitespace")
        except (ValueError, yaml.YAMLError) as error:
            errors.append(f"{path!r}: {error}")
    return errors


def check():
    with snapshot() as (directory, contents, errors):
        errors += integrity(contents)
        errors += format_sources(directory, contents)
        if errors:
            raise RuntimeError("\n".join(errors))


def format_working(*, all_files=False, check_only=False):
    with snapshot(staged=False, all_files=all_files, formats_only=True) as (
        directory,
        contents,
        errors,
    ):
        errors += format_sources(directory, contents, write=not check_only)
        if errors:
            raise RuntimeError("\n".join(errors))
        if not check_only:
            # Refuse to overwrite an edit made since the explicit formatting command started.
            for path, original in contents.items():
                if (ROOT / path).read_bytes() != original:
                    raise RuntimeError(
                        f"{path!r} changed while formatting. Retry after reviewing the edit."
                    )
            for path, original in contents.items():
                formatted = (directory / path).read_bytes()
                if original != formatted:
                    target = ROOT / path
                    if target.is_symlink() or target.read_bytes() != original:
                        raise RuntimeError(
                            f"{path!r} changed while formatting. Review it before retrying."
                        )
                    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as output:
                        output.write(formatted)
                        temporary = Path(output.name)
                    temporary.chmod(target.stat().st_mode)
                    temporary.replace(target)
                    print(f"Formatted {path}")
        print(f"Checked {len(contents)} authored source files.")


def download(url, target, sha256, *, headers=None):
    if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == sha256:
        return
    with urllib.request.urlopen(
        urllib.request.Request(url, headers=headers or {}), timeout=120
    ) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != sha256:
        raise RuntimeError(f"Checksum mismatch for {target.name}; nothing was installed.")
    temporary = target.with_suffix(".download")
    temporary.write_bytes(data)
    temporary.replace(target)


def prepare():
    settings = pins()
    node, ruby = shutil.which("node"), shutil.which("ruby")
    if not node or not ruby:
        raise RuntimeError(
            "Hook setup requires Node 22+ and Ruby from .ruby-version on PATH, in addition to Python and Go."
        )
    if int(command([node, "--version"]).stdout.decode().strip().lstrip("v").split(".")[0]) < 22:
        raise RuntimeError("Hook setup requires Node 22+.")
    ruby_version = command([ruby, "-e", "print RUBY_VERSION"]).stdout.decode()
    if ruby_version != (ROOT / ".ruby-version").read_text().strip():
        raise RuntimeError("Use the Ruby release from .ruby-version before running `just hooks`.")
    CACHE.mkdir(parents=True, exist_ok=True)
    python = CACHE / "venv/bin/python"
    if not python.exists():
        venv.EnvBuilder(with_pip=True).create(CACHE / "venv")
    subprocess.run(
        [
            str(python),
            "-m",
            "pip",
            "install",
            "--disable-pip-version-check",
            "pre-commit==" + settings["pre_commit"],
            "PyYAML==" + settings["pyyaml"],
            "ruff==" + settings["ruff"],
        ],
        cwd=ROOT,
        check=True,
    )
    jar = CACHE / ("ktfmt-" + settings["ktfmt"]["version"] + ".jar")
    download(settings["ktfmt"]["url"], jar, settings["ktfmt"]["sha256"])
    swift = CACHE / "swift-format"
    swift_settings = settings["swift_format"]
    key = platform.system() + "-" + platform.machine()
    if key not in swift_settings["bottles"]:
        raise RuntimeError(
            f"No pinned swift-format binary for {key}. Supported: {', '.join(swift_settings['bottles'])}"
        )
    digest = swift_settings["bottles"][key]
    archive = CACHE / ("swift-format-" + digest + ".tar.gz")
    if not archive.exists():
        token_url = (
            "https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/swift-format:pull"
        )
        with urllib.request.urlopen(token_url, timeout=30) as response:
            token = json.load(response)["token"]
        download(
            "https://ghcr.io/v2/homebrew/core/swift-format/blobs/sha256:" + digest,
            archive,
            digest,
            headers={"Authorization": "Bearer " + token},
        )
    if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise RuntimeError(
            "Cached Swift formatter archive failed verification; remove it and run `just hooks`."
        )
    with tarfile.open(archive) as bundle:
        member = next(m for m in bundle if m.isfile() and m.name.endswith("/bin/swift-format"))
        swift.write_bytes(bundle.extractfile(member).read())
        swift.chmod(0o755)
    if command([str(swift), "--version"]).stdout.decode().strip() != swift_settings["version"]:
        raise RuntimeError("The prepared Swift formatter does not match the pinned release.")
    version = go_version()
    env = os.environ.copy()
    env["GOTOOLCHAIN"] = "go" + version
    goroot = command(["go", "env", "GOROOT"], env=env).stdout.decode().strip()
    state = {
        "gofmt": str(Path(goroot) / "bin/gofmt"),
        "go_version": version,
        "ktfmt": str(jar),
        "swift_format": str(swift),
        "pins_sha256": hashlib.sha256(PINS.read_bytes()).hexdigest(),
        "config_sha256": hashlib.sha256(
            (ROOT / ".pre-commit-config.yaml").read_bytes()
        ).hexdigest(),
    }
    prettier_settings = settings["prettier"]
    archive = CACHE / ("prettier-" + prettier_settings["version"] + ".tgz")
    download(prettier_settings["url"], archive, prettier_settings["sha256"])
    package = CACHE / ("prettier-" + prettier_settings["version"])
    with tarfile.open(archive) as bundle:
        for member in bundle.getmembers():
            if not member.isfile():
                continue
            relative = Path(member.name).relative_to("package")
            if ".." in relative.parts:
                raise RuntimeError("Unexpected path in the Prettier package.")
            target = package / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(bundle.extractfile(member).read())
    gems = CACHE / "ruby-gems"
    ruby_env = tool_env(state)
    ruby_env["GEM_HOME"] = ruby_env["GEM_PATH"] = str(gems)
    ruby_env.pop("RUBYOPT", None)
    ruby_env.pop("RUBYLIB", None)
    for name, gem in settings["ruby_gems"].items():
        archive = CACHE / (name + "-" + gem["version"] + ".gem")
        download("https://rubygems.org/downloads/" + archive.name, archive, gem["sha256"])
        # Install the complete pinned dependency set without asking RubyGems to resolve it.
        command(
            [
                ruby,
                str(Path(ruby).with_name("gem")),
                "install",
                "--local",
                "--ignore-dependencies",
                "--no-document",
                "--install-dir",
                str(gems),
                str(archive),
            ],
            env=ruby_env,
        )
    env["GOBIN"] = str(CACHE / "bin")
    command(
        [str(Path(goroot) / "bin/go"), "install", "mvdan.cc/sh/v3/cmd/shfmt@" + settings["shfmt"]],
        env=env,
    )
    state.update(
        {
            "node": node,
            "prettier": str(package / "bin/prettier.cjs"),
            "ruff": str(CACHE / "venv/bin/ruff"),
            "ruby": ruby,
            "ruby_version": ruby_version,
            "ruby_gems": str(gems),
            "stree": str(
                gems
                / "gems"
                / ("syntax_tree-" + settings["ruby_gems"]["syntax_tree"]["version"])
                / "exe/stree"
            ),
            "shfmt": str(CACHE / "bin/shfmt"),
        }
    )
    if (
        command([node, state["prettier"], "--version"]).stdout.decode().strip()
        != prettier_settings["version"]
    ):
        raise RuntimeError("The prepared Prettier does not match the pinned release.")
    state["formatter_ready"] = [
        state[key]
        for key in (
            "gofmt",
            "ktfmt",
            "swift_format",
            "node",
            "prettier",
            "ruff",
            "ruby",
            "stree",
            "shfmt",
        )
    ]
    state["formatter_ready"] += [
        str(gems / "specifications" / (name + "-" + gem["version"] + ".gemspec"))
        for name, gem in settings["ruby_gems"].items()
    ]
    # No hook is installed until all tools and the upstream secret scanner are ready.
    subprocess.run(
        [str(python), "-m", "pre_commit", "install-hooks"],
        cwd=ROOT,
        env=tool_env(state),
        check=True,
    )
    # Resolve the installed hook for the current pinned revision, not an older cache entry.
    locator = (
        "from pre_commit.clientlib import load_config; "
        "from pre_commit.repository import all_hooks; "
        "from pre_commit.store import Store; "
        "from pre_commit.lang_base import environment_dir; "
        "from pre_commit.all_languages import languages; "
        "import os; "
        "hook = next(h for h in all_hooks(load_config('.pre-commit-config.yaml'), Store()) if h.id == 'gitleaks'); "
        "print(os.path.join(environment_dir(hook.prefix, languages[hook.language].ENVIRONMENT_DIR, hook.language_version), 'bin', 'gitleaks'))"
    )
    scanner = Path(
        command([str(python), "-c", locator], env=tool_env(state)).stdout.decode().strip()
    )
    environment = scanner.parent.parent
    state["framework_ready"] = [
        str(path.relative_to(CACHE))
        for path in (
            python,
            CACHE / "framework/db.db",
            scanner,
            environment / ".install_state_v2",
            environment.parent / ".pre-commit-hooks.yaml",
        )
    ]
    temporary = CACHE / "tools.json.new"
    temporary.write_text(json.dumps(state, indent=2) + "\n")
    temporary.replace(CACHE / "tools.json")


def install():
    existing = (
        command(["git", "config", "--get", "core.hooksPath"], check=False).stdout.decode().strip()
    )
    if existing and existing != ".githooks":
        raise RuntimeError(
            f"Preserving existing hooksPath {existing!r}; integrate the Dieter hook there explicitly."
        )
    if (
        command(["git", "config", "--get", "core.worktree"], check=False).stdout.strip()
        or git("rev-parse", "--is-bare-repository").strip() == b"true"
    ):
        raise RuntimeError(
            "Worktree-local hook setup requires a non-bare repository without core.worktree."
        )
    if not existing:
        hooks = Path(os.fsdecode(git("rev-parse", "--git-path", "hooks").strip()))
        hooks = hooks if hooks.is_absolute() else ROOT / hooks
        for installed in hooks.iterdir() if hooks.exists() else ():
            if (
                installed.name.endswith(".sample")
                or not os.access(installed, os.X_OK)
                or not installed.is_file()
            ):
                continue
            if (
                installed.name == "pre-commit"
                and b"File generated by pre-commit" in installed.read_bytes()
            ):
                continue
            raise RuntimeError(
                f"Preserving existing {installed.name!r} hook. Integrate the Dieter pre-commit dispatcher explicitly."
            )
    CACHE.mkdir(parents=True, exist_ok=True)
    with (CACHE / "setup.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        prepare()
    hook = ROOT / ".githooks/pre-commit"
    hook.chmod(0o755)
    git("config", "extensions.worktreeConfig", "true")
    git("config", "--worktree", "core.hooksPath", ".githooks")
    print(
        "Installed read-only local hooks for this worktree. Other worktrees retain their hook configuration."
    )


def run():
    value = tools()
    before = index()[0]
    try:
        result = subprocess.run(
            [
                str(CACHE / "venv/bin/python"),
                "-m",
                "pre_commit",
                "run",
                "--all-files",
                "--hook-stage",
                "pre-commit",
            ],
            cwd=ROOT,
            env=tool_env(value),
            timeout=300,
        )
    finally:
        if index()[0] != before:
            raise RuntimeError("The staged index changed during pre-commit. Review it and retry.")
    return result.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action", choices=("install", "run", "check", "format", "format-check", "test")
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Format/check all authored working-tree source files instead of changed files",
    )
    args = parser.parse_args()
    if args.all and args.action not in ("format", "format-check"):
        parser.error("--all is only supported for format and format-check")
    if sys.version_info < (3, 11):
        parser.error("Python 3.11+ is required")
    try:
        if args.action == "install":
            install()
        elif args.action == "run":
            return run()
        elif args.action == "check":
            check()
        elif args.action == "test":
            value = tools()
            return subprocess.run(
                [
                    str(CACHE / "venv/bin/python"),
                    "-m",
                    "unittest",
                    "discover",
                    "-s",
                    "fastlane/spec/precommit",
                    "-p",
                    "test_*.py",
                    "-v",
                ],
                cwd=ROOT,
                env=tool_env(value),
                timeout=300,
            ).returncode
        else:
            format_working(all_files=args.all, check_only=args.action == "format-check")
    except (RuntimeError, OSError, subprocess.SubprocessError, StopIteration) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
