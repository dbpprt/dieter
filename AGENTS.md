# AGENTS.md

Operating instructions for coding agents working in this repository. People
should read [CONTRIBUTING.md](CONTRIBUTING.md); the rules below apply to both.

## Binding rules

[docs/invariants.md](docs/invariants.md) is the source of the product
invariants (one release version, central `DIETER_HOME` storage, atomic writes
under the central lock, loopback-only raw API, a gateway that stores no project
data, bounded relays, one active turn per conversation, and more). They are
binding: do not work around them. If a task requires breaking one, stop and say
so. Read [docs/architecture.md](docs/architecture.md) before structural changes
and [docs/threat-model.md](docs/threat-model.md) before touching
authentication, transports, the vault, updaters or release signing.

## Repository map

| Path                                | Contents                                                                                       |
| ----------------------------------- | ---------------------------------------------------------------------------------------------- |
| `cmd/`, `internal/`                 | Go daemon, CLI and gateway; package map in [architecture.md](docs/architecture.md#go-packages) |
| `api/proto/`                        | The only RPC schema                                                                            |
| `apps/kotlin/`                      | One Gradle build: Kotlin core (`core/`), shared Compose UI (`ui/`), Android app (`android/`)   |
| `apps/apple/`                       | `DieterKit` (shared Swift package), `mac/` (macOS app), `ios/` (iOS app)                       |
| `native/`                           | Daemon-side helpers: `macos/` (SwiftPM capture, privacy, protocol), `linux-capture/`           |
| `third_party/`                      | Vendored packages, each with `PATCHES.md`; do not reformat                                     |
| `tests/maestro/`, `tests/fixtures/` | Device flows; cross-language golden vectors                                                    |
| `tools/`                            | `identity` (generator), `fixtures/` (fixture gateway, turn probe), `clidocs`, `brandcheck`     |
| `deploy/`                           | Gateway deployment bundle and image; Linux installer                                           |
| `fastlane/`                         | Native builds, signing, notarization, TestFlight (built-in Fastlane actions)                   |
| `site/`                             | Hugo website and the user documentation                                                        |
| `docs/`                             | Contributor documentation, ADRs, proposals                                                     |
| `config/identity.json`              | Distribution identity; everything derived is generated                                         |

Put client rules in the Kotlin core (`apps/kotlin/core`), never in an app or
the shared UI. Put user documentation in `site/content/docs` and contributor
documentation in `docs/`.

## Commands

Tools are pinned in `mise.toml`. In non-interactive shells run
`mise exec -- just …`. Each recipe wraps a plain command; see
[docs/building.md](docs/building.md#command-surface).

```sh
just setup                         # mise install + npm ci for the harness runtime
just build                         # bin/dieter, bin/dieter-gateway
just test                          # go test ./...
just test-e2e                      # go test -tags e2e ./...
just lint [--staged]               # every formatter and linter, check mode
just fmt                           # rewrite formatting
just generate                      # identity + protobuf code; CI fails on drift
just check-changed [--base REF] [--dry-run]
just kotlin <gradle tasks>         # ./gradlew -p apps/kotlin …
just framework                     # DieterCore.xcframework for apps/apple
just mac …   /   just ios …        # Apple app builds, tests, launches
just e2e <android|ios|mac> [tags:smoke|full] [flows:NAME,…]
just site serve|build|check
just hooks
just pipeline <fastlane lane> …    # signing, packaging, releases
```

Start every verification with `just check-changed --dry-run`, run the selected
checks once at the end of a change, and rerun only what failed or became newly
affected. Do not repeat full suites, all device flows or `tags:full` between
edits. Run Gradle and Xcode builds one at a time. `gofmt` Go files; run
`just fmt` before handing over. Regenerate with `just generate` after editing
`api/proto` or `config/identity.json`, and regenerate the CLI reference after
changing command help ([docs/building.md](docs/building.md#generated-code)).

## Safety

- **Never stop, restart, replace or install over the operator's running daemon
  or `Dieter.app`,** and never edit their `DIETER_HOME`. Tests and experiments
  use a temporary `DIETER_HOME`, a concrete free loopback port (never the
  default `127.0.0.1:4242`) and the fixture gateway
  (`go run ./tools/fixtures/gateway`). Stop only processes you started.
- **Devices.** Android phones are used only through a profile that names their
  exact serial; never auto-select a phone. iOS flows create and delete their
  own simulators; there is no physical-iPhone E2E. Device tests install the
  separate E2E apps (`com.getdieter.android.e2e`, `com.getdieter.ios.e2e`) and
  never the operator's apps. The Mac flows refuse to run while any `DieterMac`
  process runs.
- **Warm emulator.** Keep one Android emulator running as its own registered
  background process
  (`just pipeline android local action:emulator_run profile:android-emulator`)
  so runs borrow a booted device. If it shows a System UI "isn't responding"
  dialog, tap **Wait** (for example `uiautomator dump`, then `input tap` on its
  bounds) and force-stop only `com.getdieter.android.e2e`. Never wipe emulator
  data or kill unrelated processes to repair a run.
- **Evidence.** Missing, skipped or unavailable required assertions and cleanup
  failures fail the gate. Keep failed evidence; do not relax assertions to hide
  failures. If an integration environment is unavailable, report that instead
  of disrupting a running operator app.
- **Releases.** Do not publish releases, rotate signing material or activate
  production to test a change. Never rename `.github/workflows/release.yml`:
  installed updaters trust exactly that signer.

## Adding or changing an operation (CLI parity)

The `dieter` binary is the supported automation client. Every native-client
operation is available from the CLI, over the local route, verified direct TLS
and the gateway relay, in the same change:

1. Declare the RPC in its domain's service in `api/proto/dieter/v1/<domain>.proto`
   (e.g. `cards.proto` → `CardService`) and run `just generate`.
2. Implement it on the matching domain handler in `internal/api` (one file and
   handler type per proto service, mounted in `service.go`). Return errors with a
   `internal/platform/fault` kind; unknown errors become `Internal`.
3. Add the CLI command to the command table in `internal/cli/commands.go` with
   useful offline `--help` for the group and every leaf. The table drives
   dispatch, root help, the help contract and the generated
   [CLI reference](site/content/docs/reference/cli.md); regenerate that page.
   Global `--machine ID|NAME` must work: verified direct TLS first, then the
   authenticated bounded relay.
4. Map the RPC in `rpcCommand` (`internal/cli/help_contract_test.go`) and keep
   `TestGRPCAPIImplementsEveryDeclaredRPC` and the help-contract tests passing.
   Add operation tests and an end-to-end CLI test over local, direct-TLS and
   relay routes (`internal/testkit/topology`, `-tags e2e`).
5. Update [.agents/skills/dieter-cli/SKILL.md](.agents/skills/dieter-cli/SKILL.md)
   and the user guide in `site/content/docs` when behaviour, safety or output
   semantics change.

Remote execution lifecycle operations additionally need manager, local,
direct-TLS and relay coverage, and keep the bounds and semantics in
[invariants.md](docs/invariants.md#remote-execution).

## Skills

- [dieter-cli](.agents/skills/dieter-cli/SKILL.md): operate Dieter through the
  CLI. Prefer bounded context (`dieter card context CARD_ID`) and move your card
  with `dieter card move CARD_ID --lane review` when done.
- [dieter-pipelines](.agents/skills/dieter-pipelines/SKILL.md): builds, checks,
  device flows, CI and releases.
- [mac-app](.agents/skills/mac-app/SKILL.md): build, launch, inspect and close
  the Mac app safely.
