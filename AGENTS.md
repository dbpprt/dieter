# AGENTS.md

## Purpose

Dieter has a local Go daemon, a machine-only Go gateway, and native macOS, iOS,
and Android clients. Every card is one durable local AI SDK Harness
conversation.

## Invariants

- Ship one canonical SemVer release across gateway, daemon/CLI, and native
  clients. The gateway publishes minimum client and daemon releases; reject
  callers below those floors and do not add historical API branches. Keep only
  genuine subsystem revisions such as remote-desktop framing and persisted
  projection formats.
- Store all Dieter data centrally under `DIETER_HOME` (default `~/.dieter`). Never
  write Dieter metadata into project repositories.
- Every logical project has a Dieter-generated shared identity and may have
  several checkouts across machines. Each checkout references one existing Git
  working tree by canonical path on its immutable owner daemon.
- Shared project, board, label, placement, and portable settings are replicated
  within the account by the leaderless peer store. No machine owns a project.
  Conversations and schedules retain one execution owner and checkout.
- Every card has a Dieter-generated ID and exactly one durable conversation.
- Dieter owns transcripts, runtime status, harness/model configuration, queues,
  session resume data, board labels, card label assignments, and
  fixed workflow positions, schedules, occurrence history, and admission
  settings.
- Harness workers run locally on the daemon host without a sandbox. Keep the
  raw Dieter data plane loopback-only. An enrolled daemon automatically
  advertises a separate authenticated loopback TLS route; remote access goes
  through the gateway tunnel or an explicitly enabled additional direct TLS
  route.
- The gateway stores only account sessions, daemon identities, presence, route
  metadata, and normalized credential-free provider quota snapshots. Never put
  Dieter projects, transcripts, provider credentials, raw provider responses,
  or harness credentials on the gateway.
- A daemon proves possession of its enrolled Ed25519 key on every tunnel
  connection. Client sessions have binary full access or no access; do not add
  scopes or accept a daemon ID without cryptographic proof.
- Keep relay queues, messages, and concurrent streams bounded. A canceled relay
  RPC cancels only that transport RPC and must not implicitly stop an agent.
- Human chat messages resume the same harness session.
- Permit concurrent agent turns in the same registered checkout. There are no
  global, harness, or board parallel-session caps. Runtime leases enforce at
  most one active turn per conversation across API, CLI, and scheduled starts.
  Transport, process, and storage resource bounds still apply.
- Treat schedule occurrence records as authoritative. Use deterministic card
  identity and never replay a turn that may already have been dispatched.
- Start the scheduler only with `dieter serve`; constructing an HTTP handler in
  a test must not start background work.
- Use atomic writes and the central cross-process lock for every mutation.
- Dieter has no web UI. The public gateway root is intentionally 404; only
  OAuth completion pages, health, gateway gRPC, and tunneled Dieter gRPC exist.

## Pipeline ownership

Read `fastlane/README.md` before changing app builds, E2E or releases.
`just pipeline` / `just app` forward to the pinned Fastlane implementation.
Add compositions to `fastlane/lib/dieter`; add typed catalog/result contracts to
`internal/pipeline` and isolated fixtures to `tools/fixtures`. Do not reintroduce
platform Just modules, host test loops in scripts, or workflow shell pipelines.
Use Fastlane's maintained actions for Apple tests and archive/export.
`pipeline/action.rb` runs them inside owned processes with private input and
deadlines. Shared process, evidence, lease and product contracts belong in
`fastlane/lib/dieter/pipeline`, not duplicated adapters or workflow code.

Use `fastlane/local.example.json` as the template for ignored `fastlane/local.json`;
run `just pipeline config_init` once, then edit explicit named target profiles.
Local JSON cannot override release policy and CI ignores it. Physical Android/iOS
tests require an explicit exact-serial/UDID profile, separate E2E identities, and
existing development signing/network configuration. Never auto-select a phone.

Preserve exact-device, desktop, build and signing leases and ownership journals.
Manage only devices/processes started by the task; preserve operator apps and the
live daemon. Android lifecycle belongs to Fastlane: headless tests use a dedicated
AVD with snapshots disabled; borrowed devices remain with their owners. Never
wipe operator userdata or kill unrelated processes to repair a test run.
Required missing/skipped/unavailable assertions and cleanup failures fail gates.
Use registered background processes and collect their result before finishing.
Stream sanitized build/test progress. Keep diagnostics bounded and separate from
immutable checkpoints; never upload DerivedData, app bundles, archives or producer
copies as diagnostics. Diagnostic upload outages do not require rerunning passed
tests. Required assertions, cleanup and producer retention still fail closed.

Android emulator E2E is currently flaky and is actively being worked on. A
software-rendered boot can leave a System UI ANR dialog that steals test focus.
Keep failed evidence and ownership journals; passing subsets do not qualify the
full Android gate, and assertions must not be relaxed to hide emulator failures.

Main produces **dev** prereleases with one reserved numeric SemVer across every
component. Candidate reruns recover exact retained bytes; never rebuild a consumed
identity. TestFlight consumes the retained IPA and verifies internal delivery.
Stable promotion is separate and protected; dev cannot advance Latest/Homebrew/
updaters or activate production. See `fastlane/release-policy.json`.

## Repository checks

Shared local tools are declared in `mise.toml` and `mise.lock`. Prepare them with
`mise install --locked` and `mise run setup`; use `mise exec -- just ...` in
noninteractive shells. With managed Java, keep `toolchains.java_home` null in
`fastlane/local.json` so it inherits `JAVA_HOME`. Mise does not provision native
SDKs or devices; see `fastlane/README.md`.

For local development, inspect `just check-changed --dry-run`, then run selected
fast checks with `just check-changed`. Include branch changes with `--base REF`.
Device/desktop checks are listed separately: use `--native` or specific catalog
cases for related app, schema, fixture or lifecycle changes. Shared orchestration
edits require pipeline contracts, not every local native build. During refactors,
run focused checks as needed and affected contracts once at the integration
boundary. Repeat passing checks only after a relevant change or new failure.
Do not repeatedly run `just check`, `check-all`, full E2E catalogs, or unrelated
components between edits. Preserve the existing app,
daemon, and emulator lifecycle rules; report an unavailable integration run
instead of disrupting a running operator app. Full checks below remain for CI
and explicitly requested repository-wide validation.

CI uses `.github/workflows/qualification.yml`: affected checks on PRs and main,
full qualification on scheduled/manual runs. Routine iOS checks run portable
policies and `ios.connecting` on both layouts; full runs retain the functional
catalog. Measure cold builds, cache transfer and native execution separately;
the ten-minute feedback target is not a promise for full catalogs or TestFlight.
CI calls Release after qualification passes; Release must
not independently repeat those checks. Manual releases qualify first.
`ios_qualify` verifies one simulator build for explicit iPhone/iPad profiles under
one build lease. Physical tests require their separate exact profile, existing
development signing and authenticated fixtures; never reuse simulator bytes.

The shared Kotlin client core in `apps/core` has its own checks: `just pipeline core_test` (JVM unit and isolated end-to-end tests over the OkHttp transport that
Android shares) and, on macOS, `just pipeline core_apple_test`. See `apps/core/README.md`.
All three native clients are presentation-only clients of the core; the macOS
and iOS apps link it as `DieterShared` through `apps/mac/Sources/SharedCore`.
Put rules in the core, not in an app. `just pipeline ios build` assembles the iOS
framework slices (it needs a Java runtime) and compiles the iOS app and its test
bundles; the iOS tests run through `just pipeline ios e2e`.
`just pipeline ios test_unit` uses the small policy dependency graph and the
canonical `apps/mac/.build/dieter-ios-policy` cache, without building the Mac app.

Android builds use Android Studio's bundled JBR. If `JAVA_HOME` is absent or
points to a removed Homebrew JDK, use:

```sh
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
```

```sh
npm --prefix internal/harness/runtime ci
just check
just pipeline mac test_unit
just pipeline ios build
just pipeline android test_unit
```

Use `gofmt` on Go files. Keep every native client accessible and adaptive.
Prepare local commit tools once per checkout/worktree with `just hooks`.
Use `just format` for explicit source/config/docs working-file fixes and
`just pre-commit` for staged checks. Keep the no-stash dispatcher and avoid
automatic staging; qualify hook changes with `just hooks-test`. See
`fastlane/README.md` for pinned tools, exclusions, and Mac/Linux setup.

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
5. Regenerate Go, copied schemas, and checked-in Swift clients with
   `just proto`. Android generates from the authoritative schema during its
   build.

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
dieter card move <exact-card-id> --lane review
```

Do not edit central storage directly during normal operation.
