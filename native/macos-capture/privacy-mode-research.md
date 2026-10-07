# macOS privacy mode: design and qualification

Dieter implements boot-scoped local privacy for an already logged-in macOS
session. **Set Up Privacy Mode…** registers the privileged input helper; local
administrator approval and Input Monitoring permission are required.
**Lock Local Screen…** exclusively opens matched HID input devices and blanks
physical display transfer tables while remote control and desktop captures
continue. **Unlock Local Screen…** restores the display tables and local input.
The Mac sidebar shows a small shield, an explicit warning for degraded
protection, and last-known styling while offline.

## Research

[Jump Desktop Fluid privacy mode](https://docs.jumpdesktop.com/viewer/session/privacy-mode/)
blanks physical monitors and blocks keyboard/mouse, then locks the host at
session end. [Apple Remote Desktop curtain](https://support.apple.com/en-gb/guide/remote-desktop/apd37d6089c/mac)
also supports remote work behind a local locked screen. Neither product's public
documentation supplies a curtain API for Dieter's capture stack.

[Curtain](https://github.com/acamarata/curtain) was inspected at
`119e49d76d7d251867b2955859818d05ef3fc3dc`. Its
[input filter](https://github.com/acamarata/curtain/blob/119e49d76d7d251867b2955859818d05ef3fc3dc/Sources/CurtainCore/InputFilter.swift)
classifies HID-source events with a session tap. Its black-window approach needs
capture exclusions. Apple's [ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
provides explicit filters, but independent agent screenshots would still see
those windows. `NSWindow.sharingType = .none` is a legacy mechanism and cannot
establish compatibility with current captures.

Dieter therefore uses public `CGGetDisplayTransferByTable` /
`CGSetDisplayTransferByTable` to blank output after desktop composition. The
helper verifies zero RGB tables for every online display. Captures use normal,
unmodified content filters. Configurations that cannot read/write and verify
the tables are rejected.

## Ownership and state

The signed native capture helper runs a separate privacy service, independent
of viewers, encoders and the daemon's transport lifetime. A same-user private
Unix socket, mode 0600 in a private runtime directory, permits replacement
daemons to adopt the existing owner. A native owner lock serializes launches.
An explicit unlock restores displays before releasing the event tap and exits
the helper. An unused off helper has a bounded idle lifetime.

`DieterDaemon.app` contains the main Go daemon and its existing native capture
executable. Privacy HID code is compiled into the capture executable; there is
no separate privacy app or binary. Public `SMAppService` registers the bundle’s
LaunchDaemon in a restricted `--privacy-hid-service` mode of that same executable;
approval belongs to macOS. The root process only accepts status/on/off over a
launchd-owned transient Unix socket. Audit-token code validation requires the
capture identifier and our signing team. Development builds trust only their
exact capture CDHash; the development branch is excluded from release builds.
Clients cannot supply a file path, program, shell command or persistent root
state. The main daemon and capture process retain login-user privileges.

The root input lease belongs to the acquiring login UID. It survives transport
and user-helper disconnects; another login cannot release it. Its state is
memory-only, so reboot starts off. A replacement root process has a new generation
and cannot silently satisfy the user's old lease. The user helper reports degraded
until explicit on adopts the replacement. Registration never enables privacy.

The daemon atomically records the desired state under `DIETER_HOME`, using its
central mutation lock and `kern.bootsessionuuid`. Same-boot startup restores the
request; records from an earlier boot do not reactivate privacy. Constructors
start no restoration workers. Uncertain enable replies retain the request for
reconciliation. On/off are set operations, with bounded machine-operation
idempotency receipts.

`GetMachineInformation` reports `MachinePrivacy` and action capabilities.
`PerformMachineOperation` handles privacy on/off through the same explicit core
API and thin Connect adapter as local, direct TLS and gateway relay operations.
The CLI exposes `dieter [--machine ID|NAME] machine privacy status|setup|on|off`.
Owner-only `WatchChanges` snapshots and deltas feed the shared core, so closing
machine details does not stop sidebar updates. Privacy is not replicated as an
account preference or stored on the gateway.

Requested and effective states are separate. `ON` requires acknowledged native
protection; `DEGRADED` exposes lost or unverified protection. A failed display
restoration retains requested state and permits retrying unlock. Native audits
run every 250 ms; the daemon checks current state through its bounded snapshot
cache. Display hot-plug is reconciled by those audits.

## Input and protection limits

An active `.cgSessionEventTap` at `.headInsertEventTap` drops HID-source keyboard,
modifier, pointer, button, drag, scroll and observable system events. Synthetic
input remains available to Dieter and desktop automation. Dieter's injector uses
its own private event source. Event taps require Accessibility permission; a
root HID-location tap alone would still miss keyboard events under Secure Event
Input, as [Karabiner's developers document](https://github.com/pqrs-org/Karabiner-Elements/blob/main/DEVELOPMENT.md#the-difference-of-event-grabbing-methods).

The privileged service uses public `IOHIDDeviceOpen` with
`kIOHIDOptionsTypeSeizeDevice` before the session event path. It matches keyboard,
keypad, pointer/mouse, joystick/gamepad, consumer-control and digitizer collections.
Matching callbacks attempt to seize attached devices; a bounded rescan reconciles
enumeration. Rejected devices, revoked Input Monitoring or device overflow never
produce an active status. Partial acquisitions retain owned devices until unlock.
Off remains usable after Input Monitoring is revoked, and restoration can retry.

On lost protection, the user service requests Apple's Control-Command-Q Lock
Screen shortcut once per failure episode. This is a best-effort request, not
verified authentication. The state stays degraded regardless of that request;
no automatic password entry or OS unlock is implemented.

This is privacy for the normal graphical session, not a macOS authentication
lock. Forced power/reboot, unqualified device/gesture paths, hot-plug timing,
permission revocation and helper crashes can bypass or remove protection. Local
software with synthetic-input privileges is outside this physical-input boundary.
A forced reboot
clears privacy by design. FileVault and macOS login remain independent; Dieter
cannot unlock them. No verified automatic authentication-lock fallback is claimed.
Ordinary terminal agents do not require an unlocked desktop.

A successful table readback verifies macOS state, not the physical panel's
behavior on every display transport. DisplayLink, HDR, mirrored displays,
hot-plug, actual USB/Bluetooth hardware and every agent provider need their own
hardware qualification before making broader guarantees. Do not infer those
results from synthetic fixtures.

## Reproducible checks

```sh
mise exec -- just pipeline check component:mac operation:screens_native_test
DIETER_TEST_PRIVACY_PHYSICAL=1 mise exec -- just pipeline check component:mac operation:screens_native_test
mise exec -- just pipeline core_test
mise exec -- just pipeline mac e2e cases:mac.machine
```

Set `DIETER_TEST_PRIVACY_HELPER` to the absolute path of the exact capture binary
approved with its development daemon bundle for the opt-in desktop test. It
controls the real capture-service socket and privileged service, without giving
the test executable a root authentication exemption. Complete local administrator
approval and Input Monitoring before this required opt-in run.

The opt-in desktop test changes the display tables briefly and restores them.
Use only an owned, idle desktop. It checks all-black table readback, unfiltered
ScreenCaptureKit pixels, HID-source suppression, remote-source delivery and
exact restoration. It does not claim independent physical-panel observation or
a physical USB/Bluetooth keyboard matrix.
It also requires a nonzero protected-device count and confirms protection during
an owned Secure Event Input interval. This does not qualify every physical key,
consumer key, gesture or peripheral pathway.

On 2026-10-06, the Apple M4 test host with one GLKVM display (2560 × 1440)
passed the earlier session-filter implementation's transfer-table/capture probe
and native input/capture/restoration assertions. Those results do not qualify
the new privileged HID seizure. Lease tests cover degraded audits and retryable restoration. The
Go suite covers helper adoption, bounded protocol, boot requests, uncertain
mutations, change-stream updates and isolated CLI routes. Shared-core tests
cover cache/reset, freshness, degraded presentation and operation menus. The
packaged Mac case clicks the real Actions menu, Lock/Unlock confirmations and
result alerts through the isolated authenticated fixture. After closing details
it verifies the sidebar shield's VoiceOver label and captures the rendered row;
it never blanks the operator screen through that fixture.

On 2026-10-07, the enhanced implementation passed the isolated packaged Mac
machine journey (18 assertions, including setup, lock, unlock and the rendered
sidebar shield), 709 shared-core tests, the Go API/CLI/runtime race tests and
145 pipeline contract tests (701 assertions). Portable packaging support tests
passed; their Linux service lifecycle test was unavailable on this macOS host.
The native helper gate passed lease/recovery and capture integration checks,
including a real kernel peer-token/code-signature round trip. A release-mode
helper build confirmed that development capture trust is excluded. Android
passed 28 unit tests and lint; the iOS app and its test bundles built successfully.
The privileged desktop opt-in remains unqualified until the task-owned helper
is approved in macOS and receives Input Monitoring permission. Software and UI
fixture results must not be presented as proof of physical shortcut suppression.

On 2026-10-07, privacy was integrated into the existing daemon capture executable
and the complete `DieterDaemon.app` package. The standalone privacy application
and executable were removed. The Homebrew service keeps its existing real
`bin/dieter` path; staged copies must match the bundle's signed executables
exactly. The bundle, service definition and executable pair activate and roll
back together. Tests cover adoption of a pre-bundle activation journal and
restoration of the previous installation after a failed startup.

The final integrated native gate passed admission, lease, restart, live caller
authentication and capture integration checks. The updated portable installer
suite passed 84 tests with the existing Linux lifecycle skip on macOS; the
pipeline contracts passed 145 tests / 701 assertions. Shared-core tests passed,
as did service runtime / machine race tests, focused privacy API tests and Go
vet. Three server cases timed out under concurrent test load and passed on a
focused rerun. A release-mode capture build and bundled signature verification
passed; the development identity lookup is absent from the release executable.

The task-owned development bundle is
`tmp/privacy-daemon-current/DieterDaemon.app`. Real setup registration succeeded
and System Settings displayed `DieterDaemon` awaiting administrator approval.
The earlier task-owned standalone helper was unregistered. No privileged
physical-input qualification or privileged ON operation has completed yet:
Login Items approval and Input Monitoring remain required before the desktop
opt-in can qualify this integration. Its results must not be inferred from the
isolated UI or software tests.
