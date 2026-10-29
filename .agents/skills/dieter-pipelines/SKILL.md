---
name: dieter-pipelines
description: Build, check, and qualify Dieter components; run device flows; diagnose CI; and work on signing and releases. Use for build/test/CI/release changes and contributor setup; use the mac-app skill for live Mac UI work.
---

# Dieter pipelines

Read [docs/building.md](../../../docs/building.md),
[docs/testing.md](../../../docs/testing.md) and, for release work,
[docs/releasing.md](../../../docs/releasing.md) and
[fastlane/README.md](../../../fastlane/README.md) before changing builds, device
lifecycle or releases.

## Tools and commands

Tools are pinned in `mise.toml`/`mise.lock`; CI installs the same versions.
Prepare a checkout with `mise trust` and `just setup`; in non-interactive shells
run `mise exec -- just …`. mise does not provision Xcode, SDKs, simulator
runtimes, emulators, devices or Docker.

Every `just` recipe wraps a plain toolchain command (`go`, `./gradlew -p
apps/kotlin`, `swift`, `xcodebuild`, `hugo`). Prefer the plain command when you
need one package, task or test. `just pipeline <lane>` runs a Fastlane lane
directly; Fastlane owns native packaging, signing, notarization and store
delivery and uses its built-in actions.

## Verify efficiently

1. Inspect `just check-changed --dry-run` (add `--base REF` for a branch). It
   includes uncommitted files and lists device checks separately.
2. During implementation, run focused checks (`go test ./internal/x/...`,
   `just kotlin :core:runtime:jvmTest --tests '…'`). Rerun only what failed or
   became newly affected.
3. At the integration boundary, run `just check-changed` once, plus the one
   relevant `just e2e <platform>` run for app, schema, fixture or lifecycle
   changes. Do not repeat full suites, `tags:full` or every platform between
   edits.
4. Run `just lint` (or `just lint --staged`) and `just generate` if schemas or
   `config/identity.json` changed; CI fails on generated drift.

Measure cold builds, cache restores and test execution separately; a cold
native build is not evidence about test speed. Run Gradle and Xcode builds one
at a time on a shared machine. Use registered background processes for
long-running builds, emulators and servers, and collect their results before
you finish.

## Device flows

`just e2e <android|ios|mac> [tags:smoke|full] [flows:NAME,…]` builds the app,
starts one isolated fixture gateway, installs the separate E2E app and runs the
Maestro flows in `tests/maestro`. Keep assertions about rules in Kotlin unit
tests; add a device flow only for a journey that needs a device.

- Android borrows a running emulator, or a phone only through a profile that
  names its exact serial. Never pick an arbitrary phone, never wipe operator
  userdata, and never kill unrelated processes.
- iOS creates, boots and deletes its own simulator.
- The Mac run needs the logged-in desktop and refuses while any `DieterMac`
  process runs.
- Required missing, skipped or unavailable assertions and cleanup failures fail
  the run. Keep failed evidence; never relax assertions to hide emulator
  problems.

## CI and releases

Pull requests and `main` run the affected checks; the required check is
`ci-ok`. Dev releases are cut nightly and on demand; stable is a protected
promotion of an exact dev build (see `docs/releasing.md`). Release checksums
are signed only by `.github/workflows/release.yml@refs/heads/main`, which
installed updaters verify; never rename or bypass it. Publishing jobs run only
in the upstream repository.

Do not publish releases, rotate signing material, upload to TestFlight or
activate production to test a pipeline change. Verify those paths with dry
runs and disposable fixtures. Never stop, restart or replace the operator's
daemon or apps.
