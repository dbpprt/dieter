# Dieter for macOS

A native SwiftUI client for Dieter. It signs in to the machine-only gateway,
discovers every enrolled daemon, and automatically routes native gRPC/HTTP2
through either verified direct TLS or the bounded relay.

## What is included

- Kanban boards with native card drag/drop and ordering, draggable label chips,
  label filtering and assignment, retention,
  project context, and archives
- A board-independent global Chats workspace, with pinned and archived
  standalone conversations grouped by project, plus live server streams
- Daemon-owned terminal tabs with a real VT renderer, reconnectable scrollback,
  working-directory and shell selection, resize forwarding, and explicit close
- A machine-oriented Screens workspace with explicit host enablement, signed
  WebRTC admission, Metal-rendered view-only VP8 video, and reconnectable
  signaling over direct TLS or the gateway
- Message parts, reasoning, lazy full tool output, plans, subagents, and comments
- Project file browsing/editing and file mutations
- Schedule editing, previewing, enabling, manual runs, and occurrence history
- Server/agent settings, endpoint management, notifications, command palette,
  and a menu-bar status surface

The 22 extracted design references are in [`reference`](reference/README.md).
They are reproducibly generated from the supplied PDF by
`design/extract_reference_images.py`.

## Develop

Requirements: macOS 15+, Xcode 16+ (the current project is verified with Xcode
26), a Dieter gateway, and at least one enrolled daemon.

```sh
go run ./cmd/dieter daemon start
apps/mac/scripts/run.sh
```

For an isolated development server on another port, launch the app with
`--dieter-endpoint host:port`. That command-line selection is transient and
does not replace the user's saved endpoint.

Saved endpoints are HTTPS gateway origins. The app signs in through GitHub
using a native PKCE flow. Only the resulting Dieter session is retained in a
user-only file under `~/Library/Application Support/com.dbpprt.dieter.mac`;
the GitHub token never enters the app. The containing directory and session
file use `0700` and `0600` permissions respectively. Daemons at the same origin
share that one credential and form one combined workspace.
The sidebar keeps online and offline machines visible as presence indicators,
annotates every project with its owning hostname, and automatically routes to
that machine before opening any project surface or conversation. This directory is
built on-device from authenticated daemon responses; it is not stored by the
gateway.
For a daemon on the same Mac, the app automatically discovers and uses its
authenticated loopback TLS route; there is no separate local connection to
configure. Other daemons transparently use the encrypted gateway relay.

`Package.swift` can also be opened directly in Xcode. `scripts/build.sh`
creates an ad-hoc-signed `apps/mac/build/Dieter.app` that launches like a normal
macOS app. The script reuses SwiftPM's incremental build directory, disables the
CLI-only index store, keeps manifest and compiled-artifact caches under
`apps/mac/.build/dieter-local`, reuses SwiftPM's shared dependency download
cache, and avoids network version resolution. The dedicated scratch path keeps
Xcode, direct SwiftPM commands, and concurrent project sessions from
invalidating the app script's cache. Keep `apps/mac/.build` between builds to
retain it, or set `DIETER_SWIFT_SCRATCH_PATH` to put it elsewhere.

General settings include eight Dieter designs, with the native Monochrome
design first and selected by default. Monochrome follows the Mac's light or dark
appearance without adding a color tint. Selection is
persisted locally and updates every SwiftUI surface, terminal colors, menu-bar
surface, and the running Dock app icon. The bundle's fallback icon and
small-size product mark match Monochrome, while the 1024-pixel design icon
variants under `Resources/PaletteIcons` support runtime switching.

Public SwiftProtobuf messages and grpc-swift v2 client stubs are checked in so
ordinary builds do not compile `protoc` and both Swift generator plugins. The
build verifies their input and output fingerprints and only regenerates them
after an authoritative schema changes. Run `scripts/generate-swift-proto.sh`
directly when upgrading the generator dependencies. `scripts/sync-proto.sh`
keeps both package inputs in sync with the repository's authoritative schemas.

Navigation follows the desktop reference hierarchy: All chats is global, while
boards, Files, and Schedules live beneath each project. Creating a chat calls
`CreateChat` with an empty board ID; it never creates or appears as a board
card.

Terminals are listed across every enrolled machine and owned by the daemon for
their project, not by a Mac window or RPC. Closing or disconnecting the app cancels only its output
observer; the PTY and commands keep running until the shell exits, the user
explicitly closes the terminal, or the daemon shuts down. Reopening the app
lists the same session and resumes its sequenced output cursor. Both the daemon
and client retain a bounded 2 MiB replay buffer. Input and resize use separate
priority unary calls so output backpressure cannot make typing wait behind the
long-lived stream. A terminal may only start inside its registered project
tree, after symlink resolution.

Screens are intentionally independent of the project RPC connection. The app
selects a machine, prefers its verified direct route, falls back to the gateway
for signaling, and then establishes peer-to-peer WebRTC media. It verifies the
daemon's Ed25519 signature over the client offer, DTLS fingerprint, nonce,
session ID, and lease before accepting the answer. The current slice is
view-only, VP8-only, and limited to one session per daemon; keyboard, pointer,
clipboard, audio, file transfer, native capture helpers, and Android viewing
remain future work. The exactly pinned Google WebRTC 151.0.0 community
XCFramework is the prototype viewer dependency pending a Dieter-built,
reproducibly packaged artifact.

## Verify

```sh
swift test --disable-keychain --package-path apps/mac
apps/mac/scripts/ui-smoke.sh
apps/mac/scripts/machine-ui-smoke.sh
apps/mac/scripts/conversation-ui-smoke.sh
apps/mac/scripts/sidebar-ui-smoke.sh
apps/mac/scripts/terminal-ui-smoke.sh
apps/mac/scripts/island-ui-smoke.sh
apps/mac/scripts/accessibility-smoke.sh
```

The UI smoke test starts `dieter serve` when needed, packages and opens the app,
then delivers native mouse events to its own window to click a board, global
Chats, a standalone conversation, project Files, and project Schedules. The app captures its own SwiftUI content after each click
under `apps/mac/.build/ui-smoke`, so the flow does not need Accessibility or
Screen Recording permission.

`machine-ui-smoke.sh` is the focused authenticated machine path. It packages
the Mac app, routes it through an isolated local gateway, opens the live machine
dashboard, validates host telemetry and operation availability without invoking
a power action, and captures the rendered result under
`apps/mac/.build/machine-ui-smoke`.

`accessibility-smoke.sh` is the independent system-level path. Once the
invoking terminal has Accessibility and Screen Recording access, it drives the
packaged app through System Events and captures the board, a real chat
conversation, files, schedules, and a real card conversation.

`conversation-ui-smoke.sh` opens a real conversation that carries reasoning and
tool parts, verifies that hiding reasoning consolidates adjacent tool calls into
one collapsed group, verifies queued follow-ups remain visible beside separate
Stop and Queue composer actions, grows a model answer to verify the explicit
jump-to-latest control without viewport snapping, and toggles the composer's
reasoning switch repeatedly to prove the transcript survives it. Captures land under
`apps/mac/.build/conversation-ui-smoke`.

`sidebar-ui-smoke.sh` launches the packaged app twice against isolated local
preferences. The first launch clicks a project collapse control and records an
accepted project drop; the second launch verifies through native clicks that
both states were restored in the rendered sidebar. It attempts the drop with
in-process mouse events and uses the same accepted-drop state transition when
macOS does not admit synthetic events to its system drag manager.

`terminal-ui-smoke.sh` builds and starts a throwaway gateway on
`127.0.0.1:14244` by default, leaving the normal local ports untouched. It
creates and uses a terminal in one packaged app process, terminates that client,
then launches a second app process and verifies that the daemon-owned terminal
is still running, its prior output is replayed, and it accepts more input. It
also fills the terminal scrollback and verifies that SwiftTerm's visible caret
tracks the emulator cursor while the live viewport follows new output. The report
and screenshots land under `apps/mac/.build/terminal-ui-smoke`. Override the
alternate port with `DIETER_TERMINAL_SMOKE_PORT`.

`island-ui-smoke.sh` packages and launches the real app with isolated local
preferences, captures the compact and expanded Dieter Island plus its Settings
page, and verifies that disabling and re-enabling the saved preference removes
and restores the native panel. Captures land under
`apps/mac/.build/island-ui-smoke`.
