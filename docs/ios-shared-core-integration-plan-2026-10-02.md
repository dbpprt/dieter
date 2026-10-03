# iOS shared-core cutover plan (2026-10-02)

This plan moves the iOS app onto the shared Kotlin core as a presentation-only
client, the way Android and macOS already work. The baseline is `main` at
`4860c64c` ("Move the remaining client rules into the shared core").
[PR #113](https://github.com/dbpprt/dieter/pull/113) is used as reference
material and is not merged.

**Status: built and verified (S1–S5).** See [As built](#5-as-built) for where
the result differs from this plan, and for the suite results.

## 1. Decision: reimplement on `main`, take pieces from #113

PR #113 targets the core contract from before `4860c64c`. Replaying it is the
wrong approach:

- **It uses removed contract.** It depends on `SignOut`,
  `importLegacy`/`needsLegacyImport`/`legacyClientId`/`clientId`,
  `SessionSlice.signed_in`, `awaiting_reply`, `Result.gatewaySelected`,
  `CreateConversation.request`, and the `ScreenStep`/`TerminalStep`/`TerminalToggle`
  messages. `main` no longer has any of these.
- **It is a compatibility shim, not a cutover.** Its 830-line `IOSStore` converts
  core slices back into the legacy shapes (`DieterEndpoint`, `ConnectionPhase`,
  `Dieter_V1_CardDetail`). The views still import `DieterCore` and keep their
  Swift rules. Removing those rules would mean rewriting the same layer a
  second time.
- **It doesn't apply cleanly.** It conflicts with `main` in 4 files: the core
  README, `MarkdownAndLinksTest`, and `LegacyInputs` plus its test, which `main`
  deleted.

About 35–40% of its lines are worth keeping, almost all of them at the platform
edges:

| From #113 | Use |
|---|---|
| `Files.kt` `resolveWorkspaceImage`, `Links.kt` `WorkspaceImages.isWorkspaceImage`, the `FilesEndToEndTest` and `MarkdownAndLinksTest` cases | Re-apply by hand in W1. Both files moved after the PR was cut. |
| `Core/IOSCoreBridge.swift` (Keychain `NativeSecureStore`) | Basis for `CoreKeychainSecureStore` in W2. Keep the legacy service name (D2). |
| WebRTC media engine in `IOSRemoteDesktopSession.swift` (`IOSScreenMedia`, `IOSScreenMediaEngine`, video relay, `IOSScreenFixture`, about 540 lines) | W2/W4 screens, after reconciling with the Mac's `CoreScreenMediaEngine`. |
| `IOSArchitectureTests` | W5, extended. |
| UI test helpers (`tapVisibleFrame`, `tapWhenEnabled`, quota-sheet dismissal wait) | W5 |
| `just/ios.just`: the `shared-framework.sh … all` step and `ARCHS=arm64` | W3 |
| `IOSCoreStore`, the `IOSTerminalsModel` thin wrapper, `IOSAuthentication` trimming | Ideas only. The Mac adapter pattern replaces them. |
| `IOSStore`, `IOSCoreQuotas`, `IOSConversationPresentation`, `IOSModelTests` rewrite, view edits | Discard. |

Close #113 as superseded once W4 lands, with a comment pointing to the commits
(confirm first).

## 2. Decisions (settled 2026-10-02)

| # | Decision |
|---|---|
| D1 | **Sign-out returns to the core.** `SignOut` and `CoreRuntime.signOut()` forget the gateway credential, clear the session, journals and outbox, and stop routes. iOS uses it; Mac and Android buttons come later. |
| D2 | **Clean break, no backward compatibility.** iOS keeps credentials in a new Keychain service (`com.dbpprt.dieter.ios.core`). It does not read the legacy `…gateway-sessions` items, the `DieterIOSGateway`/`DieterIOSClientID` defaults, or any old file, so every install signs in again. |
| D3 | **iOS navigation follows Android: Inbox, Projects, Chats.** The Inbox is `SLICE_ACTIVITY` (needs you, running, recent, finish). Projects are `SharedRules.sidebarProjects` plus `SLICE_BOARD_VIEW` per board. Chats are `SLICE_CHATS`. The old "All tasks" and per-project task lists go away, and no new core slice is needed. iPad keeps the split view. |
| D4 | `compactTranscripts` is on for iPhone and iPad. |
| D5 | The screen client name is `"iPhone"` / `"iPad"`. |
| D6 | **`DieterCore` and `DieterClient` are deleted in the same change.** The Mac stops using them: `DieterEndpoint` gives way to core `MachineEntry`/gateway data, `DieterTaskSleep` moves to `SharedCore`, and `SmokeFixturePlane` gets a DEBUG-only replacement without `DieterClient`. Files that `native/macos-capture` compiles by path move to `DieterTransport`. |
| D7 | **Implementation runs end to end first; the slow suites run once at the end.** Stages S1–S4 check only that things compile. S5 runs the suites one at a time. |

## Execution stages

| Stage | Scope | Checks during the stage |
|---|---|---|
| S1 | Core: W1 (except W1.6, superseded by D3) | Kotlin compile (JVM, macOS, iOS) |
| S2 | Swift shared layer and Mac: W2, deleting `DieterCore`/`DieterClient` from the Mac side (D6), and W6.1 | `swift build`, building the tests |
| S3 | iOS app: W4, as foundation → conversation and creation → files, terminals and quotas → screens | `just ios build` |
| S4 | Tests, build, CI and docs: W3, W5, W6.2 | Compile only |
| S5 | Run every suite in §3 sequentially, then fix what fails | Full suites |

## 3. Work packages

Each package lands as its own commit on `main` and leaves Android, Mac and the
legacy iOS app green, except W4, which switches iOS over. Order: W1 → W2 → W3 →
W4 (+W5 in the same commit) → W6. W1–W3 can be done in parallel if needed, but
they change different layers, so landing them serially is simpler.

### W1 Core prerequisites (Kotlin, core tests only)

1. **Fix the `observe` crash path.** `DieterShared.observe` (`DieterShared.kt:372`) now calls `ClientApi.observe` directly. An unknown slice number becomes `SLICE_UNSPECIFIED`, and `ClientApi.kt` throws `IllegalArgumentException` across a non-`@Throws` boundary, which aborts the process. Restore the HEAD~1 behaviour: catch the error and emit one failure `Update`. Add an apple-test that observes slice 9999.
2. **Sign-out (D1).** Add `SignOut` to `client.proto`, `CoreRuntime.signOut()` and a `Credentials.remove`, with a JVM end-to-end test: after sign-out the session phase is `AUTH_REQUIRED`, the secure store is empty, and the outbox is cleared.
3. **Workspace images.** Port `resolveWorkspaceImage` from #113 into `files/Files.kt` (`file://` and absolute paths → `GetWorkspace` → workspace-relative), add `WorkspaceImages.isWorkspaceImage`, export both through `SharedRules`, and port #113's tests.
4. **Terminal keys.** Export `TerminalKeys.control` and move the arrow, F-key and Home/End/PgUp/PgDn escape sequences from `IOSTerminalsModel` into `TerminalKeys` as one table, used by iOS and Android. Port the iOS key tests to core.
5. **Touch screen input.** Export `ScreenGestures.kt` (`TouchTrackpad`, `ScreenCanvas`; already used by Android) to Swift, either as stateful façade objects or through `SharedRules` calls. This should replace `IOSRemoteDesktopGeometry` (aspect-fit, zoom, letterbox), the one-shot right click and armed modifiers. Any iOS-only behaviour goes into core first.
6. ~~Task lists~~: superseded by D3, since the Inbox is `SLICE_ACTIVITY`.
7. **Share-extension limits.** Confirm that `SharedRules.attachmentLimits`/`attachmentLimitError`/`attachmentMediaType` match the extension's 4 files / 5 MB / 6 MB, and port the MIME normalization tests.

Gates: `just core test`, `just core apple-test`, the Android unit tests, and `just mac test`. Any `client.proto` change also needs `just mac proto-generate`, then `just mac shared-framework`.

### W2 Make `SharedCore` work on both platforms (Swift; the Mac stays green)

1. **Parameterize `CoreHost`.** Add a `CoreHostPlatform` (or extend `CoreHostConfiguration`) with `secureStore`, `includeLoopbackRoutes`, `compactTranscripts`, `screenClientName`, `desktopScreens`, `clientIDPrefix`, `oauthRedirectURI`, `notifications` and `clipboard`. The Mac passes today's hard-coded values (`CoreHost.swift:56-80`). iOS doesn't build `DieterShared` by hand the way #113 did.
2. **Add `CoreKeychainSecureStore`.** It is synchronous (the façade needs `NativeSecureStore` to be sync), uses service `com.dbpprt.dieter.ios.core`, `AfterFirstUnlockThisDeviceOnly`, and is not synchronizable. Nothing is carried over (D2).
3. **Lift the Mac adapters that don't depend on AppKit into `SharedCore`**, and switch the Mac to the lifted copies in the same commit:
   - `SharedRulesSupport` (verbatim)
   - the workspace delta fold (`CoreSession.swift:54-67`) and the conversation delta fold (`ConversationModel.swift:109-151`), as `applying(_ delta:)` extensions next to `KeyedList`
   - `WorkspaceTarget`
   - `ChatsListModel`, `CreationFormModel` (inject `create` as a closure), `CoreProviderQuotas`, `FilesModel`, `TerminalsModel`, `TerminalOverviewModel`, and `FleetModel` once it no longer depends on `DieterEndpoint`

   Replace their `#if DIETER_UI_SMOKE` hooks with injectable seams. Give every model a scope parameter, so each view owns its surface.
4. **Screen media.** Split `CoreScreenMediaEngine` (`CoreScreenMedia.swift:123-400`, plain WebRTC) from its renderer through a `ScreenRenderer` protocol (`reset()`, a fresh `decodeHandler()` per engine, `onFramePresented`, `onFailure`). The Mac keeps `RemoteDesktopMetalView`. iOS provides a UIKit renderer built from #113's video relay. The engine, peer, channel and statistics code is then shared. Also add a `UIPasteboard` `NativeClipboard`.
5. **Tests.** Extend `SharedCoreTests` with Keychain store round-trips, both delta folds, and host configuration per platform. Lifted models keep their existing `DieterMacTests` adapter tests on `ScriptedCoreClient`.

Gates: `just mac test`, `just mac core-test`, `just mac format-check`, the Mac UI smoke subset touching the lifted models (`mac.core`, `mac.board`, chats, files, terminals, screens), and `just mac screens-test` (refuses to run while DieterMac is running).

### W3 Build, release and change selection

1. In `just/ios.just`, `build` runs `apps/mac/scripts/shared-framework.sh debug all`. `build-device` and the archive recipes run `release all`. Take `ARCHS=arm64` for simulator builds from #113.
2. In `apps/mac/Package.swift`, add `SharedCore` and `DieterShared` to the `DieterIOS` target. In W4, remove `DieterCore` and `DieterClient`.
3. `scripts/ios_release.py` and `.github/workflows/ios-testflight.yml`: add JBR/Java setup and the release framework build.
4. In CI `ios_quick` (`ci.yml:228-263`), give iOS its own framework cache key. The Mac's `dieter-shared-v1-<hash>` may hold only the macOS slice.
5. In `tools/e2e/main.go` `affected()` and `scripts/check_changed.py`, select iOS cases for `apps/core/`, `apps/mac/Sources/SharedCore`, `DieterTransport` and `shared-framework.sh`, as Mac and Android already do. Add tests in `runner_test.go` and `check_changed_test.py`.

Gates: `just ios build` (it links the framework but nothing uses it yet), the `tools/e2e` Go tests, `check_changed` tests, and a CI dry run of `ios_quick`.

### W4 iOS cutover (one atomic commit with W5)

The structure mirrors the Mac's: an `@Observable` per feature, `SliceSubscription`,
a `queued` command chain, surface commands that return their slice, and folds
that check the bound target. Views read presentation-ready fields or call
`SharedRules`. There is no Swift wording, ordering or enablement logic.

| Area | iOS today | Replacement |
|---|---|---|
| Bootstrap | `IOSStore` builds `ConnectionManager`/`DieterRPC` | `IOSCoreHost` = `CoreHost(iOS platform)`, `start()`. `scenePhase` → `SetForeground(true/false)`. No seeding from legacy defaults (D2). DEBUG: `DIETER_IOS_TEST_GATEWAY`/`TOKEN` → `AdoptSession` after `start()`, skipped when `START_SIGNED_OUT=1`; per-launch temporary state root and defaults suite; `DIETER_IOS_SCREEN_FIXTURE` → `NativeScreenFixture` through `CoreHostScreens.fixture` |
| Session, gateway, auth | `IOSAuthentication(+Ownership)`, `ConnectionPhase.label`, `IOSUserError` | Keep `ASWebAuthenticationSession` only. `BeginSignIn` → `authorize_url` → sheet → `CompleteSignIn`. Token entry → `AdoptSession`. Read `SessionSlice.phase_label/notice/workspace_live/gateways`. Sign-out → `SignOut` (D1). Errors through `CoreFailure` |
| Machines | `IOSStore.machines` rebuilds `DieterEndpoint`; `MachinePresenceText`; `IOSMachineInformationPresentation` | `MachineEntry.detail/available/unavailable_message/screen_status/can_share_screen/show_last_seen`, `AttachMachine`, `SharedRules.machineLastSeen/machine*/bytes/gpuMemory`, telemetry slice through the lifted `FleetModel` |
| Lists, navigation | `DieterIOSRootView` "All tasks", sorting and lane filter | Inbox (`SLICE_ACTIVITY`), Projects (`SharedRules.sidebarProjects` + `SLICE_BOARD_VIEW`), Chats (`SLICE_CHATS`), `NavigationSlice`, `SharedRules.laneKind/runtimeLabel/cardAge` (D3). Keep the `NavigationSplitView` layout |
| Conversation | `IOSConversationPresentation`, `IOSTranscript`, paging, composer pickers, fast mode, `ProviderStatusPresentation` | Lifted conversation fold + `ConversationSlice.timeline/state/turn_failure/has_earlier`, `SendMessage`, `SteerConversation`, `RemoveQueuedMessage{edit}`, `LoadEarlierMessages`, `ReturnToLatest`, `SetVisibleConversation`, `ChooseAgent` + `state.agent`, `liveActivity/liveReasoning`. Scroll position stays native |
| Creation | `IOSCreateTaskView` labels and provider options, `IOSStore.createTask` validation and title truncation | Lifted `CreationFormModel`: `CreationPreviewCommand` → `CreationPreview{problem,title,start_lanes,defers_start,agent}`, `CreateConversation{intent, submission_id}`, `RememberCreation`, `SharedRules.labelProblem` |
| Attachments, share | `IOSAttachments` limits and MIME, `IOSShareInbox` | Keep the native pickers and the app-group `ShareInbox` handoff. The extension does not link DieterShared, because of the extension memory budget. Validate on consume with `SharedRules.attachmentLimitError/attachmentMediaType`. The extension's duplicated limits stay as a pre-filter only |
| Files | `IOSFilesView` legacy reads, `RemoteWorkspaceImage` | Lifted `FilesModel` (per-view scope), `FilesSlice.document_key/language_name/type_label`, `SharedRules.fileRenderer/fileIconKind/syntaxHighlights/resolveContentLink/isWorkspaceImage` |
| Terminals | `IOSTerminalsModel` (436 lines, VT keys, retention) | Lifted `TerminalsModel`/`TerminalOverviewModel` + `TerminalKeys` from W1. SwiftTerm and the accessory bar stay |
| Screens | `IOSRemoteDesktopSession` (1192), `FeedbackPump`, geometry, phases, 30 fps cap | `SLICE_SCREEN` + `ScreenCommand` controller modelled on `RemoteDesktopController`. Shared engine plus UIKit renderer (W2.4), with the renderer attached before observing under the same scope. Read `ScreenSlice.phase_label/frame_rates/latency_label/control_unavailable_reason`. Touch input through the exported `ScreenGestures` (W1.5) |
| Quotas | `IOSProviderQuotaView` helpers, `IOSQuotaSelection` | Lifted `CoreProviderQuotas`, `QuotasSlice.group_rows`, `SharedRules.quotaResetText/quotaWarning`. Symbols and tints stay as a view-only asset mapping |

Delete afterwards: `IOSStore` (legacy), `IOSTranscript`,
`IOSRemoteDesktopFeedbackPump`, `IOSAuthenticationOwnership`,
`IOSConversationAvailability`, `IOSWorkspaceContinuity`, `IOSUserError`,
`IOSConversationPresentation` (keeping the scroll and draft bits), and the Swift
geometry and key tables.

### W5 iOS tests (same commit as W4)

- **`DieterIOSTests`.** Rewrite them as adapter tests on `ScriptedCoreClient`, mirroring `CoreSessionAdapterTests`: bootstrap and DEBUG adopt, foreground toggling, fold order, scope ownership, and share-inbox consume. Rule tests have moved to core in W1, so drop the Swift duplicates.
- **`IOSArchitectureTests`.** Start from #113's version and extend it using the `TaskSleepPolicyTests` scanner. Forbid `import DieterCore`, `import DieterClient`, `DieterRPC(`, `ConnectionManager(`, `DataPlaneConnection(` and `RemoteDesktopSignalingConnection(` in `Sources/DieterIOS`.
- **`DieterIOSNativeTests`.** Retarget `IOSCredentialNativeTests` at `CoreKeychainSecureStore` in an app host. This covers the `ios.credentials` e2e case.
- **`RemoteNodeUITests`.** Add #113's tap helpers, and update the journeys for core wording that changed.

Gates for W4 and W5:

- `just core test`, `just core apple-test`
- `just mac test`, including `DieterIOSTests`; `just mac format-check`
- `just ios build`
- `just e2e run --platform ios --device iphone` for the cases `ios.remote-node`, `ios.connecting`, `ios.https-auth`, `ios.credentials`, `ios.terminal`, `ios.screen` and `ios.share-extension`
- `just e2e run --platform ios --device ipad --suite smoke`
- **Manual check against a real gateway.** Sign-in carries over from a legacy install (D2), then sign out, sign in again, and use screens on a device.
- `git diff --check`

### W6 Cleanup and documentation

1. Delete the Swift helpers only iOS used: `MachinePresenceText` (in `DieterEndpoint.swift`), `ProviderOptionValues` (`HarnessSelection.swift`), `ProviderStatusPresentation.swift`, `RemoteWorkspaceImage.swift`, `DieterClient/DieterCredentialStore.swift`, and any other `DieterCore`/`DieterClient` code left with no users. `RemoteDesktopKeyMap.swift` and `ScreenClipboardContent.swift` stay, because `native/macos-capture` compiles them by path.
2. Update the docs:
   - `apps/core/README.md`: the F5/W7 parity rows and the deviations.
   - `apps/ios/README.md`.
   - `apps/mac/README.md`: drop "`DieterCore`/`DieterClient` are the iOS app's model and gRPC client".
   - Cutover plan §7, "Still open": how the share extension links the core.
   - `AGENTS.md`: iOS is now on the core.
   - Mark this plan as built.
3. Re-measure the iOS binary size with the core linked, and record it in `apps/core/README.md`.
4. Comment on and close #113 (confirm first).

## 4. Risks

- **Screens are the riskiest area.** The engine/renderer split touches the Mac's working screen path. W2.4 has to pass `just mac screens-test` and the Mac screen smoke before W4 builds on it. The renderer-reset contract (a fresh `decodeHandler()` per engine) broke every Mac reconnect once already.
- **Framework and schema drift.** The Swift protos and the framework must come from the same `client.proto`. Always run `proto-generate` and then `shared-framework` before Swift tests. W1.1 makes a mismatch fail gracefully instead of aborting.
- **Keychain carry-over (D2).** If the key format differs from `Gateway.origin`, every install signs out silently. W2.2 tests this explicitly.
- **iOS screen performance.** Kotlin/Native slice encoding on the main thread could cause hitches during scrolling and screen streaming. Profile the conversation and screen views on a device in W4 before removing the legacy path.
- **Shared Gradle builds.** Never run two Gradle builds against `apps/core` at once, and never `--stop` the shared daemons. Kotlin/Native iOS slices are slow to build, so run them as background processes.

## 5. As built

The iOS app runs on the core through `SharedCore`; `DieterCore` and
`DieterClient` are deleted. Where it differs from the plan:

- **Navigation (D3).** The middle column lists Inbox (`SLICE_ACTIVITY`),
  Projects (a project's boards, then one `SLICE_BOARD_VIEW` per board view),
  Chats, Terminals, and Screens. The lane filter and "All tasks" are gone.
  Machine state opens from the machines toolbar menu, which sits beside
  Settings: the iPad sidebar's narrow bar folds a second trailing item into
  its overflow. Its New task button shows only when the columns collapse.
- **Screens.** iOS uses the core's trackpad model (`TouchScreenInput`, the
  one behind Android's canvas), exported as `SharedTouchScreen`: one finger
  moves the cursor, a tap clicks, a long press drags, two fingers zoom and
  pan, three fingers scroll. The earlier iOS gestures and geometry are gone.
  The toolbar's one-shot right click and armed modifiers are core state too,
  but Android's toolbar does not use them yet. The engine is the shared
  `CoreScreenMedia`; iOS supplies a UIKit renderer and `UIPasteboard`
  clipboard. Backgrounding sleeps the session and returning resumes it.
- **Terminals.** iOS binds the lifted `TerminalsModel` per machine. It does
  not use `TerminalOverviewModel`; that stays the Mac's cross-machine view.
- **Isolated runs.** A DEBUG launch with the test gateway or a preview keeps
  sessions in memory (`IOSEphemeralSecureStore`), never in the Keychain. The
  app reads only `DIETER_IOS_TEST_GATEWAY`, `_TOKEN`, `_START_SIGNED_OUT`,
  `DIETER_IOS_CONNECTION_PREVIEW`, `DIETER_IOS_QUOTA_PREVIEW`, and
  `DIETER_IOS_SCREEN_FIXTURE`; the other test values stay with the UI tests.
- **Wording.** Static copy (empty states, sheet explanations, field labels)
  and a few unit suffixes stay in Swift on purpose. Everything derived from
  state comes from slices or `SharedRules`.
- **Tests (W5).** `DieterIOSTests` keeps the macOS-portable share inbox and
  attachment tests (now checking the core's limits and naming) and adds
  `IOSArchitectureTests`, which also keeps the share extension free of the
  core. The adapter tests (`IOSCoreAdapterTests`) need UIKit, so they are
  XCTest, compiled into the app-hosted `DieterIOSNativeTests` target, and run
  as the new e2e case `ios.adapters`. `IOSCredentialNativeTests` tests
  `CoreKeychainSecureStore`, with renamed methods.
- **Build and CI (W3).** `just ios build` and `build-device`, the unsigned
  archive, and TestFlight build the framework first (`debug all` or
  `release all`). CI's `ios_quick` caches it under its own key
  (`dieter-shared-ios-v1`), and the TestFlight workflow sets up Java.
  `apps/core`, `SharedCore`, `DieterTransport`, and `shared-framework.sh`
  changes now select the iOS checks and cases.
- **Not done.** The iOS binary size (W6.3) was not re-measured, and #113 is
  not closed yet (W6.4).

### Verification (S5, 2026-10-03)

| Suite | Result |
|---|---|
| `just core test`, `just core native-test` (JVM, native, Apple façade) | Pass |
| `just android test` | Pass |
| `just mac test` (447 tests), `just mac core-test` | Pass; a schedules test double lost the RPC message when `DieterRPCFailure` went and was fixed |
| `just mac screens-test`, `just mac screens-native-test` | Pass |
| `just e2e run --platform mac --suite smoke` | Pass (10/10) |
| iOS smoke on iPhone (7) and iPad (6) | Pass. Fixes: stale universal `.xctestrun` (now removed by `just ios build`), the files-editor tap offset, and the iPad sidebar toolbar overflow |
| Android screen, terminal, and conversation cases on the emulator | Pass, except two. Fixed on the way: a synchronization bug in `ScreenEndToEndTest`, and the canvas's default focus highlight tinting the desktop outside touch mode. `screens.screen-recovery-end-to-end-test` fails at a different step each run, on code unchanged from HEAD, with emulator decoder pressure in the logs. `ConversationDraftQueueEndToEndTest`'s queued-edit half times out as it did at HEAD |
| `just e2e check`, `check_changed` tests, `justfile-check`, `workflow-check`, format and Markdown checks, `go test ./tools/e2e` | Pass |
| `just release test` | `ios_release_test` passes. The unchanged `configure_apple_signing_test` fails locally because `openssl pkey -check` rejects its key |

Not run: the full Go race suite (no Go change besides `tools/e2e`), `just e2e
run --suite functional --changed`, and the Android cases unrelated to screens,
terminals, and conversation.
