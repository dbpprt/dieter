# Implementing all client logic in the shared KMP core

Status: implementation plan, 30 September 2026, baseline `ca36c81f`.
**Complete for Android and macOS (2 October 2026); iOS has not moved.** This
plan is kept as a record and is superseded, for macOS, by the
[macOS cutover plan](mac-shared-core-cutover-plan-2026-10-01.md) and, for the
current core, its parity matrix, and its deviations, by
[`apps/core/README.md`](../apps/core/README.md). Notes marked *As built*
below correct the plan where the result differs.

It builds on the [feasibility spike](kmp-shared-core-plan-2026-09-29.md),
committed as [`apps/core`](../apps/core/README.md). The inventory figures
come from file-by-file surveys of all three clients and a trace of every RPC
call site. Line counts are approximate where a file mixes responsibilities.

## 1. Summary

**Scope.** About 44k lines of client business logic move into one Kotlin
Multiplatform core:

| Source | Logic that moves |
| --- | --- |
| Android | About 16.1k of 38.2k lines |
| macOS | About 23.7k of 59.4k non-generated lines |
| iOS | About 4k lines, plus logic embedded in views and the share extension |

Much of it is the same logic written two or three times, so the core should
settle at roughly 18–22k lines of Kotlin. It must cover **125 of the 151
RPCs**; the other 26 are used only by the CLI or daemon.

**What stays native:**
- UI and rendering;
- media: WebRTC, decoders, Metal/SurfaceView, the capture helper;
- OS integration: notifications, widgets, services, share extensions, pasteboard;
- secure storage;
- the gRPC/TLS transport.

The core reaches all of this through a fixed set of extension interfaces
(§3, D6).

**Order of work:**

| Wave | Content | Depends on |
| --- | --- | --- |
| F | Foundation | — |
| W1 | Session and connectivity | F |
| W2 | Sync and replica | W1 |
| W3 | Mutations and durable intent | W2 |
| W4 | Conversation | W2 (partly overlaps W3) |
| W5 | Feature domains | W2; its nine packages can run in parallel |
| W6 | Screen-sharing control plane | W1 |
| W7 | Consolidation and deletion | Rolling, per domain |

**Cutover order:** within each wave, Android switches first (Kotlin, no
bridge), then iOS (the thinnest client, which gains the most), then macOS
(largest surface, most performance-sensitive).

**When a domain is done:**
- it is implemented once in `commonMain`;
- it is tested on the JVM, natively on macOS, and on the iOS Simulator;
- it is exercised end to end against the real gateway and daemon;
- it is switched on in all three apps;
- the legacy code is deleted.

**Status (2026-10-03):**
- F through W6 and the D7 contract are implemented and tested. The legacy
  importers were built and then deleted unused: neither app imports state
  from its versions before the core.
- Android is fully migrated in one pass, without rollout switches, shadow
  mode, or soak, since there are no users yet. The app's logic layer,
  protobuf-lite, and grpc-java are deleted; the Compose UI calls the core's
  Kotlin domain APIs and reads Wire models and core views directly.
- macOS is fully migrated, one domain at a time, through the
  [cutover plan](mac-shared-core-cutover-plan-2026-10-01.md). Its feature
  plane and Swift rule copies are deleted; views read slices and call
  `SharedRules`. The Apple adapter harness became the Mac's `SharedCore`
  target, and the core's Android harness was deleted.
- iOS is fully migrated through the
  [iOS cutover plan](ios-shared-core-integration-plan-2026-10-02.md); the
  Swift `DieterCore` and `DieterClient` modules are deleted. A follow-up
  audit moved the last duplicated rules (quota rows on Android, Git
  operation copy, gateway commands, chat and timeline wording, file
  editability, screen-binding checks in Mac tests) into the core.
- The parity matrix and the deviations from this plan are in
  [`apps/core/README.md`](../apps/core/README.md).

## 2. Scope

**In scope:** every piece of non-view client logic on Android, macOS, and iOS:

- identity;
- compatibility;
- machines;
- routing;
- connection supervision;
- sync;
- outbox and optimistic state;
- navigation sync;
- drafts and composition;
- conversation reading and presentation;
- board;
- schedules;
- terminals;
- workspace, git, and files;
- projects and admin;
- settings and quotas;
- activity, inbox, and notification decisions;
- search;
- executions;
- the screen-sharing control plane.

**Out of scope:**
- the Go daemon, gateway, and CLI, except for new test-fixture options;
- native UI, including the iOS screens needed to expose features iOS gains
  (a separate "iOS parity UI" track);
- media pipelines;
- `native/macos-capture`, plus the two Swift files it compiles in
  (`RemoteDesktopKeyMap.swift`, `ScreenClipboardContent.swift`).

**Dead code, not ported:**
- **Android:** connection manager L2056-2080; `retargetOutboxEndpoints`;
  `reconcileCardsDuringOperations`; `sharedBoards`; `runFeatureCall`;
  `readableTerminalError`; `Repository.watchState` and the duplicate
  schedule/terminal wrappers.
- **Swift:** `settings()`, `updateSettings`, `watchState`,
  `remoteDesktopSession(sessionID:)`.

## 3. Architecture decisions

Decisions marked **(confirm)** need the owner's agreement (§9).

**D1 — Modules** (`apps/core`):

| Module | Contents |
| --- | --- |
| `:model` | Wire models and gRPC client stubs, relocated to `com.dbpprt.dieter.api.*`, plus the client UI schema from D7 |
| `:shared` | All logic. Platform implementations live in `jvmSharedMain`, `androidMain`, and `appleMain`. |
| `:testing` | Test kit: virtual time, scripted transport, fake file system, fixture launcher, fault proxy, conformance runner |
| `:apple` | The Swift façade; the only module exported to Objective-C/Swift |

The Apple framework is renamed **`DieterShared`**, because `DieterCore` is
already the name of a Swift target that iOS imports.

**D2 — Runtime shape.** A `ClientRuntime` owns this tree of scopes:

```
ClientRuntime
└── AccountSession        (gateway + sign-in)
    └── MachineSession    (one per daemon: route, token, replica)
        └── FeatureBinding(target)   (conversation, terminal, schedules, screen session, …)
```

- Each node is a coroutine scope, so rebinding cancels its children. This
  replaces the generation counters and stale-result guards used today:
  Android's `FeatureRequests`, the Mac's `OwnedRead`, and `generation`/`&+= 1`
  guards.
- State lives in `StateFlow`s, updated on a per-session single-threaded
  dispatcher, so reducers need no locks.
- Mutations are `suspend` commands.

**D3 — Time and retry.**
- `Clock`, `TimeSource`, and dispatchers are injected everywhere; tests use
  virtual time.
- A single `Backoff` table replaces the six formulas duplicated today:
  750 ms→10 s, 500 ms→8 s, 750 ms→15 s (60 s when the disk is full),
  250 ms→5 s, 1.8×→5 s, and 1 s×1.8→15 s.

**D4 — Errors.** One `CoreError` type: transient, permanent,
unauthenticated, update-required, out-of-storage, not-found, cancelled. It is
mapped from `GrpcStatus` in exactly one place. It replaces:
- `DieterRPCFailure`;
- `outboxFailureIsPermanent`;
- `ScreenRecovery` and `RemoteDesktopRecovery` retry classification;
- `NavigationSyncHealth`;
- `IOSUserError`.

**D5 — Persistence.**
- `CoreStorage` gives each domain its own namespace, with atomic writes and
  schema-versioned proto files.
- Every storage area is bounded.
- One-time importers bring over existing on-device state (§5.3), preserving
  each install's client ID, because outbox idempotency depends on it.

**D6 — Platform extensions** (interfaces in `:shared`, implemented natively):

| Extension | Android | Apple |
| --- | --- | --- |
| `RpcTransport` (unary + server stream, gateway/relay/pinned direct) | OkHttp via Wire, with BouncyCastle JSSE for Ed25519 | grpc-swift bridge, reusing `DieterRPC.verifyDaemonCertificateChain` |
| `ControlChannelFactory` (WebRTC data channel → byte stream / loopback port) | `ControlRTCBridge.kt` | `ControlRTCBridge.swift` |
| `SecureStore` (gateway tokens) | AndroidKeyStore AES-GCM (existing format) | Keychain on iOS, 0600 file on macOS (existing formats) |
| `DeviceSettings` (device-local key-value) | SharedPreferences | UserDefaults / App Group suite |
| `BrowserAuth` (open URL, deliver callback) | Custom Tabs + intent filter | `NSWorkspace` / `ASWebAuthenticationSession` |
| `Crypto` (Ed25519 verify, X.509 chain) **(confirm)** | JCA / BouncyCastle | Security / CryptoKit |
| `Lifecycle` (foreground/background, network change) | Activity lifecycle, service | scene phase, `NSApplication` |
| `BackgroundExecution` | `DieterSyncService` start/stop | — |
| `NotificationSink` | NotificationManager | UserNotifications |
| `TerminalRenderer` | Termux view | SwiftTerm |
| `ScreenMediaEngine` (peer, tracks, data channels, stats, decoder feedback) | WebRTC + MediaCodec | WebRTC + VideoToolbox/Metal |
| `Logger`, `Diagnostics` | Logcat | `os_log` |

SHA-256 comes from Okio, so no extension is needed for it.

**D7 — UI contract (confirm).** Everything that crosses into UI is described
in a client-local schema, `api/proto/dieter/client/v1/*.proto`. This covers
feature state slices, presentation models (timeline items, activity rows, diff
rows, …), and commands.
- Wire generates the Kotlin types; SwiftProtobuf generates the Swift types
  through `just proto`.
- **Android** uses the Kotlin types and `StateFlow`s directly, with no
  serialization.
- **Apple** reaches the core through a small generic façade:
  `dispatch(command) async throws -> result`, and `observe(slice, scope,
  observer)`, which delivers snapshots or deltas as bytes.
- Large slices (board, transcript) are sent as deltas.
- This keeps the Swift surface small and generated, and keeps SwiftProtobuf as
  the Apple UI model. The alternatives (a hand-written façade per feature, or
  SKIE with exported Wire types) scale poorly: the spike measured a
  17,560-line header when Wire types were exported.

*As built:* the schema is one file,
`apps/core/model/src/commonMain/proto/dieter/client/v1/client.proto`. It
stays with the core because it never crosses the network.
`just mac proto-generate` (also part of `just proto`) copies it into the Mac
package and regenerates the Swift types. Only Swift uses the contract: Android calls the
core's Kotlin domain APIs and reads its views directly. Swift also calls
synchronous render-time rules through `SharedRules`
([cutover plan §7](mac-shared-core-cutover-plan-2026-10-01.md#7-as-built)).

**D8 — Protocol models on Android (confirm).** Android UI moves from
protobuf-lite to Wire types one domain at a time, as part of each cutover.
Until a domain moves, `toLegacy()` converts by byte copy. Once all domains
have moved, protobuf-lite and grpc-java are removed; migration temporarily
adds 1.25 MB of dex, and the removal takes out 1.73 MB.

**D9 — Formatting.** The core returns structured values: durations,
instants, counts, enums, and canonical tool categories. Platforms render
localized text. This replaces about 10 relative-time and 3 token-count
formatters.

*As built (reversed):* the core supplies the English wording (relative ages,
sizes, counts, labels, status lines), so both apps say the same thing.
Platforms format only absolute dates in the device locale.

**D10 — Rollout switches.** `CoreRollout` keeps a compiled-in switch per
domain, plus a hidden debug setting.
- **Read domains** support shadow mode: the core runs beside legacy code and
  divergences are logged.
- **Write domains** never run in shadow, to avoid double delivery; they are
  staged instead (§5).
- Each switch is deleted together with the legacy code in W7.

*As built:* no rollout switches, `CoreRollout`, or shadow mode shipped.
Android switched in one pass and macOS one domain per stage, before either
had users.

**Invariants carried into the core** (from `AGENTS.md`):
- queues, streams, caches, and journals stay bounded;
- plaintext only to loopback, except explicit debug builds;
- one canonical SemVer, with the core built into each app release;
- no historical API branches;
- tests never touch an operator's gateway, daemon, or devices.

## 4. Work packages

In each wave, rows are work packages (WPs). "Sources" are the legacy code a
WP absorbs, abbreviated: A = Android, M = macOS, I = iOS, C = shared Swift
(`DieterCore` / `DieterClient`). "Gains" are capabilities a platform
lacks today and receives automatically. Unifications that change observable
behavior are **bold** and need sign-off (§9).

### F — Foundation (blocks everything)

**F1 — Repository integration**
- Restructure the spike into `:model`, `:shared`, `:testing`, `:apple`, and
  rename the framework to `DieterShared`.
- Add a `just core` module: `doctor`, `test`, `test-native`, `test-ios`,
  `xcframework`, `check`.
- Register `apps/core` in `scripts/check_changed.py`:
  - add a `CI_COMPONENTS` entry;
  - add it to `native_roots`;
  - make a core change also select the Android, macOS, and iOS checks.
- CI jobs:
  - a Linux job running `jvmTest` (needs Go and Node for the fixture);
  - a macOS job running native tests and the XCFramework build;
  - caches for Gradle and `~/.konan`.
- Update `AGENTS.md` and the skills: "client business logic lives in
  `apps/core`; native code holds UI and platform extensions."

*As built:* the recipes are `just core test`, `native-test`, `apple-test`, and
`check`; `just mac shared-framework` assembles the XCFramework for the Mac
package.

**F2 — Test kit** (`:testing`)
- Virtual clock and dispatchers.
- A scripted `GrpcClient` that records and replays calls.
- `FakeFileSystem`.
- A launcher for `scripts/isolated-gateway`.
- A TCP fault proxy that can cut, delay, or blackhole traffic.
- A conformance-vector format: golden protobuf inputs and outputs, runnable
  against the legacy Swift and Kotlin implementations until they are deleted.
- Benchmarks (kotlinx-benchmark on the JVM and native).
- Kover coverage reports.

*As built:* the conformance-vector format, the fault proxy, benchmarks, and
Kover were not built. The test kit has fakes, the JVM platform, `SliceFolds`,
and the `IsolatedGateway` launcher.

**F3 — Fixture extensions** (Go, all opt-in flags on `scripts/isolated-gateway`)
- `-direct-route` advertises a loopback direct TLS candidate using
  `daemon.NewDirectServer`, plus a kill trigger.
- `-second-daemon`, separate from the restart trigger.
- `-daemon-token-ttl` for token-renewal tests.
- A gateway restart trigger.
- JSON readiness output.
- `DIETER_TEST_CONTROL_WEBRTC`, TURN, and the inbox, board-stress, and
  performance seeds already exist and are reused.

**F4 — Runtime primitives**
- `ClientRuntime` and the scope tree (D2).
- `CoreError` (D4) and `Backoff` (D3).
- `CoreStorage` with schema versions (D5).
- `DeviceSettings` and `Logger`.
- An operation runner: mutation mutex, "working" flags, optimistic rollback,
  and idempotency keys. It replaces Android's `action()`/`cardAction()` and
  the `didSet` fan-out in the Mac `AppSession`.

**F5 — App integration scaffolding**
- **Android:** `includeBuild("../core")`, wiring into `DieterContainer`, and
  `CoreRollout`.
- **Apple:**
  - `just mac build` and the iOS Xcode project build the XCFramework;
  - it is linked through a binary target, and linking for the share
    extension needs a decision (§9);
  - the production grpc-swift bridge moves into `DieterClient`, with pinned
    direct TLS;
  - the client-schema protos from D7 are generated.
- **Exit:** every app starts `ClientRuntime` with all domains switched off,
  and CI is green.

*As built:* there are no domain switches (D10). The production grpc-swift
bridge is the Mac's `SharedCore` target, not `DieterClient`; the WebRTC
control bridge, daemon certificate pinning (in place of
`DieterRPC.verifyDaemonCertificateChain`), and resolver targets moved into the
`DieterTransport` target, which `SharedCore` and `DieterClient` share. iOS
does not link the framework yet.

### W1 — Session and connectivity

| WP | Absorbs | Core packages / extensions | Gains and unifications |
| --- | --- | --- | --- |
| W1.1 Identity | A `DieterConnectionManager` 628-778, 2209-2258; A `AppSettingsScreen` 110-133; A `DieterCredentialStore`; M `DieterAuthentication`, `DieterStore+Connection` 606-649, 717-855; C `DieterEndpoint`, `DieterCredentialStore`; I `IOSAuthentication` 5-70, `IOSStore` 13-218, 1112-1144 | `identity/`; `BrowserAuth`, `SecureStore` | Endpoint parsing, gateway migration (`board.dbpprt.com` → `gateway.getdieter.com`), PKCE and exchange, account switch and sign-out implemented once. **Plaintext only on loopback everywhere** (Android allows it in debug; iOS in DEBUG). |
| W1.2 Compatibility | A `connectToGateway` floor, `DieterVersions`, `AppVersion`; M `DieterStoreSupport` 174-190; I `IOSMachinePolicy` | `compatibility/` | The Android app updater stays native. |
| W1.3 Machines | A connection manager 1038-1114, 1232-1332, 2174-2207, `MachinePresence`, `PeerSyncHealth`, view model 1243-1430; M `FleetModel`, `MachineDirectoryRefreshLoop`, `MachineRoutingPolicy`, `DieterStore+Connection` 1050-1164, 1187-1251; I `IOSStore` 300-381, 475-498 | `machines/` | A presence lease (30 s), refresh loops (5 s / 15 s), `WatchDaemons`, telemetry (2 s), machine operations with idempotency keys, and rename/revoke on all platforms. **iOS gains** presence and machine operations. |
| W1.4 Routing | A `DieterRepository` 159-230, 394-956; A `HedgedRoute`, `WebRTCRetryCooldown`; C `ConnectionManager`, `ControlConnection` (signaling), `DirectAccessCredential`, `HedgedRoute`, `WebRTCRouteRetryPolicy`, `DataPlaneLease`, `FeatureClientLease`; M `DieterStore+Connection` 436-604, 1253-1279; I `IOSStore` 383-405 | `routing/`; `RpcTransport`, `ControlChannelFactory` | Direct → WebRTC hedge → relay; token renewal 30 s before expiry; an idle pool (≤8, 5 min); per-project checkout header. **One cooldown policy (2–15 min). One loopback-candidate policy** (iOS excludes loopback, Mac allows it, Android never uses it). **iOS gains** connection reuse. |
| W1.5 Connection supervisor | A connection manager 73-409, 530-563, 821-1036, `BackgroundSyncMode`, `DieterBootReceiver` policy; M `DieterStore+Connection` 34-434, 651-715, `ConnectionEffects`, `SyncStreamLiveness`; I `IOSStore` 220-298, 1013-1110 | `connection/`; `Lifecycle`, `BackgroundExecution` | The phase machine; liveness (15 s, or 45 s for older daemons); background modes (LIVE / PERIODIC / APP_ONLY); `refreshForWidget`; a synchronous "should autostart" read for the boot receiver. **One reconnect backoff.** **iOS moves from fixed 2 s/3 s retries to the shared policy.** |

**Exit criteria:**
- All three apps connect, select routes, and supervise connections through the
  core.
- Shadow comparison of route and phase is clean for one release on Android and
  macOS.
- The E2E scenarios in the AUTH, COMPAT, ROUTE, and CONN groups (§6.2) pass.

### W2 — Sync and replica

| WP | Absorbs | Core packages | Gains and unifications |
| --- | --- | --- | --- |
| W2.1 WatchSync replica | A connection manager 1116-1230, `GlobalSyncPolicy`; M `DieterStore+Sync` 161-381; C `SyncState`; spike `SyncReplica` | `sync/` | Conversation limits, `recent_conversation_limit`, transcript-only fast path, cursor rules, pending-projection buffering. **Changed objects keep their list position on every platform** (Kotlin moves them to the end today). **iOS gains live sync**, replacing 15 s polling. |
| W2.2 Multi-machine directory | A `SharedDirectory`, connection manager 1334-1442, 780-819; C `MachineDirectory`; M `DieterStore+Connection` 949-1048, `DieterStore+Sync` 956-1029; I `IOSStore` 407-473 | `sync/directory` | Inactive machines refreshed with `GetState` + `ifNotModified` (3–4 in parallel); owner-detail merge; board-retirement CRDT; checkouts; peer-sync issues. |
| W2.3 Projection state | spike `CardStateProjection`; C `BoardLifecycleProjection`, `WorkspaceReplica`, `OptimisticProjection` (state parts) | `sync/projection` | A single card/board/project projection that UI slices read from. |
| W2.4 Persistence and cache | A `DieterSyncStore` (projection / directory); C `DieterSyncPersistence`, `DieterSnapshotDecoder`; M `DieterStore+Sync` 12-159, 461-542 | `sync/cache` | **One persistence policy:** coalesce writes, flush on background, bounded conversation tails. Legacy caches are dropped, not imported. **iOS gains an offline cache.** |
| W2.5 Runtime metadata | A connection manager (metadata loop); M `DieterStore+Connection` 354-434, 857-947 | `settings/catalog` | Harness catalogs per checkout machine, settings options, runtime status, with a 5 s retry. |

**Exit criteria:**
- Projection digests match legacy for one release on Android and macOS.
- iOS switches from polling to the core's live sync.
- The board-stress and performance-sweep fixtures meet the budgets in §6.4.

### W3 — Mutations and durable intent

| WP | Absorbs | Core packages | Gains and unifications |
| --- | --- | --- | --- |
| W3.1 Outbox | A `ConversationOutboxPolicy`, `DieterSyncStore` (outbox), connection manager 1654-2172; C `DieterOutboxPolicy`, `OutboxJournal`, `SyncState` 4-56; M `OutboxDelivery`, `DurableOutbox`, `DieterStore+Sync` 544-954; I `IOSMutationIdentity`, `IOSStore` 704-817 | `outbox/` | Create card/chat, send message, start card, agent hand-off. Per-endpoint order; `local_`→server retargeting (≤256 resolutions); retry and discard; per-machine summaries; deterministic IDs. **One journal bound** (Mac 1,000 entries / 64 MiB; spike 64). **iOS gains a durable outbox.** Importers for Android `outbox.json` and Mac `pending-commands.json`. |
| W3.2 Optimistic overlays | A connection manager 1444-1652, `CardStartPolicy`, `CardLaneOrder`; C `OptimisticProjection`; M `BoardPolicies`, `DieterStore+Conversation` 629-750, 819-949 | `outbox/overlay`, `board/` | Optimistic cards, chats, and messages; move, label, start, and pin with rollback; operation IDs. **iOS gains optimistic UI.** |
| W3.3 Board mutations | A view model 2310-2534, 3603-3697; M `DieterStore+Conversation` 752-973, `DieterStore+Workspace` 305-538; I `IOSStore` 819-891 | `board/` | Rename, update, archive, pin, labels, fork, cancel, merge, mark-read, archive listing. **One "active runtime" definition** (five exist on Android alone) and **one "done lane" rule.** **iOS and Android gain** merge; **iOS gains** rename, archive, pin, labels, fork, and mark-read. |
| W3.4 Navigation sync | A `SharedKV`, `SharedNavigation`, `NavigationFolder*`, `ProjectOrder`, `PinnedChatOrder`, `AppPreferences` 172-209; C `SharedKV` 42-346; M `SharedNavigation`, `*NavigationPreferences`, `PinnedChatOrdering`, `ChatListProjection` | `navigation/` | Pending-intent queue; prepared requests with re-prepare on ABORTED; fractional ranks; covering-clock watch; the full key schema. Importers for Android `dieter_shared_kv` and Mac `shared-kv/*.json`. **iOS gains** folders, pins, and ordering. |
| W3.5 Drafts and capture | A `ConversationDraftStore`, `TaskCaptureStore`, `CardCreationDraft`, `ComposerAttachments` 82-116, `ConversationCreate*`, `CreationDestination`; M `ComposerModel`, `QuickTaskPopover` / `CaptureTask` logic, `AttachmentLoader` limits, `ProjectSetup`, `ProjectDestinations`; I `IOSAttachments` (limits, share inbox), `IOSCreateTaskView` logic, share-extension staging format | `drafts/`, `composition/` | Composer drafts (64-entry LRU, queued-message restore, retarget); capture journal (≤20, submission idempotency); remembered choices; attachment limits (4 files / 5 MB / 6 MB) and name/MIME rules. Reading file bytes stays native. **iOS gains persistent drafts.** Importers for Android drafts and task capture and for Mac `DieterConversationDraftTexts`. |

**Exit criteria:**
- Every mutation goes through the core.
- The OUTBOX, KV, and DRAFT kill-and-restart scenarios pass on the JVM and in
  the native UI journeys.
- Importers are verified on real legacy data from debug builds.

### W4 — Conversation

| WP | Absorbs | Core packages | Gains and unifications |
| --- | --- | --- | --- |
| W4.1 Conversation session | A view model 1714-2047, `ConversationReducer`, `ConversationFreshness`, `ConversationReadHedge`, `ConversationPostSendRefresh`, `ConversationUiCache`; M `ConversationModel`, `DieterStore+Conversation` 51-245; C `TranscriptFreshness`, `TranscriptRetention`; I `IOSTranscript` 7-93, `IOSStore` 538-673 | `conversation/` | Read plus watch with hedged unary reads; stream restart; history paging; mark-read with stale-receipt merge; tool output; post-send recovery. **One retention policy with per-platform budgets** (Mac 2,000 messages / 32 MiB; iOS 240; Android 8 × 120 in its UI cache). |
| W4.2 Presentation | A `ConversationTimeline`, `ConversationActivityPresentation`, `ConversationMessageVisibility`, `ConversationTurnFailure`, `ModelActivityPreview`, `SubagentUsagePresentation`, `TaskTokenUsage`, `MessageContent` (markdown parser 175-296, image paths 387-441, tool labels), `ConversationScreen` 118-330, `CardDetailScreen` subagent parts; M `ConversationPresentation`, `ConversationActivity*`, `ConversationMessagePartGroup`, `ConversationMarkdown`, `ConversationContentLink`, `ConversationTurnFailure`, `ConversationContextUsage` 5-64, `MessageParts` 5-52, `MessageView` 159-180; C `RemoteWorkspaceImage`, `ProviderStatusPresentation`; I `IOSConversationPresentation` | `conversation/presentation` + client schema (D7) | Timeline and activity items, delivery states, markdown blocks, content links, and context/token usage computed once and delivered as schema types. Rendering (`AttributedString`, Compose) stays native. |
| W4.3 Send, queue, steer, selection | A view model 2197-2308, `ConversationSelectionPolicy`, `ProviderOptions` 29-52; M `DieterStore+Conversation` 247-354, `QuickTaskQueue` 7-112, `ConversationViewport` 6-36; C `HarnessSelection`; I `IOSConversationView` 703-862, 1434-1449 | `conversation/compose` | Steer placement; queued message → editable draft; retry of a failed turn; provider/model/effort/option resolution. **iOS gains** optimistic send through the outbox. |

**Exit criteria:**
- Conversation screens on all three platforms render core state.
- The long-turn fixture (680 parts) meets its budget.
- The Mac `ConversationUISmokeRunner` and Android conversation journeys pass
  with the switch on.

### W5 — Feature domains (the nine packages can run in parallel)

| WP | Absorbs | RPCs | Gains and unifications |
| --- | --- | --- | --- |
| W5.1 Schedules | A `ScheduleController`, `ScheduleClient`, `CreationScreens` 1061-1194; M `SchedulesModel`, `ScheduleEditorPolicy` | 9 | Cron, cadence, time zone, and template rendering; ownership by the owning machine. **iOS gains schedules.** |
| W5.2 Terminals | A `TerminalController`, `TerminalInputController`, `TerminalState`; M `TerminalsModel`, `TerminalOverviewModel`, `TerminalInputForwarder`, `TerminalOutputAccumulator`, `DieterStore+Navigation` 138-332, `DieterStoreSupport` 22-111; I `IOSTerminalsModel`; spike `TerminalSession` | 7 | Screen reducer (2 MiB buffer, 64 KiB chunks); resume by sequence; cross-machine overview; remembered selection; all terminal scopes; `TerminalRenderer`. **One input-pump bound** (Android 256 KiB / 8 sessions; iOS 1 MB with 12 ms coalescing). **iOS gains** project, checkout, and card terminals. |
| W5.3 Workspace and git | A `WorkspaceGitModel`, view model 2648-2875, 2922-3406, `WorkspaceChangesScreen` 146-160, `ProjectWorkspaceSettings`, `WorkspaceCardBadge`; M `WorkspaceGit`, `WorkspaceReview`, `WorktreeChangesModel`, `ProjectChangesModel`, sheet logic, `DieterStore+Workspace` 65-230 | 13 | Unified diff parser and folding (1 MiB pages); comments; SCM capabilities; git operations (start, watch, resume, cancel); the merge flow; project-workspace cleanup; validation commands; 5 s refresh while active. **iOS gains changes and git.** |
| W5.4 Files | A view model 2536-2646, `SyntaxHighlighter` (tokenizer part); M `FilesModel`, `ProjectFileLanguage`, `FileSyntaxHighlightPlan`, `ProjectFileNavigation`, `ConversationFileTree` 7-87; I `IOSStore` 893-975, `IOSFilesView` logic | 6 | List, read, save with revision, create, move, delete; navigation history; language detection; highlight ranges. Editors stay native. **iOS gains** create, move, and delete. |
| W5.5 Projects, boards, labels, admin, settings | A `AdministrationController`, view model 3408-3697, `WorkspaceManagement` logic; M `DieterStore+Workspace` 232-538, `DieterStore+SharedProjects`, `DieterStore+FilesAndSettings` 112-169, `DieterSettingsView` logic, `SharedConflictsView` 51-81 | about 30 | Projects, boards, labels, checkouts, archive, peer-record conflicts, settings, and prompt settings (5 prompt RPCs that only the Mac calls today). **Android and iOS gain** prompt settings; **iOS gains** project/board/label administration. |
| W5.6 Provider quotas | C `ProviderQuotaModel`; A view model 974-1091; I `IOSProviderQuotaSelection`, `IOSProviderQuotaView` 405-469; M `ProviderQuotaViews` 488-566 | 5 | **`WatchProviderQuotas` on every platform** (Android only today; the others poll every 60 s). |
| W5.7 Activity, inbox, notifications | A `ActivityModel`, `WidgetActivityModel`, `NotificationTransitionTracker`, `NotificationRenderPolicy`, `ResultSummaryPolicy`, `DieterSyncService` policy parts, `NotificationActionReceiver` logic; M `InboxActivity`, `RuntimeActivity`, `DieterIslandView` 6-167, `DieterMacApp` 437-503 | — | One activity projection feeds the inbox, widgets, the island, the menu bar, and notification decisions; `NotificationSink` posts natively. **iOS gains** the inbox, and notifications once native UI exists. |
| W5.8 Search | C `TaskSearchIndex`; A `ChatProjectPolicy`; M `CommandPalette` 144-175 | — | One search index; iOS's substring filter is replaced. |
| W5.9 Executions | M `ConversationProcessesModel`, `ExecutionRPC` | 3 | **Android and iOS gain** processes. |

**Exit criteria (per WP):** the WP's scenarios pass and its switch is on in
all three apps. Where iOS has no UI for a gained capability yet, "on" means
the core serves it and the iOS parity UI track picks it up.

### W6 — Screen-sharing control plane

| WP | Absorbs | Core packages / extensions |
| --- | --- | --- |
| W6.1 Session lifecycle and trust | A `ScreenController` (control plane, about 390 lines), `ScreenConnection`, `ScreenRecovery`; M `RemoteDesktopController` 10-60, 178-337, 483-706, 1194-1234, `RemoteDesktopRecovery`, `ScreensModel`; C `RemoteDesktopSessionTrust`; I `IOSRemoteDesktopSession` 116-451, 844-927 | `screens/`; `Crypto`, `ScreenMediaEngine` |
| W6.2 Control and configuration | A `ScreenController` 382-449, 527-597; M `RemoteDesktopController` 913-1101, `RemoteDesktopDisplayMatching`; I `IOSRemoteDesktopSession` 461-560, 778-842 | `screens/control` |
| W6.3 Input encoding and gestures | A `ScreenTouchGesture`, `ScreenCanvasModel`, `ScreenKeys`; M `RemoteDesktopController` 753-911; I `IOSRemoteDesktopSession` 593-776, 1099-1192, `IOSScreensView` 1144-1271 | `screens/input` |
| W6.4 Feedback, reference, clipboard protocol | A `ScreenFeedbackPump`, `ScreenReferenceReceiver`, `ScreenClipboard` (protocol), `ScreenClipboardContent.validate`; M `RemoteDesktopFeedbackPump` (policy); I `IOSRemoteDesktopFeedbackPump` 4-18 | `screens/feedback` |

Details:
- **What the core covers:** capability policy; the start request; signaling
  with its watchdog (20 s, +150 s on Linux); binding trust; ICE buffering
  (≤256); the 5 s lease; recovery; codec choice and HEVC fallback; viewport
  debounce; display matching (Mac only today); input framing and coalescing;
  gestures and geometry; the feedback, reference, and clipboard wire
  protocols.
- **Behavior changes:** **one recovery policy** (iOS caps attempts at 6;
  the others don't).
- **Stays native:** peer connections, tracks, decoders, renderers, pasteboard,
  and the macOS key-code map shared with the capture helper.
- **Tests:**
  - JVM tests use `scripts/screens-fixture` plus a scripted
    `ScreenMediaEngine` to check signaling, trust, lease, close, recovery,
    and fault endpoints (signal rejection, expiry, interrupted signaling).
  - Full media coverage stays in the existing native screens suites.
- iOS feature parity (HEVC, reference recovery, clipboard) also needs native
  media work; the core makes the control side ready for it.

### W7 — Consolidation (rolling)

After each domain has shipped with its switch on for one release, delete its
legacy code, the switch, and any shadow comparators. The bulk deletions:

| Platform | Deleted |
| --- | --- |
| Android | `DieterConnectionManager`, the `DieterRepository` feature facade, `DieterViewModel` orchestration, policy files; protobuf-lite and grpc-java once every domain's UI is on Wire types |
| macOS | The `DieterStore+*` extensions, `FeatureCompatibility`, most of `AppSession`, `DieterCore` policies (not the two capture-helper files), `DieterClient` policy files (the transport stays) |
| iOS | The orchestration in `IOSStore`, `IOSTerminalsModel`, and `IOSRemoteDesktopSession` |

Docs, `AGENTS.md`, and the Dieter skills are updated accordingly.

*As built:* on macOS, the `DieterStore+*` extensions, `FeatureCompatibility`,
and `AppSession` stayed as thin slice and command adapters with no rules, and
the transport pieces moved into `DieterTransport`
([cutover plan §7](mac-shared-core-cutover-plan-2026-10-01.md#7-as-built)).
iOS has not started.

## 5. Cutover and migration mechanics

*As built:* 5.1–5.3 did not ship as planned. There were no conformance
vectors, shadow mode, switches, or rollback: each app switched over in place,
before either had users. The importers in 5.3 were built for the macOS and
iOS formats and deleted unused; no Android importer shipped. The Mac keeps its
gateway session file as the core's secure store, so sign-in survives.
Android briefly deleted the earlier versions' unused files on start; that
cleanup was removed again (2026-10-03), since there were no installs to clean.

**5.1 Per domain, per platform:**
1. Build and test in the core; conformance vectors pass against legacy.
2. For read domains, turn on shadow mode in debug and internal builds:
   compare digests (route and phase, projection hash, transcript window) and
   log divergences through `Diagnostics`.
3. Switch on in debug builds, then internal, then release.
4. Delete after one release (W7).

Write domains (W3, parts of W4 and W5) skip shadow mode and go straight to
staged switching.

**5.2 Rollback.** Turning a switch off restores the legacy path for read
domains. Write domains take over their journal one way:
- the importer marks the legacy file as migrated;
- turning the switch off leaves new core-queued commands where the core will
  replay them after it is switched back on.

**5.3 Importers.** Each runs once and is idempotent. Legacy files are kept
until W7.

| Platform | Data | Treatment |
| --- | --- | --- |
| Android | `dieter_connection` (endpoints, gateway, mode) | Import |
| Android | `dieter_sync.client_id` | **Keep the value** (outbox idempotency) |
| Android | `global-sync/outbox.json` | Import |
| Android | `dieter_shared_kv` | Import |
| Android | `dieter_conversation_drafts` | Import |
| Android | `task-capture/*.draft` | Import |
| Android | Notification boards and creation preferences | Import |
| Android | Projection and directory caches | Drop |
| macOS | `DieterEndpoints` / `DieterActiveEndpoint` | Import |
| macOS | `DieterSyncClientID` | **Keep** |
| macOS | `pending-commands.json` | Import |
| macOS | `shared-kv/*.json` | Import |
| macOS | `DieterConversationDraftTexts` | Import |
| macOS | `quickTask.lastChoices`, creation preferences, `DieterSelectedTerminalsByTarget` | Import |
| macOS | `sync-state.json` | Drop |
| iOS | `DieterIOSGateway` | Import |
| iOS | `DieterIOSClientID` | **Keep** |
| iOS | `DieterIOSUtilityMachine:*` | Import |

- Credentials stay in each platform's existing secure-store format behind
  `SecureStore`.
- If the share extension needs network access, the Keychain access group and
  App Group defaults move first (§9).

**5.4 Release.** The core version is the canonical SemVer and is built into
every app release. Gateway minimum-version floors are unchanged. The
Kotlin/Native dSYMs ship with the Apple builds.

## 6. Testing and quality gates

### 6.1 Definition of done (every WP)

1. The legacy tests covering the absorbed code are ported to `commonTest` and
   pass on the JVM, macOS arm64, and the iOS Simulator. The sources are
   Android's 431 JVM tests and the relevant parts of 737 Mac, 27 shared-Swift,
   and 64 iOS tests.
2. Conformance vectors run against the core **and** against the legacy Swift
   and Kotlin implementations. Every mismatch is either fixed or recorded in
   §9's list of accepted unifications.
3. The JVM scenarios in §6.2 for this WP pass against `isolated-gateway`,
   including fault injection.
4. Adapter contract tests pass: the Swift harness on macOS and the iOS
   Simulator, an Android host test, and one instrumentation smoke test.
5. The existing `tests/e2e` journeys for the domain pass with the switch on:
   53 Android, 10 Mac, and 7 iOS cases today.
6. Performance budgets (§6.4) hold.
7. `commonMain` line coverage for the WP's packages is at least 85% (Kover).
8. The legacy code is deleted (W7).

*As built:* conformance vectors (item 2) and the Kover gate (item 7) were
never built. The adapter harnesses (item 4) were retired: the Swift one
became the Mac's `SharedCoreTests` (`just mac core-test`), and the Android
host harness was deleted, since `just core test` runs the same OkHttp
transport on the JVM and the app's instrumentation covers its bindings. The
core's suites are `commonTest` on the JVM and macOS (`just core test`,
`just core native-test`), the JVM end-to-end tests against isolated gateways,
and the apps' native catalogs.

### 6.2 End-to-end scenario catalog (JVM, real gateway and daemon)

- **AUTH:** sign-in exchange; revoked session; account switch clears state.
- **COMPAT:** outdated client; incompatible daemon listed but never selected
  (the fixture already provides one).
- **ROUTE:**
  - direct preferred;
  - direct cut → WebRTC → relay;
  - WebRTC cooldown;
  - token renewal at TTL;
  - relay-only machine.
- **CONN:**
  - background/foreground;
  - stale stream at 15 s / 45 s;
  - daemon offline and back (`-offline-trigger`);
  - gateway restart;
  - second daemon.
- **SYNC:**
  - resume from cursor;
  - projection pending;
  - daemon restart changes the epoch;
  - multi-machine merge;
  - `ifNotModified`;
  - board stress (100 cards);
  - performance sweep (40 chats).
- **OUTBOX:**
  - queued while offline;
  - app killed;
  - lost acknowledgement applied exactly once;
  - dependency retarget (create chat → send);
  - permanent rejection dropped;
  - disk full.
- **KV:** offline edits replayed; ABORTED re-prepare; concurrent writers.
- **DRAFT:** capture survives restart; submission idempotency.
- **CONV:**
  - stream plus paging;
  - hedged read;
  - steer and queue;
  - failed-turn retry;
  - mark-read race;
  - long turn (680 parts).
- **TERM:** create, watch, resume after a cut; input bounds; machine-home and
  project scopes.
- **GIT:** changeset, diff paging, operation watch/resume/cancel, merge flow
  to the done lane.
- **FILES:** save conflict on a revision mismatch.
- **SCHED:** create/preview/run/toggle/delete on the owning machine.
- **ADMIN:** project/board/label lifecycle; peer-record conflict.
- **QUOTA:** watch plus reset idempotency.
- **SCREEN:** start, trust, lease, close; rejected signals; expiry; recovery
  (using `screens-fixture` fault endpoints).

### 6.3 Test layers and speed

| Layer | Runs on | Target time |
| --- | --- | --- |
| `commonTest` (unit, conformance, virtual time) | JVM, macOS, iOS Simulator | Seconds |
| JVM end-to-end (Go fixture, fault proxy) | Linux CI, developer machines | Under 3 min for the full catalog |
| Adapter contract (Swift harness, Android host/instrumentation) | macOS CI, device lease | Minutes |
| Native UI journeys (`tests/e2e`) | Existing runners | Unchanged |

### 6.4 Performance budgets

- Set baselines in F2 by benchmarking the legacy implementations on the same
  fixtures (board stress, performance sweep, long turn).
- Budget: core p95 no worse than the legacy p95 on each platform, for
  snapshot apply, delta apply, transcript update apply, and UI-slice encoding
  (the Apple bytes boundary).
- Memory: a bounded steady state after one hour of the performance sweep.
- Apple binary budget: +5 MB linked on arm64 (the spike measured 5.0 MB);
  re-measure after each wave.

## 7. Sequencing, parallelism, and size

The critical path is F → W1 → W2 → W3.1/W3.2 → W4.1. W3.4, W3.5, W4.2, all
of W5, and W6 can proceed in parallel once their dependencies land. W6 needs
only W1.

| Wave | Rough effort (engineer-weeks) | Can overlap with |
| --- | --- | --- |
| F | 2–3 | — |
| W1 | 3–4 | late F |
| W2 | 2–3 | W6 |
| W3 | 3–4 | W4.2, W5 |
| W4 | 3–4 | W5 |
| W5 | 5–7 (spread over 9 WPs) | W3, W4, W6 |
| W6 | 3–4 | W2–W5 |
| W7 | 2–3 (rolling) | everything |
| **Total** | **about 23–32** | With 2–3 parallel streams after W2, roughly 12–16 calendar weeks |

These figures are estimated from the lines absorbed and tests to port, not
measured. Re-estimate after F and W1.

## 8. Tracking and governance

- **Parity matrix.** Keep a status table in `apps/core/README.md` with one row
  per WP and columns for implemented, conformance, E2E, Android, iOS, macOS,
  and deleted. *As built:* the table lists each WP's packages, tests, and
  status; platform status is the F5 row instead of one column per app.
- **Board cards.** One card per WP (F1–F5, W1.1–W6.4, and W7 per platform),
  labelled by wave. I can create these once you approve the plan.
- **Review rule.** A change that adds client business logic outside
  `apps/core` needs a stated reason: platform extension, UI, or a
  temporary legacy fix during cutover.
- **Documentation.** Each wave ends with a dated implementation record in
  `docs/`, following the repository's convention.

## 9. Decisions needed

1. **UI contract (D7).** A schema-first client API plus a generic Apple
   façade (recommended), a hand-written façade, or SKIE.
2. **Framework name and linking.** Rename to `DieterShared` (recommended).
   Then either link it into the `DieterIOS` dynamic library (simplest), or
   ship a separate dynamic framework the share extension can load without
   WebRTC and UI frameworks (recommended if the extension will talk to the
   network).
3. **Android models (D8).** Migrate the UI to Wire per domain (recommended),
   or keep a permanent byte bridge.
4. **Crypto for screen trust (D6).** A platform extension (recommended; reuses
   CryptoKit and BouncyCastle) or a pure-Kotlin library.
5. **Formatting (D9).** The core returns structured values and platforms
   localize (recommended).
6. **Behavior unifications** (bold in §4):
   - delta ordering;
   - retention budgets;
   - backoff and cooldown tables;
   - loopback-route policy;
   - the "done lane" rule;
   - the "active runtime" definition;
   - the plaintext-transport rule;
   - journal bounds;
   - iOS moving from polling to live sync;
   - quota watching everywhere.
7. **CI runners.** Linux for JVM tests and macOS for native tests
   (recommended), or macOS only.
