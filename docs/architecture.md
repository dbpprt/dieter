# Architecture

This is the contributor view of how Dieter is built. The user-facing view of
the same system, with transport limits and synchronization semantics, is the
[architecture guide](https://getdieter.com/docs/architecture/)
([source](../site/content/docs/architecture.md)). The rules every change keeps
are in [invariants.md](invariants.md); the attacker's view is in
[threat-model.md](threat-model.md).

## Components

| Component            | Code                                                      | Runs on                                | Owns                                                                                                                                       |
| -------------------- | --------------------------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `dieter` daemon      | `cmd/dieter` → `internal/daemon`                          | Apple Silicon macOS, Linux amd64/arm64 | Checkouts, conversations, harness workers, files, terminals, processes, schedules, the vault replica; a replica of shared account metadata |
| `dieter` CLI         | `cmd/dieter` → `internal/cli`                             | Same binary                            | Nothing: a client of a daemon's API                                                                                                        |
| `dieter-gateway`     | `cmd/dieter-gateway` → `internal/gateway`                 | Linux (container image)                | Account sessions, enrolled daemon identities, presence, route metadata, quota snapshots                                                    |
| Kotlin core          | `apps/kotlin/core`                                        | Every client                           | Session, routing, sync, outbox, every client rule                                                                                          |
| Android and iOS apps | `apps/kotlin/ui`, `apps/kotlin/android`, `apps/apple/ios` | Phones and tablets                     | Presentation and platform adapters                                                                                                         |
| macOS app            | `apps/apple/mac`                                          | macOS 26+                              | Presentation and platform adapters                                                                                                         |
| Native helpers       | `native/macos`, `native/linux-capture`                    | Daemon hosts                           | Screen capture, input injection, macOS privacy mode                                                                                        |
| Harness runtime      | `internal/harness/runtime` (Node)                         | Daemon hosts                           | Bridges Codex, Claude Code, Pi, Oh My Pi and DeepSeek Harness to the daemon                                                                |

One binary, `dieter`, is both daemon and CLI: `cmd/dieter` sends `serve` and
`daemon start` to `internal/daemon` and every other command to `internal/cli`,
so the CLI never links the daemon's storage or engine.

## Data flow

```text
 native client / CLI                    gateway                       daemon
 ───────────────────                    ───────                       ──────
 Kotlin core (routes) ─ verified direct TLS ───────────────────────▶ internal/api
                      ─ WebRTC data channel (TLS inside) ──────────▶   (dieter.v1 services)
                      ─ authenticated relay ──▶ internal/gateway ──▶   │
                                               (four bounded lanes)    ├─ internal/engine ── harness workers
                                                                       ├─ internal/store (DIETER_HOME)
                                                                       ├─ internal/host (terminals, exec, machine)
                                                                       └─ internal/remotedesktop ── native helpers
 daemon ◀── peer records (internal/replication) via the gateway ──▶ other daemons of the account
```

- **One API.** Every client, including the CLI, speaks the `dieter.v1` daemon API:
  one service per domain in `api/proto/dieter/v1/` (`CardService`,
  `ConversationService`, `ScreenService`, …). Loopback, direct TLS, WebRTC and relay
  carry the same calls; only transport and authentication differ.
- **Routes.** Clients prefer verified direct TLS to an advertised daemon route,
  then a data-only WebRTC channel (direct ICE or TURN) that carries an
  end-to-end daemon TLS connection, then the gateway relay. Native clients
  hedge a still-connecting WebRTC attempt with a relay connection after one
  second and keep whichever becomes healthy first. A request is sent once.
- **Relay.** The daemon keeps four authenticated tunnel connections to the
  gateway (control, replication, command, subscription), each proving
  possession of the enrolled key. The gateway forwards raw frames
  (`internal/transport/relay`) with per-lane admission and byte budgets; lanes
  change scheduling, never authorization. The gateway does not decode or store
  Dieter payloads, but it can see relayed bytes.
- **Watches.** Clients observe each online machine's `WatchChanges` stream and
  resume from the last delivered cursor. Recovery never replays mutations,
  process starts or stdin.
- **Execution.** `internal/engine` admits turns under a per-conversation
  runtime lease, starts harness workers through the Node runtime, and records
  transcripts and status in the store. The scheduler
  (`internal/engine/scheduler`) creates deterministic cards from authoritative
  occurrence records and runs only inside `dieter serve`.

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
  signature that binds the account, field, causal clock and exact value to an
  enrolled daemon certificate; third-party peers can relay but not forge them.
- `internal/replication/peersync` exchanges records with each peer through the
  gateway, at most four exchanges at a time, with independent per-peer backoff.
  Checkpoints advance only after durable merges.
- The store keeps peer records in its own write-ahead views
  (`internal/store/peer*.go`, `shared*.go`); a write acknowledges local
  durability, not a quorum.
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
                         peer), composed in service.go; errors.go is the one status mapper
  engine/                turn engine: admission, leases, harness turns, queues
  engine/scheduler/      schedules and occurrence history
  harness/               harness adapters, discovery, runner; catalog/ (embedded
                         harnesses.yaml); runtime/ (Node bridge, pinned with package-lock)
  store/                 central storage: lock, schema, cards, conversations, boards,
                         projects, schedules, peer views; vaults/, daemonstate/
  replication/           crdt/ (bounded registers, provenance), schema/ (record kinds),
                         peersync/ (daemon-to-daemon exchange)
  link/                  gateway tunnel client, enrollment identity (sole writer),
                         direct TLS route, possession-proof connections
  gateway/               auth (GitHub OAuth, enrollment, native sessions), hub,
                         relay, quota snapshots, SQLite storage, ingress limits
  transport/             relay/ (lane policy, raw codec, quota protocol),
                         controlrtc/ (TLS/gRPC over a WebRTC data channel)
  security/              trust/ (signed claims), linkauth/ (daemon key proofs),
                         localauth/ (loopback API token), vault/ (vault cryptography)
  git/                   exec, status, SCM; changeset/, operations/, workspace/
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
does not import the API, engine, daemon or CLI; the gateway imports no
daemon-side package. `forbidigo` keeps `os.Getenv` inside
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
  IDs, and the `ClientApi` command/slice contract. `:core:apple` exports it to
  Swift as the `DieterCore` framework.
- **Shared mobile UI** (`apps/kotlin/ui`). One Compose Multiplatform UI for
  Android and iOS. It sends `client.proto` commands and observes slices; it adds
  no rules.
- **Shells.** Android (`apps/kotlin/android`) and iOS (`apps/apple/ios`) supply
  credentials, transport, attachments, terminals (Termux, SwiftTerm) and screen
  media (WebRTC, GPU/Metal renderers).
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
