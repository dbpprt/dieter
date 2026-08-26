---
title: "Installation"
linkTitle: "Installation"
description: "Install the daemon and the native app with Homebrew on Apple Silicon, or build both binaries from source."
group: "Guides"
weight: 10
slug: "installation"
---

On Apple Silicon macOS, Homebrew installs the daemon and the native app as two
separate packages.

## Requirements

- Go 1.26.5 or newer *(source builds)*
- Node.js 22.19 or newer on each daemon host
- Git working trees for registered projects
- one configured harness login or API key
- macOS 15+ or Android 8+ for the official clients

The first agent turn installs the exact JavaScript harness runtime from
`internal/harness/runtime/package-lock.json` under `DIETER_HOME`.

## Install the daemon

The formula includes the `dieter` CLI and local daemon:

```sh
brew install dbpprt/tap/dieter
dieter setup ~/Development/my-project
```

`dieter setup` registers the Git working tree, enrolls the Mac, guides the macOS
Screen &amp; System Audio Recording permission, proves the exact signed
ScreenCaptureKit/VideoToolbox helper with one discarded frame, guides and
verifies Accessibility event-posting permission without moving or clicking the
pointer, enables viewing and control only after both probes succeed, and starts
the daemon as a Homebrew service.

Use `--skip-screen-sharing` during fresh setup on hosts that must not capture
their display. Re-run the standalone check at any time with:

```sh
dieter daemon permissions --check
```

## Install the Mac app

The cask installs `Dieter.app`:

```sh
brew install --cask dbpprt/tap/dieter-app
open -a Dieter
```

Sign in to the configured gateway. Dieter indexes every enrolled machine and
shows all of their projects together—there is no machine picker to babysit. The
same workspace is available from Android.

{{< callout type="tip" title="Upgrading" >}}
`brew upgrade dieter` updates the daemon in place. When upgrading from the old
manual LaunchAgent, `dieter setup` unloads it and preserves its plist with a
`.disabled` suffix before starting the Homebrew-managed service.
{{< /callout >}}

## Build from source

```sh
make build
```

This produces separate `bin/dieter` and `bin/dieter-gateway` executables. A
normal daemon machine installs only `dieter`; the public host installs only
`dieter-gateway`.

The macOS app builds via `apps/mac/scripts/build.sh` (producing
`apps/mac/build/Dieter.app`); Android builds via `apps/android/scripts/build.sh`
or a Gradle `installDebug`.

## Android

The Android client aggregates the same enrolled daemons and encrypts its gateway
session with a device-bound Android Keystore key. It auto-updates by checking the
latest `dbpprt/dieter` GitHub release for `Dieter-Android.apk`. See
`apps/android/README.md` for platform builds.

## Uninstall

Homebrew uninstall removes the service and binary but intentionally preserves
`DIETER_HOME`, so your projects, conversations, and schedules survive a
reinstall.
