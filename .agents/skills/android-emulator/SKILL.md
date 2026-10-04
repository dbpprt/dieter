---
name: android-emulator
description: Operate Dieter's Android app and isolated native tests in the visible local emulator or on an explicitly selected physical device using Fastlane.
---

# Operate the Dieter Android app

Read `fastlane/README.md` and `apps/android/agents.md`. Use `just pipeline android`
from the repository root. Fastlane owns build, exact-device admission, fixtures,
execution, native qualification and cleanup; do not add host scripts or Just loops.

For pipeline changes, read [dieter-pipelines](../dieter-pipelines/SKILL.md).
Inspect `just check-changed --dry-run`, run affected fast checks once after changes,
and select related cases for native verification. Device execution requires
`--native` or an explicit `android e2e` command. Do not rerun full functional,
screen or performance suites between edits. CI compiles E2E drivers on affected
PRs; full main qualification also compiles the performance variant.

## Configuration and ownership

Run `just pipeline doctor`; configure the ignored `fastlane/local.json` from
`fastlane/local.example.json`. The default profile selects visible
`Pixel_9_API_37_1`, `emulator-5554`, normal snapshots and host GLES. Android Studio's
bundled JBR and the SDK are discovered when absent from the environment.
Physical devices require an explicit `profile:android-device` and exact serial.
Never auto-select an attached phone. Preserve operator app data and lifecycle.

Before testing, inspect SDK-local `adb devices -l` and exact emulator/QEMU
processes. Tests borrow a healthy running emulator; a run that launches one owns
its graceful closure. Hold the shared device/build leases. A lease conflict names
its owner PID: inspect it and retry after completion; never unlink locks.

Never stop, replace or restart the operator daemon. Use separate E2E packages,
temporary DIETER_HOME roots, random authenticated fixtures and owned ADB reverses.
Normal install commands retain development-app data. Never uninstall the operator
app to solve a signing/build mismatch.

## Build and local inspection

```sh
just pipeline android test_unit
just pipeline android build
just pipeline ci action:check component:android
just pipeline android local action:status
just pipeline android local action:emulator_check
just pipeline android local action:install
just pipeline android local action:launch
just pipeline android local action:ui_dump
just pipeline android local action:screenshot
just pipeline android local action:logs
just pipeline android local action:app_stop
```

Local screenshot/XML tools write to the printed fresh evidence directory;
`output:PATH` selects a fresh explicit directory. For a phone append its exact
profile. Observe current XML and PNG before/after each interaction; derive gestures
from actual bounds and verify their outcome. Prefer read-only app journeys unless
the user authorized changes. Do not alter live cards, schedules, account settings,
or daemon terminals as a test fixture.

`emulator_check` exercises normal launch/admission/save/close without executing
cases. It borrows an already running AVD and preserves its owner. Run it twice to
qualify normal snapshot reload after lifecycle changes.

## Native tests

```sh
just pipeline catalog action:lint
just pipeline catalog action:plan platform:android suite:functional changed:true
just pipeline android e2e profile:android-emulator suite:smoke
just pipeline android e2e cases:machines.telemetry
just pipeline android e2e suite:functional
just pipeline android e2e suite:sync
just pipeline android e2e suite:sdk
just pipeline android e2e suite:performance
just pipeline android e2e suite:screens
just pipeline android e2e profile:android-device suite:functional
```

Read `tests/e2e/README.md`. YAML remains ordinary journey code; native component,
codec, input, sync and performance assertions retain exact catalog methods.
The pipeline builds/install-verifies once per variant and gives every case fresh
fixture app/state. Missing, skipped, duplicate, unavailable, interrupted or failed
methods fail required qualification. Failed cleanup fails the run too.

Performance uses a separate non-debuggable emulator app. Run clean timing without
heavy compilation, tracing or other desktop/device activity. Never weaken a
threshold to hide a regression. Screens require a qualified macOS capture host
and owned input target. Required unavailable cells are not green skips.

Use registered background process tools for sustained runs. Read JSON/JUnit,
native result logs and relevant PNGs under `tmp/app-pipelines/UUID`; collect their
final result before replying. A process completing does not wake an idle card.

## Emulator health and recovery

Use normal `default_boot` loading/saving and `-gpu host`. Never add cold-boot,
wipe, headless, software-GPU, no-snapshot or `-no-snapshot-save` flags. Never delete
userdata, snapshots, Gradle caches or app data during routine diagnosis.

Resolve the registry's external-volume `path=` and keep it mounted through save
and shutdown; require 10 GiB free. Admission requires complete boot, stopped boot
animation, host GLES launch evidence, responsive guest renderer, unlocked/focused
launcher, real launcher XML and a valid PNG. Emulator 37.1 may show lavapipe/Vulkan
or ANGLE in guest diagnostics despite a healthy Apple GLES host; the latest
`gles_mode_selected:host` and `OpenGL ES Translator (Apple ...)` launch-log lines
prove the host renderer. Bad color-buffer or snapshot errors fail admission.

Cleanup stops only owned fixture processes, returns to the launcher, explicitly
saves and validates ram.bin/snapshot.pb/textures.bin, then calls `adb emu kill`
and verifies the exact process/serial are absent. Borrowed devices remain running.
Failed cleanup preserves its ownership journal and diagnostics. A subsequent run
removes an absent owner's journal only after both process and serial are absent;
a live/changed owner requires inspection. Never use broad or force kills.

For failure, retain screenshots, XML, instrumentation and scoped crash/ANR logs.
Stop retries on ADB/protocol faults, inspect TCP 5037 and all attached devices
before changing ADB. For snapshot/volume repair follow `apps/android/agents.md`;
quarantine exact diagnosed paths only when authorized, preserve userdata, and
require healthy normal save/reload plus UI evidence. Do not improvise a cold boot.

Report exact profile/serial, build/test outcomes, evidence, mutations and whether
the app/device was borrowed, left healthy or closed by the task.
