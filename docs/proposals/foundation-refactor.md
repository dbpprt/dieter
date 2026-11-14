# Proposal: an open-source foundation for Dieter

Status: Implemented 2026-10 (see [docs/adr/0001](../adr/0001-foundation-refactor.md)) · proposed 2026-10-11 · scope: whole repository

## TL;DR

Dieter works, but the repository is organised around how it grew, not around
what it is. Contributors face three products sharing directories, four tooling
languages, a release on every push, and a CI that is red most of the time and
hard to read when it fails. This proposal:

1. **Fixes eight release/OSS blockers first.** These are cheap and partly live
   bugs; see [Phase 0](#phase-0--fix-now-and-decide).
2. **Makes plain toolchains the interface.** `go test ./...`, `./gradlew check`
   and `swift test` work from a fresh clone. `just` indexes them. One Go tool
   replaces the Ruby/Python orchestration. Fastlane remains only for Apple
   distribution.
3. **Gives the repository a layout where a directory is a product or an
   ownership boundary.** It also introduces one schema pipeline (buf), one
   Gradle build and one Apple package graph without env-var switches.
4. **Splits the Go god packages along real boundaries.** These are `cli`,
   `store`, `server` and the 148-RPC handler, plus the composition root that
   lives in `cli`. Layering gets enforced by lint, not by convention.
5. **Rebuilds the test system for speed and honesty.** It adds parallel Go tests,
   tagged e2e, shared testkits, JUnit everywhere, and lanes that fail on
   missing tests.
6. **Reshapes CI and releases.** PRs get fast, readable checks. Dev releases
   move from every push to nightly or on demand. Secrets are scoped per
   signing domain, publishing is fork-safe, and release notes are real.

Execution is six phases. Phases 0–1 are days, not weeks, and they make main
green and quiet. The deep code work (Phases 4–5) is incremental and gated by
the faster CI built first.

---

## 1. Where we are

| Area         | Evidence                                                                                                                                                                                                                                                                                                                                         |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Size         | Go 64.6k hand-written + 41.7k test + 44k generated. Kotlin 79k. Swift 203k, of which 84k is generated and 46k vendored. Tooling: Ruby 9.2k, Python 8.8k, Go 3.8k.                                                                                                                                                                                |
| Go structure | `internal/cli` (11k LOC) holds the daemon composition root (`cli.go:398 daemonStart`, 274 lines) and imports 19 internal packages. `store` has 302 methods on one type. `grpcAPI` implements all 148 RPCs, and 148 hand-written Connect wrappers sit on top. Handlers call `store` directly 145× and the `app` service 17×.                      |
| Go hygiene   | 47 `DIETER_*` env vars are read in 14 packages, and `DIETER_HOME` is resolved in 4 places. There are 5 atomic-write implementations. A package-global `store.writeMu` exists. `daemon/identity.json` has two writers, and one bypasses the store lock. Unknown errors map to `InvalidArgument` (`server/grpc.go:1681`, `connect.go:306`).        |
| Clients      | `apps/mac` is three products: the Mac app, the Apple shared layer, and the iOS host (`DIETER_SWIFT_PACKAGE=ios` switches `Package.swift`). Protos are copied 3× and 84k lines of Swift codegen are committed. Kotlin has two Gradle roots and two version catalogs. The Mac UI holds 440 direct `Dieter_V1_*` references beside the shared core. |
| Tests        | Go: 0 `t.Parallel`, 67 sleeps, 48 wall-clock polling loops, no testkit (the gateway+daemon topology is hand-built 10×), and no `-timeout`; `store` takes 523 s of the 600 s default. Kotlin e2e launches ~50 fixture processes serially. Swift lanes accept exit 0 without a test count. No JUnit or coverage reporting anywhere.                |
| CI           | 4 of the last 13 completed main runs are green, and 6 of the 8 failures are iOS. A green run takes ~94 min. Failures surface as `Process completed with exit code 1`, with no annotations or log groups and with ANSI codes in the logs. A "facade-only" rule forces every `run:` step through `bundle exec fastlane`.                           |
| Releases     | Every main push reserves a version, builds 9 signed candidates, publishes a public prerelease and uploads to TestFlight. That has produced 324 tags so far. Notes are boilerplate. The custom ledger (claim tags, receipts) has already leaked `pipeline-claims/*` tags to origin.                                                               |
| OSS          | The repo is **already public** (2 forks), but Issues and private vulnerability reporting are disabled, so SECURITY.md has no working channel. Owner ops runbooks name people and Apple IDs. A private Tailscale model route is the shipped default. Publishing workflows have no fork guards.                                                    |

### What we keep

The rework must not lose these properties:

- Atomic writes plus the cross-process lock, peerstore hard limits, and the
  signed-claim trust model.
- Contract tests:
  - `TestGRPCAPIImplementsEveryDeclaredRPC`
  - the RPC→CLI map
  - Maestro flow lint, including failing on a flow missing from JUnit
  - Go-generated golden vectors consumed by Kotlin
- Promotion of exact tested bytes: stable is a promoted dev build, never a
  rebuild. Cosign-signed `SHA256SUMS` and the signed, SBOM'd gateway image
  also stay.
- SHA-pinned actions, least-privilege top-level permissions, and the bounded
  evidence collector.
- The device-safety rules: exact-serial phones, borrowed emulators, and never
  touching the operator's live daemon.

---

## 2. Principles

Every later section applies these.

1. **A directory is a deployable or an ownership boundary.** Nothing at the root
   that is not a product, the schema, docs, or repository plumbing.
2. **Native toolchains are the contract.** Every component builds and tests with
   its own tool from a fresh clone. Orchestration adds leases, fixtures and
   reports. It never replaces the plain command.
3. **One source per fact.** Schemas, tool versions, identity values (bundle
   prefix, team ID, default gateway, update feed) and CLI reference text each
   have exactly one source. Everything else is generated, and CI fails on drift.
4. **Composition at the edge.** Binaries wire dependencies in one place, and
   packages receive config and collaborators. No `os.Getenv` below `cmd`/config,
   and no package-level mutable state.
5. **Boundaries are enforced by tools.** That means depguard rules, import
   checks for Swift targets, and buf lint/breaking. Prose in AGENTS.md alone
   is not enforcement.
6. **CI output is a product.** A failure names the test, file and line in the
   PR UI within one click. Every job writes a summary.
7. **Clean breaks.** Moves delete the old path in the same change. Protocol
   changes raise the gateway floors instead of adding compatibility branches.

---

## 3. Target repository layout

```
.
├── api/                      # the only schema source
│   ├── buf.yaml, buf.gen.yaml
│   └── proto/dieter/{v1,gateway/v1,client/v1,core/v1}/   # client/core moved from apps/core/model
├── cmd/
│   ├── dieter/               # main: `serve` → daemon.Run, everything else → cli.Main
│   └── dieter-gateway/       # main: gateway.Run
├── internal/                 # Go product code (see §4)
├── apps/
│   ├── kotlin/               # ONE Gradle build: core, ui, android app, android-webrtc, apple bridge
│   └── apple/
│       ├── DieterKit/        # Swift package: DieterAPI (generated), Transport, AppleCore — iOS + macOS
│       ├── mac/              # Mac app package (thin executable + DieterMacKit library)
│       └── ios/              # Dieter.xcodeproj, iOS host (ex apps/mac/Sources/DieterIOS), Share extension
├── native/                   # daemon-side helpers only
│   ├── macos/                # SwiftPM: RemoteDesktopProtocol, dieter-capture, dieter-privacy, tests
│   └── linux-capture/
├── third_party/              # vendored code, each with LICENSE + PATCHES.md
├── deploy/
│   ├── gateway/              # + Dockerfile, .env.example, .dockerignore (from root)
│   └── install/              # install.sh (from scripts/)
├── tests/
│   ├── maestro/
│   └── fixtures/             # all cross-language golden vectors
├── tools/
│   ├── pipeline/             # Go orchestration tool, own go.mod with `tool` pins
│   └── fixtures/             # fixture gateway, screens, turn-probe (main module: imports internal/)
├── release/                  # Fastlane (Apple distribution only), Gemfile, release-policy.json
├── site/                     # Hugo (was landingpage/)
├── docs/                     # contributor docs: architecture, invariants, ADRs, proposals
├── assets/brand/             # single brand source; platform copies are generated
└── README · LICENSE · THIRD_PARTY_NOTICES · CONTRIBUTING · SECURITY · CODE_OF_CONDUCT · AGENTS · justfile · mise.toml · go.mod
```

### Moves

| From                                                                        | To                                        | Note                                                                                                                                                                           |
| --------------------------------------------------------------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `apps/core/*` + `apps/android`                                              | `apps/kotlin/*`                           | One `settings.gradle.kts`, one wrapper, one `libs.versions.toml`. The Compose/Kotlin pins hardcoded in `mobile/build.gradle.kts` move into the catalog.                        |
| `native/android-webrtc`                                                     | `apps/kotlin/android-webrtc`              | A client build input, not a daemon helper.                                                                                                                                     |
| `apps/mac/Sources/{DieterAPI,DieterTransport,SharedCore}`                   | `apps/apple/DieterKit`                    | Remove the env-var `Package.swift` switch and the hand-kept iOS `sources:` list. Mac-only models move to the Mac package.                                                      |
| `apps/mac/Sources/DieterIOS`                                                | `apps/apple/ios/Host`                     | iOS no longer references `../mac`.                                                                                                                                             |
| `apps/mac/Vendor/*`, android-webrtc patches                                 | `third_party/*`                           | Uniform `PATCHES.md` per package. Upstream the HighlighterSwift `init(bundle:)` patch and drop it.                                                                             |
| `native/macos-{capture,privacy}`                                            | `native/macos` (SwiftPM)                  | Replaces raw `swiftc` scripts that compile `apps/mac` files by path. The shared keymap and clipboard code become the `RemoteDesktopProtocol` target that DieterKit depends on. |
| `apps/mac/{design,reference}` (10 MB PNGs)                                  | delete, or `docs/design/` if still useful | Not build inputs.                                                                                                                                                              |
| `Dockerfile.gateway`, `.env.example`, `.dockerignore`                       | `deploy/gateway/`                         | Gateway-only config at root misleads.                                                                                                                                          |
| `scripts/install.sh`                                                        | `deploy/install/`                         |                                                                                                                                                                                |
| `scripts/{generate-proto.sh,sync_apple_proto*.py}`                          | deleted → `just generate`                 | Becomes buf plus the SwiftPM plugin reading `api/proto` directly.                                                                                                              |
| `scripts/measure_process.py`                                                | delete or `tools/pipeline`                |                                                                                                                                                                                |
| `fastlane/`                                                                 | `release/` (trimmed) + `tools/pipeline`   | See §7.                                                                                                                                                                        |
| `internal/pipeline`, `tools/pipeline-{support,contract}`                    | `tools/pipeline`                          | CI tooling leaves the product module.                                                                                                                                          |
| `internal/brandassets` (test-only), `internal/fixtureturn`                  | `tools/`                                  |                                                                                                                                                                                |
| `config/harnesses.yaml` + `embed.go`                                        | `internal/harness/catalog/`               | A root dir that exists for one embed.                                                                                                                                          |
| `landingpage/`, `just/site.just`                                            | `site/`, recipes folded into `justfile`   |                                                                                                                                                                                |
| `docs/apple-release-signing.md`, `docs/ios-testflight-account-migration.md` | private ops repo                          | They name people, team IDs, cert, profile and API key IDs.                                                                                                                     |
| `.streerc`, `ruff.toml`, `Gemfile*`, `.ruby-version`                        | `release/`                                | Follows the Ruby/Python reduction in §7.                                                                                                                                       |

Local-only cleanup, not in git, done by the owner on their machine:

- Empty `drawable*/` and `mipmap-anydpi-*/` directories from an accidental
  `mkdir -p` at the repo root.
- `bin/` (67 MB of stale binaries).
- `tmp/` (3.4 GB).
- `.android/` (5 GB, an AVD inside the checkout). Point `storage_dir` outside the repo.
- `BUNDLE_PATH=tmp/bundle`; move it to the mise cache.

Remove the personal entries from `.gitignore` (`newsos.zip`,
`Native Android PWA redesign.pdf`, …).

---

## 4. Go backend

### Target package map

```
cmd/dieter            → cli.Main | daemon.Run(ctx, daemon.Config)
cmd/dieter-gateway    → gateway.Run(ctx, gateway.Config)

internal/
  daemon/          composition root: Config (all flags+env, loaded once), Run, lifecycle
                   (from cli.daemonStart + server.newServer, which today also builds the engine,
                   scheduler, terminals, remoteexec, remotedesktop, machine; remotedesktop twice)
  api/             DieterService implementation: one handler type per domain
                   (boards, cards, conversations, files, git, terminals, exec, screens,
                   schedules, vault, kv, peer, machine) + errors.go (ONE status mapper,
                   unknown → Internal) + convert/
  engine/          turn engine (was app) + scheduler
  harness/         catalog (ex config/), discovery, runner, runtime/ (JS)
  store/           root: Store, lock, schema, fsx; subpackages per aggregate:
                   cards, conversations, boards, settings, schedules, vault, checkouts
  replication/     crdt (peerstore, domain tables injected) + sync (daemon/peer, store/peer*,
                   store/shared*, server/peer; today 5 packages)
  link/            gateway tunnel client, direct TLS route, daemon identity (sole writer)
  git/             exec, status, ops, changeset, scm, workspace (6 packages → 1 with files)
  host/            machine, terminal, remoteexec, serviceruntime
  remotedesktop/   session/, media/ (fec, pacer, adaptation), native/ (helper IPC)
  gateway/         auth/, hub/, relay/, quota/, storage/
  cli/             client commands ONLY (no daemon/store/server/engine imports)
  transport/       relay policy + raw codec + controlrtc + client dialer
  security/        trust, linkauth, localauth, vault crypto
  platform/        buildinfo, config/env loader, fsx (single atomic write + flock), version
  testkit/         see §6
  gen/             generated (committed)
```

### Changes, in dependency order

1. **Composition root and config.**
   - Move `daemonStart` into `internal/daemon`. `cmd/dieter` dispatches.
   - Introduce `daemon.Config` with every `DIETER_*` variable, parsed once and
     documented in one generated table.
   - Delete the four `DIETER_HOME` resolvers and `machine.defaultRoot`.
   - Replace the six production checks of `DIETER_ENABLE_MOCK_HARNESS` with an
     injected harness registry. Fixtures register the mock.
   - _Result:_ the CLI no longer links the daemon. A client-only `dieter` could
     later build for Windows without porting the daemon.
2. **Kill package globals.**
   - Covers `store.writeMu`, the harness catalog and discovery function vars,
     `server.toolPayloadPreviews` and `machine.operationCapabilityCache`.
   - Each becomes per-instance state.
   - This is the prerequisite for `t.Parallel` and for running two daemons in
     one test process.
3. **One filesystem primitive.** `platform/fsx` gets `AtomicWrite` and `Lock`,
   and the 5 copies are deleted. `link` becomes the only writer of
   `identity.json`, and it writes under the central lock, which restores the
   AGENTS.md invariant. Register the sqlite driver explicitly in `store`.
4. **API handlers.**
   - Split `grpcAPI` (175 methods, `grpc.go` 1,698 lines) into per-domain
     handler types, composed into the service.
   - Generate the Connect adapter (connect-go's simple handler option, or a
     30-line generator) instead of hand-writing 148 wrappers. The parity test
     stays.
   - One error mapper, where unknown errors map to `Internal`.
   - Remove the unused `gatewayv1connect`.
   - Use grpc-go only where the raw relay codec needs it (gateway relay,
     direct-TLS forwarder).
5. **Store by aggregate, then a service layer.**
   - First split `store` mechanically into aggregate subpackages behind the same
     root lock.
   - Then move rules out of `store` into domain services as each domain is
     touched. Handlers call services; services call stores.
   - Move recovery (`flushScheduleOutbox`, `recoverCardWrites`,
     `recoverSyncMutation`) from every write onto startup plus a background
     sweeper.
6. **Replication.** Make one package own the sync protocol. Inject the domain
   field tables into the CRDT instead of hardcoding them in `peerstore/domain.go`.
7. **Platforms.** Declare the daemon macOS/Linux only. Delete the `*_windows.go`
   stubs; `store` doesn't compile on Windows anyway. Add `GOOS=linux,darwin`
   build checks.
8. **Harness runtime.**
   - Replace the 23-file hand-written `//go:embed` list with a directory embed.
   - Stop running `npm ci` on user machines at first use. Release builds
     produce a per-platform runtime tarball, with `node_modules` included and
     `@openai/codex` binaries resolved, and ship it inside the daemon archive.
   - Pin Bun through a lockfile instead of `npm install --package-lock=false`.
9. **Lint.** Use `golangci-lint` with:
   - `depguard`: cli ↛ daemon/store/engine/api; store ↛ api/engine; gateway ↛
     daemon packages.
   - `forbidigo`: `os.Getenv` outside `platform/config`.
   - `staticcheck`, `errcheck`, `errorlint`, `contextcheck`, `gofumpt`.

   This replaces the boundary prose in AGENTS.md with checks.

### Protocol

`dieter.proto` is 2,804 lines: one `DieterService`, 148 RPCs and 270 messages.

- **Step 1** has zero wire impact. Move messages into per-domain files in the
  same package. The service stays in `service.proto`, so full names, and
  therefore the wire, are unchanged.
- **Step 2** is a breaking change paired with a floor bump. Split into domain
  services (`CardService`, `ScreenService`, …), update `relaypolicy`'s method
  table, and raise minimum client/daemon versions at the gateway.
  - _Benefit:_ handler types map 1:1 to services, and the generated code is
    split by domain.
- **Tooling.** Add `buf lint` (with documented exceptions) and `buf breaking`
  against the last stable tag. A breaking diff is allowed but must come with a
  floor bump in the same PR; CI checks that pairing.

---

## 5. Native clients

### Kotlin (`apps/kotlin`)

- **One Gradle build:**
  - `:core:model` (Wire from `api/proto`; set `java_package` in the protos and
    delete the `relocateProto` task)
  - `:core:runtime` (ex `shared`)
  - `:core:apple`, which produces `DieterCore.xcframework`
  - `:ui` (ex `mobile`), which produces `DieterMobile.xcframework`
  - `:android:app`, `:android:webrtc` and `:testing`
- **Rename the framework tangle.** Today `:apple` produces `DieterShared` and
  `:mobile` _also_ produces `DieterShared`, renamed on disk by Fastlane.
- **Split the god objects by feature**:
  - `MobileStore` (1,190 lines, 67 functions) becomes per-feature state holders.
  - `ScreenSession` (1,279 lines) is split into session, policy and input.
  - Flat `mobile` package files are grouped into feature packages.
- **E2E is opt-in.** Move the Go-fixture tests into a separate `:core:e2e`
  source set, so `./gradlew check` runs pure tests in seconds without Go or Node.
- **Fixture gateway built once.** Build it once per run by `tools/pipeline`,
  not separately by Gradle (`upToDateWhen { false }`) and by Ruby. Reuse one
  fixture per test class where state allows.
- **Shell tests.** Add the first Android shell unit tests. The APK SHA-256
  verification in `AppUpdateManager` is security code with zero tests today.

### Apple (`apps/apple`)

- **DieterKit.** A real multi-platform package (iOS 18 / macOS 26) with no env
  switch. It holds `DieterAPI`, `DieterTransport` and `DieterAppleCore`.
  - `DieterAppleCore` is the platform-neutral part of `SharedCore`.
  - Binary targets for the KMP frameworks are produced by `just frameworks`,
    which calls plain `gradlew`, with no Fastlane in the path.
- **Mac app.** A thin executable plus a `DieterMacKit` library.
  - Tests import the library instead of `@testable` against the executable,
    which is also faster to build.
  - Feature folders become consistent: `Features/<Feature>/{Views,Model}`. The
    current split between `Features/` and `UI/` disappears, and `Networking/`,
    which is actually Metal rendering, becomes `Features/Screens/Rendering`.
- **Finish schema-first.**
  - Add a check that `DieterMacKit` imports `DieterAPI` only in an allow-listed
    adapter folder, then burn the 440 `Dieter_V1_*` references down feature by
    feature.
  - `AppSession`/`DieterStore` (~2.4k LOC across 9 files) shrinks as slices
    replace it.
- **MarkdownPreview bundle.** Stop committing the 6.2 MB minified `app.js`.
  Build it from its locked sources during the Mac build.
- **Generated Swift.** It stays committed, so a fresh clone builds without
  protoc.
  - Generate it with the grpc-swift SwiftPM plugin reading `api/proto` directly.
  - This deletes the 7.1k lines of proto copies, the sync script and the
    `.inputs.sha256` manifest.

### Identity configuration (fork-ability)

One file, `identity.properties`, defines the following for everything:

- bundle prefix
- Apple team ID
- app group
- URL schemes
- default gateway
- update-feed repository
- GHCR namespace and Homebrew tap

It is rendered into an xcconfig, Gradle properties, Kotlin `BuildConfig`, Go
ldflags and release config. It replaces values that are scattered and
inconsistent today:

- `com.dbpprt.*` and `com.getdieter.*` are mixed.
- iOS registers the `dieter-mac://` scheme.
- The team ID is a Go const (`serviceruntime/runtime.go:23`).
- `gateway.getdieter.com` is hardcoded in 3 places.
- The Android updater URL is hardcoded.

Forks change one file.

---

## 6. Tests

### Layers, applied uniformly

| Layer            | Go                                                                                              | Kotlin                              | Swift                        | Runs                              |
| ---------------- | ----------------------------------------------------------------------------------------------- | ----------------------------------- | ---------------------------- | --------------------------------- |
| L0 unit          | default `go test ./...`, `t.Parallel`, `-shuffle=on -timeout=5m`, `testing/synctest` for timing | `commonTest`                        | DieterKit/DieterMacKit tests | every PR, < 3 min each            |
| L1 component     | in-process topologies via testkit, `*_component_test.go`                                        | —                                   | —                            | every PR                          |
| L2 e2e           | `//go:build e2e`                                                                                | `:core:e2e` against fixture gateway | fixture-gated suites         | PR when affected, main, nightly   |
| L3 device        | —                                                                                               | Maestro mobile flows                | Maestro mac flows            | smoke when affected, full nightly |
| L4 hardware/live | `//go:build hardware`                                                                           | —                                   | screen runners               | manual / nightly                  |

### Changes

- **`internal/testkit` for Go**:
  - `Home(t)`, `Store(t)`, `GitRepo(t)`, `RunGit`, `MockHarness(t)`, `FakeRunner`
  - `Topology{Gateway, Daemons}`, which `tools/fixtures/gateway` reuses
  - `Eventually(t, cond)` with race-scaled budgets

  It replaces 10 hand-built topologies, 9 git helpers, 3 `fakeRunner`s and 81
  inline store setups.

- **Time.**
  - Convert the 48 wall-clock polling loops and 67 sleeps to `synctest` or
    injected clocks. Start with the known flaky ones
    (`scheduler_test.go:57`, `server/schedule_test.go:58`,
    `remotedesktop/virtual_display_test.go:194`).
  - Break the mega-tests into scenarios. For example,
    `TestGatewayEnrollsDaemonAndRelaysDieterService` is 563 lines.
- **Fail closed.**
  - Swift lanes parse the test count (`--xunit-output`) and fail below an
    expected minimum. Today a test that stops the main run loop exits 0
    mid-run and the lane passes.
  - Required lanes turn env-gated skips into failures (`testkit.RequireEnv`).
- **Cross-language vectors.** All of them live in `tests/fixtures`, generated
  by Go behind one `DIETER_UPDATE_FIXTURES=1` and loaded as resources by Kotlin
  and Swift. `board-lifecycle.tsv` is hand-copied into Kotlin today.
- **Contracts.**
  - Keep the RPC parity and RPC→CLI tests.
  - Derive the ~300 help paths from the command table instead of a hand-kept
    list.
  - Generate the CLI reference, the SKILL.md command section and the site CLI
    page from that same table. The AGENTS.md rule to hand-update README on
    every CLI change then goes away.
- **Gaps to fill first.** All are security- or correctness-critical:
  - `vault/crypto.go` (490 LOC, test ratio 0.25)
  - `envfile` 0600 enforcement (0 tests)
  - `compatibility` floors
  - `remoteexec` (0.25)
  - Android APK verification
  - Node `runner.mjs`
- **Reporting.**
  - Go runs through `gotestsum --junitfile --format github-actions` with
    `-coverprofile`.
  - Gradle test results and Kover, Swift xunit, `node --test --test-reporter=junit`.
  - Everything is published by one JUnit report step: annotations plus a
    summary.
  - Coverage is reported, not gated, at first.
  - Flaky tests get a quarantine list with an owner and expiry instead of
    retries.

---

## 7. Local tooling and developer experience

### Decision: replace the Ruby/Python orchestration with one Go tool

Today, `just pipeline …` → `bundle exec fastlane` → Ruby, which then:

- shells out to Python about 20×, 6 of those as inline `python3 -c "from fastlane.lib…"`;
- compiles a Go planner in every job;
- wraps `gradlew` through `go run`.

Process, redaction and atomic-write helpers exist in three languages. A
contributor needs Ruby, Bundler, Fastlane, Python and Go just to build the Go
binary.

**Target.** `tools/pipeline` is a Go module, invoked with `go run ./tools/pipeline`
behind the unchanged `just pipeline <platform> <action>` surface. It owns:

- affected-check planning: the existing Go planner, now emitting the CI matrix
  directly;
- e2e orchestration: fixture gateway, emulator and simulator lifecycle,
  exact-device leases, ownership journals, Maestro;
- evidence collection with the existing budgets;
- CI reporting: summaries, annotations, log groups, ANSI stripping;
- release assembly helpers.

Tool versions (`buf`, `protoc-gen-*`, `gotestsum`, `govulncheck`, `actionlint`,
`golangci-lint`) are pinned with `tool` directives in `tools/pipeline/go.mod`.
Everything else is pinned in `mise.toml`, which CI uses too through
`jdx/mise-action`. That gives one pin source; today `just` is pinned in three
places and Hugo in three.

**Exactly which Ruby moves.** Of about 6.4k lines in `fastlane/`, only two
Fastlane features are really used: `build_app` (`pipeline/action.rb`,
`platforms/ios.rb`) and `upload_to_testflight` plus Spaceship
(`distribution/testflight.rb`). `gradle(…)` and `notarize(…)` are Dieter
helpers around `gradlew` and `xcrun notarytool`.

| Ruby today                                                                                                                                                    | LOC    | Becomes                                                                                                                                  |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| Lanes, dispatch, config: `Fastfile`, `runtime.rb`, `operations.rb`, `config.rb`, `ci.rb`                                                                      | ~930   | `tools/pipeline` CLI and `just` recipes                                                                                                  |
| Engine: `pipeline/{process,context,engine,request,inputs,source,identity,artifacts,evidence,lease,contract}.rb`, `atomic.rb`, `errors.rb`                     | ~800   | Go. Process, lease and planner code already exist a second time in `internal/pipeline`.                                                  |
| Affected checks and workflow lint: `checks.rb`                                                                                                                | ~280   | The Go planner, which already exists; Ruby is only its wrapper                                                                           |
| E2E: `e2e.rb`, `maestro.rb`, `platforms/emulator.rb`, `fixtures/{gateway,screen}.rb`, `screens.rb`                                                            | ~1,300 | Go, ported behaviour-for-behaviour with leases and journals                                                                              |
| Platform builds: `platforms/{mac,framework,core,android,server,linux_capture,apple_build}.rb`                                                                 | ~1,090 | Mostly plain `go build` / `gradlew` / `swift build` recipes. Mac `.app` assembly goes to Go.                                             |
| Release coordination: `pipeline/candidate.rb`, `distribution/{github,coordinator,retention,gateway,homebrew}.rb`                                              | ~1,050 | Partly deleted, since claim tags and receipts give way to concurrency, immutable releases and attestations; the rest becomes Go and `gh` |
| **Stays:** `pipeline/action.rb`, `distribution/testflight.rb`, `distribution/apple.rb` (signing, notarytool, pkg), the `build_app` part of `platforms/ios.rb` | ~880   | `release/`                                                                                                                               |

The ~2.6k lines of Python that this Ruby shells out to also go. Port the
`fastlane/spec` cases for leases, journals and e2e first, as the acceptance
suite.

**What remains elsewhere:**

- **Fastlane** (`release/`, under 1k LOC Ruby) keeps only Apple distribution:
  `build_app`/export, signing and notarization, and
  `upload_to_testflight`/Spaceship.
- **Python** remains only in `deploy/gateway`, which is self-contained,
  stdlib-only operator tooling with its own tests that CI runs.
- **Deleted:**
  - `fastlane/lib/dieter/native/*.py`
  - `precommit.py` (738 lines)
  - the dead `bundle.py publish()`
  - the drifted Python specs

**Formatting and hooks:**

- `just fmt` and `just lint` call the formatters (gofumpt, ktfmt, swift-format,
  prettier, shfmt) directly, with versions from mise.
- CI runs `just lint`. Today gofmt, ktfmt, prettier and gitleaks run only in
  local hooks, so contributors without hooks pass CI.
- The hook is a one-liner that runs `just lint --staged` without stashing.
  Hooks become a convenience, not the enforcement point.

### `just` as the index

```
just setup        # mise install + npm ci (harness) — nothing else
just build        # go build ./cmd/...          (no Ruby)
just test         # go test ./... (L0+L1)       just test-e2e  # -tags e2e
just lint / fmt   # all languages, staged or full
just generate     # buf (Go) + SwiftPM plugin (Swift); CI fails on diff
just kotlin check # ./gradlew -p apps/kotlin check
just mac test     # swift test --package-path apps/apple/mac
just e2e <android|ios|mac> [smoke|full] [flows:…]
just site serve
```

Each component README starts with a "Build & test from a fresh clone" section
listing those plain commands and their prerequisites. A Go-only contributor
needs Go and Node (for the harness), nothing else. `LinuxCapture` is opt-in, so
`just test` passes on a stock Linux machine.

---

## 8. CI (GitHub Actions)

### Workflow set

| Workflow                            | Trigger                                               | Content                                                                                                                                                                                                                                                                                                                          |
| ----------------------------------- | ----------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ci.yml`                            | PR, push main                                         | `plan` (Go tool emits `matrix` JSON plus a "why selected" summary) → per-component jobs from `fromJSON(matrix)`: `go`, `go-e2e`, `kotlin`, `apple`, `android`, `site`, `deploy-gateway`, `lint` → `ci-ok` gate (pure `needs.*.result` expression, no toolchain install). Device smoke via reusable `e2e.yml` only when affected. |
| `nightly.yml`                       | cron, dispatch                                        | Full qualification including iPad and `full` flows → dev release (§9) → TestFlight. Upstream repo only.                                                                                                                                                                                                                          |
| `release.yml`                       | dispatch with tag                                     | Stable promotion of a qualified dev build. `stable-release` environment.                                                                                                                                                                                                                                                         |
| `_build-{server,apple,android}.yml` | `workflow_call`                                       | Per signing domain, each with its own environment (`apple-signing`, `android-signing`). No `secrets: inherit`, and no runner-label secret routing (today `component=='mac' \|\| (component=='daemon' && runner=='macos-26')` appears 7× per file).                                                                               |
| `security.yml`                      | PR, weekly                                            | CodeQL (Go, Kotlin), `dependency-review` on PRs, gitleaks, OpenSSF Scorecard                                                                                                                                                                                                                                                     |
| `site.yml`                          | PR (build + link check), main (deploy, upstream only) |                                                                                                                                                                                                                                                                                                                                  |
| `gateway-deploy.yml`                | dispatch, upstream only                               | unchanged gate                                                                                                                                                                                                                                                                                                                   |

**Delete:**

- `component-check.yml`, `component-candidate.yml` and `qualification.yml`,
  which are folded into the above;
- `ios-testflight.yml`, which becomes a nightly step;
- the "facade-only" rule in `checks.rb:263`. Small `bash`/`gh` steps are fine;
  logic lives in the Go tool.

### Outputs: what a reader sees

- **Plan summary.** Selected components, the matched paths and the reason for
  each.
- **Failures as annotations.** `::error file=…,line=…,title=<test>` comes from
  gotestsum, the JUnit reporter and the Go tool for Maestro/process failures.
  The first line of a failed iOS run should read
  `mobile/task: assertVisible "Mock harness received" timed out (180 s)`, not
  `exit code 1`.
- **Logs.**
  - Use `::group::` per owned subprocess.
  - When `CI=true`, strip ANSI, drop the `stdout:` line prefixes, and print a
    heartbeat at most every 5 min.
  - Print workspace-relative paths, not `/Users/runner/work/...`.
- **Test report.** One JUnit report per job, rendered in the summary, plus a
  coverage table.
- **Artifacts.** Stable names (`test-results-<job>`, `evidence-<job>` uploaded
  only on failure, retention 14 days). Unsigned build outputs from `main` are
  attached to the run.
- **Release summary.** Version, commit, every asset with size and digest,
  attestation links, TestFlight build number, Homebrew PR or commit.
- **Job names.** Short and stable (`go`, `kotlin`, `apple / mac`,
  `apple / ios`), with no reusable-workflow ID chains.

### Speed and reliability

- **Targets.** Non-native PR feedback in under 10 min. With globals removed,
  `t.Parallel` and e2e split out, `go` (L0+L1) should drop from ~12 min to
  under 5.
- **iOS:**
  - Move iPad and `full` flows to nightly.
  - Build once and run flows separately.
  - Quarantine the current flaky flows with owners until main is reliably green.
  - It is 6 of the last 8 main failures and the 49-min critical path.
- **Caching:**
  - Drop `github.sha` from the Apple cache key; today every run saves a new
    multi-GB entry.
  - Save on main only, with restore-only caches on PRs, and Gradle read-only
    on PRs.
  - Cache the Android system image.
  - Use a shallow checkout plus tags instead of `fetch-depth: 0`.
- **Timeouts.** Every job gets `timeout-minutes`. Currently `changes`,
  `required`, `reserve` and both pages jobs have none.

### Security

- **Builders vs publishers.** Builders run with `contents: read` and upload
  artifacts. Small publish jobs hold write tokens and `id-token`. Today a
  write-scoped `GH_TOKEN` sits next to Gradle/Xcode/npm and signing secrets.
- **Provenance.** `actions/attest-build-provenance` and SBOMs (syft) for every
  release asset, not only the gateway image.
- **Repository hygiene:**
  - Dependabot for actions, gomod, gradle, npm, bundler and swift.
  - Version comments on all SHA pins.
  - `persist-credentials: false`.
- **Fork guards.** Every publish, deploy and TestFlight job gets
  `if: github.repository == 'dbpprt/dieter'`. Today a fork's main push starts
  the release and fails.

---

## 9. Releases

| Today                                                                                                                                         | Proposed                                                                                                                                                                                                                                                                           |
| --------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Every main push → version reservation, 9 signed candidates, public prerelease, TestFlight (41–94 min, 324 tags)                               | `main` builds unsigned artifacts only. **Nightly** (if main changed and is green) plus on-demand dispatch cut a dev prerelease and TestFlight build.                                                                                                                               |
| Custom ledger: identity tags, `pipeline-claims/*` lock tags (two already leaked to origin), receipts, artifact API recovery (~1,200 LOC Ruby) | `concurrency: release-<version>` and GitHub immutable releases replace the claim locks. Retained producer bytes stay as workflow artifacts. Keep the identity tag but drop the claim refs.                                                                                         |
| Promotion verifies a literal `"qualification" => "passed"` (`candidate.rb:113`)                                                               | The release records the qualifying CI run ID and attestation. Promotion verifies the attestation.                                                                                                                                                                                  |
| Boilerplate notes ("Development build from …"), stable has no body                                                                            | `.github/release.yml` categories from PR labels for dev. A curated `CHANGELOG.md` section for stable, checked in the promotion job.                                                                                                                                                |
| Personal names hardcoded in Ruby (`dbpprt/homebrew-tap`, `ghcr.io/dbpprt`, team, bundle IDs)                                                  | Read from the identity file (§5) and repository variables.                                                                                                                                                                                                                         |
| Updaters and `install.sh` trust `(release\|release-coordinate).yml@refs/heads/main`                                                           | **Freeze one signer identity as a public contract** (`release.yml@refs/heads/main`) and document it in SECURITY.md. Add a test that fails if the signing workflow path changes. This rename happens once, together with a floor bump, so installed updaters are told to reinstall. |

Unchanged: one SemVer across all components, gateway floors, promotion of exact
bytes, cosign-signed `SHA256SUMS`, and notarized macOS artifacts.

Consider these additions:

- Build-time GoReleaser for the Linux daemon/gateway archives, checksums,
  SBOMs and the Homebrew formula. This needs a spike to confirm it can carry
  the signed darwin helper bundle; otherwise keep it in `tools/pipeline`.
- A DMG for the Mac app.

---

## 10. Open-source readiness

### Documentation structure

- **`README.md` (~100 lines):** what Dieter is, a screenshot, install, a
  60-second quickstart, links.
  - Lines 30–50, 134–145 and 226–321 move to site docs. They cover model
    routes, relay internals, causal frontiers and similar topics.
- **`site/content/docs`:** the user documentation, the single home for install,
  gateway self-hosting, the generated CLI reference, and harness setup.
- **`docs/` (contributors):**
  - `architecture.md`
  - `invariants.md`, moved out of AGENTS.md so humans read it as the source
  - `threat-model.md`, which is new and must cover a compromised gateway,
    malicious peers, and prompt injection against unsandboxed agents
  - `building.md`, covering plain Go/Gradle/SwiftPM builds, local-only
    unenrolled mode, and a quick local dev gateway
  - `testing.md`
  - `releasing.md`
  - `adr/`
- **`AGENTS.md`:** agent operating rules that link to `docs/invariants.md`.
  It drops device-tapping recipes, which move to `.agents/skills`.
- **`apps/core/README.md` (38 KB with a migration tracker):** trimmed to
  structure, build and test.

### Community and legal

- `CODE_OF_CONDUCT.md`, `CODEOWNERS`, `ISSUE_TEMPLATE/config.yml`, `.mailmap`,
  labels, repo description, topics and homepage.
- **`THIRD_PARTY_NOTICES`:** generated from `third_party/*`, the Material
  icons, Sora (OFL, deduplicated from 3 copies) and the JS bundle licences.
- **`TRADEMARKS.md`:** the name and logo are not MIT.
- **DCO** (`Signed-off-by`, checked in CI) for new contributions.
- **Main becomes PR-only** with squash merges. Agents open PRs instead of
  pushing to main. This is what makes CODEOWNERS, DCO and generated release
  notes work.

---

## 11. Execution plan

Ordering logic: blockers and noise first. Then an honest, fast CI. Then
mechanical moves in short freeze windows. Then deep refactors domain by domain,
each landing green. Sizes assume one maintainer working with agents.

### Phase 0 — fix now and decide (S, 1–2 days)

**Live bugs and blockers:**

1. **Apple team pin mismatch.** The release policy signs with `FNGU8JFNPL`, but
   `scripts/install.sh:215,223` and
   `native/macos-capture/PrivacyHIDProtocol.swift:23` accept only `DS6N5L85E7`.
   Unless something overrides this, current macOS curl installs fail
   verification and the privacy helper rejects new-team clients.
   - Fix it, and make the pin come from the identity file.
2. **Default model.** Replace the private `tailscale/glm-5.3-flash-exl3`
   default (`config/harnesses.yaml:181,204`, `omp-models.mjs:2`, README,
   SKILL.md, site docs).
3. **Security and issue channels.** Enable private vulnerability reporting and
   Issues (SECURITY.md currently points to dead channels).
4. **Ops runbooks.** Remove the two owner ops runbooks from `docs/` and the
   names in `apps/ios/README.md`.
5. **Fork guards.** Add them to publishing workflows.
6. **Release cadence.** Switch dev releases from every push to nightly plus
   dispatch. This immediately removes most red-main noise and TestFlight churn.
7. **Error mapping.** Unknown server errors become `Internal`, not
   `InvalidArgument`.
8. **Go test timeout.** Add `-timeout 20m` until the suite is faster.

**Branch and tag cleanup** (needs owner confirmation; outward-facing):

- Prune the 48 remote branches and the leaked `pipeline-claims/*` tags.
- Delete the local `pre-open-source-history-2026-08-17` branch.
- Don't rewrite `main` history: nothing secret is in it, and it is already
  forked.

**Decisions needed:** see §12.

**Exit:** main green on the new cadence; SECURITY channels work.

### Phase 1 — honest CI (M, ~1 week)

- `ci.yml` with plan matrix and `ci-ok` gate.
- JUnit from Go, Gradle, Swift, Node, Ruby and Python, plus one reporter.
- Annotations, log groups, ANSI stripping, job summaries.
- Timeouts on every job.
- Caching fixes.
- Swift test-count guard.
- Formatting and gitleaks enforced in CI.
- Dependabot, CodeQL and dependency review.
- iOS quarantine.

**Exit:** a failing test is visible as an annotation on the PR; the non-native
PR path takes under 15 min; 10 consecutive green main runs.

### Phase 2 — repository layout (M, ~1 week, freeze windows per area)

- Moves table (§3).
- One Gradle build and the Apple package split.
- buf and `just generate`, with a drift check.
- `third_party/`.
- The identity file.
- `site/`.
- Docs restructure and README rewrite.
- Community files.

Each area moves in one mechanical commit with no behaviour changes, so
parallel agent sessions rebase once.

**Exit:** a fresh clone runs `go build ./cmd/...`, `go test ./...`,
`./gradlew -p apps/kotlin check` and `swift build` in DieterKit without Ruby;
no proto copies remain.

### Phase 3 — tooling consolidation (L, 2–3 weeks)

- Port planning, e2e orchestration, evidence and reporting to `tools/pipeline`.
  Port behaviour first: leases and journals carry over as-is with their tests.
- Trim Fastlane to `release/`.
- Delete the Python from `fastlane/` and `scripts/`.
- Split the build workflows by signing domain.
- Simplify the release ledger.
- Add attestations and real release notes.

**Exit:** Ruby only in `release/`, Python only in `deploy/gateway`; release
dry-run on PRs that touch release code.

### Phase 4 — Go modularization (L, 3–5 weeks, incremental)

Order:

1. Composition root and config.
2. Globals removal, then `t.Parallel` and testkit.
3. `fsx` and the single identity writer.
4. API handler split and the generated adapter.
5. Store split by aggregate.
6. Replication consolidation.
7. Git family merge.
8. depguard rules switched on as each boundary lands.
9. Proto step 1, then step 2 with a floor bump.

**Exit:** depguard enforces cli ↛ daemon internals; L0+L1 Go under 5 min in CI;
no `os.Getenv` outside config.

### Phase 5 — client modularization (L, 3–5 weeks, incremental)

- `DieterMacKit` library and feature folders.
- `DieterAPI` import boundary and burn-down.
- `MobileStore`/`ScreenSession` splits.
- `:core:e2e` with fixture reuse.
- Android shell tests.
- MarkdownPreview built, not committed.

**Exit:** Kotlin `check` without Go/Node under 2 min; Mac `DieterAPI`
references only in the adapter folder.

### Phase 6 — launch (S)

- Threat model and building docs reviewed.
- Repo metadata.
- First curated stable release with a changelog.
- Announcement.

### Risks

- **Rename churn against concurrent agent sessions.** Mitigation: per-area
  freeze windows, mechanical-only commits, and moves done by tool (`gopls`
  rename, `git mv`), not by hand.
- **Losing pipeline safety properties during the Go port.** Mitigation: port
  the existing specs first as the acceptance suite, and keep the device-lease
  and journal semantics byte-compatible.
- **Updater trust-root change.** Mitigation: do it once, in Phase 3, paired
  with a floor bump. Nothing renames the signer workflow afterwards.
- **Changing the Android `applicationId` orphans installed apps.** Mitigation:
  decide the namespace in Phase 0 and change it once.

---

## 12. Decisions needed

| #   | Decision                                                                                                                                                                                                                                     | Recommendation                                                                                                                                                                                     |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Replace Ruby/Python orchestration with a Go `tools/pipeline` and keep Fastlane only for Apple distribution. **This reverses the current AGENTS.md "Pipeline ownership" rules** (Fastlane-owned compositions, the facade-only workflow rule). | Yes                                                                                                                                                                                                |
| 2   | Dev releases nightly plus on demand instead of every main push                                                                                                                                                                               | Yes                                                                                                                                                                                                |
| 3   | Namespace: keep `github.com/dbpprt/dieter` or move to an org (`getdieter/dieter`). Unify app IDs on `com.getdieter.*`.                                                                                                                       | If an org move is plausible within a year, do it now: Go import path (341 files), updater trust roots and app IDs should change once. Otherwise unify on `com.getdieter.*` and keep the repo path. |
| 4   | Split `DieterService` into domain services with a floor bump (proto step 2)                                                                                                                                                                  | Yes, after step 1                                                                                                                                                                                  |
| 5   | PR-only `main` with squash merges, CODEOWNERS and DCO; agents open PRs                                                                                                                                                                       | Yes, from launch                                                                                                                                                                                   |
| 6   | Daemon officially macOS + Linux; delete Windows stubs                                                                                                                                                                                        | Yes                                                                                                                                                                                                |
| 7   | Vendored Swift packages in `third_party/` with patches, rather than maintained forks                                                                                                                                                         | `third_party/`; upstream the HighlighterSwift patch                                                                                                                                                |
| 8   | Rights for past contributions. 203 commits on `main` are authored under an employer address; legal confirmation is the owner's call.                                                                                                         | Obtain written confirmation before the launch announcement; DCO going forward                                                                                                                      |
