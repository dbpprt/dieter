---
title: "Machines & routes"
linkTitle: "Machines & routes"
description: "Enroll hosts, attach checkouts, and inspect the route used for each operation."
group: "Operate"
weight: 30
slug: "machines"
---

## Enroll another host

On the new machine, install the daemon and run:

```sh
dieter setup --gateway https://dieter.example.com
```

Use your gateway origin. After GitHub sign-in, approve the machine name and
verification code. Setup starts the managed service. For manual service setups,
`dieter daemon enroll --gateway URL --name "Workstation"` handles enrollment and
`dieter daemon start` runs the daemon in the foreground.

## Attach an existing project

Each machine's checkout is a real local Git working tree. To attach one to an
existing shared project on the newly enrolled machine:

```sh
dieter project list --format jsonl
dieter project attach PROJECT_ID ~/Development/my-project
dieter project checkouts PROJECT_ID
```

`project open PATH` registers a project; `project attach PROJECT_ID PATH` deliberately
adds a checkout to an existing shared identity. Neither command clones a repository.

For task creation, global `--machine` selects the execution host. `--checkout`
disambiguates multiple checkouts on that host; it does not redirect work to another
machine.

## Inspect connectivity

```sh
dieter machine list --format jsonl
dieter machine show MACHINE_ID
dieter machine route MACHINE_ID
dieter --machine MACHINE_ID status
dieter --machine MACHINE_ID machine info
dieter peer status
```

Clients prefer verified direct TLS, then WebRTC when available, then the gateway
relay. Route details distinguish **WebRTC · Direct** from **WebRTC · TURN**.
TURN still relays traffic. Read the [architecture](/docs/architecture/) for the
transport and ownership boundaries.

`machine info` reports live CPU, memory, processes, and optional GPU/sensor data.
An absent sensor is unknown, not a measurement of zero. Release version and
application contract version are separate fields; clients require an exact
contract match.

## Optional direct TLS route

Same-device clients discover the authenticated loopback route automatically.
For a deliberately configured LAN or tailnet listener, a foreground invocation is:

```sh
dieter daemon start \
  --direct-addr 0.0.0.0:4244 \
  --direct-host 100.64.0.10 \
  --direct-network tailscale
```

Use an address clients can actually reach. This is an example for starting a
configured daemon, not a command to run beside an already-running service.
Keep raw port **4242 loopback-only**. Direct access verifies the enrolled daemon
certificate and a short-lived token targeted to that daemon.

## Updates and power controls

Machines expose only supported, authorized actions. Each requires an explicit
confirmation:

```sh
dieter --machine MACHINE_ID machine update --confirm UPDATE
dieter --machine MACHINE_ID machine restart --confirm RESTART
dieter --machine MACHINE_ID machine shutdown --confirm "SHUT DOWN"
```

macOS uses normal system authorization. Linux uses non-interactive
systemd-logind/PolicyKit; Dieter never accepts a sudo password. A service update
may disconnect the transport while work recovers. Inspect the machine afterward
instead of replaying the update.

## Unenroll

On the machine being removed, run `dieter daemon unenroll`. It revokes the machine
identity and removes the local gateway credential while retaining project data,
conversations, schedules, and harness settings.
