# Dieter for iPhone and iPad

A native SwiftUI remote client for iOS 18 or later. It uses the same generated protobuf API, authenticated HTTP/2 client, certificate identity checks, and direct-TLS/relay route selection as the Mac app. The daemon continues to own tasks, transcripts, and files; the iOS app never starts a local daemon.

## Open and build

Open `apps/ios/DieterIOS.xcodeproj` in Xcode and select the **DieterIOS** scheme. The app supports iPhone and iPad. Simulator builds are signed ad hoc and need no developer account, so native Keychain access is exercised during testing. To install on a physical device, select your development team for the DieterIOSApp target and use your device as the destination. For command-line automatic signing, explicitly supply the `DIETER_IOS_TEAM_ID` Xcode build setting (for example, `DIETER_IOS_TEAM_ID=YOUR_TEAM_ID`). No team or signing identity is discovered automatically by Dieter's setup scripts.

From the repository root:

```sh
just ios doctor
just ios build
just ios build-device
just ios signing-config
just ios smoke
just ios smoke-ipad
```

`build-device` compiles the device architecture without signing; installation on a device still requires Xcode signing. Build products and simulator evidence stay under the ignored `apps/ios/.build/` directory.

The SwiftUI screens and iOS store live in `apps/mac/Sources/DieterIOS/` so they can compose the existing package-scoped DieterCore, DieterClient, and DieterAPI modules. The small Xcode app wraps the package's public root view and embeds its shared DieterIOS framework. The Mac executable is not linked into the iOS app.

App icons are generated from `apps/ios/Artwork/AppIcon.svg`, adapted from Dieter's
existing brand SVG with an opaque square background. iOS applies the icon shape.

## Signing and TestFlight

The iOS client extends the repository's [Apple signing setup](../../docs/apple-release-signing.md#configure-ios-signing-and-testflight). Use `just release configure-apple-signing --platform ios` with explicit paths to dedicated Apple Distribution, provisioning profile, and App Store Connect team API credentials. Add `--check` for local validation without uploading secrets. `--platform all` configures both Mac and iOS credentials; the default remains `macos`.

Create the App Store Connect app record for `com.dbpprt.dieter.ios` first, or supply a matching custom bundle ID during setup. iOS uses its own signing credentials and does not use the Mac Developer ID certificates or notarization service.

The manual `ios-testflight.yml` workflow accepts a marketing `version` (default `0.1.0`) and `upload` (default `false`). It derives the build number from `run_number.run_attempt` and retains signed archive/IPA artifacts when building without upload:

```sh
gh workflow run ios-testflight.yml --repo dbpprt/dieter --ref BRANCH \
  -f version=0.1.0 -f upload=false
```

GitHub enables manual dispatch after the workflow exists on the default branch;
this becomes available when this PR is merged. Retry the latest workflow run or
dispatch a fresh run. Rerunning an older run can produce a build number below a
newer uploaded build, which Apple may reject.

The release helper limits build components to four digits for the run number and
two for the attempt. It fails before signing if a workflow exceeds those bounds.

Dispatch with `-f upload=true` to upload a new build. Pull requests and `main` pushes do not trigger an iOS upload. The local archive check and CI recipes are:

```sh
just ios archive-unsigned 0.1.0 1.1
just --yes ios testflight 0.1.0 1.1
just --yes ios testflight 0.1.0 1.1 --upload
```

`archive-unsigned` needs no credentials and checks the device archive; it does not produce an installable distribution. `testflight` is CI-only; it signs and exports, and uploads only with `--upload`. These commands do not configure tester groups. Apple processing, export-compliance information, TestFlight group assignment, and any external beta review happen separately after upload. Simulator tests and unsigned archive checks do not establish that Apple has accepted a distribution build.

## Connect to remote nodes

1. Enter your HTTPS Dieter gateway in the sign-in screen.
2. Sign in with GitHub using the native authentication session, or supply an existing gateway session token in the advanced section.
3. Select an enrolled, compatible node. The app prefers authenticated non-loopback direct routes and falls back to the gateway relay.
4. Open a project and board, create a task, or continue a conversation.

Select **Screens** in the sidebar to open the selected machine's remote desktop.
The app negotiates an independently authenticated H.264 WebRTC session over the
machine's verified direct route or gateway relay. Tap to click, move the pointer
with one finger, hold and move to drag, scroll with two fingers, and use the
keyboard and special-key menus for text and HID input. Display, quality, refresh,
frame-rate, and protocol-3 control handoff are available from the screen toolbar.
When the host supports protocol 3, Copy Remote Selection and the system Paste
button provide explicit, foreground-only text clipboard operations; Dieter does
not poll the iOS pasteboard.
On iPhone, opening Screens requests landscape automatically, then follows a
portrait remote display when its dimensions arrive. The viewer replaces the
navigation bar with floating Back and stream-settings controls; tap the live
canvas to hide or reveal those controls. iPad keeps its split-view toolbar.
The session closes when Screens is left, the machine changes, or iOS backgrounds
the app; returning establishes a new signed binding and input epoch.

The existing `dieter-mac://oauth/callback` redirect is deliberately reused inside ASWebAuthenticationSession, with PKCE. This keeps sign-in compatible with gateways already configured for the Mac client. Tokens are kept in device-only Keychain items, separated by gateway origin. Remote plaintext endpoints are rejected. The Debug-only isolated test gateway accepts a loopback address supplied by the smoke harness; production sign-in always requires HTTPS.

## Basic workflows

- Browse remote nodes, projects, boards, tasks, and standalone chats.
- Create a draft or immediately run a task with provider, model, and reasoning selection.
- Start a draft, send follow-up messages, stop an active turn, and read live transcript updates and older messages.
- Read and edit remote text files with revision-checked saves.
- View and control the selected machine through authenticated remote screen sharing.
- Suspend observation while the app is in the background and reconnect on return. Transport disconnects do not cancel agent work.

The phone uses stacked navigation; iPad uses sidebar, task list, and conversation columns. All operations remain scoped to the selected gateway, node, and workspace.

## Verification

See [implementation validation](VALIDATION.md) for observed results and current limits.

The smoke command creates its own simulator, temporary gateway, enrolled daemon, mock harness, and Git repository. It exercises real native controls and real remote RPCs without production accounts or provider credentials. It stops only those owned resources and preserves test results and screenshots. Existing simulators and operator daemons are left untouched.

Fixtures include a legacy node so compatibility rejection can be verified. Certificate tests cover exact enrolled daemon URI identity and reject the wrong daemon, wrong CA, and tampered certificates. Pure model tests cover sign-in request validation, ownership across backgrounding, stale-response isolation, and bounded transcript handling. Native application-hosted tests also exercise device-only Keychain persistence and certificate trust on iOS.

An optional, read-only check verifies that an HTTPS gateway returns its explicit authentication error for an invalid session:

```sh
python3 apps/ios/Scripts/smoke.py --https-gateway https://your-gateway.example
```

This probe never signs in or changes gateway data. The default isolated run skips it because external network access and a reachable gateway are environment dependencies. Its results are reported separately from the isolated journey.
