# Dieter for macOS

The native SwiftUI workspace for Dieter, requiring macOS 26+ on Apple Silicon.
For installation and everyday use, start with the [product tour](../../landingpage/content/docs/tour.md)
and [workspace guide](../../landingpage/content/docs/workspace.md). This page is
for building, testing, and maintaining the app.

## Build and run

Use Xcode 26.5+ and the repository's Just commands:

```sh
just mac doctor
just mac status
just mac build
just mac run
```

The canonical bundle is `apps/mac/build/Dieter.app`. `just mac run` reuses it and
refuses conflicting processes. A closed window does not quit the menu-bar app;
use `just mac quit` when you own its lifecycle. Never launch repeated copies with
`open -n`, `swift run DieterMac`, or a second scratch path.

Before rebuilding a running task-owned app, quit it normally. Do not stop an
operator app or daemon for a test. Observation can reuse an existing app.

## Build caches and signing

App builds use `apps/mac/.build/dieter-local`; unit tests use
`apps/mac/.build/dieter-tests`. Keep both caches. Product and test compiler flags
are different, so sharing their scratch directory causes avoidable rebuilds.
Do not run concurrent commands against the same cache or use `swift package clean`
as a routine fix.

Local builds use the sole available Apple Development identity when possible.
Set `DIETER_MAC_SIGNING_IDENTITY` to a certificate fingerprint when needed, or
`-` for ad-hoc signing. Ad-hoc or changed identities can require privacy grants
again. Release signing and notarization use the [Apple signing guide](../../docs/apple-release-signing.md).

## Connection and ownership

The app signs in to an HTTPS gateway using GitHub OAuth with PKCE. It retains a
Dieter session in a user-only file under
`~/Library/Application Support/com.dbpprt.dieter.mac` (`0700` directory, `0600`
file); it does not use Keychain or retain the GitHub token.

One workspace combines shared projects and their checkouts. A conversation,
file, terminal, or schedule routes to its execution owner. Routes prefer verified
direct TLS, then supported data-only WebRTC, then gateway relay. Same-Mac access
uses the discovered authenticated loopback TLS route, not raw port 4242.

`--dieter-endpoint` supplies a transient endpoint for an isolated fixture; it does
not replace the saved selection. Production remote origins require HTTPS.

## Product surfaces

- Inbox combines active cards and chats across projects in a compact, resizable
  feed with larger cards, List/Timeline modes, search, and project filters.
  Selection keeps the existing conversation, composer, and workspace detail
  pane alongside the feed. Timelines show recorded activity, not progress estimates.
- Boards and standalone chats, durable queues, labels, archives, model selection,
  plans, reasoning, and lazy full tool output.
- Conversation files, rich Markdown, code, PDFs, images, browser previews,
  terminal tabs, Processes, and Git Changes.
- Project files and schedules; shared project/chat folders and portable settings.
- Machines with routes and live telemetry; account quota details.
- Screens with H.264 and optional compatible HEVC, up to four viewers per host,
  one input controller, opt-in text/image/file clipboard, and undocked windows.
- Quick Task capture, image markup, command palette, notifications, and Dieter Island.

Screen hosting is permission-based; there is no separate host enable switch.
Screen inactivity disconnect is optional and disabled by default. Clipboard and
Android viewing are implemented. Audio is not a promised feature. The
[screen reference](../../docs/screen-sharing.md) documents negotiated limits.

Appearance includes eight designs and light/dark modes. Native Monochrome is the
default. Disable **Settings → General → Appearance → Window transparency** for
solid surfaces. macOS Reduce Transparency also disables translucency.

## Verify

```sh
just check-changed --dry-run
just check-changed
just mac test
just mac smoke core
```

`just mac smoke SUITE` supports `core`, `board`, `conversation`, `inbox`, `machine`,
`sidebar`, `terminal`, `island`, and `workspace`. `just mac smoke-suites board
inbox conversation` builds once and runs the requested suites serially;
`just mac smoke-all` runs all nine.

The driver refuses any running Dieter app and owns its exact app/gateway PIDs.
It uses a random loopback port, disposable credentials, unique state/preferences,
and a mock harness. It preserves reports, logs, and screenshots under
`apps/mac/.build/smoke/<run-id>` and verifies shutdown. Read reports and inspect
screenshots; an exit code alone does not verify the visual result.

Smoke hooks exist only in debug builds. Screen integration uses
`just mac screens-native-test` and `just mac screens-test`; real capture modes
need OS permissions and inject input only into their owned fixture window.

## Architecture and generated code

`DieterCore` holds identities, contracts, and pure policies; `DieterClient` owns
RPC, routing, and persistence. `DieterMac/Features` contains native feature models.
`AppSession` owns the menu-bar lifetime and `WindowWorkspace` owns the workspace
window. Pending commands have a durable journal separate from cached projections.

SwiftProtobuf messages and grpc-swift v2 stubs are checked in. `just proto`
regenerates authoritative schema outputs; `just mac proto-check` checks fingerprints.
Formatting excludes Generated and Vendor:

```sh
just mac format-check
just mac check
```

Historical design references live in [reference](reference/README.md). They are
not current product screenshots; see [screenshot provenance](../../docs/screenshots/README.md).
