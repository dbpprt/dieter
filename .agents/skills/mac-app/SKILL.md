---
name: mac-app
description: Operate Dieter's native macOS app in the visible local desktop from end to end. Use for Mac app development, incremental builds, launching Dieter.app, inspecting and clicking through the live SwiftUI interface, collecting screenshots and accessibility evidence, running unit tests and the Mac Maestro flow, diagnosing launch, connection, rendering, hang, crash, duplicate-process or build-cache failures, and gracefully closing every app process the task owns.
---

# Operate the Dieter Mac app

Work from the repository root. Reuse one app process, observe native UI state
after every interaction, and leave no task-owned `DieterMac` process behind.
For build and CI changes read [dieter-pipelines](../dieter-pipelines/SKILL.md);
for the package layout read [apps/apple/README.md](../../../apps/apple/README.md).

## Preserve the environment

- Never stop, restart, replace or install over the operator's running daemon or
  their installed `Dieter.app`. Use [dieter-cli](../dieter-cli/SKILL.md) for
  daemon-side inspection and never edit `DIETER_HOME`.
- Do not delete `.build` or DerivedData, run `swift package clean`, or invent
  alternate scratch paths to work around a slow build. Compare the Xcode
  version, configuration and `Package.resolved` first.
- Do not use `pkill`, `killall`, `open -n` or pattern kills. If another task or
  the operator owns a `DieterMac` process, do not terminate it or launch a
  second copy.
- Run Swift and Gradle builds one at a time; on a busy host limit compiler jobs
  (`swift build --jobs 2`) instead of stopping other processes.

## Inventory first

```sh
pgrep -lf DieterMac
ps -o pid,lstart,command -p "$(pgrep -d, DieterMac)"
```

Check the exact executable path of every process. One process from the build
you launched is normal. Several processes mean earlier launches were never
quit; they are not worker children. Closing the workspace window does not quit
Dieter, because its menu-bar extra keeps the app alive.

## Build, test and launch

```sh
just framework                                        # DieterCore.xcframework, when the Kotlin core changed
just mac build                                        # the Dieter.app bundle (Xcode project in apps/apple/mac)
swift test --package-path apps/apple/mac --no-parallel --filter NAME
just mac run                                          # launch the built app; refuses a second copy
```

`just --list` shows the exact `mac` actions. The app's presentation lives in
the `DieterMacKit` library (`apps/apple/mac/Sources/DieterMacKit`); tests import
that library. `DieterMacTests` runs serially; read the reported test count,
because a test that stops the main run loop can end the run early with exit
status 0.

The first build after a compiler, dependency, schema or source change can be
long; a second unchanged build should be incremental. After changing
`api/proto`, run `just generate`. Release signing, notarization and packaging
belong to Fastlane (`just pipeline …`); do not reproduce them by hand.

For current code, quit a task-owned app before rebuilding. For observation only,
reuse the app that is already running.

## Observe and interact

Create an evidence directory outside source control unless the user specifies
one:

```sh
pid=VERIFIED_TASK_OWNED_PID                       # from the inventory above
MAC_EVIDENCE="$(mktemp -d /tmp/dieter-mac.XXXXXX)"
screencapture -x "$MAC_EVIDENCE/00-launch.png"
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to get entire contents of window 1"
```

Inspect each PNG and the current Accessibility hierarchy. Prefer visible labels
or accessibility names. When SwiftUI exposes no stable element, derive a click
point from the current window and a screenshot taken immediately before the
click. Capture new evidence afterward; dispatching a click is not proof.

Prefer read-only journeys through All chats, projects, boards, Files,
Schedules, Machines, Terminals and Settings. Do not send messages, start
agents, edit or archive data, close daemon-owned terminals, change schedules or
alter settings without authorization.

Accessibility interaction needs permission for the invoking terminal; screen
capture may need Screen Recording. Use the isolated Maestro flow when these
permissions are unavailable.

## Run the isolated app flow

```sh
just e2e mac
just e2e mac flows:conversation
```

The run builds the debug app, starts an isolated fixture gateway on a random
loopback port with its own state and preferences, launches the app with that
fixture, and runs `tests/maestro/mac/*.yaml` through the in-app interpreter. It
refuses to run beside any existing `DieterMac` process and verifies that no app
process remains. Read the reported results and inspect the screenshots; exit
status alone is insufficient.

For an isolated performance sweep, set `DIETER_PERFORMANCE_SWEEP=1` (and
optionally `DIETER_PERFORMANCE_LONG_TURN=1`) for the flow run: the fixture
seeds 40 chats with long tool-heavy histories beside a 100-card board, and the
app records chat-switch and return samples. Run timing separately from
compilation, tracing and other suites; drawing callbacks and snapshot readiness
are not compositor presentation.

## Diagnose before restarting

For a hang, capture identity and evidence first:

```sh
pgrep -lf DieterMac
sample "$pid" 5 -file "$MAC_EVIDENCE/DieterMac.sample.txt"
log show --last 10m --style compact \
  --predicate 'process == "DieterMac"' > "$MAC_EVIDENCE/DieterMac.log.txt"
```

Check for a sheet, login browser, dialog, menu-bar-only state or off-screen
window. A client connection problem is never permission to restart the daemon.

For a crash or launch failure, inspect recent `DieterMac` reports under
`~/Library/Logs/DiagnosticReports` without deleting them, and verify the bundle
with `apps/apple/mac/scripts/verify-bundle.sh`. For a SwiftPM binary download
failure, retain the exact URL and HTTP status; do not delete the cache.

## Close cleanly

Quit only the exact process you launched; the operator's installed app has the
same bundle identifier, so never quit by name or bundle ID:

```sh
osascript -l JavaScript -e "ObjC.import('AppKit'); var app = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid); app.isNil() ? 'not running' : app.terminate"
pgrep -lf DieterMac
```

This sends a normal quit; a normal quit must not close daemon-owned terminal
sessions. Only after
recording diagnostics may you send `TERM` to an exact, re-verified task-owned
PID; never `KILL` without explicit authorization.

Report the build and configuration, cache reuse, tests, exact process count,
observed journey, evidence paths, mutations, diagnostics and final lifecycle
state.
