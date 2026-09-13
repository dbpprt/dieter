# Dieter for iPhone and iPad

A native SwiftUI remote client for iOS 18 or later. It uses the same generated protobuf API, authenticated HTTP/2 client, certificate identity checks, and direct-TLS/relay route selection as the Mac app. The daemon continues to own tasks, transcripts, and files; the iOS app never starts a local daemon.

## Open and build

Open `apps/ios/DieterIOS.xcodeproj` in Xcode and select the **DieterIOS** scheme. The app supports iPhone and iPad. Simulator builds are signed ad hoc and need no developer account, so native Keychain access is exercised during testing. To install on a physical device, select your development team for the DieterIOSApp target and use your device as the destination.

From the repository root:

```sh
just ios doctor
just ios build
just ios build-device
just ios smoke
just ios smoke-ipad
```

`build-device` compiles the device architecture without signing; installation on a device still requires Xcode signing. Build products and simulator evidence stay under the ignored `apps/ios/.build/` directory.

The SwiftUI screens and iOS store live in `apps/mac/Sources/DieterIOS/` so they can compose the existing package-scoped DieterCore, DieterClient, and DieterAPI modules. The small Xcode app wraps the package's public root view and embeds its shared DieterIOS framework. The Mac executable is not linked into the iOS app.

## Connect to remote nodes

1. Enter your HTTPS Dieter gateway in the sign-in screen.
2. Sign in with GitHub using the native authentication session, or supply an existing gateway session token in the advanced section.
3. Select an enrolled, compatible node. The app prefers authenticated non-loopback direct routes and falls back to the gateway relay.
4. Open a project and board, create a task, or continue a conversation.

The existing `dieter-mac://oauth/callback` redirect is deliberately reused inside ASWebAuthenticationSession, with PKCE. This keeps sign-in compatible with gateways already configured for the Mac client. Tokens are kept in device-only Keychain items, separated by gateway origin. Remote plaintext endpoints are rejected. The Debug-only isolated test gateway accepts a loopback address supplied by the smoke harness; production sign-in always requires HTTPS.

## Basic workflows

- Browse remote nodes, projects, boards, tasks, and standalone chats.
- Create a draft or immediately run a task with provider, model, and reasoning selection.
- Start a draft, send follow-up messages, stop an active turn, and read live transcript updates and older messages.
- Read and edit remote text files with revision-checked saves.
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
