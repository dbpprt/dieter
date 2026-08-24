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

Additional gateways can be added with an `https://` address. The resulting
Dieter session is encrypted with a device-bound Android Keystore key. GitHub
credentials, GitHub access tokens, daemon certificates, and harness credentials
are never persisted by the app.

The connection is process-wide rather than screen-scoped. While **Stay
connected in background** is enabled, a `remoteMessaging` foreground service
keeps the automatically routed workspace stream and cross-project chat/card polling alive,
and exposes a permanent connection notification with **Disconnect** and
**Open** actions. Running standalone chats receive separate dismissible
notifications; dismissing one suppresses only that running session, and its
terminal transition posts a fresh completion, failure, stopped, or needs-you
notification. Running notifications are silent; terminal and board-card review
transitions use the separate Agent results alert channel. Board-card review
notifications are off by default and can be enabled independently from each
board's overflow menu. Expanding either the connection notification or a
running-chat notification shows a compact live preview of the main model and
active subagents without exposing raw tool input.

The classic five-destination Material navigation remains the default. Its
native Terminal workspace lists daemon-owned PTYs across projects, renders ANSI
and VT sequences with the reusable Apache-2.0 Termux emulator/renderer modules,
and forwards IME, hardware keys, clipboard paste, accessory keys, and live
window-size changes over gRPC. Output is resumed from a monotonic sequence
cursor after Android process death or a route reconnect; leaving the screen or
closing the app never closes the shell. Only the explicit **Close terminal**
confirmation ends the daemon session. The bundled Termux local-process JNI
bridge is deliberately excluded because Dieter never starts a process on the
phone.

App
Settings opens from Board actions or the server-status sheet and follows the
native Connections and Display tab references. Display also offers the
optional glass lens navigation from `Copy of Native Android PWA redesign.pdf`:
a floating translucent dock, raised active destination, live chat badge,
dedicated settings and command-center actions, swipe-up gesture, and expanded
searchable command center. The preference is local to the Android device and
survives process restarts.

Chats open at the latest loaded message, retain a bounded local conversation
cache, and expose an explicit **Force refresh** action in the conversation
overflow menu. Project chat sections show the five most recent entries until
expanded. Model reasoning traces are hidden by default and can be enabled
globally under App Settings > Chat display.

The app checks the latest public `dbpprt/dieter` GitHub release when it
starts. When a newer semantic version includes `Dieter-Android.apk`, Dieter
offers to download it, verifies GitHub's published SHA-256 asset digest, and
hands the APK to Android's package installer. Android requires the user to
allow Dieter as an install source and confirm each installation; background
or silent replacement is intentionally not attempted. A manual check is
available under App Settings > Updates.

## Build

Android Studio's bundled JDK and the default macOS Android SDK are detected by:

```sh
./apps/android/scripts/build.sh
```

The project targets Android 37.1 and supports API 26+. Open `apps/android` in
Android Studio for interactive development.

Display settings include all eight official Dieter palette packs. Selection is
persisted locally and updates Compose surfaces, terminal colors, widgets,
notification accents, and the launcher icon. Each launcher variant includes
legacy density images, an adaptive foreground, and Android 13+ monochrome
artwork. Android launchers may briefly cache the prior icon after a change.

The default Arctic Console assets are still derived from the canonical
[`assets/brand`](../../assets/brand/README.md) masters. Regenerate those default
bitmap derivatives on macOS with:

```sh
./apps/android/scripts/sync-brand-assets.sh
```

## Connect

Enroll and run a daemon on the machine that owns the projects:

```sh
dieter daemon enroll --gateway https://board.dbpprt.com --name "Studio Mac"
dieter daemon start
```

Install and open the debug application:

```sh
./apps/android/gradlew --project-dir apps/android installDebug
adb shell am start -n com.dbpprt.dieter/.MainActivity
```

When more than one device is attached, add `-s <serial>` to each `adb` command.

The application validates Dieter API version 2 before opening the workspace.
The daemon's raw port 4242 remains loopback-only. Native access always uses an
authenticated route or the gateway relay as documented in the root README.

## Visible emulator verification

Start `Pixel_9_API_37_1` from Android Studio's Device Manager so the emulator
window remains visible. Run a real enrolled daemon, install the app, and
exercise it through the gateway. There is intentionally no mock server or
coordinate-driven shell smoke test.

The conversation and terminal replay reducers are covered by Kotlin unit tests.
Real-process instrumentation verifies health, runtime, state streaming,
harnesses, project files, schedule preview, and a terminal that stays alive
across a complete Android gRPC channel teardown and cursor-based reconnect,
all through the configured gateway and automatically routed real daemon:

```sh
ANDROID_SERIAL=emulator-5554 ./apps/android/gradlew \
  --project-dir apps/android connectedDebugAndroidTest
```

End-to-end UI checks use semantic inspection and active interaction on the
visible emulator. They never start a fixture or mock Dieter server.
