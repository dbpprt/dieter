---
title: "Machines & routes"
linkTitle: "Machines & routes"
description: "Enroll hosts, attach checkouts, and inspect the route used for each operation."
group: "Operate"
weight: 30
slug: "machines"
---

An enrolled Mac or Linux daemon can run agents without an open native client.
Use an always-on host for long tasks: your laptop or phone can disconnect while
the execution host keeps working. Keep the host awake and its daemon service
running. A host that sleeps shows as offline; when it wakes, its daemon and the
Mac app reconnect on their own within seconds. A headless Linux host needs no
graphical login for agents or terminals; [screen hosting](/docs/screens/) has
additional desktop requirements.

## Keep busy hosts responsive

Inspect CPU, memory, swap and free disk with `dieter machine info`. Registered
background executions can keep using resources after their agent turn finishes;
inspect them with `dieter remote list --status running`. When distributing work,
include those executions and emulators as well as active agents. Keep enough
free disk for concurrent builds, dependency caches and swap. The turn-admission
disk floor is a last-resort check, not reserved build capacity.

The Homebrew service uses Standard scheduling so the daemon and its workers can
respond to interactive requests. Older service definitions may still use
Background scheduling. After upgrading the formula, an operator can activate the
staged release and refresh the service definition with `brew services restart
dieter`. This restarts the daemon; choose the activation time explicitly.
Installing or staging a new binary alone does not change the running service's
scheduling policy.

## Enroll another host

On the new machine, install the daemon and run:

```sh
dieter setup
```

Setup defaults to `https://gateway.getdieter.com` (STUN/TURN at
`turn.getdieter.com`; an allowed account is required); for self-hosting, pass
`--gateway https://YOUR-GATEWAY`. After GitHub sign-in, approve the machine name and
verification code. Setup starts the managed service and sets up
[device trust](#trusted-devices): on your account's first machine it starts the
device roster and prints a recovery key; on any other machine it prints a
one-time code to type on a device you already trust. On macOS it also registers
the background privacy helper (see [privacy mode](#macos-privacy-mode)). For manual service setups,
`dieter daemon enroll --gateway URL --name "Workstation"` handles enrollment and
`dieter daemon start` runs the daemon in the foreground.

## Trusted devices

Machines and apps talk to each other only when both are in your account's
**device roster**, the list of trusted devices that every machine and app
checks itself. The gateway stores the list but cannot add a device to it. The
[security model](/docs/security/#trusted-devices) explains why.

### Start with the first machine

On the first machine of your account, `dieter setup` starts the roster when the
account has none; `dieter device init` does the same on its own. It prints a
recovery key once:

```text
Recovery key (shown once; store it offline, e.g. on paper):

  DRK1-…
```

Store the key offline. It adds a machine back when no trusted device is left,
and anyone who holds it can add a machine to your account. Setup starts a roster
only when the gateway reports that your account has none. If you already use
Dieter on other devices and setup starts one anyway, check your gateway: it may
be compromised.

### Pair an app

Sign in to the app. Until another device approves it, the app shows a pairing
screen with a one-time code instead of your machines. On a device you already
trust, type that code:

- in an app, under **Add a device** in **More › Devices** (Android, iPhone and
  iPad) or **Settings › Devices** (Mac);
- on a machine, with `dieter device approve CODE`, where `CODE` is the code the
  app shows (for example `ABCD-EFGH-JKMN-PQRS`; case and hyphens do not matter).

The app becomes trusted a few seconds later. The two devices do not need to be
on the same network.

{{< callout type="warn" title="Only type a code you see yourself" >}}
Type a code only when it is on the screen of your own new device. Anyone whose
code you type gets full access to your machines.
{{< /callout >}}

### Pair another machine

After `dieter setup` on a further machine, it waits with a code:

```sh
dieter device status          # PENDING, with the pairing code
```

Type the code on a trusted device as above. On a trusted machine,
`dieter device requests` lists the devices waiting to join, by name only;
codes are never listed.

### Manage devices

The **Devices** screen lists your account's machines, apps and recovery key, the
devices waiting to join, and recent changes such as "Pixel 9 was added by
Studio". **Remove** takes a device out of the roster; machines refuse it from
its next call. **Reset this device** gives this app a new key, after which it
pairs again.

```sh
dieter device status                     # state, roster head and every device
dieter device roster                     # the signed history: who added or removed whom
dieter device revoke DEVICE_ID           # remove a device (IDs start with dv_)
dieter device sync                       # refresh the roster from the gateway
dieter --machine MACHINE_ID device sync  # also offer this machine's roster to another one
```

`status`, `roster`, `sync`, `requests`, `approve` and `revoke` accept global
`--machine`; `init` and `recover` run only on the machine itself. Agent turns
cannot change device trust.

If every trusted device is lost, set up a machine with `dieter setup`; it waits
with a code. Add it with the recovery key instead, then approve your other
devices from it:

```sh
dieter device recover --recovery-key -   # paste the key, then press Ctrl-D
```

A removed machine, or one that reports a conflict, cannot rejoin with its old
key. Run `dieter daemon unenroll`, then `dieter setup` to enroll it as a new
machine, and approve its code. See
[troubleshooting](/docs/troubleshooting/#a-device-is-not-trusted).

### Upgrading from 0.5

Release 0.6 introduced trusted devices. Nothing carries over, so after you
upgrade:

1. Update the gateway, every daemon and every app. 0.5 and 0.6 cannot talk to
   each other.
2. On one machine, run `dieter device init` (or `dieter setup`) and store the
   recovery key.
3. Every other machine waits with a code; `dieter device status` shows it.
   Approve it on the first machine with `dieter device approve CODE`.
4. Open each app, sign in if it asks, and type the code it shows on a trusted
   device.

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
relay. Every route is end-to-end encrypted between two trusted devices. Route
details distinguish **WebRTC · Direct** from **WebRTC · TURN**. TURN still
relays traffic. Read the [architecture](/docs/architecture/) for the transport
and ownership boundaries.

`machine info` reports live CPU, memory, processes, and optional GPU/sensor data.
An absent sensor is unknown, not a measurement of zero. Machine listings show
the daemon release, compatibility decision, and minimum required release. An
older but compatible release remains routable; Update Required does not.

{{< screenshot src="macos-machines.png" width="1380" height="870" alt="Office mini machine details showing its local route, CPU, memory, and GPU values over a multi-machine board" caption="Inspect the host from the Mac sidebar. These are capture-time values from an isolated fixture, not performance claims." >}}

## macOS privacy mode

Open a Mac's machine details and choose **Actions → Lock Local Screen…**.
Physical displays go black and standard local keyboard, mouse and trackpad
input is suppressed while remote control and desktop agents continue working.
**Unlock Local Screen…** restores the local desktop. A small shield beside the
machine in the Mac sidebar shows privacy is on. Offline status is marked last
known; a warning shield means protection is degraded.

```sh
dieter --machine MACHINE_ID machine privacy status
dieter --machine MACHINE_ID machine privacy setup
dieter --machine MACHINE_ID machine privacy on --key UNIQUE_LOCK_ID
dieter --machine MACHINE_ID machine privacy off --key UNIQUE_UNLOCK_ID
```

Privacy mode uses a separate, signed `DieterPrivacyHelper.app` background
service; the daemon itself stays unprivileged, and the daemon and capture helper
remain standalone executables. `dieter setup` registers the helper (with
`--no-open` or `--no-start` it is deferred to `machine privacy setup`, which is
also **Set Up Privacy Mode…** in the app). An administrator approves **Dieter
Privacy Helper** in **Login Items & Extensions** and grants Input Monitoring on
the target Mac; setup never turns privacy on. Protection exclusively claims the
matched keyboard, pointer and digitizer HID devices, with a secondary session
filter; `status` reports the protected device count and whether setup is still
required. Lost protection is reported as degraded; the Lock Screen shortcut that
Dieter then requests is not a verified authentication lock.

Protection belongs to the host. It continues when viewers disconnect and across
a daemon restart, and clears when the Mac reboots. Omit `--machine` to control
the local daemon. Accessibility permission and compatible display transfer
tables are required; unsupported configurations report a reason.

This keeps an already logged-in graphical session private. It does not replace
macOS authentication or FileVault, and cannot prevent hardware/system shortcuts,
secure-input bypasses, helper failure or permission revocation. Normal macOS
login protections still apply after reboot. Terminal agents do not require an
unlocked graphical session. The
[implementation notes](https://github.com/dbpprt/dieter/blob/main/native/macos/privacy-mode-research.md)
describe the mechanism and how it was verified.

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
Keep raw port **4242 loopback-only**. It also requires the daemon's local API
token, which only the daemon user can read. Direct access runs the same mutual
TLS as every route: the client accepts only the machine's key from the device
roster, and the daemon accepts only a trusted device with a short-lived token
bound to it.

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

## Recover a re-enrolled machine

If a machine was accidentally enrolled again and its earlier conversations still
belong to the revoked original ID, keep the original `DIETER_HOME` and private
key. On that machine, after updating the gateway and CLI, run:

```sh
dieter daemon recover --old-id ORIGINAL_ID --confirm RECOVER
```

Recovery requires the active replacement and the revoked original to belong to
the same account and share the original key. Restart the daemon service, check
the original chats, then explicitly revoke the replacement ID. Never edit gateway
storage or `identity.json` by hand; see `dieter daemon recover --help`.

## Unenroll

On the machine being removed, run `dieter daemon unenroll`. It removes the
machine from your trusted devices, revokes its gateway identity, and deletes
its key and gateway credential while retaining project data, conversations,
schedules, and harness settings. Enrolling it again creates a new machine that
a trusted device approves.
