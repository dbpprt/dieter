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

The 41 view-level design references are indexed in
[`reference`](reference/README.md). They are reproducibly and losslessly
extracted from the source design PDF by `design/extract_reference_images.py`;
the source PDF itself is not checked in.

## Develop

Requirements: macOS 15+, Xcode 16+ (the current project is verified with Xcode
26), a Dieter gateway, and at least one enrolled daemon.

```sh
dieter daemon start
just mac run
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

`Package.swift` can also be opened directly in Xcode. `just mac build`
creates an ad-hoc-signed `apps/mac/build/Dieter.app` that launches like a normal
macOS app. The underlying packaging script reuses SwiftPM's incremental build directory, disables the
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
after an authoritative schema changes. Run `just mac proto-check` to verify the
checked-in sources and `just mac proto-generate` to sync both package inputs
with the repository's authoritative schemas and regenerate their clients.

Navigation follows the desktop reference hierarchy: All chats is global, while
boards, Files, and Schedules live beneath each project. Creating a chat calls
`CreateChat` with an empty board ID; it never creates or appears as a board
card.

Project setup is routed to the selected daemon host. The native form can open
an existing Git working tree, including a linked worktree whose `.git` is a
file, or create a directory and initialize a new Git repository there. Its
directory browser reads the daemon's filesystem through `ListDirectories`; it
never substitutes a local macOS file panel for a remote project path.

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
remain future work. The Google WebRTC M151 community XCFramework is pinned
directly to the byte-verified `151.0.1` release asset. This avoids the upstream
package manifest's removed `151.0.0` asset while a Dieter-built, reproducibly
packaged artifact remains future work.

## Verify

```sh
just mac test
just mac smoke core
just mac smoke-all
```

`just mac smoke <suite>` accepts `core`, `board`, `conversation`, `machine`,
`sidebar`, `terminal`, `island`, or `workspace`. One Swift driver owns the exact
packaged-app and isolated-gateway PIDs, asks the gateway for an ephemeral
loopback port, uses unique state and preferences roots, and refuses to run
beside an existing Dieter app. Multi-phase sidebar and terminal checks wait for
the first app process to quit before launching the second. Reports, logs, and
screenshots are retained under `apps/mac/.build/smoke/<run-id>`.

The app-side smoke hooks compile only in debug builds. A release build has no
smoke command-line interface. Remove generated smoke evidence with the
confirmed `just mac clean-smoke` recipe; it never removes the canonical SwiftPM
compilation cache.
