# Experimental macOS virtual desktop for screen sharing

Date: 2026-10-04. Repository baseline: `6c23aede`, with unrelated working-tree changes present.
Status: research and implementation plan; no display configuration or runtime code changed.

## Recommendation

Build a temporary, viewer-sized virtual display into Dieter's macOS display
helper. Make it the main display, capture it through the existing
ScreenCaptureKit → VideoToolbox → WebRTC path, and optionally disconnect the
**physical display that was main when the session started**. Restore the host
layout when the controlling session ends.

The virtual-display part has credible implementation precedents. Physical
display disconnection is a separate compatibility and recovery problem, and
must pass a hardware spike before Dieter advertises the complete feature.
Use an explicit host-side experimental opt-in, disabled by default. Initially
target the existing helper's Apple Silicon/macOS 15+ deployment baseline.

This operates on the logged-in user's existing desktop. It does not create a
separate user session. Changing the main display can move windows, Dock, menu
bar, and Spaces; exact restoration of every application's window placement is
not guaranteed. Other physical displays remain enabled unless a future option
explicitly includes them. Disabling one display is not a claim that the entire
host is visually private.

## What the research establishes

| Requirement | Evidence and likely mechanism | Confidence / limit |
| --- | --- | --- |
| Create a virtual display | Private CoreGraphics Objective-C classes `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplaySettings`, and `CGVirtualDisplayMode`. Chromium and DeskPad have readable implementations. [1][2] | Strong evidence of feasibility; private API, requiring runtime checks and OS qualification. |
| Choose exact dimensions and HiDPI | Descriptor supplies maximum pixel dimensions and identity; settings supply modes, refresh, and HiDPI. Chromium's HiDPI helper uses half-sized logical mode dimensions for the requested backing pixels. [1] | Must enumerate and verify the actual resulting logical and pixel dimensions; do not assume one flag guarantees a match. |
| Make it the main display | Use public `CGBeginDisplayConfiguration`, `CGConfigureDisplayOrigin`, and `CGCompleteDisplayConfiguration`; arrange the virtual display at `(0,0)` and move the other displays consistently. [3][4] | Query `CGMainDisplayID()` after the transaction; macOS may adjust layout. |
| Disable a physical display | `displayplacer` calls private `CGSConfigureDisplayEnabled(config, display, false)`. [4] | Candidate API, not proof it works reliably on Dieter's supported Macs. Its README warns re-enabling may require unplugging/replugging. Do not ship that outcome. |
| Modern Apple Silicon disconnection | Lunar documents complete screen disconnection on Apple Silicon/macOS Ventura and explicitly restricted an earlier implementation because Intel was unreliable. [5] | Confirms the product behavior exists; does not establish BetterDisplay's internal implementation or a portable API contract. |
| Automate BetterDisplay | Its maintainer documents CLI virtual-screen creation/discard and connection changes; the CLI needs BetterDisplay running. [6][7] | Useful reference/prototype backend. App dependency, current Pro integration licensing, and restoration semantics make it a poor default Dieter dependency. [8] |

The public APIs inspected do not provide a supported equivalent to
`CGVirtualDisplay`. Keep private API use in the separately distributed macOS
daemon helper, outside the native viewer apps. Dynamic symbol/class lookup must
return an unavailable capability when unsupported; symbol presence alone is
not a successful functional probe. Signed release-helper behavior must be
tested, not inferred from an unsigned sample.

BetterDisplay's own safeguards matter: its maintainer explains that when only
virtual displays remain, it can reconnect physical displays automatically
unless its “Allow disconnecting all connected display” setting permits the
operation. [9] A reference experiment needs to account for this, without
changing an operator's saved BetterDisplay configuration automatically.
Chromium also contains a display-removal timeout workaround. [1] These are
reasons to test removal, failure, and recovery as thoroughly as creation.

## Where this fits in Dieter

Existing code already supplies much of the lifecycle:

- [`DisplayModeService.swift`](../native/macos-capture/DisplayModeService.swift)
  runs a dedicated display-service helper with bounded IPC and a heartbeat.
  It uses `.forAppOnly` for temporary physical mode changes, restores on exit,
  and yields to later local mode changes.
- [`display_modes.go`](../internal/remotedesktop/display_modes.go) serializes
  changes with the control owner, checks the expected mode, releases held
  input, fences input during geometry transitions, and restores the lease.
  [`display_modes_native.go`](../internal/remotedesktop/display_modes_native.go)
  supervises the helper independently of video encoders.
- [`DieterCapture.swift`](../native/macos-capture/DieterCapture.swift) discovers
  `SCDisplay`s, selects an explicit display ID, reads backing-pixel dimensions,
  and updates input bounds. Its `primary` alias follows main-display changes;
  virtual sessions must pin the returned actual ID instead.
- [`ScreenDisplays.kt`](../apps/core/shared/src/commonMain/kotlin/com/dbpprt/dieter/core/screens/ScreenDisplays.kt)
  implements the current client-side physical-mode matching lifecycle. Extend
  shared-core rules for virtual desktops rather than implementing separate
  policies in Swift and Android.

The existing physical-mode lease is a foundation, not a complete rollback
solution for topology changes. Apple's documented application-scoped rollback
returns to the session/permanent configuration. [3] It does not establish that
every private disconnection API will reconnect a display after a crash.

## Define “native resolution” precisely

Use the viewer's **actual drawable area in backing pixels**, after safe areas
and persistent controls. In fullscreen this can match the device's usable
native display area; in a window it matches the video viewport. Keep these
three dimensions distinct:

1. Host desktop logical points, controlling macOS UI size.
2. Host virtual-display backing pixels, controlling the captured image.
3. Viewer drawable pixels, controlling final presentation.

For example, a `2732 × 2048` viewport can use a `1366 × 1024` logical macOS
desktop at 2× backing scale, then transmit `2732 × 2048` pixels for 1:1 display.
Offer 1×/2× desktop UI scale independently of the viewer's OS density. A phone
with a 3× scale does not imply macOS exposes a corresponding 3× desktop mode.
Read back every mode's actual values.

The following current limits prevent a daemon-only change from fulfilling the
request across all viewing devices:

| Current code | Current behavior | Planned change |
| --- | --- | --- |
| Shared-core `ViewportPolicy.Desktop` [local source](../apps/core/shared/src/commonMain/kotlin/com/dbpprt/dieter/core/screens/ScreenPolicies.kt) | Even sizes, independently bounded to `3840 × 2160`. | Send actual settled drawable geometry and negotiate an exact supported target. |
| `ViewportPolicy.Tablet` | iOS uses a coarse `160 × 90` grid, capped at `1920 × 1080`. | Remove coarse sizing for this mode and report actual drawable pixels/orientation. |
| `ViewportPolicy.Fixed` | Android requests fixed `1920 × 1080`. | Report the measured video surface and update after rotation/fullscreen changes. |
| [Daemon normalization](../internal/remotedesktop/session_configuration.go) and [native capture validation](../native/macos-capture/CaptureProtocol.swift) | Independent width/height caps of `3840 × 2160`; above 60 fps clamps to 1080p. | Negotiate codec/hardware axis, pixel-count, and pixel-rate limits; qualify portrait dimensions explicitly. |
| [HEVC selection](../internal/remotedesktop/codec.go) and native encoder | Currently limited to `1920 × 1080` at 60 fps. | Initially use H.264 for larger targets when supported; report strict HEVC requests as unsupported rather than silently selecting a smaller desktop. |

Start with SDR at up to 60 fps and a bounded pixel budget no larger than the
existing 4K60 envelope. Supporting portrait and taller laptop displays requires
updating axis checks across host, core, signaling, and decoder validation; a
pixel-count comparison alone does not prove hardware support. Verify actual
encoder creation and the receiver's decoding capability. 5K/6K, HDR, and higher
refresh require separate qualification and are outside the first release.

Coalesce resize/orientation changes (reuse the 350 ms settle policy). Do not
reconfigure the host when transient toolbars or the software keyboard appear.
For odd dimensions or unsupported HiDPI combinations, use an explicitly
reported aligned size with a small border, or a negotiated scaled mode. Never
label that fallback an exact match. Show requested desktop, actual desktop,
and current stream size separately.

Keep network adaptation independent of desktop topology: congestion may reduce
stream quality or resolution, but must not repeatedly resize the host desktop.
Native dimensions remove resampling blur; H.264/HEVC compression and chroma
subsampling still mean the result is not guaranteed lossless or perfectly sharp.

## Proposed design

### Host policy and user experience

Add a machine-local experimental policy under the daemon's settings, persisted
through its API under `DIETER_HOME`. Do not replicate host availability as an
account-wide capability. Native viewers expose:

- **Use a virtual desktop** — requests a desktop matching the viewer.
- **Turn off the host's main physical display** — an additional option,
  available only for qualified hardware/OS combinations.
- **Desktop UI size** — 1×/2×, with sensible device-dependent defaults.
- **Restore host displays** — always reachable while the feature is active.

Advertise virtual creation and physical disconnection separately, with a reason
when either is unavailable. Resolve the original main physical display before
changing topology and show its name. If it is already virtual or ambiguous,
require an exact physical selection or use virtual-only mode. Do not silently
turn off another screen. Initially reject mirrored/unsupported source layouts.

### Native helper and daemon ownership

Extend the existing `--display-service` helper with a `VirtualDesktopDriver`
behind a small Objective-C bridge to the private APIs. Keep its lifetime
independent of capture/encoder restarts. Add the bridge to both the release
helper build and native fixture compilation through the existing Fastlane
owners; retain the same release, signing, and installation paths.

The helper retains the `CGVirtualDisplay` object for the lease lifetime. Give
it a Dieter-owned identity, a nonzero vendor ID, and a serial unique among
active virtual displays; Chromium documents those constraints on macOS 14.
Do not manage virtual screens created by BetterDisplay, Sidecar, or another app.

One controlling session owns at most one virtual-desktop lease per host GUI
session. This is a bound on a shared display resource, not an agent-turn cap.
Other viewers may view the same virtual display at their own stream size; they
cannot resize it. Restore on control handoff/release before a new controller
can acquire a differently sized desktop. Prevent disabling a physical display
that another live Dieter viewer explicitly selected; return an actionable
conflict. Viewers selecting `primary` need an explicit topology-change event.

### Transaction and recovery

Use an explicit state machine:

`idle → preparing → virtual-ready → presenting → physical-disabled → restoring → idle`

Virtual-only mode skips `physical-disabled`. Every transition has a deadline,
an observed result, and an idempotent restore path. On failure, retain an
accurate recovery state until restoration is verified.

1. Validate host opt-in, logged-in GUI session, permissions, current control
   grant, expected topology generation, target size, and codec capability.
   Resolve physical identities using UUID plus hardware identity; IDs can
   change after hotplug. Snapshot modes, origins, main display, mirroring,
   enabled state, and current capture selection.
2. Persist a bounded recovery journal before mutations using Dieter's central
   lock and atomic-write conventions. Arm recovery supervision before a
   physical display can be disabled. Capture no screen contents in the journal.
3. Create the virtual display, wait for display callbacks and ScreenCaptureKit
   enumeration, verify the exact mode, and start capturing its explicit ID.
4. Release held input and advance topology/display generations. Make the
   virtual display main with application-scoped layout changes. Observe the
   actual main display and bounds; refresh all affected capture/input mappings.
5. Require the controlling viewer to acknowledge a **presented frame from the
   new display generation** before disabling the old physical main. A helper
   or encoder “started” reply is insufficient. Disable only the recorded target
   through the qualified backend; verify both host state and continuing video.
6. Restore on explicit stop, session expiry, sustained transport/control loss,
   handoff, logout/user-session switch, sleep, helper failure, or permission
   loss. Follow existing bounded session grace periods instead of reacting to
   every short signaling interruption. Re-enable physical displays first,
   verify them, restore the owned layout, move capture off the virtual display,
   then release the virtual object. Notify affected spectators.

For ordinary daemon/IPC loss the live helper performs restoration. For helper
crash or `SIGKILL`, prove OS rollback or use an independently supervised,
bounded recovery process that was armed before disconnection. A `defer` block
is not a crash guarantee. If the platform cannot pass this test, do not enable
physical disconnection on it. Recover an unfinished journal on daemon start;
do not reapply a takeover automatically after reboot.

Recovery must yield to later local layout edits, restore only changes Dieter
owns, and never loop against BetterDisplay or System Settings. Hotplug ends or
revalidates the lease. If a disconnected screen cannot be identified or
restored, keep the surviving virtual display/capture available while reporting
the recovery error; do not remove the last working output blindly. WindowServer
crashes and pre-login/FileVault screens are outside a user-session helper's
recovery guarantee. Lid closure also needs qualification: a virtual display
alone does not guarantee the Mac stays awake in clamshell mode.

### API, CLI, and shared-core changes

Add explicit typed RPCs for capability/policy discovery, lease start, resize,
status, and restore. Return a lease ID, topology generation, virtual display
ID, actual logical/pixel dimensions, disabled physical IDs, and recovery state.
Mutations carry session/control identity, expected generation, and an operation
ID to resolve a lost response without creating a second display. Provide an
authenticated recovery operation that remains usable after the owning screen
session disappears; it may restore Dieter-owned changes only.

Proposed CLI group: `dieter screen virtual`, with policy, capabilities, start,
resize, status, and restore operations. Exact flags should follow the typed
contract; these commands do not exist yet. Support local, direct TLS, and relay
routes and global `--machine`. Implement on `grpcAPI` with thin Connect adapters,
regenerate with `just proto`, and update root/group/leaf help, CLI parity tests,
README, screen-sharing docs, and the Dieter CLI skill in the same change.

Put sizing, intent reconciliation, status, and lease rules in `apps/core`.
Mac/iOS/Android shells supply actual drawable metrics and render controls.
Do not expose the host's private macOS API in a viewer. Preserve input epochs,
display generations, bounded media queues, and authenticated control grants
across every topology change.

## Delivery sequence and acceptance gates

1. **Native feasibility spike.** On a reserved test Mac, create/remove an exact
   custom display at 1×/2×, make it main, and verify capture/input through the
   installed-style signed helper in the daemon's actual GUI context. Test the
   disconnection candidate, including a virtual-only remaining display.
   Record OS build, hardware, helper signing identity, dimensions, callbacks,
   and restore outcome. Compare with BetterDisplay if it is available under
   the operator's existing configuration. Do not make it a dependency.
2. **Recovery implementation.** Add the topology lease, ownership journal,
   restore operation, supervision, and fake backend. Inject failure after each
   transition, including daemon death, helper kill, stale requests, lost replies,
   local changes, hotplug, and control handoff. This gates screen disabling.
3. **Virtual-only vertical slice.** Add RPC/CLI/core/macOS viewer support and
   exact-size H.264 streaming with the physical screen still on. Qualify pixel
   alignment, input mapping, resizing, and restoration end to end.
4. **Complete experimental mode.** Enable main-display replacement plus
   physical disconnection only on combinations that passed the spike and
   recovery gates. Expose truthful availability and a recovery action.
5. **All viewing devices.** Replace iOS/Android fixed/coarse requests, qualify
   portrait and landscape envelopes and HiDPI, and measure receiver output on
   each platform. The full native-resolution objective is complete only here.

Validation must include 1920×1080 at 1×, 2732×2048 at 2×, a portrait phone,
an odd viewport, a taller Retina laptop, and an out-of-budget 5K request. Verify
actual virtual mode → capture → encoded frame → decoded frame → drawable size;
use one-pixel patterns and text to detect unintended resampling. Test pointer
corners, drags and held keys during transitions, multi-viewer behavior, network
loss/reconnect, sleep/wake, lock/unlock, fast user switching, and repeated
create/resize/restore cycles. Lock behavior must be observed, not treated as an
authentication bypass.

Use unit/fake-driver tests for lifecycle invariants; Go tests for
`internal/remotedesktop`, server, and CLI; Kotlin core tests for sizing and
ownership; native helper and viewer integration for OS/media behavior. Run
`just check-changed --dry-run` then the affected checks. Extend Fastlane's
catalog/fixtures and desktop leases for the intrusive host tests. Use temporary
`DIETER_HOME`, disposable credentials, and random loopback ports; never replace
the live daemon or run display-disabling tests on an operator desktop. Physical
iOS/Android evidence requires explicit exact-device profiles. Missing required
matrix cells remain unqualified.

The go/no-go decision is simple: ship virtual-only support if creation,
capture, and cleanup pass; ship the requested physical-display replacement
only after automatic recovery also passes. Treat partial support explicitly,
not as completion of the entire request.

## Validation of this planning change

Only this Markdown plan was added. Referenced repository paths and key source
claims were checked; no native display experiment, build, or runtime test was
performed. The repository's affected-check selector excludes documentation
from code checks. An attempted `just check-changed --dry-run` could not start
because this shell selected system Ruby 2.6 without the required Bundler 2.6.9.
That does not prevent review of this plan; implementation validation needs the
repository's configured Ruby/Bundler environment. Existing unrelated changes
were left intact.

## Sources

Sources were read through the GitHub connector and the installed Apple SDK.
This is source/documentation research, not an executed hardware proof.

1. [Chromium virtual display implementation](https://github.com/chromium/chromium/blob/main/ui/display/mac/test/virtual_display_util_mac.mm): private interfaces, HiDPI setup, macOS 14 identity requirements, retained objects, removal workaround.
2. [DeskPad screen controller](https://github.com/Stengo/DeskPad/blob/c3349f0e237e000cb4826fb3ea1cdd1c44949461/DeskPad/Frontend/Screen/ScreenViewController.swift) and [private declarations](https://github.com/Stengo/DeskPad/blob/c3349f0e237e000cb4826fb3ea1cdd1c44949461/DeskPad/CGVirtualDisplayPrivate.h): working application precedent for virtual display creation and capture. Its capture path differs from Dieter's ScreenCaptureKit path.
3. Apple `CGDisplayConfiguration.h`, inspected in the installed macOS SDK: public layout configuration, application/session/permanent scope and rollback, configuration callbacks. Public API references: [CGConfigureDisplayOrigin](https://developer.apple.com/documentation/coregraphics/cgconfiguredisplayorigin(_:_:_:_:)) and [CGCompleteDisplayConfiguration](https://developer.apple.com/documentation/coregraphics/cgcompletedisplayconfiguration(_:_:)).
4. [displayplacer source](https://github.com/jakehilborn/displayplacer/blob/c23026eb3d73000eb1a14b45d82fd6dd08c921f5/src/DisplayPlacer.c) and [README](https://github.com/jakehilborn/displayplacer#readme): origin/main semantics, private enable/disable call, reconnect caveat. Its permanent configuration behavior is not suitable for copying into Dieter's temporary lease.
5. Lunar [6.0.0 release notes](https://github.com/alin23/Lunar/blob/master/ReleaseNotes/6.0.0.md) and [5.9.6 alpha notes](https://github.com/alin23/Lunar/blob/master/ReleaseNotes/5.9.6a1.md): Apple Silicon disconnection and Intel reliability restriction.
6. [BetterDisplay maintainer: create/discard virtual screens and examples](https://github.com/waydabber/BetterDisplay/issues/2521#issuecomment-1928114756).
7. [BetterDisplay maintainer: connect/disconnect virtual screens](https://github.com/waydabber/BetterDisplay/issues/4002#issuecomment-2635097514) and [betterdisplaycli prerequisites](https://github.com/waydabber/betterdisplaycli#readme).
8. [BetterDisplay README](https://github.com/waydabber/BetterDisplay#readme): virtual screens, connection management, integration and Pro requirements. Public product documentation does not reveal its current internal display backend.
9. [BetterDisplay maintainer on virtual-only layouts and safeguards](https://github.com/waydabber/BetterDisplay/issues/4568#issuecomment-3194207439).

Before incorporating third-party code, check the specific file's license and
required notices; these references are evidence and design input, not an
instruction to copy an application's implementation wholesale.
