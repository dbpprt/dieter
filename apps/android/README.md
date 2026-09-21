# Dieter for Android

Native Kotlin/Jetpack Compose client for Dieter. It follows the 19 phone and
unfolded views extracted losslessly from `Native Android PWA redesign1.pdf`,
including the cross-project Spaces overview and board quick switcher. It uses
an adaptive master-detail layout for medium and expanded windows at 600 dp and
above, including unfolded Galaxy Fold displays, and talks to Dieter through the
machine-only gateway protocol and native gRPC/Protobuf Lite.

The default endpoint is `https://board.dbpprt.com`. One native OAuth/PKCE
session discovers every daemon enrolled to the GitHub account. The connection
dialog shows their presence and route state. Dieter automatically works across
all online machines, tries gateway-provided authenticated TLS candidates, and
falls back to the encrypted relay. Local-route discovery is automatic and never
requires ADB port mapping or a manually entered daemon address.

Spaces shows all projects discovered across online daemons, with a hostname
badge on every project when more than one host is present. Opening a project or
chat automatically routes to its owning daemon before starting streams or
mutations. This project-to-host directory lives only in the Android process;
the gateway remains a machine and presence directory.

Workspace settings can add a project on any online, API-compatible enrolled
machine without interrupting the currently open project. The creation form
browses directories on the selected host and configures the first board,
workspace base remote and branch, publishing policy, project instructions, and
exact-argv validation commands. Existing project settings expose the same
workspace defaults plus a project-wide list of provisioned worktrees, including
clean-up and recovery-backed discard operations.

Additional gateways can be added with an `https://` address. The resulting
Dieter session is encrypted with a device-bound Android Keystore key. GitHub
credentials, GitHub access tokens, daemon certificates, and harness credentials
are never persisted by the app.

The connection is process-wide rather than screen-scoped. Background sync has
three modes: **Live** keeps the stream and a partial wake lock active for
immediate updates; **Smart** stays live while work is running, then performs
best-effort checks about once a minute while Android permits background work;
and **App only** sleeps until Dieter is opened. Existing enabled background-sync
preferences migrate to Live so upgrades preserve their behavior. Android may
defer Smart's idle checks during Doze. Live and Smart use a `remoteMessaging`
foreground service and expose a permanent connection notification with
**Disconnect** and **Open** actions. Running standalone chats receive separate dismissible
notifications; dismissing one suppresses only that running session, and its
terminal transition posts a fresh completion, failure, stopped, or needs-you
notification. Running notifications are silent; terminal and board-card review
transitions use the separate Agent results alert channel. Board-card review
notifications are off by default and can be enabled independently from each
board's overflow menu. Expanding either the connection notification or a
running-chat notification shows a compact live preview of the main model and
active subagents without exposing raw tool input.

Activity is the default landing page, followed by Boards, Chats, and Tools.
It combines cards and standalone chats across projects with search, project filters,
a 1h/6h/24h timeline, Needs you, Running, account usage remaining, and Recent.
The timeline uses the latest synchronized activity for each conversation, with
recorded intervals where a start is available and event dots otherwise; it does
not reconstruct complete execution history. Account quota windows remain separate
and account-wide when filtering projects, and show reset times and stale/unavailable
status without cost estimates. Opening a conversation returns to the same Activity
filter and scroll position on Back. Android palettes and light/dark appearance apply.

For a disposable mock-agent navigation journey, run
`python3 apps/android/scripts/test-activity.py` with the standard emulator running
and Android SDK/JBR environment configured. It tests both chats and cards through
the real gateway and restores the app’s previous connection configuration.

The native Terminal workspace lists daemon-owned PTYs across projects, renders ANSI
and VT sequences with the reusable Apache-2.0 Termux emulator/renderer modules,
and forwards IME, hardware keys, clipboard paste, accessory keys, and live
window-size changes over gRPC. Output is resumed from a monotonic sequence
cursor after Android process death or a route reconnect; leaving the screen or
closing the app never closes the shell. Only the explicit **Close terminal**
confirmation ends the daemon session. The bundled Termux local-process JNI
bridge is deliberately excluded because Dieter never starts a process on the
phone.

**Screens** connects to an enrolled machine through an independent authenticated
route and verifies the daemon-signed WebRTC session before accepting video or
input. H.264 uses Android MediaCodec and a shared EGL texture canvas; hardware
decoding is preferred, with the platform decoder available on emulators. No
FFmpeg process or bitmap video conversion is used. Receiver feedback drives the
same adaptive sender as the Mac viewer. The bottom bar provides keyboard,
modifier and special keys, right click, Fit screen, and refresh. Display and
quality choices are in the header.

- One finger moves the remote cursor relatively; tapping clicks at that cursor.
- Double tap double-clicks; hold then move drags.
- Two fingers zoom and pan the local canvas (1–6×).
- Three fingers scroll the remote screen.

IME composition stays local until committed, including Unicode input. Physical
keyboards and mice also work. Held input is released on focus loss; leaving
Screens or backgrounding the app closes its session. Screen capture and control
must first be enabled on the host through its permission setup.

Run `just android screens-test` on the visible emulator for the isolated native
video/input check. Set `DIETER_SCREEN_TEST_SOURCE=screen` to exercise real display
capture. The test creates a temporary authenticated loopback service and native
input window, removes its ADB port mapping on exit, and preserves app credentials
and the running operator daemon.

Chats and Boards are the primary Android destinations. Tools opens a compact,
opaque panel for Machines, Terminal, Files, Schedules, Screens, and Settings. Machines
lists every enrolled daemon with cached reachability and live per-host CPU, memory,
GPU, software, process, disk, network, and temperature telemetry. Its authenticated
actions expose only capabilities authorized by the daemon and require a second
confirmation before update, restart, or shutdown. Files and
Schedules offer a project picker when multiple projects are available. Settings
uses horizontally scrollable tabs, and Display contains the app's color palettes.

Run `just android machines-test` on the visible emulator for the isolated Machines
journey. It starts a disposable gateway and daemon, verifies the real telemetry route
and Compose presentation, and accepts only the fixture's no-op update operation. It
restores the app's previous gateway configuration afterward.

Chats render their cached tail immediately. A tail already covered by the
healthy Live projection is current on open and resumes from its sequence
without waiting for a duplicate frame. Smart, App-only, and uncached opens
request the newest 30 messages first, without waiting for the complete
workspace projection, and load older history only when the user scrolls
upward. They retain a bounded local conversation cache and expose an explicit
**Force refresh** action in the conversation overflow menu. Project chat
sections show the five most recent entries until expanded. Model reasoning
traces are hidden by default and can be enabled globally under App Settings >
Chat display.

Each conversation also owns a bounded in-memory composer draft, including
attachments and model/provider selection, so switching conversations or
recreating the Activity does not move or erase unfinished input. Messages
admitted while an agent is running appear in the queue with **Edit** and
**Remove** actions. Edit atomically removes that queued message on the daemon
and restores its text, attachments, and immutable harness selection into the
same conversation's composer.

The app checks the latest public `dbpprt/dieter` GitHub release when it
starts. When a newer semantic version includes `Dieter-Android.apk`, Dieter
offers to download it, verifies GitHub's published SHA-256 asset digest, and
hands the APK to Android's package installer. Android requires the user to
allow Dieter as an install source and confirm each installation; background
or silent replacement is intentionally not attempted. A manual check is
available under App Settings > Updates.

## Build

Android Studio's bundled JDK and the default macOS Android SDK are detected by
the Android Just module:

```sh
just android build
```

The project targets Android 37.1 and supports API 26+. Open `apps/android` in
Android Studio for interactive development.

Display settings include eight Dieter designs. Native Monochrome is first and
selected by default, follows Android's light or dark mode without adding a
color tint, and includes a matching launcher icon. Selection is persisted
locally and updates Compose surfaces, terminal colors, widgets,
notification accents, and the launcher icon. Each launcher variant includes
legacy density images, an adaptive foreground, and Android 13+ monochrome
artwork. Android launchers may briefly cache the prior icon after a change.

The canonical fallback artwork and font assets are still derived from the
[`assets/brand`](../../assets/brand/README.md) masters. Regenerate those default
bitmap derivatives on macOS with:

```sh
just android sync-brand
```

## Connect

Enroll and run a daemon on the machine that owns the projects:

```sh
dieter daemon enroll --gateway https://board.dbpprt.com --name "Studio Mac"
dieter daemon start
```

Install and open the debug application:

```sh
just android emulator-start
just android install
just android launch
```

When more than one device is attached, add `-s <serial>` to each `adb` command.

The application validates the shared contract from `api/contract-version` (currently 1) before opening the workspace.
The daemon's raw port 4242 remains loopback-only. Native access always uses an
authenticated route or the gateway relay as documented in the root README.

## Visible emulator verification

`just android emulator-start` launches `Pixel_9_API_37_1` in a detached owner
session while keeping its emulator window visible. It refuses to launch when
host memory would force software rendering, resolves AVD data located on either
the internal disk or a mounted external volume, and accepts the AVD only after
renderer, snapshot, focus, accessibility, and screenshot health checks pass.
Run a real enrolled daemon, install the app, and exercise it through the
gateway. There is intentionally no mock server or coordinate-driven shell
smoke test.

The conversation and terminal replay reducers are covered by Kotlin unit tests.
Real-process instrumentation verifies health, runtime, state streaming,
harnesses, machine-scoped project creation, validation settings, queued-message
recall, project workspace cleanup/discard, project files, schedule preview, and
a terminal that stays alive across a complete Android gRPC channel teardown and
cursor-based reconnect, all through the configured gateway and automatically
routed real daemon:

```sh
just android connected-test
```

End-to-end UI checks use semantic inspection and active interaction on the
visible emulator. They never start a fixture or mock Dieter server.

Configured-account instrumentation tests require an explicit
`-Pandroid.testInstrumentationRunnerArguments.configuredGatewayTests=1`. They can
mutate the signed-in account and are skipped by default. Development validation
uses disposable credentials with `IsolatedGatewayIntegrationTest`.
