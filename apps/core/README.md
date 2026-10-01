# Dieter shared client core (Kotlin Multiplatform)

This is the client business logic shared by the Android, macOS, and iOS apps.
It is implemented through work packages F–W6 of the
[implementation plan](../../docs/kmp-core-implementation-plan-2026-09-30.md),
and it is tested end to end on the JVM, on native macOS, from Swift, and as
the Android variant.

Android runs entirely on the core:
- The app's former logic layer, protobuf-lite, and grpc-java are gone. The
  Compose UI reads Wire models and the core's views directly.
- Presentation rules live in the core too, so every client words and decides
  things the same way. Examples: the conversation presentation and composer
  controls, task-draft editing, board and chat lists, machine rows and
  telemetry text, offline availability and the connection sheet, and
  relative times.
- The app keeps only Compose layout and Android adapters: the OkHttp
  transport, the Keystore-backed credential store, WebRTC/MediaCodec screen
  media (framed by `platform/ControlFrames.kt`), the Termux terminal renderer,
  notifications, widgets, the sideload updater, and the background service
  (`apps/android/.../sharedcore`). The adapters format dates in the device
  locale; the core supplies the wording.
- There was no soak or shadow mode and there is no Android legacy importer:
  the app had no users yet.

The macOS app runs on the core
([cutover plan](../../docs/mac-shared-core-cutover-plan-2026-10-01.md)). Its
`SharedCore` target (`apps/mac/Sources/SharedCore`) links `DieterShared`,
provides the native transport and platform services, and carries the legacy
state over once through the macOS importer. Every Mac feature is a slice and
command surface; the Mac keeps presentation, the editor, terminal rendering,
and the WebRTC, VideoToolbox, and Metal screen engine. The iOS app does not
link the core yet.

| Module | Role |
| --- | --- |
| `model` | Wire models and gRPC stubs generated from `api/proto`, relocated to `com.dbpprt.dieter.api.*`. It also holds the core's on-device records (`dieter/core/v1`) and the UI contract (`dieter/client/v1`, D7). |
| `shared` | All client logic, the platform-extension contracts (`platform/Platform.kt`, `screens/ScreenMedia.kt`, `terminals/TerminalScreen.kt`), and the OkHttp transport for Android and the JVM (`jvmSharedMain`). |
| `testing` | Fakes, the JVM platform, the JDK's Ed25519 verifier, and the `IsolatedGateway` fixture launcher used by every end-to-end test. |
| `apple` | The `DieterShared` façade, the only module exported to Swift. It offers `dispatch(command)` and `observe(slice, scope)` over encoded `dieter.client.v1` messages, a grpc-swift transport bridge, and the native extension protocols. |
| `harness/android` | The core's Android variant (OkHttp transport) in a minimal app, tested on the JVM against an isolated gateway. |

## Architecture

- **Threading.** Every piece of mutable state is confined to one serialized
  dispatcher (`CoreRuntime.dispatcher`). UIs read `StateFlow`s (Kotlin) or
  observe slices (Swift).
- **Data flow.** The attached machine streams one WatchSync feed. Other
  machines are polled. Every feature shares one data plane per machine
  (direct TLS, then WebRTC hedged against the relay, then the relay alone).
  All state enters one `WorkspaceStore` reducer, which applies optimistic
  overlays.
- **Durable intent.** Creates, sends, and starts go through a journaled
  outbox with deterministic IDs, so a retry can never duplicate a command.
- **Division of labour.** Platforms own HTTP/2, TLS, credentials, rendering,
  terminals (SwiftTerm, Termux), and screen media (WebRTC, decoders, Metal).
  The core makes every decision around them.

## Parity matrix

Status key:
- **done**: implemented in the core and covered by tests.
- **wired**: reachable from an app or adapter harness.
- **façade**: exposed through the Apple byte contract.

| WP | Core packages | Tests | Status |
| --- | --- | --- | --- |
| F Foundation | `platform`, `runtime`, `storage`, `testing`, `model` | unit, native macOS, fixture | done |
| W1.1 Identity | `identity` (gateways, PKCE sign-in, accounts, client ID) | `CoreRuntimeEndToEndTest`, `ClientApiEndToEndTest` | done, façade |
| W1.2 Compatibility | `session` (`GatewaySession.verify`) | e2e (update-required path) | done, façade |
| W1.3 Machines | `machines` (rows, fleet, formats), `admin/Machines.kt` (presence, telemetry, operations, background policy) | `AdminEndToEndTest`, `AdminRulesTest`, `MachineRowsTest` | done; rename and revoke are on the façade |
| W1.4 Routing | `routing`, `session` (direct, WebRTC hedge, relay; token renewal; cooldown) | `CoreRuntimeEndToEndTest` (live and dead direct routes, stream starvation) | done |
| W1.5 Supervisor | `connection` (phases, liveness, backoff, `refreshForWidget`; offline availability and the connection sheet) | e2e (offline, restart, widget refresh), `AvailabilityTest` | done, façade |
| W2.1–2.4 Sync and replica | `sync`, `store` (feed, directory poller, card-state projection, cache) | `SyncReplicaTest`, `CardStateProjectionTest`, e2e (cached launch) | done, façade (workspace deltas) |
| W2.5 Runtime metadata | `metadata`, `selection` | `DomainsEndToEndTest` | done |
| W3.1 Outbox | `outbox` | `OutboxPolicyTest`, `OutboxEndToEndTest`, `PendingItemsTest` | done, façade |
| W3.2–3.3 Overlays and board | `board`, `store` | `BoardPolicyTest`, `BoardPresentationTest`, `BoardEndToEndTest` | done; move, finish, labels, pin, rename, archive, restore, cancel, and read are on the façade |
| W3.4 Navigation | `navigation` (shared KV, folders, destinations, chat lists) | `NavigationTest`, `ChatListsTest`, `NavigationEndToEndTest` | done |
| W3.5 Drafts and capture | `composition` (drafts, captures, task-draft editing, destinations) | `CompositionTest`, `TaskDraftsTest` | done |
| W4 Conversation | `conversation`, `presentation`, `selection` | `ConversationReducerTest`, `PresentationTest`, `ConversationPresentationTest`, `AgentControlsTest`, `ConversationEndToEndTest` | done, façade (keyed transcript deltas, send, paging) |
| W5.1 Schedules | `schedules` | `DomainRulesTest`, `DomainsEndToEndTest` | done |
| W5.2 Terminals | `terminals` (surfaces, input pumps, replay, cross-machine overview) | `TerminalScreenTest`, `TerminalOverviewCatalogTest`, `TerminalEndToEndTest` | done |
| W5.3 Workspace and git | `workspace` | `WorkspaceRulesTest`, `WorkspacePresentationTest`, `WorkspaceEndToEndTest` | done |
| W5.4 Files | `files` (browser, tree, syntax, drafts) | `FilesTest`, `FilesEndToEndTest` | done |
| W5.5 Admin | `admin` | `AdminRulesTest`, `AdminEndToEndTest` | done |
| W5.6 Quotas | `quotas` | `DomainRulesTest`, e2e | done |
| W5.7 Activity and notifications | `activity`, `notifications` | `ActivityTest`, `WidgetModelTest` | done, façade (activity) |
| W5.8 Search | `search` | `DomainRulesTest` | done |
| W5.9 Executions | `executions` | `DomainsEndToEndTest` | done |
| W6 Screens | `screens` (trust, session controller, recovery, input, gestures, mouse buttons, clipboard, frame gating, receiver feedback), `platform/ControlFrames.kt` | `ScreenPoliciesTest`, `ScreenFramesTest`, `MouseButtonsTest`, `ControlFramesTest`, `ScreenSessionTest` (scripted daemon and engine), `ScreenEndToEndTest` | done |
| D7 UI contract | `client` (`ClientApi`, keyed deltas), `apple` | `KeyedTest`, `ClientApiEndToEndTest`, Swift harness | done |
| Legacy import | `legacy` (macOS and iOS formats) | `LegacyFormatsTest`, `LegacyInputsTest`, `LegacyImportEndToEndTest` | done, façade; Android needs none |
| F5 App integration | Android `sharedcore/` (`SharedCore`, `ConnectionPolicy`); macOS `SharedCore` and slice adapters | Android unit tests and instrumentation catalog (`tests/e2e`); `just mac test`, `just mac core-test`, `just mac screens-test` | Android and macOS on the core; iOS not yet. |
| W7 Consolidation | — | — | Android: legacy logic, protobuf-lite, and grpc-java deleted. macOS: the legacy feature plane and Swift rule copies deleted. |

**On the Apple façade:** every feature, as `client.proto` commands and
slices. Screens take a `NativeScreenMedia` engine and a `NativeClipboard`
through `SharedExtensions`; engines are created per observed screen scope.
Terminal output reaches Swift through the terminals slice.

## Deviations from the plan

- **Client schema location.** The client schema lives in
  `model/src/commonMain/proto/dieter/client/v1`, not `api/proto`. It never
  crosses the network, so it stays with the core that owns it.
- **Screen routes** use the machine's shared data plane. Tokens renew per
  RPC, so a planned route refresh is unnecessary. Every attempt fetches a
  fresh RTC configuration and the enrolled certificate, and the certificate
  is pinned for the session.
- **Screen trust failures are fatal immediately.** They are never
  resubscribed.
- **Android credentials** stay in the app's Keystore-backed
  `DieterCredentialStore`, which is keyed by origin as the core is; the core
  uses it as its `SecureStore`.
- **Pending cards** carry aliases (the deterministic and the acknowledged
  daemon ID), so a card never shows twice when sync delivers it before the
  create reply.

## Build and test

You need Android Studio's JBR, the Android SDK (platform 37.1), Go, Node (for
the mock harness, installed with `just harness install`), and, on macOS,
Xcode. The first Kotlin/Native build downloads about 1.6 GB into `~/.konan`.

```sh
just core test          # JVM unit and end-to-end tests against isolated gateways and daemons
just core android-test  # the Android variant against an isolated gateway
just core native-test   # common tests natively on macOS, plus the DieterShared XCFramework
just core apple-test    # native tests, then `just mac core-test`: DieterShared driven from the Mac bridge
just core check         # everything this host supports
```

After changing the client schema (`model/src/commonMain/proto/dieter/client/v1`),
regenerate the Mac package's Swift types with `just mac proto-generate`; it
copies the schema into `apps/mac/Sources/DieterAPI/client` first.

On an iOS simulator:
`./gradlew :shared:iosSimulatorArm64Test -Pdieter.simulator=<disposable simulator UDID>`.

Every end-to-end test starts its own gateway and daemon from
`scripts/isolated-gateway`, with a temporary `DIETER_HOME` and random loopback
ports. They never touch an operator's daemon.
