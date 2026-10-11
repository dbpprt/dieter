# Building Dieter

Every component builds and tests with its own toolchain from a fresh clone.
`just` recipes are short aliases for the same plain commands; use whichever you
prefer. Test layers and CI are described in [testing.md](testing.md).

## Set up tools

Command-line tools (Go, Node.js, Java 21, `just`, `protoc`, Hugo and the
linters) are pinned in [`mise.toml`](../mise.toml) and `mise.lock`; CI installs
the same versions. Install [mise](https://mise.jdx.dev/getting-started.html),
then from the repository root:

```sh
mise trust
just setup          # mise install + npm ci for the harness runtime
just hooks          # optional: run `just lint --staged` before each commit
```

In non-interactive shells (scripts, agents) prefix commands with `mise exec --`,
for example `mise exec -- just test`.

mise does not install platform SDKs. Install only what your change needs:

| Component                | Needs                                                                                                                     |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------- |
| Daemon, CLI, gateway     | Go and Node.js 22.19+ with npm (both from mise), Git                                                                      |
| Kotlin core, Android app | Java 21 (mise), Android SDK with platform 37.1 (`ANDROID_HOME` or `sdk.dir` in an ignored `apps/kotlin/local.properties`) |
| macOS and iOS apps       | Xcode 26.5+ on Apple Silicon; an iOS simulator runtime for iOS                                                            |
| Website                  | Hugo extended (mise)                                                                                                      |
| Gateway deployment tests | Docker with Buildx (Docker Desktop, OrbStack or colima)                                                                   |

Without mise, install the versions named in `mise.toml` yourself; Android
Studio's bundled JBR works as Java 21.

## Command surface

| Command                                                          | Does                                                                         |
| ---------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `just setup`                                                     | Install pinned tools and the harness runtime's npm dependencies              |
| `just build`                                                     | Build `bin/dieter` and `bin/dieter-gateway` (`go build ./cmd/...`)           |
| `just test`                                                      | Go unit and component tests (`go test ./...`)                                |
| `just test-e2e`                                                  | Go end-to-end tests (`go test -tags e2e ./...`)                              |
| `just lint` / `just lint --staged`                               | All formatters and linters in check mode, for the tree or the staged files   |
| `just fmt`                                                       | Rewrite formatting                                                           |
| `just generate`                                                  | Regenerate identity constants and protobuf code; CI fails on drift           |
| `just check-changed [--base REF] [--dry-run]`                    | Run the checks affected by your changes                                      |
| `just kotlin <gradle tasks>`                                     | `./gradlew -p apps/kotlin <tasks>`                                           |
| `just framework`                                                 | Assemble `apps/apple/Frameworks/DieterCore.xcframework` from the Kotlin core |
| `just mac …`, `just ios …`                                       | Build, test and run the Apple apps (`just --list` shows the actions)         |
| `just e2e <android\|ios\|mac> [tags:smoke\|full] [flows:NAME,…]` | Maestro device flows against an isolated fixture                             |
| `just site serve\|build\|check`                                  | Preview, build or link-check the website                                     |
| `just hooks`                                                     | Install the pre-commit hook                                                  |
| `just pipeline <lane> …`                                         | Run a Fastlane lane directly (signing, packaging, releases)                  |

## Daemon, CLI and gateway (Go)

```sh
npm --prefix internal/harness/runtime ci   # once; the harness runtime is embedded
go build -o bin/ ./cmd/...                 # or: just build; writes bin/dieter and bin/dieter-gateway
go test ./...                              # or: just test
go test -tags e2e ./...                    # or: just test-e2e
```

The daemon targets macOS and Linux only. `go vet` and the boundaries in
`.golangci.yml` run as part of `just lint`. The package layout is described in
[architecture.md](architecture.md#go-packages).

### Run a local-only daemon

A daemon works without a gateway: it serves its loopback API, runs agents and
answers the CLI, but native apps (which sign in through a gateway) cannot reach
it. Always use a temporary `DIETER_HOME` and a free port so you never touch an
installed daemon on `127.0.0.1:4242`:

```sh
export DIETER_HOME="$(mktemp -d)"
bin/dieter serve --addr 127.0.0.1:4343 &    # foreground daemon; Ctrl-C or kill to stop
bin/dieter status
bin/dieter project open ~/src/some-repo
bin/dieter harness list
```

The CLI finds the daemon through the runtime status in `DIETER_HOME`. Pass a
concrete port: the runtime status records the address as given.

### Run a local gateway

For client work, the fixture gateway starts a disposable gateway plus an
enrolled daemon with the deterministic mock harness, on loopback, with no GitHub
or provider accounts:

```sh
go run ./tools/fixtures/gateway -e2e-fixture
```

It prints `DIETER_ISOLATED_*` values (address, session token, daemon, project,
board) and then `READY`, and keeps running until interrupted. Its state lives in
a fresh temporary directory unless `-home` is given. The Kotlin `:core:e2e`
tests, the Mac fixture suites and the Maestro flows all use it.

To try the real sign-in flow, run `dieter-gateway` in development mode with a
GitHub OAuth app whose callback is `http://127.0.0.1:4243/auth/github/callback`:

```sh
export DIETER_GATEWAY_HOME="$(mktemp -d)"
DIETER_GATEWAY_DEV_INSECURE=1 DIETER_PUBLIC_URL=http://127.0.0.1:4243 \
DIETER_GITHUB_CLIENT_ID=… DIETER_GITHUB_CLIENT_SECRET=… \
DIETER_GITHUB_ALLOWED_USER_IDS=YOUR_NUMERIC_GITHUB_ID \
DIETER_AUTH_SECRET="$(openssl rand -hex 32)" \
bin/dieter-gateway
```

Development mode allows plain HTTP on loopback and development compatibility
floors; never expose it. Enroll a disposable daemon against it with
`DIETER_HOME=… bin/dieter daemon enroll --gateway http://127.0.0.1:4243`. To run
a real gateway, follow the [self-hosting guide](../site/content/docs/gateway.md)
and the [deployment bundle](../deploy/gateway/README.md). All variables are
listed in [reference/environment.md](reference/environment.md).

## Kotlin core and Android app

```sh
just kotlin :core:runtime:jvmTest :ui:jvmTest                      # unit tests, no Go or Node
just kotlin :core:e2e:test                                          # end-to-end against the fixture gateway
just kotlin :android:assembleDebug :android:assembleE2e :android:lintDebug
```

`just kotlin` is `./gradlew -p apps/kotlin`. The first Kotlin/Native build
downloads about 1.6 GB into `~/.konan`. Run Gradle builds one at a time. APKs
land in `apps/kotlin/android/build/outputs/apk/<type>/`. Details:
[apps/kotlin/README.md](../apps/kotlin/README.md).

## macOS and iOS apps

```sh
just framework                                   # DieterCore.xcframework from the Kotlin core
swift test --package-path apps/apple/DieterKit
swift build --package-path apps/apple/mac
swift test --package-path apps/apple/mac --no-parallel
swift test --package-path native/macos           # daemon-side capture and privacy helpers
```

`just mac …` and `just ios …` wrap the app builds, tests and launches. The iOS
app builds with `xcodebuild` for a simulator without signing. Never launch an
app copy while an operator's `Dieter.app` runs; see
[apps/apple/README.md](../apps/apple/README.md) for the exact commands, signing
settings and the iOS project.

Linux screen capture is a separate C helper: `native/linux-capture/build.sh`.

## Website

```sh
just site serve     # http://127.0.0.1:1313
just site check     # build, then check links, anchors, images and search
```

The site is plain Hugo (`hugo --source site`); see [site/README.md](../site/README.md).

## Generated code

`just generate` regenerates everything derived from a checked-in source: the
identity constants from `config/identity.json`, Go and Connect code in
`internal/gen` from `api/proto`, and the committed Swift API in
`apps/apple/DieterKit`. Kotlin generates its protobuf models during the Gradle
build. Commit regenerated files with the change that caused them; CI fails when
they drift.

Regenerate the [CLI reference](../site/content/docs/reference/cli.md) after
changing command help:

```sh
go run ./tools/clidocs -o site/content/docs/reference/cli.md
```

The page keeps a short Hugo front matter block at the top; restore it if the
generator overwrites it (see the comment in that file).

## Identity

[`config/identity.json`](../config/identity.json) is the single source of a
build's distribution identity:

| Field                                | Used for                                                                                                                                                                     |
| ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `product`                            | Display name                                                                                                                                                                 |
| `bundle_prefix`                      | Every app, extension, keychain, launchd and socket identifier (`<prefix>.mac`, `<prefix>.ios`, `<prefix>.android`, `<prefix>.daemon`, …) and the E2E app IDs (`.e2e` suffix) |
| `apple_team_id`                      | Apple signing team, and the only team the daemon and privacy helper trust                                                                                                    |
| `repository`                         | Update feed, release downloads and the release signer identity (`https://github.com/<repository>/.github/workflows/release.yml@refs/heads/main`)                             |
| `default_gateway`                    | Gateway host that `dieter setup` and the apps offer by default                                                                                                               |
| `homebrew_tap`, `container_registry` | Release destinations                                                                                                                                                         |
| `testflight_groups`                  | TestFlight groups that receive builds                                                                                                                                        |

`just generate` (`go run ./tools/identity`) renders it into Go
(`internal/platform/buildinfo`), Kotlin, Swift, Xcode configuration and the
release tooling; `go run ./tools/identity -check` fails on drift. The output
table in `tools/identity/main.go` lists every generated file.

### Forking

A fork that distributes its own builds must use its own identity:

1. Edit `config/identity.json`: your bundle prefix, Apple team, repository,
   gateway host, tap and registry.
2. Run `just generate` and commit the regenerated files.
3. Run your own gateway (the default gateway only admits its allowlisted
   accounts) and configure release secrets in your repository.

Changing the identity is a clean break: installed apps, keychain items and
services of another identity are not migrated. The Dieter name and logo are not
licensed for forks; see [TRADEMARKS.md](../TRADEMARKS.md).
