# Dieter for Android

Native Kotlin/Jetpack Compose client for Android 8+ (API 26+), targeting Android
37.1. Phones and expanded windows use adaptive navigation and master-detail
layouts. Start with the [product tour](../../landingpage/content/docs/tour.md)
for user-facing workflows; this page covers development and verification.

## Install and connect

Users can install [Dieter-Android.apk](https://github.com/dbpprt/dieter/releases/latest/download/Dieter-Android.apk)
and sign in to their HTTPS gateway. The account must be allowed by its operator.
The default endpoint is `https://gateway.getdieter.com`; custom gateways are supported.
The app discovers compatible enrolled machines and routes work to the conversation
or checkout owner. Shared projects appear once across machines.

Gateway sessions use a device-bound Android Keystore key. The app does not retain
GitHub access tokens or provider credentials. Routes prefer verified direct TLS,
then supported WebRTC, with authenticated gateway relay fallback. Ordinary use
needs no ADB reverse mapping or raw daemon address.

## Build

Android Studio's bundled JBR and the SDK are selected by the Android Just module:

```sh
just android doctor
just android build
```

If necessary, set `JAVA_HOME` to
`/Applications/Android Studio.app/Contents/jbr/Contents/Home`. Open `apps/android`
in Android Studio for interactive development. The authoritative protobuf schema
is generated into Lite messages and Kotlin stubs by Gradle; do not commit those
build outputs.

## Visible emulator

```sh
just android emulator-status
just android emulator-start
just android install
just android launch
```

The standard target is **Pixel_9_API_37_1**, serial **emulator-5554**. Preserve that
serial on every ADB and Gradle command that can choose a device; do not let an
attached physical phone become the implicit test target.

The launcher reuses a healthy visible AVD, checks resolved AVD storage, requires
10 GiB free, and verifies host rendering, boot, focus, UI hierarchy, and a valid
screenshot. Its memory estimate is advisory; the actual renderer check decides
health. Do not wipe app data, remove caches, or improvise cold-boot/software-GPU
flags. For a diagnosed lifecycle problem, read [agents.md](agents.md).

Installation and connected tests retain app data and credentials. Do not use
`adb uninstall` to fix an installation failure.

## Native workflows

**Activity** is the default destination, followed by **Boards**, **Chats**, and
**Tools**. Activity combines recent card/chat activity, project filters, a timeline,
Needs you, Running, and account quota windows. Back from a conversation preserves
its Activity filter and scroll position.

Tools opens Machines, Terminal, Files, Schedules, Screens, and Settings. Project
and checkout choices route operations to the owning daemon. Terminals render
ANSI/VT output with the bundled Apache-2.0 Termux modules; the local-process JNI
bridge is excluded because the phone does not start a local shell.

Conversations retain per-conversation drafts and attachments. Editing a queued
message atomically removes it from the host queue and restores its full payload
and selection to that composer. Reasoning traces are hidden by default and can
be enabled in chat display settings.

Screens uses MediaCodec and a shared EGL canvas, with H.264 by default and optional
negotiated HEVC. One finger moves the remote pointer, two fingers zoom/pan locally,
and three fingers scroll remotely. Clipboard sharing is opt-in for the controlling
viewer. See the [Screens guide](../../landingpage/content/docs/screens.md).

## Background activity and updates

- **Live:** keeps the stream and a partial wake lock for prompt updates.
- **Smart:** stays live during work and makes best-effort idle checks, subject to Doze.
- **App only:** observes while the app is open.

Live and Smart use a `remoteMessaging` foreground service and connection
notification. Running-chat notifications are separate; result alerts use their
own channel. Board Review notifications are off by default and configurable per
board. Closing observation never cancels a host agent.

The app checks the latest public release for updates, verifies the published APK
SHA-256 digest, then asks Android to install it. The user confirms each install;
no silent update is attempted. Manual check: **App Settings → Updates**.

Eight designs include default Native Monochrome. Appearance changes affect the
UI, terminal, widgets, notification accents, and launcher icon. Regenerate fallback
brand derivatives with `just android sync-brand`.

## Verify safely

```sh
just check-changed --dry-run
just check-changed
just android test
just android check  # unit tests, lint, debug APK and both E2E/performance app/test APKs; no device
```

For a healthy selected emulator, use the shared YAML/native runner:

```sh
just e2e lint
just e2e run --suite smoke
just e2e run --suite functional
just e2e run --case machines.telemetry
just e2e run --suite sync
just e2e run --suite performance
just e2e run --suite screens  # requires a macOS capture host
```

See [the test catalog guide](../../tests/e2e/README.md) for case authoring,
change selection, artifacts, and iOS preparation. Android runs in the separate
`com.dbpprt.dieter.e2e` package with disposable authenticated fixtures. Every
case starts with clean test app data. APKs are built once and reused by hash;
YAML-only edits need no recompilation. The old Android test aliases are removed;
use `just e2e run --suite NAME` or `--case ID`. Class filters are replaced by
explicit catalog case IDs.

Performance is a separate suite using the non-debuggable
`com.dbpprt.dieter.e2e.performance` app. It retains native frame limits and idle-CPU
measurements and never installs over the operator app. Add `dieterPerformanceFrames: "true"` under the performance case's `arguments` for diagnostic frame traces;
keep those runs separate from clean measurements.


Diagnostic frame traces are bounded to 4,096 samples and retain the frame limits.
The catalog excludes configured-account tests; they require a separately
reviewed manual operation. All standard gates use disposable fixtures and mock
agents. Real-screen input targets only the owned capture-host window.
See [WebRTC adapter details](webrtc-adapter.md).

Capture and inspect both semantic and visual evidence:

```sh
just android ui-dump apps/android/build/evidence/ui.xml
just android screenshot apps/android/build/evidence/screen.png
```

If you launched the AVD, finish with `just android emulator-stop`. It returns to
the launcher, saves and validates the normal snapshot, and closes gracefully.
Use `just android app-stop` when only your app session should stop. Never terminate
somebody else's emulator or daemon to make a test pass.
