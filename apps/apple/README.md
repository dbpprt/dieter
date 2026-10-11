# Dieter Apple clients

The native macOS app (SwiftUI, macOS 26+ on Apple Silicon) and the iOS app (a
UIKit shell hosting the shared Compose UI, iOS 18+). Both are presentation-only
clients of the shared Kotlin core in [`apps/kotlin`](../kotlin/README.md), which
they link as the `DieterCore` framework; the core owns the session, routing,
sync, the outbox, every feature surface and every rule. The daemon owns tasks,
transcripts, and files; neither app starts a local daemon.

## Layout

| Path                                | Contents                                                                                                                                                                                                                                                                                                    |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Frameworks/DieterCore.xcframework` | The Kotlin core, assembled from `apps/kotlin` (not tracked): the macOS slice from `:core:apple`, the iOS slices from `:ui`, which exports the same façade.                                                                                                                                                  |
| `DieterKit/`                        | The Swift package both apps share (macOS 26, iOS 18): `DieterCore` and `WebRTC` binary targets; `DieterAPI` (generated SwiftProtobuf messages); `DieterAPIGRPC` (generated grpc-swift clients, used only by the Mac tests); `DieterTransport`; `DieterPlatform`; and `DieterPlatformTests`.                 |
| `mac/`                              | The Mac package: the `DieterMacKit` library (all presentation, plus the Mac's adapters over the core in `Sources/DieterMacKit/Core`), the thin `DieterMac` executable, and `DieterMacTests`. `Resources/` holds the bundle inputs (Info.plist, icons); `MarkdownPreview/` the preview's JavaScript sources. |
| `ios/`                              | `Dieter.xcodeproj` (the `Dieter` app and its `DieterShare` extension), `App/`, `Share/`, the generated `Identity.xcconfig`, and `Host/`, the iOS-only Swift package whose `DieterIOS` library hosts the Compose UI.                                                                                         |
| `scripts/format-swift.sh`           | Checks (or, with `--write`, rewrites) the formatting of the hand-written Swift with `.swift-format`.                                                                                                                                                                                                        |

Related packages outside this directory: [`native/macos`](../../native/macos)
(the daemon's capture and privacy helpers, plus the `RemoteDesktopProtocol` and
`DieterIdentity` targets the apps use) and [`third_party`](../../third_party)
(vendored `grpc-swift-nio-transport`, `swift-markdown-engine` and
`HighlighterSwift`, each with a `PATCHES.md`).

### DieterKit

- `DieterTransport`: the native transport (the WebRTC control channel, daemon
  certificate pinning, and gRPC resolver targets). It re-exports
  `RemoteDesktopProtocol` (the screen key map and clipboard content the
  capture helper also uses).
- `DieterPlatform`: the apps' side of the core: the RPC bridge (`CoreRpcBridge`,
  grpc-swift), the platform services, the Keychain store
  (`CoreKeychainSecureStore`), the control channels, and the WebRTC screen
  engine, which draws through each app's renderer.
- `DieterAPI`, `DieterAPIGRPC` and `DieterClientAPI` are generated from
  `api/proto` by `just generate` (buf with the swift-protobuf and
  grpc-swift-protobuf plugins from this package's resolved versions) and checked
  in, so a fresh clone builds without protobuf tooling.

### macOS app

`DieterMacKit/Features` contains native presentation models that observe core
slices and send commands; views call `SharedRules` for rules they need while
rendering. Add or change a rule in the core, as
[its README](../kotlin/README.md#adding-a-rule) describes, not in Swift. The
editor buffer, SwiftTerm, Markdown rendering, the transcript scroll controller,
and the VideoToolbox and Metal screen renderer stay native. `AppSession` owns
the menu-bar lifetime and `WindowWorkspace` owns the workspace window.

The app signs in to an HTTPS gateway using GitHub OAuth with PKCE and the
`dieter-mac://oauth/callback` redirect. It keeps its Dieter session in a
user-only file under `~/Library/Application Support/com.getdieter.mac` (`0700`
directory, `0600` file); it does not use Keychain or retain the GitHub token.
Routes prefer verified direct TLS, then data-only WebRTC, then the gateway
relay; same-Mac access uses the discovered authenticated loopback TLS route.
`--dieter-endpoint` supplies a transient endpoint for an isolated fixture.

The debug build includes the in-app Maestro flow runner
(`Sources/DieterMacKit/Testing`, compiled with `DIETER_E2E`), which runs the
[Mac flows](../../tests/maestro/README.md) in-process
(`--e2e-activation-ready PIDFILE --e2e-flow PLAN.json --e2e-output DIR`).

### iOS app

- `App/DieterApp.swift`: the app entry. It presents the UIKit shell, forwards
  the sign-in callback URL and reports foreground state to the core.
- `Share/`: the Share extension. It asks whether shared items start a new task
  or go to an existing task or chat, stages them in the App Group, and the app
  delivers them when it next becomes active.
- `Host/Sources/DieterIOS`: `ComposeHost.swift` configures the core and drives a
  `UITabBarController` with one navigation stack per tab (a sidebar and split
  view on iPad) from the shared navigation state; each route is a Compose view
  controller, while bar buttons, menus, sheets, alerts and toasts are native.
  `NativeViews.swift` supplies the photo and document pickers, Quick Look
  previews, SwiftTerm terminals, and the Metal screen view with touch input.
  `ShareInbox.swift` reads the Share extension's staged request.

`Identity.xcconfig` is generated from
[`config/identity.json`](../../config/identity.json) by `go run ./tools/identity`
and is the base configuration of every build configuration:
`DIETER_IOS_BUNDLE_ID` (`com.getdieter.ios`), `DIETER_IOS_SHARE_BUNDLE_ID` and
`DIETER_IOS_APP_GROUP` (both derived from the bundle ID, so overriding
`DIETER_IOS_BUNDLE_ID`, as the E2E app `com.getdieter.ios.e2e` does, keeps them
consistent), `DIETER_IOS_TEAM_ID`, and `DIETER_IOS_URL_SCHEME`. Sign-in returns
through `dieter-ios://oauth/callback`; the gateway must list that redirect.
Sessions live in device-only Keychain items of the `com.getdieter.ios.core`
service, one per gateway origin, and the core's state under
`Application Support/Dieter/core`. Debug builds accept the flows' isolated
loopback fixture session; release builds do not. Signing settings
(`DIETER_IOS_SIGN_IDENTITY`, `DIETER_IOS_SIGN_STYLE`,
`DIETER_IOS_PROFILE_SPECIFIER`, `DIETER_IOS_SHARE_PROFILE_SPECIFIER`) and
`DIETER_RELEASE_VERSION` are passed by the release pipeline.

## Build and test from a fresh clone

You need Xcode 26.5+ (with an iOS simulator runtime for iOS), Java 21 and the
Android SDK for the Kotlin build (see [apps/kotlin](../kotlin/README.md)), and
Node for the Markdown preview. From the repository root:

```sh
# 1. The DieterCore framework (debug). Add the iOS slices you build for.
apps/kotlin/gradlew -p apps/kotlin :core:apple:linkDebugFrameworkMacosArm64 \
    :ui:linkDebugFrameworkIosSimulatorArm64
rm -rf apps/apple/Frameworks/DieterCore.xcframework
xcodebuild -create-xcframework \
    -framework apps/kotlin/core/apple/build/bin/macosArm64/debugFramework/DieterCore.framework \
    -framework apps/kotlin/ui/build/bin/iosSimulatorArm64/debugFramework/DieterCore.framework \
    -output apps/apple/Frameworks/DieterCore.xcframework
#    (iOS device: :ui:linkDebugFrameworkIosArm64 and
#     -framework apps/kotlin/ui/build/bin/iosArm64/debugFramework/DieterCore.framework)

# 2. Shared Swift layer.
swift test --package-path apps/apple/DieterKit

# 3. macOS app: the preview bundle, the app, and its tests.
apps/apple/mac/scripts/build-markdown-preview.sh
swift build --package-path apps/apple/mac --product DieterMac
swift test --package-path apps/apple/mac --no-parallel

# 4. iOS app (simulator, unsigned). SwiftTerm ships a build-tool plugin.
xcodebuild -project apps/apple/ios/Dieter.xcodeproj -scheme Dieter \
    -destination 'generic/platform=iOS Simulator' -skipPackagePluginValidation \
    build CODE_SIGNING_ALLOWED=NO

# 5. The daemon's macOS helpers (see native/macos).
swift test --package-path native/macos
```

The core has no x86_64 simulator slice, so the project excludes x86_64 for the
simulator SDK (`EXCLUDED_ARCHS`).

`swift build` produces the `DieterMac` executable and its resource bundles
(`DieterMac_DieterMacKit.bundle`, `Highlighter_Highlighter.bundle`) and
`WebRTC.framework` under `apps/apple/mac/.build/<configuration>`; the release
pipeline assembles `Dieter.app` from them with `mac/Resources` and checks it
with `mac/scripts/verify-bundle.sh`. Never launch repeated app copies or touch an
operator's running app or daemon while testing.

`DieterMacTests` uses `--no-parallel`: several suites own process-wide state. A
test that stops the main run loop can end the run early with exit status 0, so
check the reported test count. Fixture-backed suites
(`SharedCoreIntegrationTests`, `AppSessionCoreIntegrationTests`, screen tests)
skip unless the isolated fixture environment (`DIETER_ISOLATED_*`,
`DIETER_TEST_*`) is set.

Regenerate the Swift API after a schema change (it uses grpc-swift-protobuf's
SwiftPM plugin and `protoc`):

```sh
apps/apple/DieterKit/scripts/sync-proto.sh
```

On a busy host, limit compiler concurrency with `swift build --jobs 2`. Keep
separate scratch paths for builds and tests (`--scratch-path`) if you switch
between them often; their compiler flags differ.
