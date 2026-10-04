# Dieter shared client core (Kotlin Multiplatform)

This is the client business logic of the Dieter apps. The Android, macOS, and
iOS apps run on it. It is tested end to end on the JVM (over the OkHttp transport
Android shares), on native macOS, and from Swift.

Every rule lives here: wording, counts, enablement, ordering, decisions,
defaults, and parsing, so every client words and decides things the same way.
Examples: the conversation timeline, state, and composer agent controls,
task-draft editing and creation previews, board lanes and card flags, chat list
sections, machine rows and telemetry formats, offline availability and the
connection sheet, diff layout, schedule cadences, and relative times. The apps
keep view mechanics (layout, scrolling, focus, animation, gesture geometry),
locale date formatting, colours, icons, and their platform adapters. A rule an
app still builds itself belongs in the core, with core tests (see
[Adding a rule](#adding-a-rule)).

Android runs entirely on the core:

- The Compose UI calls the core's Kotlin domain APIs and reads its views
  (`CoreRuntime`, Wire models, `StateFlow`s) directly; the app has no logic
  layer, protobuf-lite, or grpc-java of its own, and it does not use
  `ClientApi`.
- The app keeps only Compose layout and Android adapters: the TLS providers
  for the core's OkHttp transport, the Keystore-backed credential store,
  WebRTC/MediaCodec screen media (framed by `platform/ControlFrames.kt`), the
  Termux terminal renderer, notifications, widgets, the sideload updater, and
  the background service (`apps/android/.../sharedcore`). The adapters format
  dates in the device locale; the core supplies the wording.
- The app includes this build from source and imports its version catalog
  (`gradle/libs.versions.toml`) as `coreLibs`, so both apply the same Kotlin,
  AGP, coroutines, and OkHttp versions.

Both Apple apps run on the core through the `SharedCore` target
(`apps/mac/Sources/SharedCore`). It links `DieterShared`, carries the core's
RPCs over grpc-swift through the `DieterTransport` target (the WebRTC control
bridge, daemon certificate pinning, and resolver targets), and provides the
platform services (`CoreHost` with a per-platform `CoreHostPlatform`). It also
holds the adapter models both apps present (chats, creation, files, terminals,
fleet, quotas, the delta folds, and drafts) and the WebRTC screen engine, which
draws through a per-app renderer. Every feature observes a slice and sends
commands; views call `SharedRules` for rules they need while rendering.

- The macOS app keeps presentation, the editor, terminal rendering, and the
  VideoToolbox and Metal screen renderer.
- The iOS app (`apps/ios`, `apps/mac/Sources/DieterIOS`) keeps SwiftUI
  presentation, `ASWebAuthenticationSession` sign-in, the Keychain store
  (`CoreKeychainSecureStore`), SwiftTerm, the UIKit screen renderer and
  pasteboard, and the native attachment pickers. Touch input on shared
  screens is the core's `SharedTouchScreen`. Sign-out (`SignOut`) and
  reconnect (`Reconnect`) are core commands. The share extension does not
  link the core; the app validates what it hands over with `SharedRules`.

| Module    | Role                                                                                                                                                                                                                                                                                                                                                                                                            |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `model`   | Wire models and gRPC stubs generated from `api/proto`, relocated to `com.dbpprt.dieter.api.*`. It also holds the core's on-device records (`dieter/core/v1`) and the UI contract (`dieter/client/v1/client.proto`, D7).                                                                                                                                                                                         |
| `shared`  | All client logic, the platform-extension contracts (`platform/Platform.kt`, `screens/ScreenMedia.kt`, `terminals/TerminalScreen.kt`), and the OkHttp transport for Android and the JVM (`jvmSharedMain`).                                                                                                                                                                                                       |
| `testing` | Fakes, `SliceFolds` (applies keyed deltas as a Swift observer does), the JVM platform, the JDK's Ed25519 verifier, and the `IsolatedGateway` fixture launcher used by every end-to-end test.                                                                                                                                                                                                                    |
| `apple`   | The only module exported to Swift: the `DieterShared` façade (`dispatch(command)` and `observe(slice, scope)` over encoded `dieter.client.v1` messages), the synchronous `SharedRules` exports (`SharedRules.kt`), the `SharedTouchScreen` touch input for shared screens (`TouchScreen.kt`), and the native extension protocols, including the RPC bridge the Mac implements with grpc-swift (`NativeRpc.kt`). |

## Architecture

- **Threading.** Every piece of mutable state is confined to one serialized
  dispatcher (`CoreRuntime.dispatcher`). UIs read `StateFlow`s (Kotlin) or
  observe slices (Swift). `SharedRules` calls are stateless and run on any
  thread.
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

### Source layout

Under `shared/src/commonMain/kotlin/com/dbpprt/dieter/core/`:

- One package per domain (`activity`, `admin`, `board`, `composition`,
  `connection`, `conversation`, `files`, `machines`, `navigation`,
  `presentation`, `quotas`, `schedules`, `screens`, `terminals`, `workspace`,
  and others). Each holds the domain's state, operations, and rules; Android
  calls these directly. `CoreRuntime.kt` wires them together.
- `client/` implements the Apple contract (`client.proto`):
  - `ClientApi.kt` dispatches commands and serves slice observations.
  - `Surfaces.kt` keeps per-view surfaces by scope (files and file trees,
    terminals and their overview, review, project changes and workspaces,
    schedules, telemetry, processes, screens, board views, chats, and open
    conversations): the first observer opens one, the last release stops it.
  - `*Commands.kt` (`AdminCommands`, `CreationCommands`, `FileCommands`,
    `MachineCommands`, `NavigationCommands`, `ReviewCommands`,
    `ScreenCommands`, `TerminalCommands`) handle each domain's commands.
  - `SliceMappers.kt`, `RuntimeSlices.kt`, and `BoardViewSlices.kt` map the
    Kotlin views to slices; `Deltas.kt` turns keyed lists (cards, messages,
    timeline items) into keyed deltas.
  - `rules/` holds one stateless `*Exports` object per domain
    (`FormatExports`, `BoardExports`, `ConversationExports`, …): adapters with
    primitive inputs and outputs over the domain rules, for `SharedRules`.

## Adding a rule

1. Write the rule in its domain package, as a function or a property of the
   domain's Kotlin view, with `commonTest` unit tests in the same package.
   Android calls it there.
2. Give Swift the result:
   - **A value derived from slice state** (what a row or control shows or
     allows) becomes a slice field in `client.proto`: compute it in the
     Kotlin view, copy it in the slice mapper, and assert it in a
     `client/*SliceTest` or a `ClientApi*EndToEndTest`. Keyed lists travel
     as keyed deltas.
   - **A rule a view calls while rendering**, from values it already holds,
     becomes a `SharedRules` export: add a function to the domain's
     `client/rules/<Domain>Exports.kt` with a test in
     `commonTest/.../client/rules/<Domain>ExportsTest.kt`, and a forwarder in
     the domain's region of `apple/.../SharedRules.kt`. Inputs are primitives
     (`String`, `Long`, `Int`, `Double`, `Boolean`, lists of them) or encoded
     messages; times are epoch milliseconds, 0 meaning unknown; outputs are
     primitives or encoded `dieter.client.v1` messages. A forwarder only
     converts and calls one export. Swift calls
     `SharedRules.shared.<name>(...)`, often per rendered row, so keep exports
     cheap.
3. After a schema change, run `just pipeline mac local action:proto_generate`. Avoid field names
   that Wire escapes (`value`, `data`, and `file` become `value_`, `data_`,
   and `file_`).
4. Delete the app's copy and its tests.

## Parity matrix

Status key:

- **done**: implemented in the core and covered by tests.
- **façade**: Swift reaches it through the named slices and commands, or
  through `SharedRules`.

| WP                              | Core packages                                                                                                                                            | Tests                                                                                                                                                                                                                                                                                                                  | Status                                                                                                                                                                                                                      |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| F Foundation                    | `platform`, `runtime`, `storage`, `testing`, `model`                                                                                                     | unit, native macOS, fixture                                                                                                                                                                                                                                                                                            | done                                                                                                                                                                                                                        |
| W1.1 Identity                   | `identity` (gateways, PKCE sign-in, accounts, client ID)                                                                                                 | `CoreRuntimeEndToEndTest`, `ClientApiEndToEndTest`                                                                                                                                                                                                                                                                     | done, façade (session; sign-in commands)                                                                                                                                                                                    |
| W1.2 Compatibility              | `session` (`GatewaySession.verify`)                                                                                                                      | e2e (update-required path)                                                                                                                                                                                                                                                                                             | done, façade (session)                                                                                                                                                                                                      |
| W1.3 Machines                   | `machines` (rows, fleet, formats), `admin/Machines.kt` (presence, telemetry, operations, background policy)                                              | `ClientApiAdminEndToEndTest`, `AdminRulesTest`, `MachineTelemetryTest`, `MachineRowsTest`                                                                                                                                                                                                                              | done, façade (session machine entries, telemetry, machine formats; rename and revoke)                                                                                                                                       |
| W1.4 Routing                    | `routing`, `session` (direct, WebRTC hedge, relay; token renewal; cooldown)                                                                              | `CoreRuntimeEndToEndTest` (live and dead direct routes, stream starvation)                                                                                                                                                                                                                                             | done                                                                                                                                                                                                                        |
| W1.5 Supervisor                 | `connection` (phases, liveness, backoff, `refreshForWidget`; offline availability and the connection sheet)                                              | e2e (offline, restart, widget refresh), `AvailabilityTest`                                                                                                                                                                                                                                                             | done, façade (session)                                                                                                                                                                                                      |
| W2.1–2.4 Sync and replica       | `sync`, `store` (feed, directory poller, card-state projection, cache)                                                                                   | `SyncReplicaTest`, `CardStateProjectionTest`, `DirectoryTest`, `FeedTest`, e2e (cached launch)                                                                                                                                                                                                                         | done, façade (workspace, keyed deltas)                                                                                                                                                                                      |
| W2.5 Runtime metadata           | `metadata`, `selection`                                                                                                                                  | `ClientApiEndToEndTest`                                                                                                                                                                                                                                                                                                | done, façade (metadata)                                                                                                                                                                                                     |
| W3.1 Outbox                     | `outbox`                                                                                                                                                 | `OutboxPolicyTest`, `OutboxEndToEndTest`, `PendingItemsTest`                                                                                                                                                                                                                                                           | done, façade (outbox)                                                                                                                                                                                                       |
| W3.2–3.3 Overlays and board     | `board`, `store`                                                                                                                                         | `BoardPolicyTest`, `BoardPresentationTest`, `BoardViewTest`, `LanesTest`, `BoardEndToEndTest`, `ClientApiBoardViewEndToEndTest`                                                                                                                                                                                        | done, façade (board, board view, card commands)                                                                                                                                                                             |
| W3.4 Navigation                 | `navigation` (shared KV, folders, destinations, chat lists)                                                                                              | `NavigationTest`, `ChatListsTest`, `ChatsSurfaceTest`, `NavigationEndToEndTest`                                                                                                                                                                                                                                        | done, façade (navigation, chats)                                                                                                                                                                                            |
| W3.5 Drafts and capture         | `composition` (drafts, captures, task-draft editing, creation previews, destinations)                                                                    | `CompositionTest`, `TaskDraftsTest`, `CreationPlanTest`, `WorkspaceModeTest`, `CreationCommandsTest`                                                                                                                                                                                                                   | done, façade (creation, drafts, creation preview)                                                                                                                                                                           |
| W4 Conversation                 | `conversation`, `presentation`, `selection`                                                                                                              | `ConversationReducerTest`, `LiveActivityTest`, `TimelineTest`, `UsageTest`, `AgesTest`, `ConversationPresentationTest`, `AgentControlsTest`, `ConversationSliceTest`, `ConversationEndToEndTest`                                                                                                                       | done, façade (conversation: keyed timeline deltas, state, send, paging)                                                                                                                                                     |
| W5.1 Schedules                  | `schedules`                                                                                                                                              | `ScheduleRulesTest`, `SchedulesTest`, `DomainRulesTest`, `ClientApiEndToEndTest`                                                                                                                                                                                                                                       | done, façade (schedules)                                                                                                                                                                                                    |
| W5.2 Terminals                  | `terminals` (surfaces, input pumps, replay, cross-machine overview)                                                                                      | `TerminalScreenTest`, `TerminalOverviewCatalogTest`, `TerminalSelectionsTest`, `TerminalEndToEndTest`                                                                                                                                                                                                                  | done, façade (terminals, terminal overview)                                                                                                                                                                                 |
| W5.3 Workspace and git          | `workspace`                                                                                                                                              | `WorkspaceRulesTest`, `WorkspacePresentationTest`, `ReviewPresentationTest`, `DiffsTest`, `ReviewSliceTest`, `ClientApiWorkspaceEndToEndTest`                                                                                                                                                                          | done, façade (review, project changes, project workspaces)                                                                                                                                                                  |
| W5.4 Files                      | `files` (browser, tree, syntax, drafts)                                                                                                                  | `FilesTest`, `FilesEndToEndTest`                                                                                                                                                                                                                                                                                       | done, façade (files, file tree)                                                                                                                                                                                             |
| W5.5 Admin                      | `admin`                                                                                                                                                  | `AdminRulesTest`, `ClientApiAdminEndToEndTest`                                                                                                                                                                                                                                                                         | done, façade (`AdminCommand`)                                                                                                                                                                                               |
| W5.6 Quotas                     | `quotas`                                                                                                                                                 | `DomainRulesTest`, `QuotaRowsTest`, `UsageWidgetTest`, `QuotasEndToEndTest`                                                                                                                                                                                                                                            | done, façade (quotas)                                                                                                                                                                                                       |
| W5.7 Activity and notifications | `activity`, `notifications`                                                                                                                              | `ActivityTest`, `WidgetModelTest`, `NotificationsTest`                                                                                                                                                                                                                                                                 | done, façade (activity; notifications through the native sink)                                                                                                                                                              |
| W5.8 Search                     | `search`                                                                                                                                                 | `DomainRulesTest`                                                                                                                                                                                                                                                                                                      | done, façade (`SearchCommand`)                                                                                                                                                                                              |
| W5.9 Executions                 | `executions`                                                                                                                                             | `DomainRulesTest`, `ClientApiProcessesEndToEndTest`                                                                                                                                                                                                                                                                    | done, façade (processes)                                                                                                                                                                                                    |
| W6 Screens                      | `screens` (trust, session controller, recovery, input, gestures, mouse buttons, clipboard, frame gating, receiver feedback), `platform/ControlFrames.kt` | `ScreenPoliciesTest`, `ScreenFramesTest`, `MouseButtonsTest`, `ControlFramesTest`, `ScreenSessionTest` (scripted daemon and engine), `ClientApiScreenEndToEndTest`                                                                                                                                                     | done, façade (screen)                                                                                                                                                                                                       |
| D7 UI contract                  | `client` (`ClientApi`, per-scope surfaces, domain command handlers, slice mappers, keyed deltas), `apple`                                                | `KeyedTest`, the `client/*SliceTest`s, the `ClientApi*EndToEndTest`s, `just pipeline check component:mac operation:core_test`                                                                                                                                                                                          | done                                                                                                                                                                                                                        |
| Rules for Swift                 | `client/rules` (`*Exports`), `apple/SharedRules.kt`                                                                                                      | the `*ExportsTest`s, `SharedCoreTests` (Swift)                                                                                                                                                                                                                                                                         | done, façade (`SharedRules`)                                                                                                                                                                                                |
| F5 App integration              | Android `sharedcore/` (`SharedCore`, `ConnectionPolicy`); Apple `SharedCore`, `DieterTransport`, and slice adapters (`DieterMac`, `DieterIOS`)           | Android unit tests and instrumentation catalog (`tests/e2e`); `just pipeline mac test_unit`, `just pipeline check component:mac operation:core_test`, `just pipeline check component:mac operation:screens_test`; `just pipeline ios build` and the iOS cases (`ios.adapters`, `ios.credentials`, `RemoteNodeUITests`) | Android, macOS, and iOS on the core.                                                                                                                                                                                        |
| W7 Consolidation                | —                                                                                                                                                        | —                                                                                                                                                                                                                                                                                                                      | Android: legacy logic, protobuf-lite, grpc-java, and rule duplicates deleted. macOS and iOS: the legacy feature plane, the legacy importer, the Swift rule copies, and the `DieterCore` and `DieterClient` modules deleted. |

**On the Apple façade:** every feature, as `client.proto` commands and
slices, plus `SharedRules` for render-time rules. Screens take a
`NativeScreenMedia` engine and a `NativeClipboard` through
`SharedExtensions`; engines are created per observed screen scope. Terminal
output reaches Swift through the terminals slice.

## Deviations from the plan

- **Client schema location.** The client schema lives in
  `model/src/commonMain/proto/dieter/client/v1`, not `api/proto`. It never
  crosses the network, so it stays with the core that owns it. It is one
  file, `client.proto`, not one file per domain.
- **Wording (D9 reversed).** The core supplies English text (relative ages,
  sizes, counts, labels, status lines), so both apps say the same thing; the
  apps format only absolute dates in the device locale.
- **Rules for Swift.** Values derived from slice state are slice fields
  computed by the core's Kotlin views, which Android reads directly; pure
  render-time rules are synchronous `SharedRules` exports. D7 planned only
  slices and commands.
- **Android reads the Kotlin views.** D7 planned for Android to use the
  client types; it calls the domain APIs instead, so `ClientApi` serves Swift
  only.
- **No rollout switches or shadow mode** (D10), no conformance vectors, and
  no Kover coverage gate. Android switched in one pass and macOS one domain
  at a time, before either had users.
- **No legacy import.** Neither app imports state from its versions before
  the core; there were no users yet. The macOS and iOS importer was built and
  then deleted unused. The Mac's gateway session file is the core's secure
  store, so sign-in survives. Files earlier Android versions left behind
  are not cleaned up; reinstalling removes them.
- **Harnesses retired.** The Apple adapter harness became the Mac's
  `SharedCore` target and `SharedCoreTests` (`just pipeline check component:mac operation:core_test`). The
  Android harness was deleted: `just pipeline core_test` runs the same OkHttp
  transport on the JVM, and the app's instrumentation
  (`SharedCoreIntegrationTest`) covers the Android bindings.
- **Screen routes** use the machine's shared data plane. Tokens renew per
  RPC, so a planned route refresh is unnecessary. Every attempt fetches a
  fresh RTC configuration and the enrolled certificate, and the certificate
  is pinned for the session.
- **Screen trust failures are fatal immediately.** They are never
  resubscribed.
- **Android credentials** stay in the app's Keystore-backed
  `DieterCredentialStore`, which is keyed by origin as the core is; the core
  uses it as its `SecureStore`.
- **iOS starts clean.** Its sessions live in a new Keychain service
  (`com.dbpprt.dieter.ios.core`); earlier installs' items and defaults are not
  read, so every install signs in once.
- **iOS navigation follows Android.** Inbox (`SLICE_ACTIVITY`), Projects (a
  board view per board), and Chats replace the earlier "All tasks" list; no
  task-list slice was added.
- **iOS screens use the trackpad model.** The core's `TouchScreenInput`
  (also behind Android's canvas) replaced the iOS gesture and geometry code.
  The one-shot right click and armed modifiers live there too, but only the
  iOS toolbar uses them so far.
- **Pending cards** carry aliases (the deterministic and the acknowledged
  daemon ID), so a card never shows twice when sync delivers it before the
  create reply.

## Build and test

You need Android Studio's JBR, the Android SDK (platform 37.1), Go, Node (for
the mock harness, installed with `npm --prefix internal/harness/runtime ci`), and, on macOS,
Xcode. The first Kotlin/Native build downloads about 1.6 GB into `~/.konan`.

```sh
just pipeline core_test          # JVM unit and end-to-end tests against isolated gateways and daemons, over the OkHttp transport Android shares
just pipeline core_apple_test   # Kotlin Apple tests, then Swift fixture integration through the Mac bridge
just pipeline ci action:check component:core         # everything this host supports
```

The lanes own Gradle options and isolated fixture setup. Use `filter:NAME` on
unit lanes when narrowing validation; see [pipeline commands](../../fastlane/README.md).

After changing the client schema (`model/src/commonMain/proto/dieter/client/v1`),
regenerate the Mac package's Swift types with `just pipeline mac local action:proto_generate`; it
copies the schema into `apps/mac/Sources/DieterAPI/client` first.

On an iOS simulator:
`./gradlew :shared:iosSimulatorArm64Test -Pdieter.simulator=<disposable simulator UDID>`.

Every end-to-end test starts its own gateway and daemon from
`tools/fixtures/gateway`, with a temporary `DIETER_HOME` and random loopback
ports. They never touch an operator's daemon.
