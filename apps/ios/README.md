# Dieter for iPhone and iPad

A UIKit shell hosting [the shared Compose UI](../core/mobile/README.md), which the
Android app also uses, on iOS 18 or later. Like every Dieter client, it is a
presentation-only client of [the shared Kotlin core](../core/README.md), which
owns the session, routing, sync, the outbox, and every rule. The daemon owns
tasks, transcripts, and files; the iOS app never starts a local daemon.

## What lives here

- `Dieter.xcodeproj`: the `Dieter` app target (`Dieter.app`), its embedded
  `DieterShare` Share extension and the `DieterUITests` journey target, built
  with the shared `Dieter` scheme.
- `App/DieterApp.swift`: the app entry. It presents the UIKit shell, forwards
  the sign-in callback URL and reports foreground state to the core.
- `App/Info.plist` and `App/Assets.xcassets` (`DieterAppIcon`, generated from
  `Artwork/AppIcon.svg` with an opaque background).
- `Share/`: the Share extension. It asks whether shared items start a new task
  or go to an existing task or chat, stages them in the `group.<bundle ID>` App
  Group, and the app delivers them when it next becomes active.
- `Tests/JourneyUITests.swift`: the native journey and the share case.

The Swift host is the `DieterIOS` target of `apps/mac/Package.swift`, sources in
`apps/mac/Sources/DieterIOS`. The package selects its iOS graph when
`DIETER_SWIFT_PACKAGE=ios` is set; the pipeline sets it for every iOS build.

- `ComposeHost.swift` configures the core and drives a `UITabBarController` with
  one navigation stack per tab (a sidebar and split view on iPad) from the
  shared navigation state. Each route is a Compose view controller; bar buttons,
  menus, sheets, alerts and toasts are native.
- `NativeViews.swift` supplies the photo and document pickers, Quick Look
  attachment previews, SwiftTerm terminals, and the Metal screen view with
  touch input.
- `ShareInbox.swift` reads the Share extension's staged request from the App
  Group and hands its files to the shared UI.

It links `apps/mac/Frameworks/DieterMobile.xcframework`, which
`just pipeline framework platforms:ios-simulator|ios-device` builds from the
`:mobile` Gradle module, and compiles the Keychain store, platform services,
gRPC bridge, WebRTC control channels and screen media from `SharedCore`. To
work in Xcode, build the framework slice first and run Xcode with
`DIETER_SWIFT_PACKAGE=ios` in its environment; otherwise package resolution
selects the Mac graph, which has no `DieterIOS` product.

## Build and test

From the repository root, use [the shared Fastlane pipeline](../../fastlane/README.md):

```sh
mise exec -- just pipeline config_init
mise exec -- just pipeline doctor
mise exec -- just pipeline core_test        # core and shared UI JVM tests
mise exec -- just pipeline ios build
mise exec -- just pipeline ios e2e profile:ios-iphone
mise exec -- just pipeline ios e2e profile:ios-ipad
mise exec -- just pipeline ios_qualify profiles:ios-iphone,ios-ipad
```

The build assembles the needed framework slice (it needs a Java runtime and uses
Android Studio's JBR when `JAVA_HOME` is absent), then builds the app and its
test bundle with Xcode. Simulator builds use ad-hoc signing so tests exercise
real Keychain access. Framework slices and SwiftPM caches are canonical and
protected by the Apple build lease. Xcode products live in `.build/`; evidence
is printed under `tmp/app-pipelines/UUID`. Source builds embed the
source-derived compatibility SemVer; release archives embed the single reserved
SemVer used by every component. There is no separate iOS unit lane: the shared
UI's tests run with `core_test` and its rules are tested in the core.

Fastlane `run_tests` owns XCTest command generation; `build_app` owns
distribution archive/export. Dieter retains leases, private launch files,
exact-result qualification and cleanup around those maintained actions.

`ios e2e` runs the catalog case `ios.journey` (`JourneyUITests/testSharedTaskJourney`)
as the separate `com.dbpprt.dieter.ios.e2e` app. Each run creates and journals its
own exact simulator, starts a disposable authenticated gateway, enrolled daemon
and mock harness, and walks Inbox, Projects, a board and its card menu, a task
and its subagents, task creation with live replies, Review, Chats, Tools,
Machines, Files, Schedules and dark appearance. The creation header and composer
must stay reachable with the keyboard open; iPad runs in landscape with the
board beside the conversation. Missing, skipped, failed, interrupted,
unavailable and cleanup failures fail required runs. Only that simulator is
deleted; existing simulators and operator daemons are left untouched.
`ios.share` (`JourneyUITests/testShareExtensionStartsATask`, iPhone only) places
an owned PNG in the E2E app's Documents, shares it from the Files app through
the Share extension, and checks that Dieter opens a new task holding that file.
`ios_qualify` verifies one simulator build and runs both layouts on the same
worker with fresh simulator and client state.

For physical tests, explicitly configure `ios-device` in ignored
`fastlane/local.json`: exact UDID, an existing Apple Development identity,
development profiles covering the `.e2e` app, its `.e2e.share` extension with
the `group.<.e2e bundle ID>` App Group, and its test runner, and a
reachable authenticated TLS fixture route. The pipeline refuses unowned
installed fixture apps and journals/cleans up only its own packages. No Apple
resources or operator credentials are replaced.

```sh
mise exec -- just pipeline ios prepare_tests profile:ios-device
mise exec -- just pipeline ios e2e profile:ios-device
```

PR/main CI builds the app and runs the journey on iPhone and iPad simulators for
affected changes; the manual **Native qualification** workflow reruns it. Main
calls Release without repeating qualification. Manual releases qualify first.
Required producer bytes are retained separately from bounded diagnostic uploads.

## Identity and sign-in

The release bundle ID is `com.getdieter.ios`, the TestFlight app in Dennis
Bappert's team; it does not share storage with the earlier `com.dbpprt.dieter.ios`
app, so the first install signs in again. Sessions live in device-only Keychain
items of the `com.dbpprt.dieter.ios.core` service, one per gateway origin, and
the core's state stays under `Application Support/Dieter/core`. **Sign out**
forgets the session and this device's unsent changes for the account.

Sign-in opens the gateway's sign-in page in the browser and returns to the app
through `dieter-mac://oauth/callback`, the redirect the Mac client also uses, so
gateways configured for the Mac accept it. The core begins and completes the
PKCE sign-in. Remote plaintext endpoints are rejected; Debug builds accept the
journeys' isolated loopback fixture session, release builds do not.

The app observes the workspace while it is open. It has no widgets or
notifications.

## Signing and TestFlight

See the [release pipeline guide](../../fastlane/README.md#ci-and-release-policy)
for Apple credentials and release policy.
The release targets Dennis Bappert’s team through the tracked iOS identity in
`fastlane/release-policy.json`; see the [migration runbook](../../docs/ios-testflight-account-migration.md).
Dedicated Apple Distribution credentials, separate app/Share App Store profiles,
and a team App Store Connect API key are required for distribution. The default
identities are `com.getdieter.ios`, `.share`, and
`group.com.getdieter.ios`; both profiles must include that App Group.

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

## Using the app

1. Enter your HTTPS Dieter gateway and sign in.
2. The app loads one global workspace from every enrolled, online machine
   accepted by the gateway's release policy.
3. Use **Inbox** for what needs you, is running, or is ready for review;
   **Projects** for project folders, boards and their lanes; **Chats** for
   standalone chats; and **Tools** for machines, terminals, screens, files,
   changes, schedules, usage and settings. The core routes each operation to the owning
   checkout's or conversation's machine.

Screens use the core's touch model: one finger moves the remote cursor, a tap
clicks, a long press drags, two fingers zoom and pan, and three fingers scroll.
The screen toolbar offers zoom, fit, the keyboard and a right click at the
cursor; its menu offers refresh, display, quality, frame rate, codec, clipboard
sharing and control handoff.
