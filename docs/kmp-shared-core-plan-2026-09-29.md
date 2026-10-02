# Kotlin Multiplatform shared client core: deep dive, plan, and feasibility

Status: proposal backed by a working spike in [`apps/core`](../apps/core/README.md),
29 September 2026, baseline `4eaf615d`. Other agents' uncommitted work in the
tree was not touched. An earlier gomobile (Go) spike was removed at the
owner's request; its measurements appear here only for comparison.

**Superseded** by the [implementation plan](kmp-core-implementation-plan-2026-09-30.md),
the [macOS cutover plan](mac-shared-core-cutover-plan-2026-10-01.md), and
[`apps/core/README.md`](../apps/core/README.md). Android and macOS run on the
core; iOS does not yet. The Apple framework and façade are named
`DieterShared`, not `DieterCore.xcframework` and `AppleCore`. This record is
otherwise unchanged.

**Recommendation:** move the Android, macOS, and iOS business logic into a
Kotlin Multiplatform module, `apps/core`. Android consumes it as ordinary
Kotlin. The Apple apps link it as `DieterCore.xcframework` through a thin
façade.

- **Platform-native code stays for** transport (HTTP/2 with gRPC trailers), TLS
  pinning, credentials, and all media and rendering: screen sharing, terminal
  views, notifications, and widgets. The core reaches this code through small
  "native extension" interfaces.
- **Tests:** the core is tested end to end on the JVM against a real gateway
  and daemon, with no device.

The spike runs one core on the JVM, the Android variant, macOS, and the iOS
Simulator. Linked into iOS, it adds 5.0 MB.

## 1. What the clients duplicate today

| Concern | Swift (Mac / iOS) | Kotlin (Android) |
| --- | --- | --- |
| Route selection: pinned direct TLS, relay, WebRTC race | `ConnectionManager.swift`, `DieterRPC.swift`, `HedgedRoute.swift` | `DieterRepository.kt` (1,442 lines), `HedgedRoute.kt` |
| Connection phases, backoff, stale streams | `DieterStore+Connection.swift` (1,288), `DieterStore+Sync.swift` (1,030); iOS `IOSStore.swift` (1,160) | `DieterConnectionManager.kt` (2,346) |
| Sync replica and disk cache | `SyncState.swift`, `DieterSyncPersistence.swift` (Mac only) | `GlobalSyncPolicy.kt`, `DieterSyncStore.kt` |
| Durable outbox, optimistic overlays | `DieterOutboxPolicy.swift`, `OutboxJournal.swift` (Mac only) | `ConversationOutboxPolicy.kt` plus about 500 lines in the manager |
| Causal card merge | `CardStateProjection.swift` | `CardStateProjection.kt` |
| Terminal control | `TerminalsModel`, `TerminalOverviewModel`, `TerminalInputForwarder`, `TerminalOutputAccumulator`; iOS `IOSTerminalsModel` (about 1.2k lines) | `TerminalController`, `TerminalInputController` (322) |
| Screen-session control | Mixed into `RemoteDesktopController.swift` (1,377) and iOS `IOSRemoteDesktopSession.swift` (1,192) | `ScreenController.kt` (774) plus about 470 lines of pure policy |

The copies have drifted:

- `applyGlobalDelta` keeps changed objects in place on Swift but moves them to
  the end on Kotlin.
- iOS has no WatchSync, outbox, or offline cache. It polls every 15 s.
- Reconnect backoff is 1 s × 1.8 up to 15 s on Mac, and 750 ms × 2ⁿ up to 10 s
  on Android.
- Android never uses loopback routes.

**Why Kotlin fits.** Android's non-UI code is already Kotlin. Classified by
the platform APIs each file imports:

| Android main sources | Lines | What happens to them |
| --- | --- | --- |
| Pure Kotlin | 2.8k | Moves to `commonMain` almost verbatim once the protobuf types change. The spike moved `CardStateProjection.kt` this way. |
| JVM-only APIs (`java.time` and similar) | 1.0k | Moves after swapping in multiplatform equivalents. |
| Business logic entangled with `Context`, `SystemClock`, `Log`, `AndroidChannelBuilder` | 9.3k | Must be refactored; the core logic in `DieterConnectionManager`, `DieterRepository`, `DieterSyncStore`, and `SharedKV` sits here. |
| Compose UI | 24k | Stays native. |

## 2. Target architecture

```
SwiftUI/AppKit ── @Observable adapter                 Compose ── ViewModel (StateFlow)
      │  apple façade: AppleCore (bytes, callbacks, async)      │  Kotlin API, Wire models
      └──────────────────────────┬───────────────────────────────┘
                     apps/core/shared (commonMain)
  session · machine selection · route choice (direct → relay) · token renewal
  WatchSync replica + cache · durable outbox · card merge · terminal/screen control
                                 │ Wire-generated gRPC stubs over GrpcClient
         native extension: OkHttp (Android/JVM) │ grpc-swift bridge (Apple)
                                 │
                      gateway ── relay ── daemon
```

**Modules**

- `shared` targets `android`, `jvm` (host tests), `iosArm64`,
  `iosSimulatorArm64`, and `macosArm64`. The Mac app ships arm64 only, so there
  are no x86_64 targets.
- `jvmShared` is an intermediate source set holding the OkHttp transport for
  Android and the host JVM.
- `apple` depends on `shared` and is the only module exported to
  Objective-C/Swift.

**Models.** Wire generates Kotlin models and client stubs from `api/proto` into
`com.dbpprt.dieter.api.*`. The build rewrites `java_package` in a copy of the
protos, so the Wire classes can share one classpath with the app's existing
protobuf-lite classes during migration.

**Boundary rules**

1. Android uses the core's Kotlin API and `StateFlow` directly.
2. Apple uses `AppleCore`:
   - domain values cross as protobuf bytes, so the SwiftUI views keep the
     SwiftProtobuf types they render today;
   - state arrives through an observer callback;
   - suspend functions appear in Swift as `async throws`.
3. Every piece of platform work is an interface in the core, implemented natively:

| Native extension | Android / JVM | Apple | Core interface |
| --- | --- | --- | --- |
| HTTP/2 + gRPC (trailers) | OkHttp via Wire `GrpcClient` | grpc-swift (`GRPCBridge`) | `CoreTransport`; `NativeRpcBridge` on Apple |
| Direct TLS pinning (CA + SPIFFE URI) | `DaemonTrustManager` (JSSE; BouncyCastle for Ed25519 on Android) | `DieterRPC.verifyDaemonCertificateChain` | `CoreTransport.direct` |
| WebRTC control data channel | libwebrtc AAR (`ControlRTCBridge.kt`) | WebRTC.xcframework (`ControlRTCBridge.swift`) | Planned: the core decides when to race; the platform supplies the byte stream |
| Terminal rendering | Termux view | SwiftTerm | `TerminalRenderer` (**tested**) |
| Screen media | WebRTC PeerConnection, MediaCodec, SurfaceView | WebRTC, VideoToolbox, Metal, capture helper | Planned `ScreenMediaEngine`; the core keeps start, trust, leases, recovery, feedback, and gesture/canvas math |
| Credentials and browser OAuth | AndroidKeyStore, Custom Tabs | Keychain, `ASWebAuthenticationSession` | Planned `SecureStore` and `BrowserLauncher`; PKCE and the token exchange live in the core |
| Signature checks (screen-session trust) | JCA / BouncyCastle | CryptoKit | Planned `SignatureVerifier` |
| Notifications, widgets, background work, share extensions | Native | Native | Core events |
| Persistence | Okio, in an app-provided private directory | Same | `CoreStorage` (common) |

## 3. Feasibility: what was built and run

**Code**

- About 1,150 lines of core Kotlin: `shared` plus the `apple` façade.
- 385 lines of Kotlin tests.
- About 420 lines across the Swift and Android harnesses.

**What the core implements**

- gateway compatibility and session checks, and machine selection;
- direct-then-relay routing with renewed daemon tokens;
- the WatchSync replica with pending-projection buffering and a disk cache;
- a bounded, atomic outbox that the daemon applies exactly once through
  `client_id`/`command_id`;
- the moved card merge;
- terminal sessions that resume after the last sequence.

**Results**

| Question | Result |
| --- | --- |
| Toolchain fit | Kotlin 2.4.10, AGP 9.3.1 with its KMP library plugin, Gradle 9.7, and Wire 7.1.0 all work with the app's versions. Kotlin/Native builds under **Xcode 27**. |
| Protocol models | Wire generates 328 Kotlin files from `dieter.proto` and `gateway.proto`, with gRPC stubs usable from common code. |
| Conformance tests (`commonTest`) | 8 tests pass on the **JVM**, natively on **macOS arm64**, and on a disposable **iOS 27 simulator**. They include the card-merge cases both apps ship today and an unsigned-clock case. |
| End to end on the JVM, against a real Go gateway and daemon (`scripts/isolated-gateway`) | 4 tests pass in about 9 s total:<br>• relay sync, then a cached projection after restart;<br>• a command queued while the daemon is offline survives an app kill **and** a lost acknowledgement, and is applied exactly once;<br>• a revoked session and an outdated release each stop retrying;<br>• a terminal session streams into a native renderer. |
| Android | A harness app builds with **both** the app's protobuf-lite models and the core's Wire models; there are no duplicate classes. The core's Android variant passes an end-to-end host test (2.8 s) and hands the snapshot to protobuf-lite by a byte copy (`toLegacy()`). |
| macOS | A Swift Testing test drives the core through an `@Observable` store, with grpc-swift as the transport: relay, first projection in 230–240 ms, card delivered, terminal output rendered by a Swift renderer, and cache restored offline. |
| iOS Simulator | The same Swift test passes on a disposable iPhone 17 Pro running iOS 27; first projection in 0.87 s, including simulator cold start. |
| Swift-facing surface | Before the façade split, the header was 17,560 lines and each static slice 30 MB. With only `apple` exported: **377 lines, 17 MB per slice**. |
| iOS size | **+5.0 MB** after linking, dead-stripping, and `strip -x` for arm64. The Go/gomobile spike added 12.9 MB. |
| Android size (unminified debug dex) | Core logic 440 methods / 55 KB. Wire models 9.6k methods / 1.25 MB. The app's protobuf-lite models, which migration removes, are 33k methods / 1.73 MB. |
| Build time on this machine | Warm run of `jvmTest` + macOS + iOS-simulator tests: 2 m 13 s. Release XCFramework (three release links): 12–19 min cold. The first native build downloads 1.6 GB to `~/.konan`. |

### Findings that shape the design

1. **Apple has no usable Kotlin HTTP/2 client with gRPC trailers**
   (URLSession and Ktor's Darwin engine expose no trailers). Transport must be
   a native extension; grpc-swift, already used by the apps, works well
   through a 130-line bridge.
2. **Wire vs protobuf-lite semantics:**
   - Fields keep snake_case names, and `value`/`data` become `value_`/`data_`.
   - `google.protobuf.Empty` maps to `Unit`.
   - `uint64` maps to `Long`; causal clocks must compare as unsigned. A test
     covers this.
   - Unset message fields are `null` instead of a default instance. Porting
     `CardStateProjection.kt` hit this trap and now keeps the old behavior
     explicitly.
   - Server streams need `explicitStreamingCalls = true`.
3. **Wire's JVM client gzips requests by default.** The Go gateway rejects them
   (`UNIMPLEMENTED: no decompressor`); the transport turns request compression off.
4. **Package collision:** Wire's classes would land in the same packages as the
   app's protobuf-lite classes. Relocation fixes it, and byte-level conversion
   bridges screens that are not yet migrated.
5. **Swift 6 concurrency:** Kotlin objects are not `Sendable`.
   - Adapters copy them into Swift values at the boundary.
   - Kotlin callback objects are boxed as `@unchecked Sendable`. They are safe
     to call from any thread in Kotlin/Native, but Swift cannot see that.
   - `suspend` maps to `async throws` (requires `@Throws`).
   - Flows are exposed as observer callbacks. SKIE 0.10.15 could expose them
     as `AsyncSequence`, but its compatibility with Kotlin 2.4.10 is unverified.
6. **Export surface:** everything public in the framework module is exported to
   Objective-C. Keep models and logic in `shared` and give `apple` only
   façade types.
7. **Build integration:**
   - AGP's KMP DSL expresses Android 37.1 as
     `compileSdk { version = release(37) { minorApiLevel = 1 } }`.
   - The consuming app must compile with Kotlin 2.4 or newer. The app's Compose
     plugin already provides this; the harness had to add it.
   - Gradle's `Exec` resolved `go` from the daemon's PATH, so the fixture task
     accepts `-Pdieter.go`.
8. `scripts/check_changed.py` selects no checks for `apps/core` yet.

### Not validated yet

- An Android instrumentation run on a device: the operator emulator was shut
  down, and the attached physical phone was not used.
- The direct TLS route: `isolated-gateway` advertises no direct candidate. The
  JVM trust manager is written but not exercised, and the Apple harness stubs
  the direct path.
- WebRTC control and the screen-sharing control plane.
- Background, suspension, and memory behavior, including the share-extension limit.
- Large-workspace performance. The spike re-encodes the full snapshot per
  change; production needs delta events.
- Wiring into the real app builds.

*Since validated (2 October 2026):*
- The Android app runs on the core on the emulator through the native test
  catalog (`just e2e run`).
- Pinned direct TLS is covered on the JVM (`CoreRuntimeEndToEndTest`) and
  from Swift (`SharedCoreIntegrationTests`).
- The screen-sharing control plane is covered by `ScreenSessionTest`,
  `ClientApiScreenEndToEndTest`, `just mac screens-test`, and the Android
  screens suite. The WebRTC control route runs in both apps, but no
  automated core test drives it.
- Android's live background sync runs on the core (`just e2e run --suite
  sync`). The iOS share-extension limit is untested, because iOS does not use
  the core yet, and memory was not measured.
- Board and transcript slices travel as keyed deltas. Their cost was not
  compared against the legacy implementations.
- Android and macOS run on the core.

## 4. Migration plan

Each phase ships behind a per-platform switch.

**Phase 1: foundation**

- Recipes: `just core test` and `just core xcframework`.
- CI:
  - `jvmTest`, including the Go fixture, on every core change;
  - native tests and the XCFramework build on macOS runners;
  - cache Gradle and `~/.konan`.
- Selector rules for `apps/core`.
- A direct-route option in `isolated-gateway`, so both pinning implementations
  are exercised.
- Apps consume the core:
  - Android: `includeBuild("../core")` plus `implementation("com.dbpprt.dieter:shared")`.
  - Apple: a binary target linked into the dynamic `DieterIOS` framework, so
    the app and its share extension share one copy.

**Phase 2: connection and sync**

- Replace Mac `connect()`, WatchSync, and the disk cache, plus iOS polling.
  iOS gains live sync and an offline cache.
- Replace Android's `openScopedMachine`, `collectGlobalSync`, and `DieterSyncStore`.
- Run the old and new paths side by side in debug builds for one release,
  logging any divergence.

**Phase 3: mutations and identity**

- Outbox for chats, messages, and card starts, with optimistic overlays and
  retargeting.
- `SharedKV`, machine directory and presence, token lifecycle.
- OAuth PKCE and exchange, behind `BrowserLauncher` and `SecureStore`.

**Phase 4: feature control planes**

- Terminals: replaces about 1.5k lines across three apps.
- Screen-session control behind `ScreenMediaEngine` (about 3.3k mixed lines
  today).
- Schedules, git/diff parsing, and activity/notification derivations.
- Move pure derivations of daemon state into daemon projections where that is
  simpler.

**Phase 5: consolidation**

- Android UI switches from protobuf-lite to Wire types feature by feature,
  then drops protobuf-lite and grpc-java.
- Apple keeps SwiftProtobuf models over the byte façade.
- Delete the duplicated Swift and Kotlin logic.

## 5. Testing strategy

1. **`commonTest` conformance**, on the JVM, macOS, and the iOS Simulator.
   During migration, the same golden cases run against the legacy Swift and
   Kotlin code before each switch.
2. **JVM end-to-end tests** against the real gateway and daemon from
   `scripts/isolated-gateway`. They take seconds and need no device. Cover:
   - every route;
   - faults: cut paths, daemon offline, restarts, token expiry;
   - durability: app kill, lost acknowledgements;
   - compatibility floors.
3. **Binding contract tests:** the Swift harness on macOS and the iOS
   Simulator, and Android host tests plus one instrumentation smoke test.
4. **Existing `tests/e2e` UI journeys**, unchanged.

## 6. Risks

| Risk | Mitigation |
| --- | --- |
| Kotlin/Native build time and toolchain size | Iterate on the JVM. Build the XCFramework only when `apps/core` or Apple code changes. Use debug frameworks locally, and cache `~/.konan`. |
| Xcode and Kotlin release coupling | Kotlin 2.4.10 worked with Xcode 27. Treat Kotlin upgrades as part of each Xcode upgrade and test both in CI. |
| Swift developers writing Kotlin | Keep the Apple façade small and documented. Put platform work behind native extensions written in Swift. |
| Android UI churn from snake_case Wire models | Migrate screen by screen with `toLegacy()`; removing protobuf-lite then shrinks the app. |
| Crash diagnosis across the boundary | Ship the Kotlin/Native dSYMs. Forward core logs to `os_log` and Logcat. Report failures as state, never as a crash. |
| Mobile lifecycle | Add pause and resume driven by `scenePhase` and the Android lifecycle. Android's foreground service keeps sync alive as it does today. |
