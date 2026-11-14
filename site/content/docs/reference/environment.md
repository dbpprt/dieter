---
title: "Environment variables"
linkTitle: "Environment variables"
description: "Every variable the daemon, CLI, and gateway read, and where to set them."
group: "Reference"
weight: 45
slug: "environment"
---

Most installations need none of these: `dieter setup` and the gateway's `.env`
cover the normal cases. Command-line flags take precedence over variables.

## Where to set them

- **Daemon:** the service environment, or `$DIETER_HOME/.env` (or
  `--env-file PATH`). The file must have mode `0600` and never overrides a
  variable that is already set. Restart the service to apply a change; do not
  start a second daemon beside it.
- **Gateway:** `$DIETER_GATEWAY_HOME/.env` (mode `0600`) or the process
  environment, which wins. Start from
  [`deploy/gateway/gateway.env.example`](https://github.com/dbpprt/dieter/blob/main/deploy/gateway/gateway.env.example).

## Daemon and CLI

| Variable                                                                     | Meaning                                                                                                                                                                  |
| ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `DIETER_HOME`                                                                | Central data directory, default `~/.dieter`. The global `--store PATH` option overrides it.                                                                              |
| `DIETER_GATEWAY`                                                             | Gateway origin the CLI requires when `--gateway` is not given.                                                                                                           |
| `DIETER_HARNESS_CONFIG`                                                      | Harness registry YAML when `--harness-config` is not given. Otherwise `$DIETER_HOME/harnesses.yaml`, then the built-in catalog. See [Agents & models](/docs/harnesses/). |
| `DIETER_HARNESS_ENV`                                                         | Comma-separated names of extra variables to pass to agent processes. Agents otherwise receive only basic user variables, provider keys and proxy settings.               |
| `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `PI_AGENT_DIR`, `OMP_PROFILE`, `DSH_HOME` | Select each provider's configuration directory or profile.                                                                                                               |
| `DIETER_CODEX_ACCOUNT_HOMES`, `DIETER_CLAUDE_ACCOUNT_HOMES`                  | `:`-separated additional provider profiles (up to eight) to include in quota reporting.                                                                                  |
| `DIETER_MIN_FREE_BYTES`                                                      | Free disk space a turn requires (default 2 GiB).                                                                                                                         |
| `DIETER_SERVICE_MANAGER`                                                     | `homebrew`, `systemd-user` or `managed`; written by the installers.                                                                                                      |
| `DIETER_REMOTE_DESKTOP_HELPER`                                               | Path of an alternative screen-capture helper (development and diagnostics).                                                                                              |
| `DIETER_REMOTE_DESKTOP_DISPLAY`                                              | Capture source (display) to share.                                                                                                                                       |
| `DIETER_REMOTE_DESKTOP_SOURCE`                                               | `screen` (default) or `synthetic`, reserved for transport diagnostics.                                                                                                   |
| `DIETER_SCREEN_FEC`, `DIETER_SCREEN_FAST_BITRATE`, `DIETER_SCREEN_LTR`       | `0` disables forward error correction, fast bitrate reduction or acknowledged reference recovery (all on by default). For A/B diagnostics.                               |
| `DIETER_SCREEN_CONTENT_ADAPTATION`, `DIETER_SCREEN_OVERLAP`                  | `1` enables experimental content-class adaptation or overlapping native encode.                                                                                          |
| `DIETER_SCREEN_VIRTUAL_DISPLAY`                                              | `1` enables experimental macOS [virtual displays](/docs/screens/#experimental-virtual-displays-macos).                                                                   |
| `DIETER_SCREEN_VIRTUAL_DISABLE`                                              | `1` additionally allows disabling the physical main display (hardware-qualified opt-in).                                                                                 |

The daemon sets `DIETER_HOME`, `DIETER_CARD_ID` and `DIETER_TURN_TOKEN` for agent
processes, so an agent's `dieter` commands reach this daemon and identify their
turn (the token gates [vault](/docs/vault/) access).

## Gateway

| Variable                                                         | Meaning                                                                                                                      |
| ---------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `DIETER_GATEWAY_HOME`                                            | State directory (SQLite database and private keys), default `~/.dieter-gateway`.                                             |
| `DIETER_GATEWAY_ADDR`                                            | Listen address, default `127.0.0.1:4243`. Keep it on loopback behind a reverse proxy.                                        |
| `DIETER_PUBLIC_URL`                                              | Public HTTPS origin. Required.                                                                                               |
| `DIETER_GATEWAY_ISSUER`                                          | Durable identity origin; keep the original origin here after [moving an endpoint](/docs/gateway/#moving-a-gateway-endpoint). |
| `DIETER_GATEWAY_PROXY_MODE`                                      | `1` behind a same-host TLS-terminating reverse proxy.                                                                        |
| `DIETER_GATEWAY_TLS_CERT`, `DIETER_GATEWAY_TLS_KEY`              | Certificate and key when the gateway terminates TLS itself.                                                                  |
| `DIETER_GITHUB_CLIENT_ID`, `DIETER_GITHUB_CLIENT_SECRET`         | GitHub OAuth App credentials.                                                                                                |
| `DIETER_GITHUB_ALLOWED_USER_IDS`                                 | Comma-separated immutable numeric GitHub user IDs allowed to sign in.                                                        |
| `DIETER_GITHUB_BASE_URL`, `DIETER_GITHUB_API_URL`                | GitHub endpoints, for GitHub Enterprise (defaults `https://github.com`, `https://api.github.com`).                           |
| `DIETER_AUTH_SECRET`                                             | Hex session-signing secret (`openssl rand -hex 32`).                                                                         |
| `DIETER_NATIVE_SESSION_TTL`                                      | Native app session lifetime, for example `720h`.                                                                             |
| `DIETER_NATIVE_REDIRECT_URIS`                                    | Exact allowed app callbacks, comma-separated.                                                                                |
| `DIETER_MINIMUM_CLIENT_VERSION`, `DIETER_MINIMUM_DAEMON_VERSION` | Oldest client and daemon releases the gateway admits.                                                                        |
| `DIETER_RTC_STUN_URLS`, `DIETER_RTC_TURN_URLS`                   | Comma-separated ICE servers for Screens and WebRTC API routes.                                                               |
| `DIETER_RTC_TURN_SECRET`                                         | Hex-encoded coturn REST secret, at least 32 bytes.                                                                           |
| `DIETER_RTC_TTL`                                                 | Lifetime of signed ICE configuration, default five minutes.                                                                  |
| `DIETER_GATEWAY_DEV_INSECURE`                                    | `1` for a disposable local development gateway only: allows plain HTTP. Never expose it.                                     |

Contributors: the [complete reference](https://github.com/dbpprt/dieter/blob/main/docs/reference/environment.md)
also lists internal, fixture and test variables and the code that reads each one.
