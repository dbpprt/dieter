# Architecture

This is the contributor view of how Dieter is built. The user-facing view of
the same system, with transport limits and synchronization semantics, is the
[architecture guide](https://getdieter.com/docs/architecture/)
([source](../site/content/docs/architecture.md)). The rules every change keeps
are in [invariants.md](invariants.md); the attacker's view is in
[threat-model.md](threat-model.md).

## Components

| Component            | Code                                                      | Runs on                                | Owns                                                                                                                                                   |
| -------------------- | --------------------------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `dieter` daemon      | `cmd/dieter` → `internal/daemon`                          | Apple Silicon macOS, Linux amd64/arm64 | Checkouts, conversations, harness workers, files, terminals, processes, schedules, agent mail, the vault replica; a replica of shared account metadata |
| `dieter` CLI         | `cmd/dieter` → `internal/cli`                             | Same binary                            | Nothing: a client of a daemon's API                                                                                                                    |
| `dieter-gateway`     | `cmd/dieter-gateway` → `internal/gateway`                 | Linux (container image)                | Account sessions, enrolled daemon identities, presence, route metadata, the signed device roster, pairing requests, quota snapshots                    |
| Kotlin core          | `apps/kotlin/core`                                        | Every client                           | Session, device trust, routing, sync, outbox, every client rule                                                                                        |
| Android and iOS apps | `apps/kotlin/ui`, `apps/kotlin/android`, `apps/apple/ios` | Phones and tablets                     | Presentation and platform adapters                                                                                                                     |
| macOS app            | `apps/apple/mac`                                          | macOS 26+                              | Presentation and platform adapters                                                                                                                     |
| Native helpers       | `native/macos`, `native/linux-capture`                    | Daemon hosts                           | Screen capture, input injection, macOS privacy mode                                                                                                    |
| Harness runtime      | `internal/harness/runtime` (Node)                         | Daemon hosts                           | Bridges Codex, Claude Code, Pi, Oh My Pi and DeepSeek Harness to the daemon                                                                            |

One binary, `dieter`, is both daemon and CLI: `cmd/dieter` sends `serve` and
`daemon start` to `internal/daemon` and every other command to `internal/cli`,
so the CLI never links the daemon's storage or engine.

## Data flow

```text
 native client / CLI                    gateway                       daemon
 ───────────────────                    ───────                       ──────
 Kotlin core (routes) ═ mutual TLS, direct candidate ══════════════▶ DirectServer (internal/link)
                      ═ mutual TLS, WebRTC data channel ═════════════▶ │
                      ═ mutual TLS, relay tunnel ▶ internal/gateway ═▶ │ opaque frames over
                                                                       │ four bounded lanes
                                                                       ▼
                                                                     internal/api (dieter.v1 services)
                                                                       ├─ internal/engine ── harness workers
                                                                       ├─ internal/store (DIETER_HOME)
                                                                       ├─ internal/host (terminals, exec, machine)
                                                                       └─ internal/remotedesktop ── native helpers
 daemon ◀══ peer records (internal/replication), same carriers ══▶ other daemons of the account
```

- **One API.** Every client, including the CLI, speaks the `dieter.v1` daemon API:
  one service per domain in `api/proto/dieter/v1/` (`CardService`,
  `ConversationService`, `ScreenService`, …). Loopback, direct TLS, WebRTC and relay
  carry the same calls. Every remote carrier ends at the daemon's
  `DirectServer` (`internal/link/direct.go`), which authenticates the device and
  forwards the call to the loopback API.
- **Routes.** Clients prefer verified direct TLS to an advertised daemon route,
  then a data-only WebRTC channel (direct ICE or TURN), then a gateway relay
  tunnel. All three carry the same mutual TLS 1.3 connection, pinned on both
  sides to keys in the account's device roster; WebRTC signaling itself runs
  over a relay tunnel. Native clients hedge a still-connecting WebRTC attempt
  with a relay connection after one second and keep whichever becomes healthy
  first. A request is sent once.
- **Relay.** The daemon keeps four authenticated link connections to the
  gateway (control, replication, command, subscription), each proving
  possession of the enrolled key. A client opens a tunnel with
  `RelayService.OpenTunnel`, naming the daemon and a lane; the gateway asks the
  daemon on that lane's link, the daemon dials its own loopback TLS listener,
  and the gateway splices frames of at most 64 KiB with end-to-end credits (8
  frames per direction). It never parses them. Per daemon and lane at most
  `relay.TunnelLimit` tunnels are open (control 4, replication 8, command 32,
  subscription 32), inside per-lane byte budgets; lanes change scheduling,
  never authorization. Apps and the CLI use the command lane, peer sync the
  replication lane.
- **Device trust.** Each daemon pins the account's device roster in
  `DIETER_HOME/daemon/roster.pb` (`internal/link/trust.go`, its only writer),
  follows it with `WatchDeviceRoster`, and asks to join through a pairing
  request while it is new. Apps keep theirs in the Kotlin core. The gateway
  stores roster entries and pairing requests and verifies appends, but every
  entry is signed by a member. After a client opens a connection, and in every
  peer-sync round, both sides compare roster heads through `TrustService`, so
  an entry the gateway withholds still propagates.
- **Watches.** Clients observe each online machine's `WatchChanges` stream and
  resume from the last delivered cursor. Recovery never replays mutations,
  process starts or stdin.
- **Execution.** `internal/engine` admits turns under a per-conversation
  runtime lease, starts harness workers through the Node runtime, and records
  transcripts and status in the store. The scheduler
  (`internal/engine/scheduler`) creates deterministic cards from authoritative
  occurrence records and runs only inside `dieter serve`.
- **Harness runtime.** The daemon embeds the runtime sources and installs them
  once per content digest under `DIETER_HOME/runtime/harness/<digest>`, with the
  managed Bun under `runtime/tools/bun`. A release daemon pins the SHA-256 of its
  platform's prebuilt archive (`buildinfo.HarnessRuntimeSHA256`), downloads it
  from its own release, checks its manifest against the embedded runtime digest
  and lockfile, and extracts it; a source build runs `npm ci` instead. The
  runtime's `package-lock.json` pins the agent CLIs (the Claude Agent SDK with
  its Claude Code executable, Codex, OMP) and every package their AI SDK bridges
  import. The Claude, Codex and OMP bridge bootstraps (`runtime-packages.mjs`)
  link those packages into the shared bootstrap directory and check each CLI's
  version and platform package instead of running npm; only DSH still installs
  from npm. An active turn keeps its runtime digest across restarts.

## Shared metadata and peer replication

Projects, boards, labels, card placement and portable settings are shared by
every daemon of an account. Conversations, schedules, files and execution stay
with their owner machine.

- `internal/replication/crdt` implements bounded, leaderless multi-value
  registers with causal clocks. No wall clock decides an edit; concurrent edits
  become siblings that a domain rule or a person resolves. Hard limits cap
  records, actors, versions and value, state and page sizes.
- `internal/replication/schema` declares which fields each record kind has and
  validates incoming values. Owner-scoped fields carry an owner provenance
  signature that binds the account, field, causal clock and exact value to the
  owner daemon's key in the device roster; third-party peers can relay but not
  forge them.
- `internal/replication/peersync` exchanges records with each peer that is a
  daemon in the pinned roster, over the same mutual TLS carriers as clients (a
  direct candidate, WebRTC, or a relay tunnel on the replication lane), at most
  four exchanges at a time, with independent per-peer backoff. Each round also
  compares roster heads. Checkpoints advance only after durable merges.
- The store keeps peer records in its own write-ahead views
  (`internal/store/replica`); a write acknowledges local durability, not a
  quorum.
- Vault items replicate through the same records as AES-256-GCM ciphertext;
  keys are sealed to each member's hybrid ML-KEM-768/X25519 key
  (`internal/security/vault`, `internal/store/vaults`).

## Go packages

```text
cmd/dieter               daemon.Handles(args) ? daemon.Main : cli.Main
cmd/dieter-gateway       gateway server

internal/
  daemon/                composition root: Config, Run, Services (engine, scheduler,
                         terminals, remote exec, remote desktop, machine, API), service log
  api/                   dieter.v1 services: one handler type per service (machine, state,
                         settings, projects, boards, cards, conversations, git, files,
                         terminals, executions, screens, control, schedules, vault, kv,
                         peer, trust, channels, mail), composed in service.go; errors.go
                         is the one status mapper
  engine/                turn engine: admission, leases, harness turns, queues
  engine/scheduler/      schedules and occurrence history
  harness/               harness adapters, discovery, runner; catalog/ (embedded
                         harnesses.yaml); runtime/ (Node bridge, pinned with package-lock)
  store/                 central storage: a composition root (Store, New, Ensure, Recover,
                         Close) over aggregates: home/ (DIETER_HOME, writer lock, schema,
                         change counter), replica/ (peer replica), leases/, kv/, settings/,
                         commands/, channels/, mail/ (agent mail), kanban/ (projects,
                         checkouts, boards, cards, chats), workspaces/, conversations/,
                         schedules/; vaults/, daemonstate/
  replication/           crdt/ (bounded registers, provenance), schema/ (record kinds),
                         peersync/ (daemon-to-daemon exchange)
  link/                  gateway link client, enrollment identity and device trust
                         (sole writer of both), DirectServer and roster-pinned TLS
                         (tls.go, dial.go), relay tunnels (tunnel.go), possession proofs
  gateway/               auth (GitHub OAuth, enrollment, native sessions), hub,
                         relay tunnels, device roster and pairing requests, quota
                         snapshots, SQLite storage, ingress limits
  transport/             relay/ (lane and tunnel bounds, raw codec, quota protocol),
                         controlrtc/ (TLS/gRPC over a WebRTC data channel)
  security/              roster/ (device roster, pairing, recovery key), codes/ (typed
                         Crockford codes), trust/ (signed claims), linkauth/ (daemon
                         key proofs), localauth/ (loopback API token), vault/ (vault
                         cryptography)
  git/                   exec, status, SCM; changeset/, operations/, workspace/
  filetransfer/          bounded rooted file I/O, checksums and the pure one-way sync planner
  host/filetransfer/     durable chunked upload sessions, quotas and commit receipts
  host/                  machine/ (telemetry, power, updates), terminal/, remoteexec/,
                         serviceruntime/ (signed executables at stable paths)
  remotedesktop/         screen sessions, WebRTC media, native helper IPC
  providerquota/         provider quota collectors (daemon side)
  cli/                   client commands only; commands.go is the command table that
                         drives dispatch, help, the help contract and tools/clidocs
  model/, prompt/        shared domain types, prompt templates
  platform/              config/ (the only reader of the environment), fsx/ (atomic
                         write + lock), fault/ (error kinds), version/ (floors),
                         buildinfo/ (version and generated identity)
  testkit/               test fixtures; topology/ builds in-process gateway + daemons
  gen/                   generated protobuf and Connect code (committed)
```

`.golangci.yml` enforces the main boundaries with depguard: the CLI does not
import the store, API, engine, daemon, harness, git or host packages; the store
does not import the API, engine, daemon or CLI, and its aggregates import only
the layers below them (home; then replica, leases, settings, commands, channels
and mail; then kv and kanban; then workspaces, conversations and schedules,
which never import each other); the gateway imports no daemon-side package. `forbidigo` keeps `os.Getenv` inside
`internal/platform/config`. See [adr/0001](adr/0001-foundation-refactor.md) for
the parts of the target layout that are deferred.

Errors carry a kind from `internal/platform/fault`. `internal/api/errors.go`
maps kinds and well-known errors to RPC codes in one place; an error without a
kind is `Internal`, which the Kotlin core treats as transient.

## Clients

```text
api/proto ─▶ :core:model (Wire) ─▶ :core:runtime (all client logic, OkHttp transport on JVM/Android)
                                        │
             ┌──────────────────────────┼─────────────────────────────┐
             ▼                          ▼                             ▼
   :android (Material shell)    :ui (Compose Multiplatform)    :core:apple (Swift façade)
             └────── uses ──────▶ shared screens ◀── iOS host       │  DieterCore.framework
                                                  (apps/apple/ios)   ▼
                                               DieterKit (DieterAPI, DieterTransport,
                                               DieterPlatform) ─▶ macOS app (SwiftUI)
```

- **Kotlin core** (`apps/kotlin/core`). `:core:model` holds Wire models generated
  from `api/proto`, the core's on-device records and the client contract
  (`dieter/client/v1/client.proto`). `:core:runtime` holds every rule: one
  package per domain, `AccountSync` (one replica per machine, joined like the
  peer store), `MachineChoice` routing, a journaled outbox with deterministic
  IDs, and the `ClientApi` command/slice contract. Its `trust` package verifies
  the device roster (the Go rules, checked against the same golden vectors),
  pairs the device, and keeps it trusted, pending, removed or in conflict;
  `routing` reaches a machine only while the device is trusted, with TLS pinned
  to the machine's roster key. `:core:apple` exports it to Swift as the
  `DieterCore` framework.
- **Shared mobile UI** (`apps/kotlin/ui`). One Compose Multiplatform UI for
  Android and iOS. It sends `client.proto` commands and observes slices; it adds
  no rules.
- **Shells.** Android (`apps/kotlin/android`) and iOS (`apps/apple/ios`) supply
  credentials, the device key (Android Keystore, Secure Enclave), transport
  (pinned TLS and relay tunnels), attachments, terminals (Termux, SwiftTerm) and
  screen media (WebRTC, GPU/Metal renderers).
- **macOS** (`apps/apple/mac`). SwiftUI presentation over the same core through
  `DieterKit` (`apps/apple/DieterKit`): generated Swift API types, the native
  transport and the platform side of the core. Native rendering (editor,
  transcript scrolling, Markdown, screens) stays in Swift.

Per-component details: [apps/kotlin](../apps/kotlin/README.md),
[apps/apple](../apps/apple/README.md), [tests/maestro](../tests/maestro/README.md),
[deploy/gateway](../deploy/gateway/README.md).

## Generated and pinned inputs

| Source                     | Generated into                                                                                 | Command                                                        |
| -------------------------- | ---------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| `api/proto`                | `internal/gen` (Go + Connect), `apps/apple/DieterKit` (Swift, committed), Kotlin at build time | `just generate`                                                |
| `config/identity.json`     | Go, Kotlin, Swift, Xcode and installer constants                                               | `just generate`                                                |
| `internal/cli/commands.go` | the [CLI reference](https://getdieter.com/docs/cli-reference/)                                 | `go run ./tools/clidocs -o site/content/docs/reference/cli.md` |
| `internal/platform/config` | the [environment reference](reference/environment.md)                                          | maintained by hand                                             |

CI fails when committed generated files drift from their sources.
