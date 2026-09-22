---
title: "Installation"
linkTitle: "Installation"
description: "Choose a daemon host and a native client."
group: "Start here"
weight: 10
slug: "installation"
---

The daemon runs agents; the app connects to them. Install both on a Mac that will
host work, or install just a client when your agents run on another machine.

## Supported platforms

| Role | Apple Silicon macOS | Linux amd64 / arm64 | Android | iPhone / iPad |
| --- | --- | --- | --- | --- |
| CLI and daemon | Yes | Yes | — | — |
| Native client | macOS 26+ | — | Android 8+ | iOS 18+, beta |
| Screen host | With OS permissions | Active X11 / Wayland desktop | — | — |
| Gateway | Source build | Published image and binaries | — | — |

Each daemon host needs **Node.js 22.19+**, **npm**, **Git**, and a configured
[harness account](/docs/harnesses/). Install **tmux** if terminals should survive
daemon restarts. Published binaries do not require Go or `just`.

## macOS

Install the daemon with Homebrew:

```sh
brew install dbpprt/tap/dieter
dieter setup --gateway https://dieter.example.com
dieter project open ~/Development/my-project
```

Use your actual gateway origin and an existing Git checkout. Setup enrolls the
machine, starts the Homebrew service, and guides the daemon's Screen Recording
and Accessibility grants. Unsupported screen hosting does not prevent agent work.

Install the native app separately:

```sh
brew install --cask dbpprt/tap/dieter-app
open -a Dieter
```

The app signs in to your gateway. Its capture and browser-context features have
separate app permissions; grant access to **Dieter.app** when its setup asks.
Daemon capture permissions apply to the executable identified by the daemon's
guide. Recheck the host with `dieter daemon permissions --check`.

## Linux

Use a systemd user session. Install Node.js 22.19+, npm, Git, and
[cosign](https://docs.sigstore.dev/cosign/system_config/installation/) first;
`tmux` is recommended. Then:

```sh
curl -fsSL https://github.com/dbpprt/dieter/releases/latest/download/install.sh | sh
dieter setup --gateway https://dieter.example.com
dieter project open ~/Development/my-project
dieter doctor
```

The installer verifies the release's Sigstore-signed SHA-256 manifest and installs
the daemon/capture-helper pair. It creates a private systemd user service when a
user manager is available. Use `--version`, `--install-dir`, or `--no-service`
when needed; download the script and run `sh install.sh --help` for all options.

Agents work on headless hosts. Screen hosting additionally needs an active
graphical session, GStreamer, and X11 or Wayland portal packages. The
[Linux host reference](https://github.com/dbpprt/dieter/blob/main/docs/linux-support.md)
lists distribution packages and service details. Do not run the daemon as root.

## Android

Download [Dieter-Android.apk from the latest release](https://github.com/dbpprt/dieter/releases/latest/download/Dieter-Android.apk).
Allow installation from your download source when Android asks, install it, and
sign in to your gateway. No daemon runs on the phone.

The app checks public releases for updates, verifies the asset's published
SHA-256 digest, and hands installation to Android. You still confirm each
installation. A manual check is available in **App Settings → Updates**.

For source builds, see the [Android developer guide](https://github.com/dbpprt/dieter/blob/main/apps/android/README.md).

## iPhone and iPad beta

The SwiftUI client supports iOS 18+ on iPhone and iPad. It provides project and
board navigation, conversations, attachments and screenshot sharing, remote file
editing, machine telemetry, and Screens. It connects to remote daemons and does
not host agents.

iOS distribution uses the manual TestFlight workflow. Availability depends on
beta access; there is no App Store download promised here. You can also build
with Xcode using the [iOS guide](https://github.com/dbpprt/dieter/blob/main/apps/ios/README.md).

## Updates

Homebrew stages the next daemon/helper pair without replacing the running pair.
Activate it with a service restart at an appropriate time:

```sh
brew upgrade dieter
brew services restart dieter
```

Managed macOS and Linux hosts also expose an explicit authenticated update:

```sh
dieter machine update --confirm UPDATE
```

Use global `--machine MACHINE_ID` to select another host. Capability checks explain
when managed update is unavailable. Updates prepare the pinned harness runtime
before restarting; an active turn retains its runtime digest across recovery.
See [service activation and rollback](https://github.com/dbpprt/dieter/blob/main/docs/homebrew-service-runtime.md).

## Build from source

See [Development](/docs/development/) for tool versions and checks.
`just build` produces `bin/dieter` and `bin/dieter-gateway`.
`just mac build` packages the Mac app; `just android build` produces the debug APK.

## Uninstall

Homebrew uninstall removes the installed program while preserving `DIETER_HOME`.
On Linux, `dieter daemon service uninstall` removes the user unit; remove the
installed binaries separately. Neither operation deletes your conversations or
registered repositories.
