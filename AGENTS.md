# AGENTS.md

## Purpose

Dieter has a local Go daemon, a machine-only Go gateway, and native macOS and
Android clients. Every card is one durable local AI SDK Harness conversation.

## Invariants

- Store all Dieter data centrally under `DIETER_HOME` (default `~/.dieter`). Never
  write Dieter metadata into project repositories.
- Every project references an existing Git working tree by canonical path and
  has a Dieter-generated project ID.
- Every card has a Dieter-generated ID and exactly one durable conversation.
- Dieter owns transcripts, runtime status, harness/model configuration, queues,
  session resume data, comments, board labels, card label assignments, and
  fixed workflow positions, schedules, occurrence history, and admission
  settings.
- Harness workers run locally on the daemon host without a sandbox. Keep the
  raw Dieter data plane loopback-only. An enrolled daemon automatically
  advertises a separate authenticated loopback TLS route; remote access goes
  through the gateway tunnel or an explicitly enabled additional direct TLS
  route.
- The gateway stores only account sessions, daemon identities, presence, and
  route metadata. Never put Dieter projects, transcripts, or harness credentials
  on the gateway.
- A daemon proves possession of its enrolled Ed25519 key on every tunnel
  connection. Client sessions have binary full access or no access; do not add
  scopes or accept a daemon ID without cryptographic proof.
- Keep relay queues, messages, and concurrent streams bounded. A canceled relay
  RPC cancels only that transport RPC and must not implicitly stop an agent.
- Comments never wake the agent or count as approval. Human chat messages
  resume the same harness session.
- Permit concurrent agent turns in the same registered project folder. Only
  explicit global, harness, and board parallel-session limits restrict separate
  chats; a single conversation still has at most one active turn.
- Enforce global, harness, and board parallel-session limits at runtime lease
  acquisition so HTTP, CLI, and scheduled starts share one policy.
- Treat schedule occurrence records as authoritative. Use deterministic card
  identity and never replay a turn that may already have been dispatched.
- Start the scheduler only with `dieter serve`; constructing an HTTP handler in
  a test must not start background work.
- Use atomic writes and the central cross-process lock for every mutation.
- Dieter has no web UI. The public gateway root is intentionally 404; only
  OAuth completion pages, health, gateway gRPC, and tunneled Dieter gRPC exist.

## Repository checks

Android builds use Android Studio's bundled JBR. If `JAVA_HOME` is absent or
points to a removed Homebrew JDK, use:

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
```

```sh
npm --prefix internal/harness/runtime ci
go test -race ./...
go vet ./...
go build ./cmd/dieter
go build ./cmd/dieter-gateway
```

Use `gofmt` on Go files. Keep both native clients accessible and adaptive.

## Daemon CLI feature parity

The `dieter` binary is the supported automation client as well as the local
daemon executable. Operational commands must go through the running daemon API;
do not reintroduce direct-store reads or writes for normal CLI operation.

When a feature team adds, changes, or removes a native-client operation:

1. Declare the operation in `api/proto/dieter/v1/dieter.proto` and implement it
   explicitly on `grpcAPI`. Keep `connectAPI` a thin adapter to that core so
   loopback, authenticated direct TLS, and gateway relay routes behave alike.
2. Add or update the equivalent command in `internal/cli`. It must work against
   the local daemon and with global `--machine ID|NAME`; machine targeting must
   prefer verified direct TLS and fall back to the authenticated bounded relay.
3. Give the group and every leaf command useful offline `--help` text. Update
   the root help, `README.md`, and `.agents/skills/dieter-cli/SKILL.md` whenever
   discovery, flags, output, safety, or semantics change.
4. Extend `rpcCommand` in `internal/cli/help_contract_test.go`, add operation
   tests, and cover the CLI path end to end. Keep
   `TestGRPCAPIImplementsEveryDeclaredRPC` passing; it prevents implicit
   `Unimplemented` drift.
5. Regenerate Go and copied schemas with `./scripts/generate-proto.sh`, then
   regenerate checked-in Swift clients with
   `./apps/mac/scripts/generate-swift-proto.sh`. Android generates from the
   authoritative schema during its build.

Never stop, restart, replace, or install over an operator's currently running
daemon during tests. Use temporary `DIETER_HOME` roots, random loopback
listeners, isolated in-process gateways/daemons, and disposable credentials.
Verify local, direct-TLS, and relay CLI routes without touching the live service.

Remote execution is a separate agent-oriented interface from screen terminals.
Keep it exact-argv and shell-free by default, retain stdout/stderr boundaries,
propagate explicit exit state, and make admission idempotent when a key is
provided. A watch disconnect must never stop an execution. Keep process count,
input frames, output frames/bytes, retained sessions, timeouts, and relay
streams bounded. New execution lifecycle operations require proto, core server,
Connect adapter, CLI/help, skill/docs, manager, local, direct-TLS, and relay
coverage in the same change.

## Use Dieter as an agent

Read `.agents/skills/dieter-cli/SKILL.md`. Prefer bounded context:

```sh
dieter card context <exact-card-id>
dieter card comment <exact-card-id> --message "Meaningful progress."
dieter card move <exact-card-id> --lane review
```

Do not edit central storage directly during normal operation.
