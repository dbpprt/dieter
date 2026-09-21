---
title: "Installation"
linkTitle: "Installation"
description: "Install a signed Linux daemon service, use Homebrew on Apple Silicon, or build from source."
group: "Guides"
weight: 10
slug: "installation"
---

Dieter supports headless Linux daemon hosts and Apple Silicon macOS. The native
viewer clients are available for macOS and Android.

## Requirements

- Go 1.26.8 or newer *(source builds)*
- Node.js 22.19 or newer on each daemon host
- Git working trees for registered projects
- One configured harness login or API key
- macOS 26+ or Android 8+ for the official clients
- systemd user manager and cosign for managed Linux installation and updates

The first agent turn installs the exact JavaScript harness runtime from
`internal/harness/runtime/package-lock.json` under `DIETER_HOME`.

## Install the daemon

On Linux amd64/arm64, install cosign and run:

```sh
curl -fsSL https://github.com/dbpprt/dieter/releases/latest/download/install.sh | sh
dieter setup
dieter project open ~/Development/my-project
dieter doctor
```

The installer verifies the GitHub OIDC Sigstore signature and archive checksum,
then installs a private systemd user service when available. Linux hosts support
agents, projects, schedules, terminals, remote execution, telemetry, power
operations, and rollback-capable updates. Screen hosting requires an active
X11 or Wayland desktop and the dependencies in the
[Linux host guide](https://github.com/dbpprt/dieter/blob/main/docs/linux-support.md).
Use `--version`, `--install-dir`, or `--no-service` when the defaults do not fit
the host; `install.sh --help` documents their environment-variable equivalents.

On Apple Silicon macOS, Homebrew installs the daemon and app separately:

The formula includes the `dieter` CLI and local daemon:

```sh
brew install dbpprt/tap/dieter
dieter setup
dieter project open ~/Development/my-project
```

`dieter setup` enrolls the Mac and starts the daemon as a Homebrew service. It
never registers a project; `dieter project open PATH` is the explicit
registration step. Through that running service, setup guides the macOS Screen
&amp; System Audio Recording permission, proves the exact signed
ScreenCaptureKit/VideoToolbox helper with one discarded frame, and guides and
verifies Accessibility event-posting permission without moving or clicking the
pointer. Screen sharing is
automatically available after the required OS permissions are granted.

There is no screen-sharing enable switch. Unsupported/headless hosts report why
screen sharing is unavailable. Re-run the standalone check at any time with:

```sh
dieter daemon permissions --check
```

The Mac app separately requires Accessibility and Screen Recording for Dieter.app.
Its setup screen guides each grant and checks automatically when you return from
System Settings. App grants and daemon grants are separate.

## Install the Mac app

The cask installs `Dieter.app`:

```sh
brew install --cask dbpprt/tap/dieter-app
open -a Dieter
```

Sign in to the configured gateway. Dieter indexes every enrolled machine and
shows all of their projects together. There is no machine picker to manage. The
same workspace is available from Android.

{{< callout type="tip" title="Upgrading" >}}
`brew upgrade dieter` updates the daemon in place. When upgrading from the old
manual LaunchAgent, `dieter setup` unloads it and preserves its plist with a
`.disabled` suffix before starting the Homebrew-managed service.
{{< /callout >}}

## Build from source

```sh
just build
```

This produces separate `bin/dieter` and `bin/dieter-gateway` executables. A
normal daemon machine installs only `dieter`; the public host installs only
`dieter-gateway`.

The macOS app builds via `just mac build` (producing
`apps/mac/build/Dieter.app`); Android builds via `just android build` and
installs with `just android install`.

## Android

The Android client aggregates the same enrolled daemons and encrypts its gateway
session with a device-bound Android Keystore key. It auto-updates by checking the
latest `dbpprt/dieter` GitHub release for `Dieter-Android.apk`. See
`apps/android/README.md` for platform builds.

## Uninstall

Homebrew uninstall removes the service and binary but intentionally preserves
`DIETER_HOME`, so your projects, conversations, and schedules survive a
reinstall.

On Linux, `dieter daemon service uninstall` disables and removes the user unit
while preserving the same data. Remove the installed CLI separately only after
the service is gone.
