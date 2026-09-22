<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/brand/assets/svg/logo-horizontal-light.svg">
    <img src="assets/brand/assets/svg/logo-horizontal-dark.svg" alt="Dieter" width="240">
  </picture>
</p>

<h1 align="center">Close your laptop.<br>Keep your agents running.</h1>

<p align="center">
  Run coding agents on always-on Macs and headless Linux hosts.<br>Follow the work from your Mac or phone.<br>
  Open source. Native apps. Self-hostable.
</p>

<p align="center">
  <a href="https://github.com/dbpprt/dieter/actions/workflows/ci.yml"><img src="https://github.com/dbpprt/dieter/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/dbpprt/dieter/releases/latest"><img src="https://img.shields.io/github/v/release/dbpprt/dieter?color=18181b" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-18181b" alt="MIT license"></a>
</p>

<p align="center">
  <a href="https://getdieter.com/">Website</a> ·
  <a href="https://getdieter.com/docs/">Documentation</a> ·
  <a href="https://getdieter.com/docs/tour/">Product tour</a> ·
  <a href="https://github.com/dbpprt/dieter/releases/latest">Downloads</a>
</p>

![Dieter on macOS: a shared project board with tasks across multiple machines](landingpage/static/images/screenshots/macos-board.png)

Dieter is a native workspace for **Codex, Claude Code, Pi, Oh My Pi, and DeepSeek
Harness**. A local daemon runs agents on the machine with your Git checkout,
credentials, and tools. Native clients bring those machines together.
Managed OMP discovery and turns use the same pinned build. Dieter selects the
advertised model when launching OMP, so the full OMP catalog works even though
OMP's ACP model picker exposes only the user's smaller cycling list.

Your laptop is the remote control. An agent on another host keeps running when
you close the app, disconnect, or put your laptop to sleep. Keep that execution
host powered on and awake; a headless Linux host needs no desktop.

- **Give work a home.** Boards, standalone chats, labels, and schedules. Every
  task keeps one durable conversation.
- **Keep context beside the chat.** Open files, diffs, web pages, terminals, and
  background processes in the optional Mac conversation workspace.
- **Work across machines.** One shared project can have checkouts on your laptop,
  workstation, and Linux server. Each conversation keeps its execution owner.
- **Pick up from your phone.** Android provides Activity, boards, chats, files,
  terminals, and machine tools. iPhone and iPad support is in beta.
- **Step in when needed.** Queue a follow-up, review a result, or open an
  authenticated remote screen with explicit input control.

[See the native apps in action →](https://getdieter.com/docs/tour/)

## Quick start

You need a configured agent account on the host and access to a Dieter gateway.
Use your own gateway origin below; [self-hosting is documented](https://getdieter.com/docs/gateway/).

On **Apple Silicon macOS**:

```sh
brew install dbpprt/tap/dieter
dieter setup --gateway https://dieter.example.com
dieter project open ~/Development/my-project

brew install --cask dbpprt/tap/dieter-app
open -a Dieter
```

Sign in to the same gateway in the app, open your project, and create a task.
`setup` enrolls the machine and starts its service. `project open` separately
registers an existing Git working tree.

The standard gateway is `https://gateway.getdieter.com`, with STUN/TURN at
`turn.getdieter.com`. Access requires an allowed account. Existing installations
retain their identity when the endpoint moves; see the
[gateway migration guide](https://getdieter.com/docs/gateway/#moving-a-gateway-endpoint).

On **Linux amd64/arm64**, install Node.js 22.19+, npm, Git, and
[cosign](https://docs.sigstore.dev/cosign/system_config/installation/), then:

```sh
curl -fsSL https://github.com/dbpprt/dieter/releases/latest/download/install.sh | sh
dieter setup --gateway https://dieter.example.com
dieter project open ~/Development/my-project
dieter doctor
```

| Client | Get it |
| --- | --- |
| macOS 26+, Apple Silicon | Homebrew cask above or [release downloads](https://github.com/dbpprt/dieter/releases/latest) |
| Android 8+ | [Download the APK](https://github.com/dbpprt/dieter/releases/latest/download/Dieter-Android.apk) |
| iOS 18+, iPhone and iPad | [Beta and source-build guide](apps/ios/README.md) |

The daemon supports headless Linux hosts. Screen hosting needs an active desktop
and [platform dependencies](docs/linux-support.md).
[Full installation guide →](https://getdieter.com/docs/installation/)

## How it works

**Daemon → gateway → native client.** The daemon owns local execution and
replicates shared project metadata with your other daemons. The gateway handles
account identity, machine discovery, and bounded relay. Clients prefer verified
direct TLS, then supported WebRTC, with gateway relay fallback.

The gateway stores control metadata and normalized quota snapshots, **not**
repositories, transcripts, or provider credentials. Relay requests can pass
through it. Agents run with your user permissions, without a Dieter sandbox;
cloud model providers may receive prompts and code according to their settings.
Read the [security model](https://getdieter.com/docs/security/).

There is no browser application or hosted agent runtime. The website is the
project's documentation; your agents run on your machines.

## Find your way

| You want to… | Read |
| --- | --- |
| Run your first agent | [Quick start](https://getdieter.com/docs/quickstart/) |
| Understand tasks, worktrees, and review | [Projects & tasks](https://getdieter.com/docs/projects/) |
| Automate through the daemon | [CLI guide](https://getdieter.com/docs/cli/) |
| Add machines or host a gateway | [Machines](https://getdieter.com/docs/machines/) · [Self-hosting](https://getdieter.com/docs/gateway/) |
| Understand internals | [Architecture](https://getdieter.com/docs/architecture/) · [Technical index](docs/README.md) |
| Fix a connection or setup problem | [Troubleshooting](https://getdieter.com/docs/troubleshooting/) |

## Contribute

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, repository structure, and review
expectations. Start local validation with:

```sh
just check-changed --dry-run
just check-changed
```

[Mac](apps/mac/README.md) · [Android](apps/android/README.md) ·
[iOS](apps/ios/README.md) · [Website](landingpage/README.md)

Dieter is [MIT-licensed](LICENSE). Pronounced **DEE-ter**. Made in Berlin.
