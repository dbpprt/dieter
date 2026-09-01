---
title: "Run a gateway"
linkTitle: "Run a gateway"
description: "Host the machine-to-machine control and relay service behind an HTTPS reverse proxy, or terminate TLS directly."
group: "Guides"
weight: 12
slug: "gateway"
---

The gateway authenticates allowlisted GitHub accounts and relays each account
only to its own enrolled daemons. It never stores code, transcripts, files, or
harness credentials; only sessions, identities, presence, and routes.

## Register a GitHub OAuth App

Create a GitHub OAuth App with:

- homepage: `https://dieter.example.com`
- callback: `https://dieter.example.com/auth/github/callback`
- Device Flow **disabled**

## Configure the environment

Copy `.env.example` to `$DIETER_GATEWAY_HOME/.env` (default
`~/.dieter-gateway/.env`), fill its values, and set mode `0600`.

{{< callout type="warn" title="Match on the numeric GitHub ID" >}}
`DIETER_GITHUB_ALLOWED_USER_ID` accepts one immutable numeric GitHub ID.
`DIETER_GITHUB_ALLOWED_USER_IDS` accepts a comma-separated list and is combined
with the singular value when both are set. Logins are display-only and must
never be used for authorization. Accounts cannot see or control one another's
daemons.
{{< /callout >}}

## Behind a reverse proxy

Run behind a same-host HTTPS reverse proxy:

```sh
DIETER_GATEWAY_HOME=/var/lib/dieter-gateway dieter-gateway
```

Keep `DIETER_GATEWAY_ADDR` on loopback, enable `DIETER_GATEWAY_PROXY_MODE=1`, and
proxy HTTP/2 to it. Proxy mode requires an HTTPS `DIETER_PUBLIC_URL` and refuses
non-loopback listeners. The external hop is TLS and every daemon link still uses
its cryptographic challenge, so a forwarded daemon ID is never trusted.

## Terminating TLS directly

If the gateway terminates TLS itself, disable proxy mode and set
`DIETER_GATEWAY_TLS_CERT` and `DIETER_GATEWAY_TLS_KEY`. It enforces TLS 1.3.

## What the origin serves

The public origin intentionally serves only:

- `/healthz`
- the minimal GitHub OAuth start, callback, exchange, and completion routes
- `dieter.gateway.v1.GatewayService` and `DaemonLinkService`
- authenticated `dieter.v1.DieterService` relay calls

**All other paths, including `/`, return 404.**

## ICE / TURN for Screens

Remote viewing can use `DIETER_RTC_STUN_URLS` and `DIETER_RTC_TURN_URLS` as
comma-separated ICE server URLs. When TURN URLs are configured, set
`DIETER_RTC_TURN_SECRET` to a hex-encoded secret of at least 32 bytes shared
with coturn's REST authentication; the gateway derives ephemeral credentials
instead of storing static TURN passwords. `DIETER_RTC_TTL` controls the signed
configuration lifetime and defaults to five minutes.

## Storage

The gateway owns a SQLite database under `DIETER_GATEWAY_HOME` plus its private
signing and daemon-CA keys. A container image is available via
`Dockerfile.gateway`.
