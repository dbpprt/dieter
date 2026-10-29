# Maestro flows

The native clients' device tests are a few short [Maestro](https://maestro.dev)
flows. They cover the journeys that matter and favour execution speed over
completeness. Rules belong in the Kotlin core and its unit tests, not here.

```text
tests/maestro/
  mobile/         Android and iOS run the same flows (one Compose UI)
    common/       subflows, never run on their own
  mac/            Maestro syntax interpreted in-app on the Mac
```

Every flow file has a header (`name`, `tags`), then `---` and its commands.
`tags: [smoke]` flows run in CI when a change affects the app; `tags: [full]`
flows run nightly and with `tags:full` locally.

## Run

```sh
mise exec -- just e2e android profile:android-emulator
mise exec -- just e2e ios
mise exec -- just e2e mac
mise exec -- just e2e ios tags:full profile:ios-ipad
mise exec -- just e2e android profile:android-emulator flows:task
```

Each run builds the app it tests, starts one isolated gateway fixture
(`tools/fixtures/gateway -e2e-fixture`), installs the separate E2E
application (`com.getdieter.android.e2e`, `com.getdieter.ios.e2e`), and runs
the selected flows. Evidence, `results.json`,
Maestro's `junit.xml` and its screenshots are in
`tmp/app-pipelines/<run>/`. The fixture token is redacted from Maestro's
evidence.

- **Android** borrows the warm emulator if one runs (see `AGENTS.md`), never a
  phone unless a profile names its exact serial. The fixture is reachable
  through an owned `adb reverse` port.
- **iOS** creates, boots and deletes its own simulator for every run. The boot
  overlaps the build.
- **macOS** needs the logged-in desktop and refuses while any `DieterMac` runs.
  Maestro has no macOS driver, so the pipeline converts each flow to a JSON
  plan and the debug app (`DIETER_E2E`) runs it with
  `--e2e-flow PLAN --e2e-output DIR`. Add `screenshots:compositor` to capture
  the actual window, including layer-backed SwiftUI/native content, instead of
  the default in-process view capture. It requires Screen Recording permission
  and fails if capture is unavailable; visual qualification must open these PNGs.
  The in-process capture can omit composited layers and is insufficient for Mail
  transparency/selection verification.

The run installs the pinned, checksum-verified Maestro CLI. Use that same
binary for `maestro studio` or `maestro hierarchy` while writing a flow.

## Write fast flows

- Select by the shared Compose `testTag`s (`id:`), which Android exposes as
  resource ids in debug builds. Use text only for tabs and seeded content.
- `id:` and `text:` are regular expressions matched against the whole value.
  iOS uses the system back button: tap `id: "chrome-back|BackButton"`.
- Every tap costs about 1–3 s on Android, and typing costs time per character.
  Keep inputs short, avoid `hideKeyboard` (7–9 s on iOS) and do not add
  steps that only repeat what a unit test checks.
- Mobile taps set `waitToSettleTimeoutMs: 500`; continuous animations
  otherwise hold every tap for Maestro's full settle timeout.
- The fixture is shared by every flow of a run: create what you change, and
  assert on content you created or on the seeded workspace in
  `tools/fixtures/gateway/e2e_fixture.go`.

The Mac interpreter supports `launchApp`, `tapOn`, `assertVisible`,
`assertNotVisible`, `inputText`, `extendedWaitUntil`, `takeScreenshot` and
`pressKey` and `scroll` (a downward wheel event at the window center). Any other command fails the flow, and `just check-changed` lints
every flow without a device.
