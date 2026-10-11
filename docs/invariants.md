# Invariants

These rules are binding for every change, whether a person or an agent makes
it. A change that needs to break one starts with an [ADR](adr/) that replaces
the rule, not with an exception in code. Where a test or lint rule enforces an
invariant, it is named; keep it passing rather than weakening it.

## Product shape

- Dieter is a local Go daemon (`dieter`, also the CLI), a machine-only Go
  gateway (`dieter-gateway`), and native macOS, iOS and Android clients. Every
  card and standalone chat is one durable local harness conversation.
- Dieter has no web UI. The public gateway root is intentionally 404; only
  OAuth completion pages, health, gateway gRPC and tunneled Dieter gRPC exist.
- All three native clients are presentation-only clients of the shared Kotlin
  core (`apps/kotlin/core`). Rules belong in the core, never in an app or the
  shared Compose UI.

## Releases and compatibility

- Ship one canonical SemVer release across gateway, daemon/CLI and native
  clients. The gateway publishes minimum client and daemon releases and rejects
  callers below those floors (`internal/platform/version`,
  `internal/api/compatibility.go`, `internal/gateway/compatibility.go`).
- Do not add historical API branches or development-store migrations. Keep only
  genuine subsystem revisions, such as remote-desktop framing and persisted
  projection formats. A breaking protocol change raises the floors instead.
- Release checksums are signed only by
  `.github/workflows/release.yml@refs/heads/main`. Installed updaters verify that
  exact identity (`internal/platform/buildinfo`, generated from
  [`config/identity.json`](../config/identity.json)); renaming the workflow is a
  protocol break that needs a floor bump.

## Data and storage

- Store all Dieter data centrally under `DIETER_HOME` (default `~/.dieter`).
  Never write Dieter metadata into project repositories.
- Use atomic writes and the central cross-process lock for every mutation
  (`internal/platform/fsx`: `WriteFile`, `LockHome`). The daemon identity file
  has exactly one writer (`internal/link`), which holds the same lock.
- Dieter owns transcripts, runtime status, harness/model configuration, queues,
  session resume data, board labels, card label assignments, fixed workflow
  positions, schedules, occurrence history and admission settings.
- Normal operation never edits central storage directly; it goes through the
  daemon API.

## Projects, replication and ownership

- Every logical project has a Dieter-generated shared identity and may have
  several checkouts across machines. Each checkout references one existing Git
  working tree by canonical path on its immutable owner daemon.
- Shared project, board, label, placement and portable settings records are
  replicated within the account by the leaderless peer store
  (`internal/replication`). No machine owns a project.
- Conversations and schedules retain one execution owner and checkout.
  Replication never moves a running agent or copies a working tree.
- Every card has a Dieter-generated ID and exactly one durable conversation.
- Peer records keep their hard limits (`internal/replication/crdt`: records,
  actors, versions, value, state and page sizes) and their owner provenance
  signatures.

## Execution

- Harness workers run locally on the daemon host, as the daemon user, without a
  sandbox.
- Human chat messages resume the same harness session.
- Permit concurrent agent turns in the same registered checkout. There are no
  global, harness or board parallel-session caps. Runtime leases enforce at most
  one active turn per conversation across API, CLI and scheduled starts.
  Transport, process and storage resource bounds still apply.
- Treat schedule occurrence records as authoritative. Use deterministic card
  identity and never replay a turn that may already have been dispatched.
- Start the scheduler only with `dieter serve` (`internal/daemon`). Constructing
  an HTTP handler in a test must not start background work.

## Network and identity

- Keep the raw Dieter data plane loopback-only, guarded by the user-only local
  API token (`internal/security/localauth`). An enrolled daemon automatically
  advertises a separate authenticated loopback TLS route; remote access goes
  through the gateway tunnel or an explicitly enabled additional direct TLS
  route.
- The gateway stores only account sessions, daemon identities, presence, route
  metadata and normalized, credential-free provider quota snapshots. Never put
  Dieter projects, transcripts, provider credentials, raw provider responses or
  harness credentials on the gateway.
- A daemon proves possession of its enrolled Ed25519 key on every tunnel
  connection (`internal/link/possession.go`, `internal/security/linkauth`).
  Never accept a daemon ID without cryptographic proof.
- Client sessions have binary full access or no access. Do not add scopes.
- Keep relay queues, messages and concurrent streams bounded
  (`internal/transport/relay`). A canceled relay RPC cancels only that transport
  RPC and must not implicitly stop an agent.

## Automation surface (CLI)

- The `dieter` binary is the supported automation client as well as the daemon
  executable. Operational commands go through the running daemon API; there are
  no direct-store reads or writes for normal CLI operation. The CLI package
  must not import daemon, store, API or engine packages (enforced by depguard
  in `.golangci.yml`).
- Every RPC declared in `api/proto/dieter/v1` is implemented explicitly by the
  handler of its service in `internal/api`
  (`TestGRPCAPIImplementsEveryDeclaredRPC`) and has a CLI command
  (`TestEveryDaemonRPCMapsToCLICommand`) with offline help
  (`TestEveryDaemonCLICommandHasOfflineHelp`, `TestEveryRPCCommandIsDocumented`).
- Every operation behaves the same over the local loopback route, verified
  direct TLS and the gateway relay. Global `--machine ID|NAME` prefers verified
  direct TLS, then WebRTC, and falls back to the authenticated bounded relay.

## Remote execution

Remote execution is a separate, agent-oriented interface from screen
terminals.

- Keep it exact-argv and shell-free by default, retain stdout/stderr
  boundaries, propagate explicit exit state, and make admission idempotent when
  a key is provided.
- A watch disconnect never stops an execution.
- Keep process count, input frames, output frames and bytes, retained sessions,
  timeouts and relay streams bounded.

## Tests and operators

- Never stop, restart, replace or install over an operator's running daemon or
  app during tests. Use temporary `DIETER_HOME` roots, random loopback
  listeners, isolated in-process gateways and daemons (`internal/testkit`,
  `tools/fixtures/gateway`), and disposable credentials.
- Device tests use the separate E2E app identities
  (`com.getdieter.android.e2e`, `com.getdieter.ios.e2e`), disposable iOS
  simulators, and Android phones only when a profile names their exact serial.
  Missing, skipped or unavailable required assertions and cleanup failures
  fail the gate.
