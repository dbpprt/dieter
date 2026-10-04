---
name: mac-app
description: Operate Dieter's native macOS app in the visible local desktop from end to end. Use for Mac app development, incremental SwiftPM builds, packaging or launching Dieter.app, inspecting and clicking through the live SwiftUI interface, collecting screenshots and accessibility evidence, running unit or native UI smoke tests, diagnosing launch, connection, rendering, hang, crash, duplicate-process, or build-cache failures, and gracefully closing every app process the task owns.
---

# Operate the Dieter Mac app

Run the repository's `just pipeline mac` lanes from the repository root. Reuse one
packaged app process, observe native UI state after every interaction, and leave
no task-owned `DieterMac` process behind.

## Preserve the environment

Use these canonical paths:

```sh
MAC_APP_BUNDLE="$PWD/apps/mac/build/Dieter.app"
MAC_APP_EXECUTABLE="$MAC_APP_BUNDLE/Contents/MacOS/DieterMac"
MAC_APP_SCRATCH="$PWD/apps/mac/.build/dieter-local"
MAC_TEST_SCRATCH="$PWD/apps/mac/.build/dieter-tests"
```

Never stop, restart, replace, or install over the operator's running daemon.
Use `$dieter-cli` for daemon-side inspection and never edit `DIETER_HOME`.

Do not run `swift run DieterMac`, create alternate scratch paths, delete
`.build`, or use `swift package clean`. `just pipeline mac build` packages the app with
the canonical app cache, while `just pipeline mac test_unit` uses the canonical test cache so
their incompatible compiler flags cannot invalidate each other. The Mac build/test/core-test and iOS build commands share an Apple build lease.
Apple E2E holds it until its packaged app/test products are no longer in use.
Contention fails promptly with the owner PID; inspect the active command and
retry after it completes. Never delete its lock to bypass admission.

When compiler processes contend for memory, run builds and tests sequentially.
The configured `toolchains.swift_jobs` defaults to two jobs for SwiftPM and Xcode;
`DIETER_SWIFT_JOBS` may select an explicit integer from 1 to 64 on a build or test.
This preserves canonical caches. Do not stop unrelated processes.

## Inventory first

```sh
just pipeline mac local action:status
```

Inspect the exact command of every reported PID. One process from the canonical
bundle is normal. Many processes mean repeated launches were not followed by
application quit; they are not app worker children. A closed workspace window
does not quit Dieter because its menu-bar extra keeps the app alive.

Do not use `pkill`, `killall`, `open -n`, or a pattern kill. If another bundle
or task owns a process, do not terminate it or launch a second copy.

## Build, test, and launch

```sh
just pipeline doctor
just pipeline mac local action:proto_check
just pipeline mac build
just pipeline mac test_unit filter:NAME
just pipeline mac local action:run
```

The first build or test after a compiler, dependency, generated-schema,
configuration, or source change can be long. A second unchanged command should
be incremental. If it is not, compare the Xcode version, configuration,
`Package.resolved`, and the command's canonical scratch path before cleaning
anything. Never point builds at `dieter-tests` or tests at `dieter-local`.
Shared-core framework preparation uses a cross-process publication lease,
hashes production sources/schema/toolchains, and preserves identical framework
bytes and timestamps. `ios-simulator` builds only macOS and simulator slices;
Mac refreshes retain any existing slices of the same configuration. Test and
documentation edits do not replace the framework.

`just pipeline mac local action:run` refuses conflicting processes, launches without `open -n`, and
requires exactly one canonical executable. If that app is already running, it
activates it without building or signing. Builds check for running apps before
compilation and again before packaging, through the shared Mac adapter.
For current code, quit a task-owned app before rebuilding. For observation only,
reuse the already-running canonical app. `just pipeline check component:portable operation:support_tests` verifies
these guards with isolated fixtures, without launching an app.

Release builds use `just pipeline mac build configuration:release`. Versioning, signing, notarization, package verification and retention live in
the candidate composition. See `fastlane/README.md`; do not duplicate those
steps in workflow shell blocks.

After changing the authoritative protobuf schema, run `just proto`. Use
`just pipeline mac local action:proto_generate` only when working specifically on Swift generator
inputs or dependencies.

## Observe and interact

Create an evidence directory outside source control unless the user specifies
one:

```sh
MAC_EVIDENCE="$(mktemp -d /tmp/dieter-mac.XXXXXX)"
screencapture -x "$MAC_EVIDENCE/00-launch.png"
osascript -e 'tell application "System Events" to tell process "Dieter" to get entire contents of window 1'
```

Inspect each PNG and the current Accessibility hierarchy. Prefer visible labels
or accessibility names. When SwiftUI exposes no stable element, derive a click
point from the current window and screenshot immediately before the click.
Capture and inspect new evidence afterward; dispatching a click is not proof.

Prefer read-only journeys through All chats, projects, boards, Files,
Schedules, Machines, Terminals, and Settings. Do not send messages, start
agents, edit or archive data, close daemon-owned terminals, change schedules,
or alter settings without authorization.

Accessibility interaction needs permission for the invoking terminal. Screen
capture may need Screen Recording permission. Use the isolated native smoke
suites when these permissions are unavailable.

## Run isolated packaged-app smoke tests

```sh
just pipeline mac e2e cases:mac.core
just pipeline mac e2e cases:mac.conversation
just pipeline mac e2e suite:smoke
```

Suites are `core`, `board`, `conversation`, `machine`, `sidebar`, `terminal`,
`island`, `workspace`, and `inbox`, plus the YAML `mac.navigation` journey.
Run cases sequentially through `just pipeline mac e2e`. The shared Fastlane pipeline:

- refuses to run beside any existing `DieterMac` process;
- owns the exact packaged-app and isolated-gateway PIDs;
- uses an ephemeral loopback listener and unique state/preferences roots;
- waits for multi-phase app processes to exit before relaunching;
- preserves reports, logs, and screenshots under
  `tmp/app-pipelines/<run-id>` with shared JSON/JUnit reports; and
- verifies no app process remains.

Read every report and inspect relevant PNGs; exit status alone is insufficient.
The app-side smoke interface exists only in debug builds. Retain the selected
shared-runner evidence directory until reviewed.

For a longer isolated performance sweep, run
`DIETER_PERFORMANCE_SWEEP=1 just pipeline mac e2e cases:mac.board`. It seeds 40 chats with two
300-message tool-heavy histories alongside the 100-card board, measures 15
returns per Board/Chats route and 30 alternating chat clicks, and records quiet
CPU, physical footprint, rendering counters and directory-generation deltas.
Raw chat samples are in `chat-switch-samples.json` beside the smoke report.
Five All Chats returns restoring the last conversation are recorded separately
in `chat-return-samples.json`. Both capture prepared/positioned timeline readiness
in addition to snapshot readiness; directory drawing alone can hide a slow chat.
Add `DIETER_PERFORMANCE_LONG_TURN=1` to seed a 680-part final assistant turn
and measure six alternating opens. Samples also record
`fresh_and_positioned_ms`, the combined upper bound for positioned content and
authoritative freshness, and require both before passing. Earlier sections
remain available through “Show earlier in this message”.
Run timing separately from compilation, tracing and other test suites. Drawing
callbacks and snapshot readiness are distinct from compositor presentation;
first selection can already have Live cache coverage.

## Diagnose before restarting

For a hang, capture identity and evidence first:

```sh
just pipeline mac local action:status
sample <verified-pid> 5 -file "$MAC_EVIDENCE/DieterMac.sample.txt"
log show --last 10m --style compact \
  --predicate 'process == "DieterMac"' > "$MAC_EVIDENCE/DieterMac.log.txt"
```

Check for a sheet, login browser, dialog, menu-bar-only state, or off-screen
window. A client connection problem is not permission to restart the daemon.

For a crash or launch failure:

```sh
just pipeline mac local action:verify
ls -lt "$MAC_EVIDENCE" tmp/e2e-* 2>/dev/null
```

Inspect recent `DieterMac` reports under `~/Library/Logs/DiagnosticReports`
without deleting them. For a SwiftPM binary download failure, retain the exact
URL and HTTP status; do not delete the cache.

## Close cleanly

```sh
just pipeline mac local action:quit
just pipeline mac local action:status
```

`just pipeline mac local action:quit` sends a normal application quit event and fails while preserving
the process if it does not exit. Only after recording diagnostics may you send
`TERM` to an exact, reverified task-owned PID. Do not use `KILL` without explicit
authorization. Closing the app must not close daemon-owned terminal sessions.

Report the bundle and configuration, cache reuse, tests, exact process count,
observed journey, evidence paths, mutations, diagnostics, and final lifecycle
state.
