# Android sync warnings

The persistent red banners came from historical timeouts to offline laptops.
`GetState` returned every recorded failure, and Android blamed the reporting
machine without examining which peer failed, its presence, or the attempt age.
The selected machine was also excluded from routine directory refreshes, so a
warning collected before switching to it could remain after recovery.

The fix preserves diagnostic history while changing the current warning
projection:

- The daemon records authenticated peer availability without changing attempt,
  success, or workspace cursors. Offline/removed-peer transport failures,
  cancellations, and transport attempts older than five minutes do not become
  current workspace warnings. Record rejection and non-transport failures are
  not suppressed by age or presence.
- Android retains structured diagnostics, checks the affected peer's presence,
  names both machines, and suppresses old live warnings while disconnected.
  Routine refreshes include the selected daemon and consume diagnostics even
  when its workspace response is unchanged.
- Navigation subscriptions pause with their route and rebind on recovery.
  Brief transport interruptions get ten seconds to recover. Persistent errors
  explain reconnection, sign-in, or access problems without exposing transport
  metadata. A successful read cannot hide a failed pending edit, and a local
  edit cannot erase a read error. Account changes clear the prior account's
  error state while its durable outbox remains in its account cache.

No new RPCs, data resets, gateway changes, or operator-daemon restarts are needed.
The change is local source work and has not been published or installed on a
physical phone.

Validation includes Go race tests and vet for affected packages, 428 Android
unit tests, APK assembly, and isolated device tests on `Pixel_9_API_37_1`
(`emulator-5554`). The focused device run passed navigation rendering, real
gateway offline-edit replay, and five new recovery tests, including selected
machine diagnostics with an unchanged workspace cursor and account switching.

Focused evidence: `tmp/e2e-sync-warning-recovery/results.json`.
Before/after UI captures are in that run's
`component.navigation-folders-test/captures/` directory as
`project-sync-needs-attention.png` and `project-sync-recovered.png`.

The final `just check-changed` passed, including all **44 affected Android
device cases** with no failures or unavailable results. Full device evidence:
`tmp/e2e-1457123323/results.json`. The earlier attempts interrupted by a shared
device lease and a closed emulator were superseded by this complete run.
Final debug APK assembly passed, and the owned emulator session saved its
snapshot and stopped cleanly after verification.
