---
title: "Development"
linkTitle: "Development"
description: "Build the component you need, run the affected checks, and contribute a focused change."
group: "Contribute"
weight: 50
slug: "development"
---

Dieter is MIT-licensed and developed in the open on
[GitHub](https://github.com/dbpprt/dieter). Contributor documentation lives in
the repository, next to the code it describes.

## Get started

```sh
git clone https://github.com/dbpprt/dieter.git
cd dieter
mise trust
just setup          # pinned tools and the harness runtime
just build          # bin/dieter and bin/dieter-gateway
just test
```

Tools are pinned in `mise.toml`; platform SDKs (Xcode, the Android SDK) are
installed separately and only for the component you change. The
[building guide](https://github.com/dbpprt/dieter/blob/main/docs/building.md)
covers prerequisites, every component, a local-only daemon, a local gateway and
forking.

| You want to…                           | Read                                                                                |
| -------------------------------------- | ----------------------------------------------------------------------------------- |
| Send a change                          | [CONTRIBUTING.md](https://github.com/dbpprt/dieter/blob/main/CONTRIBUTING.md)       |
| Find your way around                   | [Architecture](https://github.com/dbpprt/dieter/blob/main/docs/architecture.md)     |
| Know the rules every change keeps      | [Invariants](https://github.com/dbpprt/dieter/blob/main/docs/invariants.md)         |
| Pick and run tests                     | [Testing](https://github.com/dbpprt/dieter/blob/main/docs/testing.md)               |
| Understand the security boundaries     | [Threat model](https://github.com/dbpprt/dieter/blob/main/docs/threat-model.md)     |
| Work on the Kotlin core or Android app | [apps/kotlin](https://github.com/dbpprt/dieter/blob/main/apps/kotlin/README.md)     |
| Work on the Mac or iOS app             | [apps/apple](https://github.com/dbpprt/dieter/blob/main/apps/apple/README.md)       |
| Write device flows                     | [tests/maestro](https://github.com/dbpprt/dieter/blob/main/tests/maestro/README.md) |
| Edit this website                      | [site](https://github.com/dbpprt/dieter/blob/main/site/README.md)                   |
| Cut a release                          | [Releasing](https://github.com/dbpprt/dieter/blob/main/docs/releasing.md)           |

## Repository map

| Directory         | Contents                                                                  |
| ----------------- | ------------------------------------------------------------------------- |
| `cmd`, `internal` | Daemon, CLI, gateway, storage, transports, harness integration (Go)       |
| `api/proto`       | The authoritative RPC schema                                              |
| `apps/kotlin`     | Shared Kotlin client core, the Android/iOS Compose UI, the Android app    |
| `apps/apple`      | Shared Swift package, the macOS app, the iOS app                          |
| `native`          | Daemon-side screen capture, input and privacy helpers                     |
| `third_party`     | Vendored packages with their patches                                      |
| `deploy`          | Gateway deployment bundle and the Linux installer                         |
| `tests`           | Maestro device flows and cross-language fixtures                          |
| `tools`           | Identity generator, fixture gateway, CLI reference generator, brand check |
| `fastlane`        | Native app builds, signing and distribution                               |
| `site`            | This website                                                              |
| `docs`            | Contributor documentation and design records                              |
| `assets/brand`    | The brand source: logo, icons, font, colors                               |

## Check your change

```sh
just check-changed --dry-run    # what would run, and why
just check-changed              # run the affected checks
just lint
```

The selection includes uncommitted changes; add `--base origin/main` for a
whole branch. Device flows are listed separately; run the relevant one with
`just e2e <android|ios|mac>`. Pull requests need the `ci-ok` check.

Never stop, restart or install over a daemon or app that is already running on
your machine to test a change. Use a temporary `DIETER_HOME`, a free loopback
port and the fixture gateway, as the building guide shows.

## Change an operation

A native-client operation is declared in `api/proto`, implemented by a domain
handler in `internal/api`, and exposed by a CLI command with offline help in
`internal/cli`, in the same change. Contract tests fail when one of those is
missing. Run `just generate` after schema changes and regenerate the
[CLI reference](/docs/cli-reference/) after help changes.
