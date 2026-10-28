# Changelog

Dieter ships one version across the daemon/CLI, gateway and native clients.
Nightly dev prereleases (`v0.6.N`) list their pull requests on the GitHub
release. A stable release promotes one tested dev build; before you promote it,
copy the **Unreleased** notes into a section named after that exact version
(for example `## 0.6.412`). Promotion fails without that section.

## Unreleased

### Added

- Antigravity harness: Google's Antigravity CLI (`agy`) runs as a sixth harness
  with model and effort selection between turns. Each turn is one headless
  `agy --output-format stream-json` run continued with `--conversation`; the
  prompt travels on stdin, Antigravity's own tools show as provider-executed
  tool calls, each model request reports its own usage, and quota or sign-in
  failures become one plain sentence in the conversation. Host-defined tools
  (present_content, background processes) reach `agy` as the MCP server
  `dieter`, a stdio proxy the adapter registers once with `agy mcp add` and
  that forwards calls to the running turn; compaction runs agy's `/compact`;
  a conversation agy no longer has restarts fresh with the instructions and a
  note. Suspend/continue and image input are not available through the CLI.
  `agy` must be installed and signed in on the execution machine.

## 0.6.431

### Fixed

- Mail charts on the Mac and iPhone now blend with the reader in light and dark
  appearance. Charts with an explicitly white background keep that background,
  and selected Mac mailbox rows remain readable.
- Mac Mail and Files keep chart text and paths sharp in large reports. Bounded
  parallel rendering, faster source lookups and cached chart reuse reduce
  rendering time and speed up reopening messages.
- Wide tables in Mac Mail stay below their headings when charts finish loading,
  including after scrolling, changing appearance and reopening a message.
- Android Mail keeps its reader background stable during fast scrolling, and
  the Inbox title now aligns with the toolbar actions.

## 0.6.430

### Added

- Mail reports render Mermaid diagrams and inline-data Vega-Lite and Vega
  charts on the Mac, Android, iPhone and iPad, using the same bundled offline
  renderer as the Mac Files preview. Graphics fit narrow screens and follow
  the app's light or dark appearance; Mac PDF and HTML exports keep them as
  static graphics.
- Invalid or unsupported diagrams keep readable source without hiding the
  rest of the report. Remote images, external chart data and scripts remain
  blocked; charts use inline data and their controls are read-only.

## 0.6.429

### Added

- **Mail**: agents can send you read-only Markdown reports, such as a nightly
  audit or a finished migration, and you read them in a new mailbox on the Mac,
  Android, iPhone and iPad. Agents send with `dieter mail send` from cards,
  chats and schedules created with mail access (`--mail`, or **Allow mail** in
  the new-task, chat and schedule forms); a conversation without it can't send
  or grant it. Mail stays on the machine that received it, with unread, flag,
  archive and trash state, search and filters, and Mac notifications whose tap
  opens the message. Reports render rich tables that scroll sideways; see the
  [Mail guide](https://getdieter.com/docs/mail/).
- Notification clicks on the Mac now open the card or chat they belong to.

### Changed

- Android, iPhone and iPad have a **Mail** tab with unread badges. The iPhone
  tab bar keeps five tabs, so the experimental Channels tab is not shown there
  for now.
- Chats and cards you reopen show their messages at once and mark themselves
  **Refreshing** until the owning machine has caught up.

## 0.6.428

### Added

- Agent channels (experimental) are account-wide: a project has one channel,
  shared by all your machines. Messages, delivery receipts, pins and file
  claims travel between machines with peer sync, end to end encrypted; the
  gateway stores none of it. Each machine delivers to the agents it runs, and
  another machine's claims show as advisory ("also being changed … on machine
  M"), since they block writes only in their own checkout.
- `@here`: a person's post with `dieter channel post --here`, or **@here** in
  the composer, interrupts every running agent of the project on every
  machine.
- Android and iOS have a **Channels** tab with an unread badge. It lists the
  project channels; a channel shows the agents' messages live, with a composer
  for Everyone, @here or picked agents, and an info sheet with member agents,
  claims (with Release) and pinned decisions. **Settings → Experimental** has
  the switch.
- Android and iOS highlight a channel message that joined an agent's turn, like
  the Mac, with its author, channel and a link to open it, and label a turn
  that a channel message started **From agent channels**.

### Changed

- A channel post without recipients no longer interrupts running agents; they
  read it when their next turn starts (posts from the last 24 hours). Direct
  messages and @here still reach running agents at once. Done and archived
  cards are no longer channel members.
- `dieter channel inbox` marks messages delivered only on the machine that
  runs the card; on another machine, add `--peek` or `--machine`.
- Turning agent channels on or off saves on the next reachable machine when
  one cannot, for example when this device is not yet trusted there.

## 0.6.427

### Changed

- Updated the bundled agents: Claude Code 2.1.310 (Agent SDK 0.3.310), Codex
  0.164.0, Oh My Pi 18.12.6, Pi 1.4.0 and DSH 0.2.1-rc.2. The AI SDK harness
  adapters move to the newest releases that start (harness 1.0.158); the newer
  Claude Code, Codex and ACP adapters were published without a file their
  setup reads and stay held back until a fixed release.
- A machine stays responsive while many agent turns run at once: running turns
  write to the daemon's storage only when their state changes, and repeated
  reads share a small cache. The Homebrew service now uses Standard instead of
  Background scheduling; `brew services restart dieter` applies it after an
  upgrade (this restarts the daemon).

### Fixed

- DSH lists its models again. Model discovery looked for DSH in the wrong
  directory, so apps showed only a default model.
- A late or duplicate quota reply no longer disconnects a machine's control
  connection.

## 0.6.426

### Changed

- Agents get shorter, precise instructions on every turn, the same for every
  harness. They name the card or chat and the daemon's own `dieter` binary by
  absolute path, so an older `dieter` earlier on the `PATH` can no longer run
  instead, and send agents to `dieter --help` for everything beyond the
  essentials. Nothing is said twice any more, and the follow-up card command
  now includes its required `--title` and `--workspace`. When a harness has not
  loaded the presentation or background process tools, their instructions name
  the equivalent `dieter` command, and they ask agents to open a file in the
  workspace pane when you want to see it instead of printing it.
- Prompt templates you have not changed follow each release's defaults; saving
  settings no longer freezes the defaults of the release you saved them with.
  `dieter prompt update --reset template|board-skill|chat-skill` restores a
  replaced default, and `dieter prompt preview --card CARD` shows a
  conversation's exact instructions.

### Fixed

- Turning agent channels on in the app lists the project's channel right away;
  before, the list could stay empty for up to a minute.
- `dieter chat` help shows `dieter chat … CHAT` instead of the card commands,
  and chats no longer offer `start`, `labels`, `--lane` or `--labels`.
  `dieter chat list --project` now filters by project instead of being ignored.
- CLI help names the flags machine actions need (`--name`, `--confirm`), the hex
  format of `board label --color`, what `card context` and `card archive` do,
  and the `--direct-network` option of `daemon start`; the `project`, `board`,
  `workspace`, `screen resolution`, `kv` and `peer` help is corrected.
  `card context` also returns the card title, and `board label list` prints
  `[]` for a board without labels.

## 0.6.425

### Added

- Agent channels (experimental, off by default): agents working in the same
  project on one machine share a channel. They post notes, requests, done
  messages and decisions, and Dieter delivers them into a running agent's turn
  or ahead of an idle agent's next prompt. A direct message can wake an idle
  agent, within a budget of 4 wakes per agent per hour. Files an agent changes
  are claimed until its turn ends: Codex is stopped before it writes another
  agent's claimed file or commits it, and other agents are warned right after.
  Turn it on in **Settings › Experimental** on the Mac, and override it per
  project in **Project context** and per board in board settings. The
  setting syncs to every machine. The Mac app has a **Channels** section with
  the messages, claims, member agents and pinned decisions; the CLI has
  `dieter channel`. See [Agent channels](https://getdieter.com/docs/channels/).

## 0.6.423

### Fixed

- Returning to the Android or iOS app no longer marks every Inbox row's
  machine as not responding while the app reconnects. A machine is only
  reported offline or not responding for what happens while the app is
  connected.
- An open conversation keeps updating across reconnects. Before, it could
  stop refreshing without saying so after the app returned from the
  background, until you reopened it.
- Android keeps its connection when the screen rotates or the theme changes,
  and iOS keeps it while Control Center, the app switcher or a system prompt
  covers the app.
- The Mac app exports Markdown to PDF and renders Mermaid and Vega diagrams
  again. Markdown files open in Files and conversation tabs reload when they
  change on disk; unsaved edits stay and offer **Reload from Disk** or
  **Overwrite Disk**.
- Go 1.26.10 fixes GO-2026-6809 in `crypto/x509`.

## 0.6.421

### Added

- Inbox rules show or hide conversations by project and label. Open **Inbox
  rules** from the filter button on the Mac or the filter menu on Android and
  iOS. A rule hides the matching conversations or shows only them, can require
  a project and a label together or accept either, and can be switched off
  without deleting it. A conversation matching any hiding rule is left out;
  while a showing rule is on, only matching conversations are listed. Rules
  sync across your account, apply to the Inbox, widgets, island and menu bar,
  and the Inbox says how many conversations they hide.

### Fixed

- Saving a project or board on Android no longer fails: the project sheet now
  edits the project's agent instructions (it showed the template override
  before), and the prompt template override is a separate, validated field
  that is sent only when you change it.
- On the Mac, the project context sheet saves your instructions without
  waiting on workspace settings you did not change and shows a failed save in
  the sheet. Project and board prompt overrides in Settings explain what the
  daemon rejects before you save.
- Claude turns that stop on an expired sign-in resume once after the token
  refreshes instead of failing.

## 0.6.420

### Changed

- Inbox cards on Android and iOS lead with their project's color and
  initial and carry a status badge: a pulsing dot while the agent works, a
  dot for replies, an eye for review, a check for finished work and a cross
  for failures. Cards that need you, are running or wait for review are
  tinted in their status color, and **Mark done** is a compact chip beside
  the status.
- Pin Inbox cards to keep them in a **Pinned** section at the top on Mac,
  Android and iOS. Pins follow your account through shared KV and sync once
  a machine is reachable; search and project filters still apply.
- Updated the bundled agent tools (Claude Agent SDK, Codex, Oh My Pi and the
  AI SDK harnesses), WebRTC M155 on Apple and Android, and the Go, Swift,
  Kotlin, npm and Ruby dependencies.

### Fixed

- The Mac app refreshes its sync when you switch back to it, and Inbox rows
  no longer keep stale content after they move to another section.

## 0.6.418

### Fixed

- Large Markdown files on Mac open as fully editable source, avoiding expensive rich layout and keeping multi-megabyte documents usable in Files and conversation tabs.
- Syntax highlighting limits work for large files and unusually long lines, cancels stale requests, and avoids repeated work when switching tabs.
- File navigation preserves selection and undo history; reloaded files refresh their highlighting. Opening a Markdown context menu no longer renders rich clipboard content unnecessarily.

## 0.6.416

### Fixed

- Screen sharing on Mac and Android recovers automatically when the initial
  signaling connection is interrupted, without requiring a second Connect.
- Connecting to a Mac desktop gives a cold capture helper enough time to wake
  the display before reporting a startup error.
- Active screen sharing keeps its video connection while signaling reconnects.

## 0.6.415

### Fixed

- Task creation remembers your project, board, workspace, checkout and agent
  choices, including when you close the form without creating a task. Submitting
  immediately after changing an option uses the latest selection, and an explicit
  Default effort stays selected.
- Android option pickers use readable, scrollable dialogs that mark the current
  selection instead of narrow dropdown menus.

## 0.6.413

### Changed

- New `dieter file cp` and `dieter file sync` commands copy files and
  synchronize directories one way between your computer and a project checkout
  or conversation workspace. They use the same authenticated routes as every
  other CLI command, verify all content with SHA-256, and handle binary files of
  up to 64 GiB.
- The Mac app is faster throughout. Switching chats takes about 40% less work,
  browsing changes about 30% and switching sections about 20%. Streaming
  replies, typing, the board, the sidebar, the Inbox, terminals and the file
  editor redraw only what changed.
- The Changes view wraps every line to the pane, side by side too, so long
  Markdown paragraphs and code lines no longer scroll sideways. Diffs of
  thousands of lines open, scroll and resize smoothly.

### Fixed

- A Mac reconnects promptly after it wakes from sleep. It used to stay
  "Connected" with every machine offline for minutes. A daemon likewise
  reconnects to the gateway as soon as it notices a sleep, instead of waiting
  about 45 seconds.
- The Mac app's **Show reasoning** setting now follows changes to the
  preference, for example from another device.

## 0.6.410

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

### Fixed

- The iOS app no longer crashes when it opens a conversation that contains a
  fenced Markdown code block. Only optimized release builds were affected.

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
