# Nauclio for macOS

A native SwiftUI client for Nauclio. It signs in to the machine-only gateway,
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
26), a Nauclio gateway, and at least one enrolled daemon.

```sh
go run ./cmd/nauclio daemon start
apps/mac/scripts/run.sh
```

For an isolated development server on another port, launch the app with
`--nauclio-endpoint host:port`. That command-line selection is transient and
does not replace the user's saved endpoint.

Saved endpoints are HTTPS gateway origins. The app signs in through GitHub
using a native PKCE flow. Only the resulting Nauclio session is retained in the
macOS Keychain; the GitHub token never enters the app. Daemons at the same
origin share that one credential and form one combined workspace.
The sidebar keeps online and offline machines visible as presence indicators,
annotates every project with its owning hostname, and automatically routes to
that machine before opening any project surface or conversation. This directory is
built on-device from authenticated daemon responses; it is not stored by the
gateway.
For a daemon on the same Mac, the app automatically discovers and uses its
authenticated loopback TLS route; there is no separate local connection to
configure. Other daemons transparently use the encrypted gateway relay.

`Package.swift` can also be opened directly in Xcode. `scripts/build.sh`
creates an ad-hoc-signed `apps/mac/build/Nauclio.app` that launches like a normal
macOS app. Its explicit development-only designated requirement remains stable
across rebuilt binaries so one Keychain approval can be retained without a
local signing certificate. Because an ad-hoc binary can claim the same bundle
identifier, this requirement is a development convenience rather than a
security boundary; release packaging replaces it with the certificate-backed
signature. The script reuses SwiftPM's incremental build directory, disables the
CLI-only index store, keeps manifest and compiled-artifact caches under
`apps/mac/.build/nauclio-local`, reuses SwiftPM's shared dependency download
cache, and avoids network version resolution. The dedicated scratch path keeps
Xcode, direct SwiftPM commands, and concurrent project sessions from
invalidating the app script's cache. Keep `apps/mac/.build` between builds to
retain it, or set `NAUCLIO_SWIFT_SCRATCH_PATH` to put it elsewhere.

The build packages the canonical app icon and small-size product mark directly
from [`assets/brand`](../../assets/brand/README.md). The SwiftUI theme implements
the same dark semantic palette; platform-specific copies are intentionally not
kept in this app directory.

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

Terminals are global to the selected machine and owned by its daemon, not by a
Mac window or RPC. Closing or disconnecting the app cancels only its output
observer; the PTY and commands keep running until the shell exits, the user
explicitly closes the terminal, or the daemon shuts down. Reopening the app
lists the same session and resumes its sequenced output cursor. Both the daemon
and client retain a bounded 2 MiB replay buffer. Input and resize use separate
priority unary calls so output backpressure cannot make typing wait behind the
long-lived stream. A terminal may only start inside its registered project
tree, after symlink resolution.

## Verify

```sh
swift test --package-path apps/mac
apps/mac/scripts/ui-smoke.sh
apps/mac/scripts/conversation-ui-smoke.sh
apps/mac/scripts/sidebar-ui-smoke.sh
apps/mac/scripts/terminal-ui-smoke.sh
apps/mac/scripts/accessibility-smoke.sh
```

The UI smoke test starts `nauclio serve` when needed, packages and opens the app,
then delivers native mouse events to its own window to click a board, global
Chats, a standalone conversation, project Files, and project Schedules. The app captures its own SwiftUI content after each click
under `apps/mac/.build/ui-smoke`, so the flow does not need Accessibility or
Screen Recording permission.

`accessibility-smoke.sh` is the independent system-level path. Once the
invoking terminal has Accessibility and Screen Recording access, it drives the
packaged app through System Events and captures the board, a real chat
conversation, files, schedules, and a real card conversation.

`conversation-ui-smoke.sh` opens a real conversation that carries reasoning and
tool parts, verifies that hiding reasoning consolidates adjacent tool calls into
one collapsed group, and toggles the composer's reasoning switch repeatedly to
prove the transcript survives it. Captures land under
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
is still running, its prior output is replayed, and it accepts more input. The
report and screenshots land under `apps/mac/.build/terminal-ui-smoke`. Override
the alternate port with `NAUCLIO_TERMINAL_SMOKE_PORT`.
