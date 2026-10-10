---
title: "Troubleshooting"
linkTitle: "Troubleshooting"
description: "Start with bounded diagnostics and preserve the work already running."
group: "Operate"
weight: 33
slug: "troubleshooting"
---

## The app cannot connect

1. Confirm the app and daemon use the same HTTPS gateway origin and GitHub account.
2. Run `dieter daemon status` on the host, then `dieter machine list`.
3. Check the gateway's minimum client/daemon releases and each installed release.
4. Check `dieter machine route MACHINE_ID` and `dieter --machine MACHINE_ID status`.

A healthy local API can coexist with a reconnecting gateway tunnel. A recent
`gatewayLastAcknowledgedAt` is bidirectional tunnel liveness evidence. A sync
heartbeat alone does not mean all workspace data has arrived.

The gateway root returning **404 is expected**. `/healthz` is its health route;
the public marketing and documentation site is a different service.

## Setup fails or the service does not start

Run `dieter setup` for the standard gateway, `https://gateway.getdieter.com`.
Access requires an allowed GitHub account. For a self-hosted gateway, pass its
actual HTTPS origin with `--gateway`. `dieter.example.com` is a documentation
placeholder and must not be copied as a real address.

If enrollment failed before authorization, correct the origin and rerun setup.
Incomplete enrollment retries update the origin and machine name while keeping
the original private key. Completed enrollments retain their existing identity;
see [gateway migration](/docs/gateway/#moving-a-gateway-endpoint). Do not delete or manually edit
`identity.json` or `identity-key.pem`.

On macOS, setup uses Homebrew's background service. If an earlier
`dieter daemon start` is still running in a terminal, stop that foreground process
with Ctrl-C and rerun `dieter setup`. Two daemons cannot share the local API port.
Setup reports the foreground process instead of accepting its local API as proof
that the new service started.

Check `dieter daemon status`: expect `homebrew (started)`, a healthy local API,
and a connected gateway. If the service still fails, inspect `brew services list`
and `dieter daemon logs`. Agent work can run without screen sharing; remote desktop
also requires the daemon's Screen Recording and Accessibility permissions. Run
`dieter daemon permissions --check` to verify them.

## A project is missing or duplicated

`dieter setup` does not register projects. Use `dieter project open PATH` for an
existing Git working tree on the host. For another checkout of an existing
shared project, use `dieter project attach PROJECT_ID PATH`.

Inspect `dieter project checkouts PROJECT_ID` and `dieter peer status`. A replica
can show shared project metadata while a conversation's execution owner is offline;
that does not make its local files or agent executable on another machine.

## A model is unavailable

Run `dieter harness list --format jsonl` on the execution host, or use global
`--machine MACHINE_ID`. Verify that provider's normal configuration and login on
that host. The catalog is machine-specific. Updating a global CLI does not update
Dieter's pinned runtime. See [Agents & models](/docs/harnesses/).

## A task seems stuck

Use `dieter card context CARD_ID`, `dieter card transcript --last 20 CARD_ID`, and
`dieter daemon logs --follow`. Check whether it is running, awaiting input, queued,
or failed before acting. A lost client connection does not stop its turn.

After a start/send command times out, inspect the conversation before sending it
again. The original turn may already have been admitted.

## Screen sharing is unavailable

```sh
dieter daemon permissions --check
dieter screen capabilities
```

The result distinguishes ready, permission required, and unsupported. Grant
permissions **on the target machine**, to the executable identified by setup.
Mac app permissions and daemon permissions are separate. Linux needs an active
graphical session and the [screen host requirements](/docs/screens/#capture-on-linux).
Wayland may require local portal consent when connecting.

For network failures, check the configured STUN/TURN service. H.264 is the default;
strict HEVC may fail when either endpoint lacks support. Use `screen status SESSION`
to inspect actual codec and stream state. Do not treat emulator timings as physical
device latency measurements.

## Phone updates stop in the background

The Android and iOS apps observe your workspace only while they are open. They
have no background sync service, notifications, or widgets; reopening the app
reconnects and catches up. The host's agent continues regardless.

## A terminal disappeared after a host restart

Client reconnect persistence is built in. Persistence through a daemon restart
requires `tmux` on the host. Remote executions are separate and end when the
daemon shuts down. [Terminals & automation](/docs/automation/) explains the difference.

## Report a useful bug

Include the Dieter release and contract versions, OS/device, selected route,
steps to reproduce, expected and actual behavior, and a small redacted log excerpt
or screenshot. Avoid complete transcript dumps and remove credentials and personal
data. See [Contributing](https://github.com/dbpprt/dieter/blob/main/CONTRIBUTING.md).
