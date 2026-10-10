---
title: "Development"
linkTitle: "Development"
description: "Build the component you need, run affected checks, and contribute a focused change."
group: "Contribute"
weight: 50
slug: "development"
---

## Get the source

```sh
git clone https://github.com/dbpprt/dieter.git
cd dieter
```

Install [mise](https://mise.jdx.dev/getting-started.html) 2026.10.2+ for shared
command-line tools on macOS and Linux. The repository tracks versions in
[mise.toml](https://github.com/dbpprt/dieter/blob/main/mise.toml) and
[mise.lock](https://github.com/dbpprt/dieter/blob/main/mise.lock). See the
[pipeline setup guide](https://github.com/dbpprt/dieter/blob/main/fastlane/README.md#setup-and-machine-configuration)
for Java path configuration and shell activation. Native SDKs remain separate:

| Component        | Toolchain                                    | Build / guide                                                                      |
| ---------------- | -------------------------------------------- | ---------------------------------------------------------------------------------- |
| Daemon / gateway | Go                                           | `just build`                                                                       |
| macOS            | macOS 26+, Xcode 26.5+                       | [Mac guide](https://github.com/dbpprt/dieter/blob/main/apps/mac/README.md)         |
| Android          | Android SDK and Android Studio's bundled JBR | [Android guide](https://github.com/dbpprt/dieter/blob/main/apps/android/README.md) |
| iOS beta         | Xcode and Java; signing for physical devices | [iOS guide](https://github.com/dbpprt/dieter/blob/main/apps/ios/README.md)         |
| Website          | Hugo extended 0.164+                         | `just site serve`                                                                  |

```sh
mise trust
mise install --locked
mise run setup
mise exec -- just hooks
mise exec -- just pipeline config_init
mise exec -- just doctor
```

Build lanes print fresh evidence paths and `artifacts.json` product manifests. Published releases already contain their native
capture helpers; source screen-host development needs the relevant platform
helper dependencies. Local build lanes never replace an operator service.

## Repository map

| Directory                                         | Responsibility                                               |
| ------------------------------------------------- | ------------------------------------------------------------ |
| `cmd`, `internal`                                 | Daemon, CLI, gateway, storage, transports, harnesses         |
| `api/proto`                                       | Authoritative RPC schema and stable package namespaces       |
| `apps/core`                                       | Shared Kotlin client core and the Android/iOS Compose UI     |
| `apps/mac`, `apps/ios`, `apps/android`            | Native clients and their fixtures                            |
| `native`                                          | Platform screen capture and WebRTC integration               |
| `config`                                          | Embedded harness registry                                    |
| `landingpage`                                     | Public website and maintained user guides                    |
| `deploy/gateway`                                  | Signed gateway deployment tooling                            |
| `fastlane`, `internal/pipeline`, `tools/fixtures` | Shared pipelines, typed contracts and isolated test services |
| `just`, `scripts`                                 | Thin command facade and generated-code/distribution tools    |

## Run checks for your change

```sh
just check-changed --dry-run
just check-changed
```

The default includes staged, unstaged, deleted, renamed, and untracked changes.
Use `--base origin/main` to include branch changes since the merge base. The dry
run lists the exact affected checks. Markdown-only changes skip application tests;
website implementation changes build the site. `just site check` additionally
validates rendered links, fragments, images, and repository documentation links.

Go changes select race tests and vet for affected packages and reverse dependencies.
Native changes select the relevant app's unit tests; app/shared schema/fixture
changes also select related integration checks. Tests stop on the first failure.

Explicit full validation remains available:

```sh
just check
just pipeline core_test
just pipeline mac test_unit
just pipeline android test_unit
just pipeline android e2e profile:android-emulator
just pipeline ios e2e profile:ios-iphone
just pipeline ios e2e profile:ios-ipad
```

Use `just pipeline lanes` to discover component operations. Configure ignored
`fastlane/local.json` from its tracked template for emulator or exact physical
device targets. The same lanes run locally and in CI. Main releases are dev
prereleases; stable promotion and production gateway admission are separate.

## Preserve running services

Never restart or install over an operator's daemon to test a change. Use temporary
Dieter roots, random loopback listeners, disposable credentials, and the existing
native smoke drivers. Mac smoke refuses to run beside a Dieter app. Android tests
must pin the selected emulator and preserve app data and saved connections.

If the integration environment is unavailable, report it explicitly. Do not
silently use a production account or stop somebody else's app to make a test pass.
The native platform guides document process, build-cache, and emulator lifecycle.

## Change release compatibility together

A native operation requires a declared protobuf RPC, an explicit `grpcAPI`
implementation, a thin Connect adapter, CLI parity, offline help, and route tests.
Regenerate bindings with `just proto`. Update user documentation, gateway floors,
and the CLI skill in the same change when older software becomes unsafe. Additive
changes do not raise the floors. Contract tests catch declared RPCs without
implementations.

Use `gofmt` for Go and the native formatter commands for their sources. Keep
accessibility and adaptive layouts intact.

## Contribute

Read [CONTRIBUTING.md](https://github.com/dbpprt/dieter/blob/main/CONTRIBUTING.md)
for bug reports and pull requests. Keep changes focused, explain the resulting
behavior, and report relevant validation and limitations. `git diff --check`
should pass before review.

Fastlane owns signed releases, Apple credentials, and TestFlight delivery. See
the [pipeline guide](https://github.com/dbpprt/dieter/blob/main/fastlane/README.md#ci-and-release-policy).
