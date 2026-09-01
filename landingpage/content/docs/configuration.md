---
title: "Configuration & storage"
linkTitle: "Configuration"
description: "Where Dieter keeps its data, how persistence survives restarts, and the environment that shapes each daemon and gateway."
group: "Reference"
weight: 22
slug: "configuration"
---

Each daemon owns all of its domain data locally. This page covers the storage
layout, restart behavior, and the environment variables that matter.

## Daemon storage

Dieter state defaults to `~/.dieter` (`DIETER_HOME`). A daemon owns projects,
boards, cards, transcripts, queues, schedules, labels, runtime sessions, and
worker recovery records under it, using atomic writes and a cross-process
mutation lock.

| Path | Contents |
| --- | --- |
| `$DIETER_HOME` | All domain data (default `~/.dieter`). |
| `$DIETER_HOME/logs` | Bounded managed logs. |
| `$DIETER_HOME/daemon` | Enrolled device identity. |
| `$DIETER_HOME/harnesses.yaml` | Optional registry override. |

{{< callout type="note" title="Dieter never writes into your repos" >}}
All Dieter metadata is stored centrally under `DIETER_HOME`. Every project simply
references an existing Git working tree by canonical path and carries a
Dieter-generated project ID. Nothing is written into the repository itself.
{{< /callout >}}

## Persistence & restarts

Graceful daemon shutdown parks active harness turns with provider continuation
state; startup resumes them without replaying the user prompt. An unverifiable
orphaned worker is interrupted instead of risking duplicate tool effects. The
scheduler starts only with `dieter serve`. Constructing an HTTP handler in a test
never starts background work.

## Gateway storage

The gateway owns a separate SQLite database under `DIETER_GATEWAY_HOME` (default
`~/.dieter-gateway`) plus its private signing and daemon-CA keys. It stores
account sessions, pending OAuth and enrollment records, daemon public
identities, revocation generations, presence, and route metadata. It never
stores projects, transcripts, schedules, files, or harness credentials.

## Gateway environment

| Variable | Purpose |
| --- | --- |
| `DIETER_GATEWAY_HOME` | Gateway data directory. |
| `DIETER_PUBLIC_URL` | Public HTTPS origin. |
| `DIETER_GATEWAY_ADDR` | Listener address (loopback in proxy mode). |
| `DIETER_GATEWAY_PROXY_MODE` | `1` behind an HTTPS reverse proxy. |
| `DIETER_GATEWAY_TLS_CERT` / `_KEY` | Direct TLS termination (TLS 1.3). |
| `DIETER_GITHUB_ALLOWED_USER_ID` | Immutable numeric GitHub ID allowed to sign in. |
| `DIETER_GITHUB_ALLOWED_USER_IDS` | Comma-separated immutable numeric GitHub IDs; combined with the singular value. |
| `DIETER_RTC_STUN_URLS` / `_TURN_URLS` | ICE servers for Screens. |
| `DIETER_RTC_TURN_SECRET` | Hex secret (≥32 bytes) for coturn REST auth. |
| `DIETER_RTC_TTL` | Signed ICE config lifetime (default 5 minutes). |

## Protocol

The source contracts are `api/proto/dieter/v1/dieter.proto` and
`api/proto/dieter/gateway/v1/gateway.proto`. Regenerate Go and native inputs with
`./scripts/generate-proto.sh`. The application has no REST data API; native
clients and the raw gateway relay use protobuf gRPC.
