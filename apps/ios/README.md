# Dieter for iPhone and iPad

A native SwiftUI remote client for iOS 18 or later. Like the Android and Mac apps, it is a presentation-only client of the [shared Kotlin core](../core/README.md), which owns the session, routing, sync, the outbox, and every rule; the app observes the core's slices and sends its commands through the `SharedCore` target. The daemon continues to own tasks, transcripts, and files; the iOS app never starts a local daemon.

## Build and test

Open `DieterIOS.xcodeproj` in Xcode with the **DieterIOS** scheme for development.
From the repository root, use [the shared Fastlane pipeline](../../fastlane/README.md):

```sh
bundle install
just pipeline config_init
just pipeline doctor
just pipeline ios build
just pipeline ios test_unit
just pipeline ios e2e profile:ios-iphone suite:functional
just pipeline ios e2e profile:ios-ipad suite:functional
```

The pipeline builds the Kotlin shared framework using Android Studio's JBR when
JAVA_HOME is absent, then builds the app and its test bundles with Xcode.
Simulator builds use ad-hoc signing so tests exercise real Keychain access.
Shared framework slices and SwiftPM caches are canonical and protected by the
Apple build lease. Xcode products live in `.build/`; evidence is printed under
`tmp/app-pipelines/UUID`. Source builds embed the source-derived compatibility
SemVer; release archives embed the single reserved SemVer used by every component.

Each simulator run creates and journals its own exact simulator, retains fresh
fixture/client state per case, qualifies exact XCTest methods from xcresult,
and deletes only that simulator. Missing, skipped, duplicate, failed,
interrupted, unavailable and cleanup failures fail required runs. iPhone's Share
extension journey is excluded from the iPad catalog by layout eligibility.

For physical tests, explicitly configure `ios-device` in ignored
`fastlane/local.json`: exact UDID, existing Apple Development identity and
app/Share/runner provisioning profiles, separate `.e2e` bundle/app-group identities,
and a reachable authenticated TLS fixture route. The `DieterIOSE2E` scheme builds
those development-signed products. The pipeline refuses unowned installed fixture
apps and journals/cleans up only its fixture packages. No Apple resources or
operator credentials are replaced. Physical Share testing needs owned media
setup and remains unavailable until that prerequisite can be supplied.

```sh
just pipeline ios prepare_tests profile:ios-device cases:ios.remote-node
just pipeline ios e2e profile:ios-device cases:ios.remote-node
```

The SwiftUI client lives in `apps/mac/Sources/DieterIOS`. Each feature observes
its core slice and closes its scope when leaving. The Xcode host embeds the
DieterIOS framework; it does not link the Mac executable. The Share extension
stages validated files in the App Group without linking the core. Icons come
from `Artwork/AppIcon.svg` with an opaque background.

Pull-request CI runs portable iOS policy tests and compiles the app/test bundles.
Every main release additionally runs both complete iPhone and iPad functional
catalogs before candidate preparation.

## Signing and TestFlight

See [Apple credential setup](../../docs/apple-release-signing.md) and
[release policy](../../fastlane/README.md#ci-and-release-policy).
Dedicated Apple Distribution credentials, separate app/Share App Store profiles,
and a team App Store Connect API key are required for distribution. The default
identities are `com.dbpprt.dieter.ios`, `.share`, and
`group.com.dbpprt.dieter.ios`; both profiles must include that App Group.

Main builds one immutable signed IPA and retains it on the **dev** GitHub
prerelease. Publication delivers those exact bytes to internal TestFlight groups
and records upload, Apple processing and verified group membership. Reruns
reconcile existing delivery without rebuilding or blindly reuploading. The Apple
build number encodes the reserved native counter; it is independent of the
canonical marketing SemVer and never derives from workflow attempts.

The release-event workflow also handles an explicitly published retained release.
Resume an existing delivery with:

```sh
gh workflow run ios-testflight.yml --ref main -f tag=v0.4.413
```

Stable promotion is a separate protected operation on the retained qualified
release. It requires live valid/unexpired TestFlight delivery. External beta
review and App Store submission are not part of internal distribution.

## Connect to remote machines

1. Enter your HTTPS Dieter gateway in the sign-in screen.
2. Sign in with GitHub using the native authentication session, or supply an existing gateway session token in the advanced section.
3. The app loads one global workspace from every enrolled, online machine accepted by the gateway's release policy. Daemons requiring an update or reporting an invalid version are excluded.
4. Use **Inbox** for what needs you, is running, or finished recently; **Projects** for a project's boards and their lanes; and **Chats** for standalone chats. Create a task on a board's checkout or continue a conversation; the core routes each operation to that checkout or conversation's machine without changing the workspace.
5. Open **Machine state** from the machines menu to choose a machine and inspect live CPU, memory, storage, network, GPU, daemon build, and Dieter process telemetry.

Select **Screens** in the sidebar, then choose a machine to open its remote desktop.
The core negotiates an independently authenticated WebRTC session over the
machine's verified direct route or gateway relay; the app decodes and draws it.
The device works as the host's trackpad, as on Android: one finger moves the
cursor, a tap clicks, a long press drags, two fingers zoom and pan, and three
fingers scroll. Use the keyboard and the toolbar keys for text and HID input; the
toolbar arms a one-shot right click and modifiers for the next click or key.
Display, quality, codec, frame rate, refresh, and control handoff are available
from the screen toolbar. The session closes when the screen is left; when iOS
backgrounds the app, input is released and the session sleeps, and it resumes
on return.

The existing `dieter-mac://oauth/callback` redirect is deliberately reused inside ASWebAuthenticationSession, with PKCE; the core begins and completes the sign-in. This keeps sign-in compatible with gateways already configured for the Mac client. Tokens are kept in device-only Keychain items of the `com.dbpprt.dieter.ios.core` service, one per gateway origin. Sessions saved by releases before the shared core are not read, so every install signs in once. **Sign out** forgets the session and this device's unsent changes for the account. Remote plaintext endpoints are rejected. The Debug-only isolated test gateway accepts a loopback address supplied by the smoke harness; production sign-in always requires HTTPS.

## Basic workflows

- Browse the Inbox, projects, boards, tasks, and standalone chats across compatible remote machines.
- Create a draft or immediately run a task with provider, model, and reasoning selection.
- Attach photos, pasted screenshots, and files from New Task or any conversation. The iOS share extension can route a shared screenshot or file into a new task, an existing task, or an existing chat. After choosing the destination, tap **Done** and open Dieter to continue; iOS does not allow a Share extension to launch its containing app directly.
- Start a draft, send follow-up messages, stop an active turn, and read live transcript updates and older messages.
- Read and edit remote text files with revision-checked saves.
- Inspect a chosen machine's live resource, software, and Dieter process state.
- View and control a chosen machine through authenticated remote screen sharing.
- Suspend observation while the app is in the background and reconnect on return. Transport disconnects do not cancel agent work.

The phone uses stacked navigation; iPad uses sidebar, list, and conversation columns. Navigation is global within the selected gateway; machine selection is local to Screens and Machine state.

## Verification

See [implementation validation](VALIDATION.md) for observed results and current limits.

The shared E2E runner creates its own simulator, temporary gateway, enrolled daemon, mock harness, and Git repository. It exercises real native controls and real remote RPCs without production accounts or provider credentials. It stops only those owned resources and preserves test results and screenshots. Existing simulators and operator daemons are left untouched.

Fixtures include an incompatible node so exact application-contract filtering can be verified. The rules themselves are tested in the core. The app's tests are:

- `DieterIOSTests` (`just pipeline mac test_unit DieterIOSTests`, on the Mac host): share inbox hand-off and validation, attachment reading, and an architecture check that the app reaches gateways only through `SharedCore` and that the share extension does not link the core.
- `IOSCoreAdapterTests` (in `apps/mac/Tests/DieterIOSTests`, compiled into the app-hosted `DieterIOSNativeTests` target; case `ios.adapters`): the app's adapters against a scripted core — launch configuration, test-session adoption, foreground, sign-out and reconnect commands, delta folds and stale targets, and per-view scopes.
- `IOSCredentialNativeTests` (`ios.credentials`): device-only Keychain persistence through the core's secure store.
- `RemoteNodeUITests`: the isolated journeys.

An optional, read-only check verifies that an HTTPS gateway returns its explicit authentication error for an invalid session:

```sh
DIETER_IOS_TEST_HTTPS_GATEWAY=https://your-gateway.example \
  just pipeline ios e2e cases:ios.https-auth
```

This probe never signs in or changes gateway data. The default isolated suite excludes this manual case because external network access and a reachable gateway are environment dependencies. Its results are reported separately from the isolated journey.

The [native test catalog](../../tests/e2e/README.md) includes every existing iOS
XCTest method, including application-hosted Keychain assertions. iPhone and iPad
plans select exact methods; the phone-only Files share journey is declared in
the catalog. Skipped or missing required tests fail qualification. An installed
Simulator runtime is required; `just pipeline ios build` alone does not run these tests.
