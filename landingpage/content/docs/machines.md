---
title: "Machines & direct routes"
linkTitle: "Machines & routes"
description: "Enroll additional daemons, advertise direct TLS routes over a tailnet or LAN, and unenroll cleanly."
group: "Guides"
weight: 13
slug: "machines"
---

Dieter aggregates every enrolled machine into one project list. This guide
covers enrolling additional daemons and exposing optional direct routes.

## Enroll a machine

```sh
dieter daemon enroll \
  --gateway https://dieter.example.com \
  --name "Studio Mac"
```

The command opens GitHub, displays a verification code, stores the resulting
device identity under `DIETER_HOME/daemon`, and **never stores a GitHub token.**
On the next `dieter daemon start`, the daemon maintains its outbound tunnel and
reconnects with exponential backoff after network or gateway restarts.

## Register projects

```sh
dieter project open ~/Development/my-project
dieter daemon start
```

The raw local data plane listens on `127.0.0.1:4242`. An enrolled daemon also
creates a separate authenticated TLS listener on an ephemeral loopback port;
native clients discover it automatically through the gateway. `dieter serve`
remains an alias for `dieter daemon start`.

## Advertise a direct route

No flags are needed for same-device access. To advertise an additional direct
route, expose a dedicated TLS port only on a trusted LAN or tailnet and name the
address clients can actually reach:

```sh
dieter daemon start \
  --direct-addr 0.0.0.0:4244 \
  --direct-host 100.64.0.10 \
  --direct-network tailscale
```

The direct listener does not accept the gateway session itself. It requires a
short-lived token targeted to this daemon and serves the enrolled daemon
certificate.

{{< callout type="warn" title="Keep 4242 loopback-only" >}}
Do not advertise raw port `4242`; that port stays loopback-only. Only the
authenticated TLS route (a dedicated port on a trusted network) should be
reachable off-device.
{{< /callout >}}

## Unenroll

Unenroll a machine from that machine itself:

```sh
dieter daemon unenroll
```

The command signs the request with the enrolled machine identity, revokes the
gateway record, closes its relay, and removes the local gateway credential. It
does **not** remove projects, conversations, schedules, or harness settings.

## How routing works

The client prefers a reachable direct route and otherwise uses the relay. Both
paths expose the same `dieter.v1.DieterService` API. Opening a project's board,
chats, terminals, files, or schedules moves the active connection to that
project's owning daemon automatically, there is no machine picker.
