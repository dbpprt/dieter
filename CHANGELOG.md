# Changelog

Dieter ships one version across the daemon/CLI, gateway and native clients.
Nightly dev prereleases (`v0.6.N`) list their pull requests on the GitHub
release. A stable release promotes one tested dev build; before you promote it,
copy the **Unreleased** notes into a section named after that exact version
(for example `## 0.6.412`). Promotion fails without that section.

## Unreleased

End-to-end encryption between your devices. This release starts the 0.6 line
and is a clean break: nothing migrates, and every machine and app pairs again
after the upgrade.

### Upgrading

0.5 and 0.6 cannot talk to each other, so update everything in one go:

1. **Gateway.** Deploy the 0.6 gateway. Its minimum client and daemon releases
   are `0.6.0-dev.0`, so it rejects 0.5 apps and daemons.
2. **First machine.** Update the daemon on the host itself (`brew upgrade dieter`
   on macOS; `dieter machine update --confirm UPDATE` or `install.sh` on
   Linux), then run `dieter setup`. It starts your account's device roster and
   prints a recovery key once. Store it offline.
3. **Other machines.** Update each one the same way and run `dieter setup`. It
   prints a one-time code; approve it on the first machine with
   `dieter device approve CODE`.
4. **Apps.** Update each app and open it. It shows a one-time code; type it on a
   trusted device: `dieter device approve CODE` on a machine, or
   **Devices → Add a device** in an app that is already trusted.

### Security

- Every remote call now runs mutually authenticated TLS 1.3 between the calling
  device and the daemon, on every route: direct TLS, WebRTC and the gateway
  relay. The relay is an opaque tunnel, so the gateway forwards bytes it can
  neither read nor change: chats, terminals, files, executions, Git, vault
  content, peer records and screen signaling. It still sees metadata (devices,
  presence, routes, tunnel timing and sizes, provider quota snapshots) and can
  deny service.
- Every machine and app has its own key in the account's device roster, an
  append-only list in which every change is signed by a trusted device. The
  gateway stores the list but cannot add a device or remove one. A new device
  shows a one-time code; typing it on a trusted device adds it. Only type a code
  you see on your own new device.
- App keys live in the Secure Enclave (Mac, iPhone, iPad) or the Android
  Keystore and cannot be exported. The Mac app keeps its key in its user-only
  data folder, never in the Keychain.
- Gateway tokens are bound to the calling device, so a session or token without
  the device key reaches no machine. The gateway's daemon CA now only
  authenticates daemons to the gateway; clients pin keys from the roster.

### Changed

- New `dieter device` commands: `status`, `roster`, `sync`, `init`, `requests`,
  `approve`, `revoke` and `recover`. `init` and `recover` run only on the
  machine itself, and agent turns cannot change device trust.
- `dieter setup` starts the device roster on an account's first machine, or
  prints the code that a new machine waits with.
- `dieter daemon unenroll` also removes the machine from the trusted devices and
  deletes its key. Enrolling it again creates a new machine that a trusted
  device approves.
- The apps show a pairing screen until the device is trusted, and a Devices
  screen (**Tools › Devices** on Android, iPhone and iPad; **Settings › Devices**
  on Mac) to add, list and remove devices.
- Vault commands that return decrypted content now work over the gateway relay
  too, and the vault audit records which device asked.
- Claude Code, Codex and OMP now run at the latest versions Dieter ships with
  instead of the versions the AI SDK adapters pin: Claude Code 2.1.296 (Claude
  Agent SDK 0.3.296), Codex 0.162.1 and OMP 18.10.1. Updates follow each release.
- Release daemons no longer need npm. The prebuilt harness runtime now includes
  the Claude Code, Codex and OMP command-line tools, and an agent's first turn
  links them instead of installing them with npm. Only the DeepSeek Harness
  (DSH) still installs from npm, and daemons built from source still install
  their runtime with npm. The runtime download grows accordingly, to about
  600 MB on macOS and about 1 GB on Linux.
- OMP and DSH conversations started before this update cannot continue: the
  updated agent adapter no longer accepts their saved session. Start a new
  conversation for them.

## 0.5.405

### Changed

- Release daemons no longer install their harness runtime with npm. Each release
  publishes a prebuilt runtime per daemon platform
  (`dieter-harness-runtime-<os>-<arch>.tar.gz`); the daemon downloads the one
  whose SHA-256 its binary pins on first use and during updates, and verifies
  it before installing. Hosts still need Node.js 22.19+, npm (for agent provider
  bridges) and Git. Daemons built from source keep installing with npm.
- The daemon's storage (`internal/store`) is split into one package per
  aggregate (projects and cards, conversations, schedules, workspaces, the peer
  replica, …) with a lint-enforced dependency order. Files on disk do not
  change.

### Fixed

- `brew uninstall --zap dieter-app` removes the Mac app's data under its
  current identifier, `com.getdieter.mac`.

## 0.5.404

The open-source foundation release. It is a clean break: reinstall the daemon
and apps; nothing migrates from 0.4.

### Upgrading

0.4 and 0.5 cannot talk to each other, so update everything in one go:

1. **Gateway.** Deploy the 0.5.404 gateway bundle. Its signature now comes from
   `.github/workflows/release.yml`, so a deployment controller that pins signer
   workflows must trust that identity first. The new gateway rejects 0.4 apps
   and daemons.
2. **Daemons.**
   - macOS: run `brew upgrade dieter`, then `dieter setup` to register the
     service and privacy helper under the new identifiers.
   - Linux: run `dieter machine update` on the host, or reinstall with
     `install.sh`.
3. **Apps.**
   - macOS: `brew install --cask dbpprt/tap/dieter-app`, or download
     `Dieter-macOS-arm64.zip`.
   - iOS: the TestFlight build.
   - Android: install `Dieter-Android.apk`. It is a new app
     (`com.getdieter.android`), so remove the old one.

   Sign in again on every app.

### Breaking

- **Identifiers.** Every app and helper moves to `com.getdieter.*`:
  - `com.getdieter.mac`, `com.getdieter.ios` and `com.getdieter.android`;
  - `com.getdieter.daemon`, `com.getdieter.capture` and `com.getdieter.privacy`.

  Android and macOS installs are new apps. Sign in again on every device, and
  re-register the macOS privacy helper (`dieter setup`).

- **Apple team.** Signed binaries, the privacy helper and the installer trust
  only team `FNGU8JFNPL`.
- **iOS sign-in** uses the `dieter-ios://` callback. The gateway must allow it
  (the deployment renders it).
- **Daemon API.** `dieter.v1` is one service per domain (`CardService`,
  `ConversationService`, `ScreenService`, …) instead of one `DieterService`.
  - RPC paths change, so clients, daemons and gateways below 0.5 cannot talk to
    0.5.
  - The gateway's minimum client and daemon version is `0.5.0-dev.0`.
- **Release signing.** Checksums and the gateway deployment bundle are signed
  only by `.github/workflows/release.yml@refs/heads/main`.
- **Removed.** The private OMP/Pi model routes (Tailscale GLM, Box Qwen) are
  gone from the default catalog.

### Changed

- **Repository layout.**
  - `apps/kotlin` is one Gradle build: core, Compose UI and the Android app.
  - `apps/apple` holds `DieterKit`, the Mac app and the iOS app.
  - `native/macos` is a SwiftPM package for the daemon helpers.
  - Vendored code moved to `third_party/`, the website to `site/`, and the
    gateway deployment files to `deploy/`.
- **Daemon.** The startup wiring moved out of the CLI into `internal/daemon`,
  with one configuration loader and per-domain API handlers.
  - Unknown server errors are reported as `Internal`, so clients retry them
    instead of dropping the command.
- **Schemas.** All `.proto` files live in `api/proto`. `just generate` runs buf
  for Go and Swift and fails CI on drift; Kotlin generates from the same files.
- **Builds.**
  - Fastlane builds, signs and distributes using its built-in actions.
  - The Mac app now has an Xcode project, built with `build_mac_app`.
  - Plain `go`, `gradlew` and `swift` commands work without Fastlane.
- **CI.**
  - Pull requests run only the affected checks, behind one required `ci-ok`
    check.
  - Failures show as annotations, every job writes a summary, and every test
    runner reports JUnit.
  - Dev releases are cut nightly, not on every push.

### Fixed

- **Installer.** It verified the old Apple team, so it rejected current
  releases.
- **Privacy helper.** It authorized clients signed by the old team only.
- **Local daemon on a random port.** `dieter serve --addr 127.0.0.1:0` now
  records the port it actually bound, so the CLI can reach it.
- **Fixture gateways.** They no longer reinstall the harness runtime for every
  test fixture.
