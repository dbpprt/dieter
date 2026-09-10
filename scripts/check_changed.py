#!/usr/bin/env python3
"""Plan and run local validation from Git changes, without touching services."""

import argparse
import json
from pathlib import Path
import shlex
import subprocess
import sys


MAC_SMOKE_SUITES = ("core", "board", "conversation", "machine", "sidebar", "terminal", "island", "workspace")
MAC_SOURCE_ROOT = "apps/mac/Sources/DieterMac/"

# This is a conservative component map, not a Swift dependency graph. Shared
# app/store/navigation/theme code and unclassified paths always run every suite.
# Keep entries in sync with the surfaces exercised by the native smoke runners.
MAC_SMOKE_COMPONENTS = {
    "Features/Conversation/": ("core", "board", "conversation", "workspace"),
    "Features/Changes/": ("workspace",),
    "Features/Files/": ("core", "workspace"),
    "Features/Terminals/": ("terminal",),
    "Features/Schedules/": ("core", "board"),
    "Features/Search/": ("core", "board", "sidebar"),
}
MAC_SMOKE_FILES = {
    "Testing/NativeUISmokeRunner.swift": ("core", "board"),
    "Testing/ConversationUISmokeRunner.swift": ("conversation",),
    "Testing/MachineUISmokeRunner.swift": ("machine",),
    "Testing/SidebarNavigationUISmokeRunner.swift": ("sidebar",),
    "Testing/TerminalUISmokeRunner.swift": ("terminal",),
    "Testing/IslandUISmokeRunner.swift": ("island",),
    "Testing/WorkspaceUISmokeRunner.swift": ("workspace",),
    "UI/BoardView.swift": ("core", "board", "conversation", "workspace"),
    "UI/BoardLaneList.swift": ("core", "board"),
    "UI/BoardCardMergeDrop.swift": ("board",),
    "UI/BoardConversationOverlay.swift": ("core", "board", "conversation", "workspace"),
    "UI/ChatsView.swift": ("core", "conversation", "sidebar"),
    "UI/ConversationMarkdownView.swift": ("core", "board", "conversation"),
    "UI/SelectableMessageText.swift": ("core", "board", "conversation"),
    "UI/Attachments.swift": ("core", "board", "conversation"),
    "UI/CaptureTask.swift": ("core", "board", "conversation", "island"),
    "UI/DieterIslandView.swift": ("island",),
    "UI/DieterIslandWindow.swift": ("island",),
    "UI/MachinesView.swift": ("core", "machine", "sidebar"),
    "UI/FilePaneSplit.swift": ("workspace",),
    "Features/Forms/EditCardSheet.swift": ("core", "board"),
    "Features/Forms/LabelForms.swift": ("core", "board"),
    "Features/Forms/BoardForms.swift": ("core", "board"),
    "Features/Forms/HarnessFields.swift": ("core", "board", "conversation"),
    "Features/Forms/NewConversationSheet.swift": ("core", "board", "conversation"),
    "Features/Forms/ConversationWorkspacePickerSheet.swift": ("core", "board", "workspace"),
    "Model/BoardProjection.swift": ("core", "board"),
    "Model/DieterIslandPreferences.swift": ("island",),
    "Model/TerminalOutputAccumulator.swift": ("terminal",),
    "Model/FileEditorSession.swift": ("core", "workspace"),
    "Model/FileSyntaxHighlightPlan.swift": ("core", "workspace"),
    "Model/ProjectChangesModel.swift": ("workspace",),
    "Model/WorkspaceGit.swift": ("workspace",),
    "Model/WorkspaceReview.swift": ("workspace",),
    "Model/PinnedChatNavigationPreferences.swift": ("core", "sidebar"),
    "Model/ChatProjectDisclosurePreferences.swift": ("core", "sidebar"),
    "Model/SidebarProjectNavigationPreferences.swift": ("core", "sidebar"),
    "Model/ConversationRenderCache.swift": ("core", "board", "conversation"),
    "Model/ConversationPresentation.swift": ("core", "board", "conversation"),
    "Model/ConversationTurnFailure.swift": ("core", "board", "conversation"),
    "Model/ConversationMessagePartGroup.swift": ("core", "board", "conversation"),
    "Model/ConversationMarkdown.swift": ("core", "board", "conversation"),
    "Model/ConversationCreationPreferences.swift": ("core", "board", "conversation"),
    "Model/ReasoningTracePreferences.swift": ("core", "board", "conversation"),
    "Model/SubagentUsagePresentation.swift": ("core", "board", "conversation"),
    "Model/AttachmentLoader.swift": ("core", "board", "conversation", "island"),
}


def affected_mac_smoke_suites(paths):
    selected = set()
    for path in paths:
        if path.startswith(("api/proto/", "scripts/isolated-gateway/", "assets/brand/")) \
                or path in {"scripts/generate-proto.sh", "just/mac.just"}:
            return MAC_SMOKE_SUITES
        if not path.startswith("apps/mac/") or path.startswith("apps/mac/Tests/"):
            continue
        relative = path.removeprefix(MAC_SOURCE_ROOT)
        suites = MAC_SMOKE_FILES.get(relative)
        if suites is None:
            suites = next((suites for prefix, suites in MAC_SMOKE_COMPONENTS.items()
                           if relative.startswith(prefix)), None)
        if suites is None:
            return MAC_SMOKE_SUITES
        selected.update(suites)
    # Paths need not exist: deleted and renamed files validate their old component
    # too. Union mixed edits once, in the same order as the full smoke run.
    return tuple(suite for suite in MAC_SMOKE_SUITES if suite in selected)


def output(root, *args):
    return subprocess.check_output(args, cwd=root).decode()


def changed_paths(root, base=None):
    # Disabling rename detection keeps both the deleted and added paths, so
    # moving code between components validates both sides of the move.
    revision = output(root, "git", "merge-base", base, "HEAD").strip() if base else "HEAD"
    tracked = output(root, "git", "diff", "--name-only", "--no-renames", "-z", revision, "--")
    untracked = output(root, "git", "ls-files", "--others", "--exclude-standard", "-z")
    return sorted(set(filter(None, (tracked + untracked).split("\0"))))


def go_packages(root):
    raw = output(root, "go", "list", "-json", "./...")
    decoder = json.JSONDecoder()
    packages = []
    while raw.strip():
        package, end = decoder.raw_decode(raw.lstrip())
        packages.append(package)
        raw = raw.lstrip()[end:]
    return packages


def affected_go_packages(root, paths, packages):
    by_name = {p["ImportPath"]: p for p in packages}
    if any(p in {"go.mod", "go.sum", "just/daemon.just", "just/gateway.just"}
           or p.startswith(("api/proto/", "native/")) for p in paths):
        return sorted(by_name)
    affected = set()
    for package in packages:
        directory = Path(package["Dir"]).relative_to(root).as_posix()
        owned = {directory + "/" + file for field in ("EmbedFiles", "TestEmbedFiles", "XTestEmbedFiles")
                 for file in package.get(field, [])}
        if any(Path(path).parent.as_posix() == directory or path in owned
               or path.startswith(directory + "/testdata/") for path in paths):
            affected.add(package["ImportPath"])
    # Include reverse dependencies, including packages that import a changed
    # package only from tests. Never guess individual test names from filenames.
    while True:
        more = {name for name, p in by_name.items()
                if affected.intersection(p.get("Imports", []) + p.get("TestImports", []) + p.get("XTestImports", []))}
        expanded = affected | more
        if expanded == affected:
            return sorted(affected)
        affected = expanded


def plan_checks(root, paths, packages=None):
    commands = []

    def add(*command):
        if list(command) not in commands:
            commands.append(list(command))

    # Documentation alone does not require compilers or devices.
    code = [p for p in paths if not p.endswith((".md", ".txt")) or "/testdata/" in p]
    schema = any(p.startswith("api/proto/") or p == "scripts/generate-proto.sh" for p in code)
    fixture = any(p.startswith("scripts/isolated-gateway/") for p in code)
    brand = any(p.startswith("assets/brand/") for p in code)
    mac = schema or fixture or brand or any(p.startswith("apps/mac/") or p == "just/mac.just" for p in code)
    android = schema or fixture or brand or any(p.startswith("apps/android/") or p == "just/android.just" for p in code)
    mac_suites = affected_mac_smoke_suites(code)
    android_integration = android and (schema or fixture or brand or any(
        (p.startswith("apps/android/") and not p.startswith("apps/android/app/src/test/"))
        or p == "just/android.just" for p in code))

    if any(p.startswith("scripts/check_changed") or p in {"justfile", "just/mac.just"} for p in code):
        add("python3", "-m", "unittest", "discover", "-s", "scripts", "-p", "check_changed_test.py")
    if any(p == "justfile" or p.startswith("just/") for p in code):
        add("just", "justfile-check")
    if any(p.startswith(".github/workflows/") or p == "just/release.just" for p in code):
        add("just", "workflow-check")
    if schema:
        add("just", "proto")
    go_changed = schema or any(
        p.endswith(".go") or p in {"go.mod", "go.sum", "just/daemon.just", "just/gateway.just"}
        or p.startswith(("config/", "native/", "internal/", "api/gen/")) for p in code)
    if go_changed:
        affected = affected_go_packages(root, code, go_packages(root) if packages is None else packages)
        if schema and not affected:
            affected = ["./..."]
        if affected:
            add("go", "test", "-race", *affected)
            add("go", "vet", *affected)
    if any(p.startswith("internal/harness/runtime/") or p in {"config/harnesses.yaml", "just/harness.just"} for p in code):
        add("just", "harness", "test")
    if mac:
        add("just", "mac", "test")
    if android:
        add("just", "android", "test")
    if mac_suites == MAC_SMOKE_SUITES:
        add("just", "mac", "smoke-all")
    elif mac_suites:
        add("just", "mac", "smoke-suites", *mac_suites)
    if android_integration:
        add("just", "android", "connected-test")
    if brand or any(p.startswith("landingpage/") or p == "just/site.just" for p in code):
        add("just", "site", "build")
    return commands


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="Compare the working tree with the merge base of this ref and HEAD.")
    parser.add_argument("--dry-run", action="store_true", help="Print changed paths and commands without running checks.")
    args = parser.parse_args()
    root = Path(output(Path.cwd(), "git", "rev-parse", "--show-toplevel").strip())
    paths = changed_paths(root, args.base)
    commands = plan_checks(root, paths)
    print("Changed paths:", flush=True)
    for path in paths:
        print("  " + path, flush=True)
    if not commands:
        print("No affected code checks.", flush=True)
        return 0
    print("Selected checks (native clients use their complete module test suite):", flush=True)
    for command in commands:
        print("  " + shlex.join(command), flush=True)
    if args.dry_run:
        return 0
    for command in commands:
        if command[:3] in (["just", "mac", "smoke-all"], ["just", "mac", "smoke-suites"]):
            # The smoke driver refuses concurrent app processes. Check before
            # packaging so a known lifecycle conflict doesn't waste a build.
            running = subprocess.run(["pgrep", "-x", "DieterMac"], capture_output=True, text=True)
            if running.returncode == 0:
                print("Mac integration tests blocked: DieterMac is running (PIDs "
                      + ", ".join(running.stdout.split()) + "). Quit the app before rerunning; "
                      "no app or daemon was stopped.", file=sys.stderr)
                return 1
            if running.returncode != 1:
                print("Could not check for running DieterMac processes.", file=sys.stderr)
                return 1
        print("Running " + shlex.join(command), flush=True)
        result = subprocess.run(command, cwd=root)
        if result.returncode:
            return result.returncode
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (subprocess.CalledProcessError, OSError) as error:
        print(f"Change detection failed: {error}", file=sys.stderr)
        sys.exit(1)
