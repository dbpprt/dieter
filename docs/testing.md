# Testing

Tests run with each component's own toolchain; `just` only names them. How to
install the toolchains is in [building.md](building.md).

## Layers

| Layer         | Go                                                                     | Kotlin                                    | Swift                                         | Devices                                              | Runs                                  |
| ------------- | ---------------------------------------------------------------------- | ----------------------------------------- | --------------------------------------------- | ---------------------------------------------------- | ------------------------------------- |
| L0 unit       | `go test ./...`                                                        | `commonTest`, `jvmTest`, `macosArm64Test` | `DieterKit`, `DieterMacTests`, `native/macos` | —                                                    | Every PR                              |
| L1 component  | in-process topologies (`internal/testkit/topology`) in the default run | —                                         | —                                             | —                                                    | Every PR                              |
| L2 end-to-end | `go test -tags e2e ./...`                                              | `:core:e2e` against the fixture gateway   | fixture-gated suites                          | —                                                    | PRs that affect them, `main`, nightly |
| L3 device     | —                                                                      | —                                         | —                                             | Maestro flows: `smoke` when affected, `full` nightly | see below                             |
| L4 hardware   | opt-in `DIETER_TEST_*` suites                                          | —                                         | screen runners                                | real displays, GPUs, phones                          | manual                                |

`just check-changed` runs the checks your working tree affects and lists the
device checks separately; add `--base origin/main` for a whole branch and
`--dry-run` to see the plan first. The required pull-request check is `ci-ok`,
which aggregates every selected CI job.

To rerun only Release iPhone verification after diagnosing an iOS CI failure:

```sh
gh workflow run ci.yml --ref main -f ios_only=true
```

This runs the iPhone build and smoke flows, overrides `full`, and skips unrelated
components. Pull requests and main pushes keep their usual affected-check
selection. The job allows for the cold Kotlin/Native and Xcode builds before the
unchanged 25-minute Maestro deadline.

## Go

```sh
just test                                 # go test ./...  (L0 + L1)
just test-e2e                             # go test -tags e2e ./...
go test -race ./internal/engine/...       # one package, with the race detector
```

- **Where tests go.** Next to the code, as `*_test.go`. Name end-to-end files
  `*_e2e_test.go` and give them `//go:build e2e`; they start real gateways,
  daemons or processes and take longer.
- **Parallel by default.** New tests call `t.Parallel()` unless they use
  `t.Setenv`, `os.Chdir` or process-wide state. Packages hold no mutable
  globals, so two daemons can run in one test process.
- **Fixtures.** Use `internal/testkit` instead of hand-built setups:
  `testkit.Home(t)` and `testkit.Store(t)` for an isolated `DIETER_HOME`,
  `testkit.GitRepo(t)` and `testkit.RunGit` for repositories,
  `testkit.FakeRunner` and `testkit.MockCatalog()` for harnesses, and
  `testkit.Eventually` (race-scaled budgets) instead of sleeps.
  `internal/testkit/topology` starts an in-process gateway with enrolled
  daemons that share one device roster, sessions and relay tunnels.
  `Gateway.NewClient` pairs a test app device (a software P-256 key) through the
  production pairing path, so tests dial daemons over the same mutual TLS as
  the apps. Packages that `testkit` itself imports (store, harness and their
  dependencies) keep local helpers to avoid cycles.
- **Time.** Do not poll the wall clock or sleep to wait for an effect. Inject a
  clock, wait on an observer (for example `scheduler.Manager.OnRunSettled`), or
  use `testkit.Eventually`.
- **Opt-in suites.** Tests that need real hardware, real providers or long runs
  skip unless a `DIETER_TEST_*` variable enables them (for example
  `DIETER_TEST_CAPTURE_HELPER`, `DIETER_TEST_SCREEN_CAPTURE_REAL`,
  `DIETER_TEST_LINUX_CAPTURE_REAL`). See
  [reference/environment.md](reference/environment.md#fixtures-and-tests).

For concurrent-turn storage measurements, run
`DIETER_TEST_CONGESTION=1 go test ./internal/engine -run '^TestConcurrentTurnWriterCost$' -count=1 -v`.
It uses a 100-card isolated store and measures 1, 8 and 16 streaming turns after
fixture setup and admission. Run it separately from compilation and other
suites. The end-to-end `TestConcurrentTurnsStayResponsiveAcrossRoutes` in
`internal/testkit/topology` additionally covers local, direct TLS and relay
admission, watches, concurrent edits, peer exchange and cold journal replay.

### Contract tests

These keep the product surfaces in step. Never weaken them to land a change:

| Test                                                                                                                                              | Guards                                                                  |
| ------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `TestGRPCAPIImplementsEveryDeclaredRPC` (`internal/api`)                                                                                          | Every RPC in the schema is implemented by exactly one domain handler    |
| `TestEveryDaemonRPCMapsToCLICommand`, `TestEveryRPCCommandIsDocumented` (`internal/cli`)                                                          | Every RPC has a CLI command, and that command is a documented help path |
| `TestEveryDaemonCLICommandHasOfflineHelp`, `TestCommandTableDispatchesNamesAndAliasesOnly`, `TestReferenceCoversTheCommandTable` (`internal/cli`) | The command table drives dispatch, help and the generated reference     |
| `go run ./tools/identity -check`                                                                                                                  | Committed identity constants match `config/identity.json`               |
| `go test ./tools/brandcheck`                                                                                                                      | Brand assets exist once and every product uses them                     |
| Maestro flow lint (in `just check-changed`)                                                                                                       | Every flow parses and only uses supported commands                      |
| `TestGatewayRelaysButNeverSeesContent`, `TestDaemonsAndClientsRefuseUntrustedPeersThroughTheGateway` (`internal/testkit/topology`, `-tags e2e`)   | The gateway relays only ciphertext and cannot impersonate a device      |

## Kotlin

```sh
just kotlin :core:runtime:jvmTest :ui:jvmTest           # pure unit tests, seconds, no Go/Node
just kotlin :core:runtime:macosArm64Test :core:apple:macosArm64Test
just kotlin :core:e2e:test                               # needs Go and the harness runtime
```

Rules live in the core, so their tests do too: put them in `commonTest` beside
the rule. `:core:e2e` builds `tools/fixtures/gateway` once and starts a fresh
gateway and daemon with a temporary home and random ports for each test. iOS
simulator tests need a caller-provided simulator:
`just kotlin :core:runtime:iosSimulatorArm64Test -Pdieter.simulator=<UDID>`.

### Pairing in fixtures

Machines answer only trusted devices, so every fixture client pairs. The fixture
gateway starts the device roster on its primary daemon, pairs its other
daemons, and prints one pairing code, `DIETER_ISOLATED_PAIRING_CODE`, before
`READY`. Its primary daemon keeps approving every request that proves that code,
exactly as `dieter device approve` does. Clients receive the code in
`AdoptSession.pairing_code` (fixtures only; the Mac app reads it from
`--dieter-pairing-code-file`) and use it instead of a random one. Everything else
is the production path: the client still verifies the approver's confirmation
before it pins the roster.

## Swift

```sh
swift test --package-path apps/apple/DieterKit
swift test --package-path apps/apple/mac --no-parallel
swift test --package-path native/macos
```

`DieterMacTests` runs serially because several suites own process-wide state.
A test that stops the main run loop can end the run early with exit status 0,
so always read the reported test count. Fixture-backed suites skip unless the
fixture gateway's `DIETER_ISOLATED_*` values are set; the release pipeline sets
them.

## Device flows (Maestro)

```sh
just e2e android profile:android-emulator
just e2e ios
just e2e mac
just e2e ios tags:full profile:ios-ipad
just e2e android profile:android-emulator flows:task
```

Each run builds the app it tests, starts one isolated fixture gateway, installs
the separate E2E app (`com.getdieter.android.e2e`, `com.getdieter.ios.e2e`) and
runs the selected flows. iOS creates and deletes its own simulator; Android
borrows a running emulator or uses a phone only when the profile names its exact
serial; the Mac run refuses while any `DieterMac` process runs. Flows, tags and
how to write fast flows: [tests/maestro/README.md](../tests/maestro/README.md).

Favour speed over completeness: add a device flow only for a journey that unit
tests cannot cover, and keep assertions about rules in Kotlin unit tests.

## Cross-language fixtures

Golden vectors shared by Go, Kotlin and Swift live in `tests/fixtures` (for
example `board-lifecycle.tsv`, read by `internal/store/kanban` and the Kotlin
`BoardLifecycleTest`, and `roster/vectors.json`, the device roster's encoding,
hashes, device IDs, pairing codes and MACs, read by
`internal/security/roster`, the Kotlin `RosterVectorsTest` and DieterKit's
`DeviceTrustTests`). Go generates or validates them; the clients load them as
test resources. Change the producer and every consumer in one change.

## Safety

Tests must never touch the operator's environment:

- Never stop, restart, replace or install over a running daemon or app. Use
  temporary `DIETER_HOME` roots, random loopback ports (pass a concrete port to
  `dieter serve`), isolated gateways and disposable credentials.
- Use only devices and processes the test started. Never auto-select a phone,
  wipe emulator data or kill unrelated processes to repair a run.
- Missing, skipped or unavailable required assertions and cleanup failures fail
  the gate. Keep failed evidence for diagnosis.

## Flaky tests

A flaky test is a bug in the test or the product. Do not add retries, longer
sleeps or relaxed assertions to make it pass. Reproduce it alone (for example
`go test -run TestName -count=50 -race ./pkg`), fix the race or the missing
synchronization, and say in the pull request what caused it. If a fix cannot
land at once, skip the test with a link to an issue that names an owner and an
expiry date, and keep that list short.
