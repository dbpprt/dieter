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

For Go and harness development, use Go **1.26.8+**, Node.js **22.19+**, npm, Git,
Python 3, and **just 1.58+**. Native and website toolchains are separate:

| Component | Toolchain | Build / guide |
| --- | --- | --- |
| Daemon / gateway | Go | `just build` |
| macOS | macOS 26+, Xcode 26.5+ | [Mac guide](https://github.com/dbpprt/dieter/blob/main/apps/mac/README.md) |
| Android | Android SDK and Android Studio's bundled JBR | [Android guide](https://github.com/dbpprt/dieter/blob/main/apps/android/README.md) |
| iOS beta | Xcode; signing for physical devices | [iOS guide](https://github.com/dbpprt/dieter/blob/main/apps/ios/README.md) |
| Website | Hugo extended 0.164+ | `just site serve` |

```sh
just doctor
bundle install
npm --prefix internal/harness/runtime ci
just pipeline config_init
just build
```

Build lanes print fresh evidence paths and `artifacts.json` product manifests. Published releases already contain their native
capture helpers; source screen-host development needs the relevant platform
helper dependencies. Local build lanes never replace an operator service.

## Repository map

| Directory | Responsibility |
| --- | --- |
| `cmd`, `internal` | Daemon, CLI, gateway, storage, transports, harnesses |
| `api/proto` | Authoritative RPC schema and stable package namespaces |
| `apps/mac`, `apps/ios`, `apps/android` | Native clients and their fixtures |
| `native` | Platform screen capture and WebRTC integration |
| `config` | Embedded harness registry |
| `landingpage` | Public website and maintained user guides |
| `docs` | Technical references, screenshot sources, historical investigations |
| `deploy/gateway` | Signed gateway deployment tooling |
| `fastlane`, `internal/pipeline`, `tools/fixtures` | Shared pipelines, typed contracts and isolated test services |
| `just`, `scripts` | Thin command facade and generated-code/distribution tools |

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
just pipeline mac test_unit
just pipeline android test_unit
just pipeline ios e2e profile:ios-iphone suite:smoke
just pipeline ios e2e profile:ios-ipad suite:smoke
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

Signed releases use the existing Just release recipes. Apple credentials and the
manual TestFlight workflow are documented in
[Apple release signing](https://github.com/dbpprt/dieter/blob/main/docs/apple-release-signing.md).
