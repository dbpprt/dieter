# macOS privacy mode: design and qualification

Dieter implements boot-scoped local privacy for an already logged-in macOS
session. **Lock Local Screen…** blanks physical display transfer tables and
suppresses physical session input while remote control and desktop captures
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

The daemon atomically records the desired state under `DIETER_HOME`, using its
central mutation lock and `kern.bootsessionuuid`. Same-boot startup restores the
request; records from an earlier boot do not reactivate privacy. Constructors
start no restoration workers. Uncertain enable replies retain the request for
reconciliation. On/off are set operations, with bounded machine-operation
idempotency receipts.

`GetMachineInformation` reports `MachinePrivacy` and action capabilities.
`PerformMachineOperation` handles privacy on/off through the same explicit core
API and thin Connect adapter as local, direct TLS and gateway relay operations.
The CLI exposes `dieter [--machine ID|NAME] machine privacy status|on|off`.
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
root-only HID-location tap is not used.

This is privacy for the normal graphical session, not a macOS authentication
lock. Hardware/system shortcuts, secure-input paths, permission revocation and
helper crashes can bypass or remove session-level protection. A forced reboot
clears privacy by design. FileVault and macOS login remain independent; Dieter
cannot unlock them. No private screen-lock API or unverified automatic OS-lock
fallback is claimed. Ordinary terminal agents do not require an unlocked desktop.

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

The opt-in desktop test changes the display tables briefly and restores them.
Use only an owned, idle desktop. It checks all-black table readback, unfiltered
ScreenCaptureKit pixels, HID-source suppression, remote-source delivery and
exact restoration. It does not claim independent physical-panel observation or
a physical USB/Bluetooth keyboard matrix.

On 2026-10-06, the Apple M4 test host with one GLKVM display (2560 × 1440)
passed the transfer-table/capture probe and native input/capture/restoration
assertions. Lease tests cover degraded audits and retryable restoration. The
Go suite covers helper adoption, bounded protocol, boot requests, uncertain
mutations, change-stream updates and isolated CLI routes. Shared-core tests
cover cache/reset, freshness, degraded presentation and operation menus. The
packaged Mac case clicks the real Actions menu, Lock/Unlock confirmations and
result alerts through the isolated authenticated fixture. After closing details
it verifies the sidebar shield's VoiceOver label and captures the rendered row;
it never blanks the operator screen through that fixture.
