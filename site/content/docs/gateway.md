---
title: "Run a gateway"
linkTitle: "Run a gateway"
description: "Host the machine-to-machine control and relay service behind an HTTPS reverse proxy, or terminate TLS directly."
group: "Operate"
weight: 31
slug: "gateway"
---

The gateway authenticates allowlisted GitHub accounts and relays each account
only to its own enrolled daemons. Every relayed connection is TLS between two
of the account's trusted devices, so the gateway forwards bytes it cannot read.
It never stores code, transcripts, files, or harness credentials; only control
metadata, each account's signed device roster, short-lived pairing requests,
and normalized, credential-free provider quota snapshots.

## Register a GitHub OAuth App

Create a GitHub OAuth App with:

- homepage: `https://dieter.example.com`
- callback: `https://dieter.example.com/auth/github/callback`
- Device Flow **disabled**

## Configure the environment

Copy [`deploy/gateway/gateway.env.example`](https://github.com/dbpprt/dieter/blob/main/deploy/gateway/gateway.env.example)
to `$DIETER_GATEWAY_HOME/.env` (default `~/.dieter-gateway/.env`), fill its
values, and set mode `0600`. The [environment reference](/docs/environment/#gateway)
lists every variable.

{{< callout type="warn" title="Match on the numeric GitHub ID" >}}
`DIETER_GITHUB_ALLOWED_USER_IDS` accepts one or more immutable numeric GitHub
IDs as a comma-separated list. Logins are display-only and must
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

The proxy must enforce Dieter's TLS 1.3 policy on the external connection.
For Caddy, an example site configuration is:

```caddyfile
dieter.example.com {
    tls {
        protocols tls1.3
    }
    header Strict-Transport-Security "max-age=31536000"
    reverse_proxy h2c://127.0.0.1:4243
}
```

Keep the proxy upstream private, configure connection and request limits at
the edge, and avoid logging authorization headers or OAuth query parameters.
Gateway rate limits use the transport peer, so requests through one proxy share
its rate bucket; forwarded identity headers are never trusted for authorization.

## Terminating TLS directly

If the gateway terminates TLS itself, disable proxy mode and set
`DIETER_GATEWAY_TLS_CERT` and `DIETER_GATEWAY_TLS_KEY`. It enforces TLS 1.3.

## What the origin serves

The public origin intentionally serves only:

- `/healthz`
- the minimal GitHub OAuth start, callback, exchange, and completion routes
- `dieter.gateway.v1.GatewayService` and `DaemonLinkService`
- `dieter.gateway.v1.RelayService`, whose tunnels carry encrypted connections
  from an account's devices to its own daemons

**All other paths, including `/`, return 404.**

Daemon enrollment includes a browser confirmation after GitHub sign-in. Check
the machine name and enrollment code before approving; the page also shows the
public-key fingerprint. The approval form is bound to that browser and expires
after two minutes.

## Security validation

Deploy only signed release builds. Each release's gateway image passes the Go
vulnerability check, the deployment tests and real TURN payload tests before it
is published, and is signed with build provenance and an SBOM; verify the
bundle with `deploy/gateway/scripts/bundle.py verify` (see the
[deployment guide](https://github.com/dbpprt/dieter/tree/main/deploy/gateway)).
Confirm the deployed build identity through `/healthz` after deployment.

## ICE / TURN for Screens and API connections

Remote viewing and data-only WebRTC API connections can use `DIETER_RTC_STUN_URLS` and `DIETER_RTC_TURN_URLS` as
comma-separated ICE server URLs. When TURN URLs are configured, set
`DIETER_RTC_TURN_SECRET` to a hex-encoded secret of at least 32 bytes shared
with coturn's REST authentication; the gateway derives ephemeral credentials
instead of storing static TURN passwords. `DIETER_RTC_TTL` controls the signed
configuration lifetime and defaults to five minutes.

## Storage

The gateway owns a SQLite database under `DIETER_GATEWAY_HOME` plus its private
signing and daemon-CA keys. The database holds account sessions, enrolled
daemons, presence and routes, provider quota snapshots, each account's device
roster and its pending pairing requests. Roster entries are signed by the
account's devices: the gateway checks every new entry and serves the list, but
cannot write one, so it cannot add a device to an account. A pairing request
holds the new device's name, kind and public key and a proof of its code, never
the code itself, and expires after 15 minutes. The daemon CA only
authenticates daemons to the gateway; clients never receive it. Releases
publish a container image; build one from source with
[`deploy/gateway/Dockerfile`](https://github.com/dbpprt/dieter/blob/main/deploy/gateway/Dockerfile).

## Relay tunnels

A client reaches a daemon through the relay by opening a tunnel: one gRPC
stream that names the daemon and a traffic class. The gateway admits it only
for the caller's own daemon, asks the daemon on that class's connection, and
then forwards frames of at most 64 KiB in both directions, eight unacknowledged
frames per direction at most. Inside, the client and the daemon run the same
mutually authenticated TLS as on a direct route. The gateway never parses the
frames; it sees when a tunnel opens and closes and how many bytes it carries.
Per daemon, the gateway admits at most 4 control, 8 replication, 32 command and
32 subscription tunnels at once, within its per-class byte budgets.
Signing out closes a session's tunnels within about five seconds; revoking a
machine closes all of them at once.

Enrolled daemons advertise `controlWebrtc` in route discovery when their
WebRTC-to-authenticated-TLS bridge is available. Current clients prefer direct
TLS, then attempt WebRTC, retaining the gateway relay for unavailable routes or failed
ICE negotiation. Machine connection details distinguish WebRTC Direct from
WebRTC TURN using the selected candidate pair. TURN traffic is still relayed;
the TLS connection inside stays pinned to both devices' roster keys, and the
per-call access token is still verified.

## Signed deployment bundles

Gateway releases include a signed deployment bundle alongside the image. The
bundle binds the image digest, source commit, canonical release, compatibility floors, store schema
and infrastructure dependencies. It provides strict configuration rendering,
durable deployment operations, encrypted off-host backup hooks, and tested
UDP/TCP/TLS TURN transport configuration. See the
[gateway deployment guide](https://github.com/dbpprt/dieter/tree/main/deploy/gateway).

## Moving a gateway endpoint

A gateway's public HTTPS endpoint can change without changing its enrolled
identity. Set `DIETER_PUBLIC_URL` to the new origin and preserve the original
origin in `DIETER_GATEWAY_ISSUER`. The issuer is a durable authentication,
device roster and peer-store namespace; it is not a network destination. Keep
the signing keys, daemon CA, sessions, allowlist and state volume intact.
Machines keep their trusted devices across the move. Apps sign in again at the
new origin and show their pairing code once more; approving it confirms their
existing key and adds no device.

On startup an enrolled daemon checks the account-bound endpoint assertion signed
by its pinned gateway key, authenticates the destination, and atomically updates
its network address under the central store lock. Local data, peer database,
actor identity, owner signatures and daemon enrollment remain unchanged. If
discovery or destination verification fails, startup retains the current address.
Keep the previous hostname serving the same gateway while offline machines and
older installations update. Native clients authenticate separately at the new
origin; saved credentials are not copied between origins.

Update DNS, OAuth callback URLs, and TLS certificates for the new origin before
cutover. Keep the previous endpoint available until enrolled machines reconnect.

The standard gateway is now `https://gateway.getdieter.com`, with STUN/TURN at
`turn.getdieter.com`. App updates move saved standard gateway addresses and ask
for a fresh sign-in at the new origin; custom gateway addresses are preserved.

## Relay protocol rollout

Release 0.6 replaced the per-call relay with end-to-end encrypted tunnels and
raised both compatibility floors to `0.6.0-dev.0`. Update the gateway, every
daemon and every app together, then start the device roster on one machine and
pair the others: see
[upgrading to trusted devices](/docs/machines/#upgrading-from-05).

Deploy the gateway and daemon/CLI from the same canonical SemVer release. The
first release with isolated relay connections must set
`minimumDaemonVersion` in the deployment compatibility policy to that release;
older daemons do not implement the current link contract. Native clients continue
to use the same daemon API and receive the route diagnostics as additional
fields. New daemons require the gateway to acknowledge their exact connection
class and process session before opening auxiliary connections. Stage a compatible
daemon for authenticated deployment readiness before gateway activation; its local
API remains available while it waits for the new gateway acknowledgement. Admit
other daemon updates before raising the gateway floor, or update them through
their host-local CLI afterward. An outdated daemon cannot receive an update
through a relay that rejects its release. A deployment must qualify the retained
release bytes and follow the existing protected activation and rollback procedure.
Updating source locally
does not change running gateway or daemon services.
