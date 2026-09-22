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
just android lint
```

For a healthy selected emulator:

```sh
just android connected-test
just android machines-test
just android sync-test
just android screens-test
```

The complete connected suite includes production-mode frame performance checks
and restores the debug APK without clearing data. A class filter runs debug
instrumentation only; `just android performance-test` runs the performance case.

For a separate diagnostic run:

```sh
env 'ORG_GRADLE_PROJECT_android.testInstrumentationRunnerArguments.dieterPerformanceFrames=true' \
  just android performance-test
```

The diagnostic records up to 4,096 frame phase
samples on a dedicated callback thread and reports dropped samples, percentiles,
and the slowest frames under the `DieterPerformance` logcat tag. The optional
`dieterPerformanceControl=true` argument runs the same input journey against
native buttons to identify system/rendering costs. Neither diagnostic replaces
a clean Dieter timing run without extra tracing; the p95 and severe-frame limits stay active.

Default integration uses disposable enrolled gateway/daemon fixtures and mock
agents. Configured-account tests are skipped unless explicitly enabled with
`-Pandroid.testInstrumentationRunnerArguments.configuredGatewayTests=1`; those can
mutate the signed-in account. Inspect the test before enabling them.

Machines and Activity journeys restore the prior connection configuration.
Screens uses a separate `com.dbpprt.dieter.screenfixture` app, preserving the
operator app, and removes only its temporary reverse mapping. Real-screen mode
injects input into an owned host fixture window. See [WebRTC adapter details](webrtc-adapter.md).

Capture and inspect both semantic and visual evidence:

```sh
just android ui-dump apps/android/build/evidence/ui.xml
just android screenshot apps/android/build/evidence/screen.png
```

If you launched the AVD, finish with `just android emulator-stop`. It returns to
the launcher, saves and validates the normal snapshot, and closes gracefully.
Use `just android app-stop` when only your app session should stop. Never terminate
somebody else's emulator or daemon to make a test pass.
