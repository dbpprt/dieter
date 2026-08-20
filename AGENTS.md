# AGENTS.md

## Purpose

Nauclio has a local Go daemon, a machine-only Go gateway, and native macOS and
Android clients. Every card is one durable local AI SDK Harness conversation.

## Invariants

- Store all Nauclio data centrally under `NAUCLIO_HOME` (default `~/.nauclio`). Never
  write Nauclio metadata into project repositories.
- Every project references an existing Git working tree by canonical path and
  has a Nauclio-generated project ID.
- Every card has a Nauclio-generated ID and exactly one durable conversation.
- Nauclio owns transcripts, runtime status, harness/model configuration, queues,
  session resume data, comments, board labels, card label assignments, and
  fixed workflow positions, schedules, occurrence history, and admission
  settings.
- Harness workers run locally on the daemon host without a sandbox. Keep the
  raw Nauclio data plane loopback-only. An enrolled daemon automatically
  advertises a separate authenticated loopback TLS route; remote access goes
  through the gateway tunnel or an explicitly enabled additional direct TLS
  route.
- The gateway stores only account sessions, daemon identities, presence, and
  route metadata. Never put Nauclio projects, transcripts, or harness credentials
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
- Start the scheduler only with `nauclio serve`; constructing an HTTP handler in
  a test must not start background work.
- Use atomic writes and the central cross-process lock for every mutation.
- Nauclio has no web UI. The public gateway root is intentionally 404; only
  OAuth completion pages, health, gateway gRPC, and tunneled Nauclio gRPC exist.

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
go build ./cmd/nauclio
go build ./cmd/nauclio-gateway
```

Use `gofmt` on Go files. Keep both native clients accessible and adaptive.

## Use Nauclio as an agent

Read `.agents/skills/nauclio-cli/SKILL.md`. Prefer bounded context:

```sh
nauclio card context <exact-card-id>
nauclio card comment <exact-card-id> --message "Meaningful progress."
nauclio card move <exact-card-id> --lane review
```

Do not edit central storage directly during normal operation.
