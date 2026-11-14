# ADR 0001: Open-source foundation refactor

- Status: accepted, implemented 2026-10
- Proposal: [docs/proposals/foundation-refactor.md](../proposals/foundation-refactor.md)

## Context

Before the refactor the repository was organized around how Dieter grew: the
Mac app directory also held the shared Apple layer and the iOS host, Kotlin had
two Gradle roots, the Go CLI package was the daemon's composition root, a
handful of Go packages held process-wide state, identifiers were spread over
many files with two namespaces, every push to `main` cut a signed release, and
contributors needed Ruby, Python, Fastlane and Go to build the Go binary. The
proposal lists the evidence. The repository was already public and needed
working security and contribution channels.

## Decision

Adopt the proposal with the owner's answers to its open questions:

- **Layout.** A top-level directory is a product or an ownership boundary:
  `api/`, `cmd/`, `internal/`, `apps/kotlin` (one Gradle build), `apps/apple`
  (`DieterKit`, `mac`, `ios`), `native/` (daemon-side helpers),
  `third_party/` (vendored code with `PATCHES.md`), `deploy/{gateway,install}`,
  `tests/{maestro,fixtures}`, `tools/`, `site/` (Hugo, was `landingpage/`),
  `docs/`, `assets/brand`, `config/identity.json`.
- **Identity.** One file, `config/identity.json`, rendered by
  `go run ./tools/identity` (`just generate`) into Go, Kotlin, Swift, Xcode and
  release tooling. Namespace `com.getdieter.<platform>`; one Apple team. The Go
  module path stays `github.com/dbpprt/dieter`. Changing identifiers is a clean
  break: no migration of keychain items, launchd labels, sockets or app data.
- **Release signer.** Only `.github/workflows/release.yml@refs/heads/main` signs
  release checksums, and installed updaters verify exactly that identity. It is
  a public contract ([releasing.md](../releasing.md#signing-identity)).
- **Releases.** Dev prereleases are cut nightly and on demand, not on every
  push; stable is a promotion of an exact tested dev build.
- **Orchestration.** Native builds, signing, notarization and store delivery
  stay in Fastlane, using its built-in actions; the custom Ruby and Python glue
  is removed. `just` is a thin index over plain toolchain commands
  ([building.md](../building.md#command-surface)). (The proposal had suggested a
  Go `tools/pipeline`; the owner chose to keep Fastlane.)
- **Go structure.** `internal/daemon` is the composition root and the CLI no
  longer links daemon packages; configuration is read once in
  `internal/platform/config`; package globals became per-instance state; one
  atomic-write and lock primitive (`internal/platform/fsx`) with `internal/link`
  as the only identity writer; the daemon API is implemented by per-domain
  handlers with one error mapper (unknown errors are `Internal`); packages were
  regrouped under `platform`, `security`, `transport`, `git`, `host`, `engine`,
  `replication`; Windows stubs were removed; `golangci-lint` enforces the
  boundaries.
- **Tests.** `internal/testkit` and `internal/testkit/topology` replace
  hand-built fixtures; end-to-end tests use the `e2e` build tag; tests run in
  parallel by default; the CLI command table drives dispatch, help, the help
  contract and the generated reference (`tools/clidocs`).
- **Clients.** One Gradle build with an opt-in `:core:e2e`; the Kotlin core
  ships to Swift as the `DieterCore` framework; a `DieterKit` Swift package is
  shared by the Mac and iOS apps without environment switches; the Mac app is a
  `DieterMacKit` library plus a thin executable; the MarkdownPreview bundle is
  built from locked sources instead of committed.
- **Open source.** Contributor docs in `docs/`, user docs only on the site,
  invariants moved out of `AGENTS.md`, a threat model, community files, DCO
  sign-off, squash-merged pull requests with a required `ci-ok` check, and
  private vulnerability reporting.

## Deviations and deferred work

Recorded so nobody mistakes the proposal's target for the current state:

- **Store aggregates, done.** `internal/store` is a composition root over
  aggregate subpackages behind the same root lock: `home` (DIETER_HOME, writer
  lock, schema, change counter), `replica` (the peer replica and its
  write-ahead views), `leases`, `kv`, `settings`, `commands`, `kanban`
  (projects, checkouts, boards, cards and chats), `workspaces`,
  `conversations` and `schedules`, beside `vaults` and `daemonstate`. The
  graph is acyclic: a lower aggregate reaches a higher one only through hooks
  the root wires, and depguard enforces the order. Durable formats and the lock
  order did not change. Rules still live in the aggregates; domain services
  (handlers → services → stores) come as each domain is touched. Recovery work
  moved off the write path to startup plus a periodic sweeper.
- **Replication, partially.** The CRDT (`replication/crdt`), record schema
  (`replication/schema`) and peer exchange (`replication/peersync`) are separate
  packages; the peer replica stays in `internal/store/replica`, because a
  replica transaction commits together with the store's local file effects.
- **Protocol split done, as a wire break.** `dieter.proto` became one file and
  service per domain (`CardService`, `ConversationService`, …) plus
  `common.proto`. RPC paths changed from `/dieter.v1.DieterService/X` to
  `/dieter.v1.<Domain>Service/X`, so the release line moved to 0.5 and the
  gateway's minimum client and daemon versions to `0.5.0-dev.0`. The gateway
  relays any `dieter.v1` service (`relay.DaemonMethod`).
- **Schema tooling is buf.** `just generate` runs `buf lint` and `buf generate`
  for Go, Connect and Swift straight from `api/proto` (the Swift plugins are
  built from DieterKit's resolved packages); the client and core contracts moved
  into `api/proto`; the schema copies, sync scripts and checksum manifest are
  gone. Kotlin's Wire build reads `api/proto` directly.
- **Harness runtime packaging.** Daemons still install the harness runtime's
  locked npm dependencies on first use instead of shipping a prebuilt
  per-platform runtime.
- **Remaining duplicate.** Compose resources must live inside their module, so
  `apps/kotlin/ui` keeps a byte-identical copy of the Sora font, verified by
  `go test ./tools/brandcheck`.
- **Behaviour changes worth knowing.** The loopback API no longer accepts the
  h2c upgrade handshake (clients use HTTP/2 prior knowledge or HTTP/1.1);
  `dieter daemon status` takes its project count from the running API;
  `DIETER_SCREEN_VIRTUAL_DISPLAY=1` now actually enables virtual displays; the
  Kotlin core retries `Internal`/`Unavailable` errors that were previously
  dropped as invalid.

## Consequences

- A fresh clone builds and tests each component with its plain toolchain.
- Forks change one identity file and run `just generate`.
- Anything that renames the release workflow, the identity prefix or the Apple
  team breaks installed updaters and needs a compatibility floor bump.
- The deferred items above are the next structural work; new code follows the
  target layout (domain handlers in `internal/api`, rules in the Kotlin core,
  `fault` kinds for errors, `testkit` for fixtures).
