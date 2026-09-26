---
title: "Configuration & storage"
linkTitle: "Configuration & storage"
description: "Keep runtime settings, project metadata, and credentials in their proper locations."
group: "Reference"
weight: 43
slug: "configuration"
---

## Daemon storage

Dieter data defaults to `~/.dieter`, overridden by `DIETER_HOME` or the CLI's
`--store PATH`. This is the central location for metadata, transcripts, queues,
local execution state, logs, and managed runtime/worktree data. Shared project
and settings records replicate between account daemons; execution records retain
their owner.

Repositories stay ordinary Git working trees. Dieter does not write its metadata
into them, although agents intentionally edit repository files when doing work.
Use the daemon API or CLI for operations instead of editing central storage.

## Agent configuration

| Setting | Purpose |
| --- | --- |
| `DIETER_HOME` | Central daemon data root |
| `$DIETER_HOME/harnesses.yaml` | Optional per-daemon model/capability registry override |
| `DIETER_HARNESS_CONFIG` / `--harness-config` | Explicit registry path |
| `CODEX_HOME`, `CLAUDE_CONFIG_DIR`, `PI_AGENT_DIR`, `OMP_PROFILE`, `DSH_HOME` | Provider-specific configuration selection |
| `DIETER_CODEX_ACCOUNT_HOMES` | Explicit OS path-list of up to eight quota profile directories |

See [Agents & models](/docs/harnesses/) for credentials and runtime behavior.

## Gateway settings

Keep the real `.env` at `$DIETER_GATEWAY_HOME/.env` with mode `0600`; process
environment values override it. Start from
[`.env.example`](https://github.com/dbpprt/dieter/blob/main/.env.example).

| Setting | Purpose |
| --- | --- |
| `DIETER_GATEWAY_HOME` | Gateway SQLite and private identity root; default `~/.dieter-gateway` |
| `DIETER_PUBLIC_URL` | Public HTTPS origin |
| `DIETER_GATEWAY_ISSUER` | Durable authentication namespace; preserve the original origin when [moving a gateway endpoint](/docs/gateway/#moving-a-gateway-endpoint) |
| `DIETER_GATEWAY_ADDR` | Listener; loopback behind a same-host reverse proxy |
| `DIETER_GATEWAY_PROXY_MODE` | `1` for reverse-proxy TLS termination |
| `DIETER_GATEWAY_TLS_CERT`, `DIETER_GATEWAY_TLS_KEY` | Direct TLS certificate and key |
| `DIETER_GITHUB_CLIENT_ID`, `DIETER_GITHUB_CLIENT_SECRET` | GitHub OAuth App credentials |
| `DIETER_GITHUB_ALLOWED_USER_IDS` | Comma-separated immutable numeric GitHub IDs |
| `DIETER_AUTH_SECRET` | Gateway authentication secret |
| `DIETER_NATIVE_SESSION_TTL` | Native session lifetime |
| `DIETER_NATIVE_REDIRECT_URIS` | Exact allowlisted native OAuth callbacks |
| `DIETER_RTC_STUN_URLS`, `DIETER_RTC_TURN_URLS` | ICE services for Screens and data-only WebRTC API routes |
| `DIETER_RTC_TURN_SECRET` | Hex-encoded coturn REST secret, at least 32 bytes |
| `DIETER_RTC_TTL` | Signed ICE configuration lifetime; default five minutes |

The signed deployment bundle accepts canonical printable UTF-8 `turnSharedSecret`
text and hex-encodes its exact bytes for Dieter while giving coturn the text.
Follow the [deployment guide](https://github.com/dbpprt/dieter/tree/main/deploy/gateway)
when using the bundle; do not double-encode or silently replace an existing secret.

The gateway stores control metadata and normalized credential-free quota
snapshots. Provider credentials and raw provider responses stay off the gateway.

## Restart and recovery

Graceful shutdown preserves continuation state. Managed service updates stage a
verified daemon/helper pair and prepare its harness runtime before activation.
An in-flight turn stays pinned to its runtime until completion. Terminal restart
persistence requires tmux; remote execution processes end on daemon shutdown.

Never launch a second daemon beside an existing service to change configuration.
Inspect `dieter daemon status` and use the platform's managed service lifecycle.
Development tests must use isolated state and random loopback ports.

## Release compatibility and protocol

The authoritative schema lives in `api/proto`. Gateway, daemon/CLI, and native
clients share one release version; the gateway publishes minimum client and
daemon releases. `just proto` regenerates Go and copied Swift schema clients;
Android generates its bindings during the build. There is no historical API
compatibility branch, REST application API, or browser application.

## Mac workspace panel

**Settings → Experimental → Show the workspace side panel** enables files, browser previews, terminals, changes, and processes alongside conversations. It is off by default. See [Conversation workspace](/docs/workspace/).
