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

## Use Dieter as an agent

Read `.agents/skills/dieter-cli/SKILL.md`. Prefer bounded context:

```sh
dieter card context <exact-card-id>
dieter card comment <exact-card-id> --message "Meaningful progress."
dieter card move <exact-card-id> --lane review
```

Do not edit central storage directly during normal operation.
