# Dieter Kotlin clients

One Gradle build holds the client business logic every Dieter app runs on (a
Kotlin Multiplatform core), the Compose Multiplatform UI the Android and iOS
apps share, and the Android app shell. The macOS and iOS apps link the core as
the `DieterCore` framework from [`apps/apple`](../apple/README.md).

Every rule lives in the core: wording, counts, enablement, ordering, decisions,
defaults, and parsing, so every client words and decides things the same way.
The apps keep view mechanics (layout, scrolling, focus, animation, gesture
geometry), locale date formatting, colours, icons, and their platform adapters.
Every client sends `client.proto` commands and observes slices; the apps keep no
logic layer of their own.

## Layout

| Project         | Directory      | Role                                                                                                                                                                                                                                                                                                                                 |
| --------------- | -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `:core:model`   | `core/model`   | Wire models and gRPC stubs generated from `api/proto` (relocated to `com.getdieter.api.*`), the core's on-device records (`dieter/core/v1`, `com.getdieter.core.v1`) and the UI contract (`dieter/client/v1/client.proto`, `com.getdieter.client.v1`).                                                                               |
| `:core:runtime` | `core/runtime` | All client logic (`com.getdieter.core.*`), the platform-extension contracts (`platform/Platform.kt`, `screens/ScreenMedia.kt`, `terminals/TerminalScreen.kt`), the OkHttp transport for Android and the JVM (`jvmSharedMain`), the distribution identity (`identity/DistributionIdentity.kt`, generated), and its unit tests.        |
| `:core:testing` | `core/testing` | Fakes, `SliceFolds` (applies keyed deltas as a Swift observer does), the JVM platform (a software device key in its state directory), the JDK's Ed25519 and ECDSA verifier, and the `IsolatedGateway` fixture launcher, whose pairing code makes test runtimes trusted devices.                                                      |
| `:core:apple`   | `core/apple`   | The Swift façade (`com.getdieter.apple`): `DieterShared` (`dispatch(command)` and `observe(slice, scope)` over encoded `dieter.client.v1` messages), the synchronous `SharedRules` exports, `SharedTouchScreen`, and the native extension protocols, including the RPC bridge (`NativeRpc.kt`). Its macOS framework is `DieterCore`. |
| `:core:e2e`     | `core/e2e`     | JVM end-to-end tests of the core and the shared UI against a disposable gateway and daemon built from this repository. Opt-in: they need Go and Node.                                                                                                                                                                                |
| `:ui`           | `ui`           | The Compose Multiplatform UI of the Android and iOS apps (`com.getdieter.mobile`): screens, view lifetime, and navigation over `ClientApi`. Its iOS framework, also named `DieterCore`, exports the `:core:apple` façade.                                                                                                            |
| `:android`      | `android`      | The Android app (`com.getdieter.android`): adapters only. `android/webrtc` holds the audited WebRTC SDK extension the app applies (see its [README](android/webrtc/README.md) and [adapter contract](android/webrtc/ADAPTER.md)).                                                                                                    |

`build-logic` (an included build) provides the `dieter.kmp` convention plugin:
every core module targets the JVM, Android, `iosArm64`, `iosSimulatorArm64` and
`macosArm64`, and Android and the JVM share the OkHttp-backed `jvmShared` source
set. `gradle/libs.versions.toml` is the one source of every toolchain and
library version.

Mail's graphics reuse `apps/apple/mac/MarkdownPreview` on every platform. The
UI's `buildMarkdownPreview` task needs the pinned Node/npm toolchain and builds
the offline bundle from its shared lockfile; Android packages it as resources,
and the iOS app copies the prepared Compose resources after linking its framework.
The core owns fence names and aliases; WebView adapters only load packaged
assets, present diagrams and release views.

## Architecture

- **Threading.** Every piece of mutable state is confined to one serialized
  dispatcher (`CoreRuntime.dispatcher`). UIs read `StateFlow`s (Kotlin) or
  observe slices (Swift). `SharedRules` calls are stateless and run on any
  thread.
- **Data flow.** Every online, compatible machine streams its changes
  (`WatchChanges`) at once; no machine is chosen. `AccountSync` keeps one
  replica per machine, joins the replicated records per register as the peer
  store does, and projects the account view with the daemon's rules (`sync/`),
  so any order of frames from any machines converges. Each machine's view is
  cached and resumes from its cursor. `MachineChoice` routes each call: a
  card's work to its owner, project reads to a machine with a checkout,
  compare-and-swap writes to a machine that observed the joined register.
  Every feature shares one data plane per machine (direct TLS, then WebRTC
  hedged against the relay, then the relay alone). All state enters one
  `WorkspaceStore` reducer, which applies optimistic overlays.
- **Durable intent.** Creates, sends, and starts go through a journaled outbox
  with deterministic IDs, so a retry can never duplicate a command. Pending
  cards carry aliases (the deterministic and the acknowledged daemon ID), so a
  card never shows twice when sync delivers it before the create reply.
- **Device trust.** `trust/DeviceTrust` keeps this device's place in the
  account's signed device roster: it pairs with a one-time code that a trusted
  device types, pins the roster only after the approver's confirmation, and
  enters CONFLICT when a later roster does not extend the pinned one. Every
  route (direct, WebRTC, and the relay's opaque tunnel) is mutual TLS pinned to
  the machine's roster key, so the gateway relays ciphertext only. Machines are
  reachable only while the device is trusted.
- **Division of labour.** Platforms own HTTP/2, TLS, credentials, rendering,
  terminals (SwiftTerm, Termux), and screen media (WebRTC, decoders, Metal).
  The core makes every decision around them.

Under `core/runtime/src/commonMain/kotlin/com/getdieter/core/`:

- One package per domain (`activity`, `admin`, `board`, `composition`,
  `connection`, `conversation`, `files`, `machines`, `navigation`,
  `presentation`, `quotas`, `schedules`, `screens`, `terminals`, `workspace`,
  and others). Each holds the domain's state, operations, and rules; Android
  calls these directly. `CoreRuntime.kt` wires them together.
- `client/` implements the client contract (`client.proto`): `ClientApi.kt`
  dispatches commands and serves slice observations; `Surfaces.kt` keeps
  per-view surfaces by scope (the first observer opens one, the last release
  stops it); `*Commands.kt` handle each domain's commands; `SliceMappers.kt`,
  `RuntimeSlices.kt`, and `BoardViewSlices.kt` map the Kotlin views to slices;
  `Deltas.kt` turns keyed lists into keyed deltas; `rules/` holds one stateless
  `*Exports` object per domain for `SharedRules`.

The core supplies English text (relative ages, sizes, counts, labels, status
lines); the apps format only absolute dates in the device locale. The client
schema lives in `api/proto/dieter/client/v1` (Wire reads all schemas from
`api/proto`): it never crosses the network.

### Adding a rule

1. Write the rule in its domain package, as a function or a property of the
   domain's Kotlin view, with `commonTest` unit tests in the same package.
   Android calls it there.
2. Give Swift the result:
   - **A value derived from slice state** (what a row or control shows or
     allows) becomes a slice field in `client.proto`: compute it in the Kotlin
     view, copy it in the slice mapper, and assert it in a `client/*SliceTest`
     or a `ClientApi*EndToEndTest` (`:core:e2e`). Keyed lists travel as keyed
     deltas.
   - **A rule a view calls while rendering**, from values it already holds,
     becomes a `SharedRules` export: add a function to the domain's
     `client/rules/<Domain>Exports.kt` with a test in
     `commonTest/.../client/rules/<Domain>ExportsTest.kt`, and a forwarder in
     the domain's region of `core/apple/.../SharedRules.kt`. Inputs are
     primitives (`String`, `Long`, `Int`, `Double`, `Boolean`, lists of them)
     or encoded messages; times are epoch milliseconds, 0 meaning unknown;
     outputs are primitives or encoded `dieter.client.v1` messages. A forwarder
     only converts and calls one export. Swift calls
     `SharedRules.shared.<name>(...)`, often per rendered row, so keep exports
     cheap.
3. After a schema change, regenerate the Apple Swift types with
   `apps/apple/DieterKit/scripts/generate-swift-proto.sh`. Avoid field names
   that Wire escapes (`value`, `data`, and `file` become `value_`, `data_`, and
   `file_`).
4. Delete the app's copy and its tests.

## Shared mobile UI (`:ui`)

The Android and iOS apps share one Compose Multiplatform UI, organized as
**Inbox / Projects / Chats / More**, with compact task cards, project folders,
agent controls, transcript tools, files, Git review, schedules, terminals,
screens and machine tools. More holds Mail, Channels, Terminals, the machines,
Usage, Devices and Settings (`app/More.kt`). Tools live with their scope:
Files, Changes and Schedules open from a project and carry its ID (and Files
and Changes a checkout), a machine's page shows its screen, terminals and
checkouts, and nothing falls back to the last project opened. Native code supplies credentials, transport,
attachments, terminal emulation, screen video/input and, on iOS, navigation
chrome.

`MobileStore` binds core scopes (board, project, conversation, files,
terminals, telemetry) to the visible routes of per-tab navigation stacks
(`Navigation.kt`). It sends the core's `ClientApi` commands and observes its
slices, including keyed deltas and temporary-to-confirmed task ID resolution.
It adds no server API or business rules. Android and the JVM tests call
`ClientApi` directly; on iOS, `MobileHost` uses the `DieterShared` byte contract
of `:core:apple`, which the iOS framework exports.

Each platform gets its own chrome and controls; the screens' content, state and
commands are shared.

- **Android:** Material 3 throughout. Colors come from the wallpaper (dynamic
  color, Android 12+, switchable in Settings) or from tonal schemes built from
  the eight Dieter palettes; Monochrome is the default. Navigation is a
  navigation bar whose More item slides up a sheet with the bar docked below
  it (a rail from 840 dp); system back pops the visible tab stack.
- **iOS:** UIKit owns navigation: a `UITabBarController` holds one
  `UINavigationController` per tab (a sidebar-adaptable tab bar on iPad), so
  titles, back gestures and bar buttons are the system's own. Compose draws
  each screen's content with iOS system colors, Dynamic Type sizes, SF Symbols
  and inset-grouped lists.
- **Adaptive layouts:** Android shows list and detail side by side from 600 dp
  wide and 480 dp tall (unfolded foldables, tablets), split by a draggable
  handle whose position `LayoutModel` keeps; iPad uses a split view in regular
  width. `MobileRoute.list` decides which routes stay in the list column on both. A board shows parallel lanes from
  700 dp and swipeable lane tabs below that.

| Surface                                                                      | Shared implementation                           | Native boundary                                    |
| ---------------------------------------------------------------------------- | ----------------------------------------------- | -------------------------------------------------- |
| Inbox, projects, folders, chats, boards, card actions                        | `WorkspaceScreens`, `BoardScreens`              | Navigation chrome                                  |
| Task creation, agent/model/effort/options, attachments                       | `CreationScreen`                                | Photo/document pickers                             |
| Transcript, Markdown/tables/code, tools, plans, subagents, queues and drafts | `ConversationScreen`, `RichText`                | Attachment previews                                |
| Files/editing/history, Git diffs/operations/merge                            | `ToolScreens`, `ReviewScreen`, `WorkspaceTools` | Binary previews                                    |
| Schedules/editor/history, projects/checkouts/boards/labels/archive           | `ManagementScreens`, `AdministrationScreens`    | Core administration                                |
| Machine telemetry/actions, quotas, gateways, appearance                      | `ToolScreens`, `MobileTheme`                    | Core operations                                    |
| Pairing (until this device is trusted), trusted devices, adding a device     | `DevicesScreen`                                 | Device key and TLS client authentication           |
| Persistent terminals                                                         | Shared controls and bounded core output         | Termux on Android, SwiftTerm on iOS                |
| Screen sharing                                                               | `ScreenUI` and core session state               | GPU/Metal renderers, WebRTC and native touch input |

Machines answer only a trusted device, so until the session's `device_trust` is
trusted (or still unknown) both apps show the pairing screen instead of the
tabs: the one-time code to type on a trusted device (More › Devices, or
`dieter device approve CODE` on a machine), or Reset after this device was
removed or saw a conflicting roster. More › Devices lists the account's
devices, adds one by the code it shows, and removes one.

Items shared from other apps reach `MobileStore.share` as `SharedItems` once the
workspace has loaded: a new task opens prefilled, or `ShareTargetScreen` picks
the task or chat whose composer receives them. Screens use the core's touch
model (`TouchScreenInput`): one finger moves the remote cursor, a tap clicks, a
long press drags, two fingers zoom and pan, and three fingers scroll. The apps
have no background service, notifications or widgets.

## Android app (`:android`)

A Material 3 shell hosting the shared UI. It keeps only adapters, under
`android/src/main/kotlin/com/getdieter/android`:

- `MainActivity`: the single Activity, edge-to-edge window, OAuth callback and
  update dialog.
- `DieterSession`: an `AndroidViewModel` that owns the core runtime, the shared
  `MobileStore`, preferences and screen media across Activity recreation.
- `data/DieterCredentialStore`: session tokens encrypted with a device-bound
  Android Keystore key, keyed by gateway origin; the core's `SecureStore`.
- `data/AndroidDeviceKeys`: the device key, a non-exportable ECDSA P-256 key
  in the Android Keystore (StrongBox when available). `data/KeyStoreTls`
  configures BouncyCastle JSSE (Conscrypt cannot verify the machines' Ed25519
  certificates) to sign the TLS 1.3 client CertificateVerify with it through
  the Keystore's own provider.
- `sharedcore/ControlRTCBridge`: the WebRTC control channel the core routes
  requests over.
- `screens/` and `ComposeScreenSurface`: WebRTC/MediaCodec screen media, the
  GPU canvas, IME input and the clipboard provider. The decoder adapter in
  `android/src/main/java/org/webrtc` is described in
  [android/webrtc/ADAPTER.md](android/webrtc/ADAPTER.md).
- `update/`: the sideload updater.

The Termux terminal view and attachment helpers live in `:ui`'s `androidMain`.

The application ID is `<bundle_prefix>.android` from
[`config/identity.json`](../../config/identity.json) (`com.getdieter.android`;
Android 8+). Build types are `debug`, `release` and `e2e`; the `e2e` type adds
the `.e2e` suffix so Maestro flows never touch the operator's app or session.
Debuggable builds (`debug` and `e2e`) expose the shared Compose `testTag`s as
resource ids, which the flows select. Sign-in returns through
`dieter-android://oauth/callback`; debug builds also accept an isolated fixture
session for Maestro flows, release builds do not.

Release builds check the latest public GitHub release of the repository named in
`config/identity.json` when the app starts. When it is newer, the app downloads
`Dieter-Android.apk`, verifies the SHA-256 digest GitHub publishes for that
asset, and hands it to the system installer; the user confirms each
installation. Dev prereleases are never offered.

Release signing reads `DIETER_ANDROID_KEYSTORE_PATH`,
`DIETER_ANDROID_KEYSTORE_PASSWORD`, `DIETER_ANDROID_KEY_ALIAS` and
`DIETER_ANDROID_KEY_PASSWORD`; `DIETER_RELEASE_VERSION` and
`DIETER_RELEASE_VERSION_CODE` set the version. Never commit the keystore or
passwords.

## Build and test from a fresh clone

You need Java 21 (`mise install` provides Temurin 21; Android Studio's JBR also
works), the Android SDK with platform 37.1 (`ANDROID_HOME`, or `sdk.dir` in an
ignored `apps/kotlin/local.properties`), and, for Apple targets, Xcode. The
first Kotlin/Native build downloads about 1.6 GB into `~/.konan`. Run Gradle
builds one at a time.

```sh
cd apps/kotlin

# Unit tests: no Go, Node or devices.
./gradlew :core:runtime:jvmTest :ui:jvmTest
./gradlew :core:runtime:macosArm64Test :core:apple:macosArm64Test   # macOS host

# End-to-end tests against a disposable gateway and daemon (tools/fixtures/gateway).
npm --prefix ../../internal/harness/runtime ci
./gradlew :core:e2e:test

# Android app: debug and isolated E2E APKs, and lint.
./gradlew :android:assembleDebug :android:assembleE2e :android:lintDebug

# DieterCore frameworks for apps/apple (debug; use linkRelease… for releases).
./gradlew :core:apple:linkDebugFrameworkMacosArm64        # macOS
./gradlew :ui:linkDebugFrameworkIosSimulatorArm64         # iOS simulator
./gradlew :ui:linkDebugFrameworkIosArm64                  # iOS device
```

APKs are written to `android/build/outputs/apk/<type>/android-<type>.apk`. The
framework links write `core/apple/build/bin/macosArm64/debugFramework/DieterCore.framework`
and `ui/build/bin/<target>/debugFramework/DieterCore.framework`;
[apps/apple](../apple/README.md#build-and-test-from-a-fresh-clone) assembles them
into one `DieterCore.xcframework`. Kotlin/iOS tests run on a caller-provided
simulator: `./gradlew :core:runtime:iosSimulatorArm64Test -Pdieter.simulator=<UDID>`.

`:core:e2e` builds the fixture gateway with `go build ./tools/fixtures/gateway`
(Gradle reruns it only when Go sources change; `-Pdieter.go=PATH` selects the Go
binary). Every end-to-end test starts its own gateway and daemon with a
temporary `DIETER_HOME` and random loopback ports, and never touches an
operator's daemon. The Android and iOS Maestro flows in
[`tests/maestro`](../../tests/maestro/README.md) cover the shells on devices.
