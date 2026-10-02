# iOS shared-core integration plan (2026-10-02)

How to land the uncommitted KMP follow-on work on `main`, then rebase PR #113
(`feat/ios-kmp-core`, "Migrate iOS client logic to shared KMP core") onto it,
and finish iOS as a presentation-only client like Android and macOS.

## 1. Starting point

| | State |
|---|---|
| `main` / `origin/main` | `11f4c9f6`. The Mac app and Android already run on the core. |
| Local tree on `main` | About 667 uncommitted files (+33.6k / −34.2k, 88 untracked). Another session is still editing it: the core `client.proto` changed at 11:00 and the Mac copy at 11:06. |
| PR #113 | 3 commits on `11f4c9f6`, including a merge from `main`. 36 files (+2076 / −3271). All 8 CI checks are green, but against `origin/main`, not the local tree. No reviews. |

**What the local changeset does:**

- **A. Rules move into the core.** New `core/client/rules/*Exports.kt`, `apple/SharedRules.kt` (87 synchronous rules for Swift), and new domain files for board view, chats, open requests, quota rows, schedule and review presentation, screen input/signaling/view, and browser rules. `client.proto` grows from 1974 to 3378 lines.
- **B. Legacy importer deleted.** `core/legacy/*`, `importLegacy`, `needsLegacyImport`, `legacyClientId` and `MacLegacyInputs` are gone. There were no users to carry over.
- **C. Core Android harness retired.** `apps/core/harness/android`, `just core android-test`, and its CI step are removed.
- **D. Mac finishes the cutover.** 23 Swift rule files are deleted and replaced by `SharedRulesSupport`, `ChatsListModel`, `CreationFormModel` and `CoreNavigation`.
- **E. Swift module split.** New `DieterTransport` target (`ControlRTCBridge`, `DaemonCertificatePinning`, `DieterTransportTarget`). `DieterCore` and `DieterClient` are pruned to what iOS still uses, and `SharedCore` now depends on `DieterTransport` instead of `DieterClient`.
- **F. Android cleanup.** Rule duplicates deleted, versions come from the core's catalog, and the proguard file and legacy launcher icons are removed.
- **G. e2e and check tooling.** A change under `apps/core` now selects every Mac case and all non-Apple Android cases.
- **H. Docs.** Plans marked as built, plus READMEs and the parity matrix.

**Overlap with PR #113.** No local change touches `apps/mac/Sources/DieterIOS/**`, `apps/mac/Tests/DieterIOSTests/**` or `apps/ios/**`. The PR's iOS files therefore apply cleanly. The real work is semantic: the PR's iOS code targets the old façade and the old `client.proto`.

## 2. Decisions needed before Phase 2

| # | Decision | Recommendation |
|---|---|---|
| D1 | **Sign-out.** The local tree deleted the `SignOut` command and `CoreRuntime.signOut()` because neither Mac nor Android used them. The PR's `IOSGatewayView` has a "Sign out" button that dispatches it. | **Restore it in the core.** Clearing the session, secure-store entry and journals is a core rule, and Mac and Android should offer sign-out too. The alternative is to drop the iOS button. |
| D2 | **iOS legacy data.** The PR imports old iOS state through `importLegacy`: the gateway, the Keychain token, the preferred machine and the client ID. The local tree deletes the importer. | **No import.** This follows the "no users yet" ruling already applied to Android and Mac. Existing iOS installs sign in again, because the Keychain service changes to `com.dbpprt.dieter.ios.shared-core`. |
| D3 | **Debug test gateway.** The PR's `LegacyInputs` loopback change exists only so `DIETER_IOS_TEST_GATEWAY` / `DIETER_IOS_TEST_TOKEN` reach the core through the importer. | Replace it with a DEBUG-only bootstrap that dispatches `adoptSession{gatewayURL, sessionToken}`. The core's `Gateway.permitted` already accepts loopback. |
| D4 | **How much of PR #113 is "done".** Phase 2 makes it compile and pass. Phase 3 removes the Swift rules it still keeps. | Land Phase 2 as PR #113. Phase 3 can follow as its own PR, or go into #113 if you want one iOS cutover commit, like the Mac's. |

## 3. Phase 0: Finish and stabilize the local changeset

1. **Let the other editing session finish.** Don't commit while files are still changing. If it is still running, coordinate with it, or use a private index (see the shared-tree selective-commit note).
2. **Fix the `observe` regression in `apps/core/apple/.../DieterShared.kt`.** At HEAD, `observe` turned a `ClientFailure`, or an unknown slice number, into a failure `Update`. The local version calls `api.observe` directly from a non-`@Throws` function. An old framework paired with a newer app (unknown slice → `SLICE_UNSPECIFIED`) would then abort instead of reporting a failure. Restore the `try`/`catch`, and add an Apple façade test that observes an unknown slice.
3. **Sync the generated Swift.** Run `just mac proto-generate`, then `just mac shared-framework`. The Mac copy of `client.proto` and `client_client.pb.swift` lagged the core: `has_earlier` was missing, but `ConversationModel.swift` uses `hasEarlier_p`. The Mac app doesn't compile until they match.
4. **If D1 is accepted, restore `SignOut`** (command, `CoreRuntime.signOut`, a core test) now, so Phase 2 doesn't change the core contract again.
5. **Gates, all green on the final tree:**
   - `just core test`
   - `just core apple-test`
   - `just mac build`, `just mac test`, `just mac format-check`
   - the Android unit tests, plus `just e2e run` on the emulator only (`ANDROID_SERIAL`), with the sync suite
   - `just ios build`, as a guard: the iOS target should still build on the legacy Swift client after the pruning
   - `go test ./internal/brandassets ./internal/remotedesktop ./tools/e2e`
   - `git diff --check`

## 4. Phase 1: Commit the local changeset to `main`

Each commit must build on its own. Most of the work is one atomic commit, because the core's Kotlin API (`CoreRuntime.signOut`/`sendMessage`/`RuntimeConfig` changes), `client.proto`, the generated Swift, the Mac app and Android all move together.

| # | Commit | Contents |
|---|---|---|
| 1 | Drop unused Android build and brand leftovers | `proguard-rules.pro`, legacy launcher icons, `sync-brand-assets.sh`, `internal/brandassets/assets_test.go` (workstream F, independent part) |
| 2 | Retire the core's Android harness | `apps/core/harness/android`, `just/core.just`, the CI step, `scripts/check_changed*.py`, `AGENTS.md` (workstream C). This must not land after commit 3, because the harness compiles against the old core API. |
| 3 | Move every client rule into the shared core | Workstreams A, B, D, E, the rest of F, and G, plus the generated Swift and the Phase 0 fixes |
| 4 | Record the as-built state | Plan docs, READMEs, `docs/README.md` (workstream H). This can be folded into commit 3. |

Then push to `origin/main` once you approve. CI on `main` gates only `mac.core` / `mac.board`, so dispatch the full Mac smoke manually. Four cases are known to fail on the runner regardless.

## 5. Phase 2: Rebuild PR #113 on the new `main`

### 5.1 Replay the PR as one patch

Don't merge the PR's merge commit forward. Replay its net diff onto the new `main`:

```sh
git switch -c feat/ios-kmp-core-v2 origin/main
git diff 11f4c9f6 origin/feat/ios-kmp-core | git apply -3 --index
```

Resolve as follows:

| File | Resolution |
|---|---|
| `core/files/Files.kt` | Merges cleanly. Keep `resolveWorkspaceImage()`; the PR's `call { it.GetWorkspace(…) }` works with the local `call`. |
| `core/presentation/Links.kt` | Merges cleanly. Keep `WorkspaceImages.isWorkspaceImage` and also export it through `SharedRules` (Phase 3 uses it). |
| `MarkdownAndLinksTest.kt` | The conflict is only in the import block. Keep both `assertFalse` and `assertFailsWith`. |
| `FilesEndToEndTest.kt` | Applies cleanly (the `file://` image case). |
| `legacy/LegacyInputs.kt`, `LegacyInputsTest.kt` | **Keep them deleted.** Drop the PR's hunks (D2/D3). |
| `apps/core/README.md` | Keep the local rewrite. Update the iOS paragraph and the F5/W7 parity rows to "iOS on the core". Drop the PR's legacy-import row and its "carried over once by the importer" sentence. |
| `apps/mac/Package.swift` | Take the merge (DieterIOS gains `DieterShared` and `SharedCore`), then remove `"DieterClient"` from DieterIOS once the import path is gone. `SharedCore` already brings in `DieterTransport`. |
| `just/ios.just`, xcscheme, `apps/ios/**`, `DieterIOS/**`, `DieterIOSTests/**` | Take the PR's version. |

### 5.2 Fix the compile breaks against the new contract

**Façade (`DieterShared.kt`):**

1. `IOSCoreStore.swift:54`: remove the `legacyClientId:` argument from `SharedConfiguration`.
2. `IOSCoreStore.swift:84`, `IOSStore.swift:134,192`: `shared.clientId` is gone. Delete `clientID` and the `DieterIOSClientID` default.
3. `IOSCoreStore.swift:85-97`, `IOSStore.bootstrap()` (around 162-191): delete `needsLegacyImport`, `importLegacy` and `SharedAppleLegacyInput`, and the `DieterCredentialStore.token` read. Add the DEBUG `adoptSession` bootstrap (D3). It stays inert unless `DIETER_IOS_TEST_GATEWAY` is set and `DIETER_IOS_TEST_START_SIGNED_OUT != "1"`.

**`client.proto` / generated Swift:**

4. `IOSCoreStore.swift:~195-198`: replace the hand-written conversation delta fold with the Mac fold (`DieterMac/Features/Conversation/ConversationModel.swift:107-142`). That covers `upsertedTimeline` / `removedTimelineIds` / `timelineOrder`, `unattachedPlanIds`, `clearTurnFailure()` and `hasEarlier`. `awaitingReply` is gone; use `state.working`. Better still, lift the fold into `SharedCore` so both apps share one implementation.
5. `IOSStore.swift:129`: `session.signedIn` is gone. Use `session.phase != .authRequired`, as `CoreSession.swift:206` does.
6. `IOSStore.swift:221`: `Result.gatewaySelected` is gone. Read `session.gatewayOrigin` after `completeSignIn`, as `DieterStore+Connection.swift:54` does.
7. `IOSStore.swift:254`: `SignOut` is restored (D1), or the button is removed.
8. `IOSStore.swift:420`: `MachineMetadata.error` is gone. Handle the `ensureMetadata` failure in the command result.
9. `IOSStore.swift:462`: `ClientCreateConversation.request` → `intent` (`ClientCreationIntent{projectID, boardID, checkoutID, lane, title, prompt, attachments, selection, labelIds, workspaceMode}`) + `submissionID`.
10. `IOSStore.swift:706,731`: `ClientTerminalToggle` / `ClientTerminalStep` → `ClientToggle` / `ClientStep`.
11. `IOSRemoteDesktopSession.swift:106,107,110,229,250`: `ClientScreenStep` → `ClientStep`.

To find anything this list misses, build: `just mac proto-generate && just mac shared-framework && just ios build`.

### 5.3 Phase 2 gates

- `just core test`, `just core apple-test`
- `just ios build`, `just mac test` (`DieterIOSTests`, including `IOSArchitectureTests`), `just mac format-check`
- `just e2e run --platform ios --device iphone --case ios.remote-node`, `--case ios.terminal`, `--case ios.share-extension`
- `just e2e run --platform ios --device ipad --suite smoke`
- `git diff --check`

Then force-push `feat/ios-kmp-core-v2` to `feat/ios-kmp-core`, with confirmation first, and update the PR body. Remove the legacy-import claim and add D1–D3.

## 6. Phase 3: Make iOS presentation-only

The PR still keeps Swift rules that the new core owns. Move each to its core source. Each row can be its own commit with `DieterIOSTests` updated.

| iOS code today | Core replacement |
|---|---|
| `IOSConversationPresentation.timelineItems` (activity grouping, `isTool`, `needsAttention`, "N commands · N edits") | `ConversationSlice.timeline` (`TimelineItem.activity/summary/groups/delivery/copyable`). Keep only scroll behaviour, the draft struct and `queuedDraft`. |
| `IOSStore.phase` → `ConnectionPhase.label` (root, gateway and conversation views) | `session.phaseLabel`, `session.notice`, `session.workspaceLive` |
| `IOSStore.machines` rebuilding `DieterEndpoint`; `MachinePresenceText.lastSeen` in the machine, terminals and screens views | `MachineEntry.detail/showLastSeen/available/unavailableMessage/screenStatus/canShareScreen`, `SharedRules.machineLastSeen` |
| `IOSStore.createTask` validation, the 100-character title truncation, lane and `workspaceMode` choice; `harnesses()`, `ProviderOptionValues.*`, composer pickers | The `.creationPreview` slice + `CreationPreviewCommand` + `CreateConversation{intent}`; `ChooseAgent` + `ConversationState.agent`. Mirror Mac's `CreationFormModel`. |
| `IOSRemoteDesktopPhase.label`, the Linux/Accessibility wording, the `[30,60,90,120]` frame-rate filter | `ScreenSlice.phaseLabel/controlUnavailableReason/frameRates/latencyLabel`. Mirror Mac's `RemoteDesktopController`. |
| `ProviderStatusPresentation.label` | `ConversationState.liveActivity` / `liveReasoning` |
| `RemoteWorkspaceImage.isWorkspaceImageURL` | A `SharedRules` export of `WorkspaceImages.isWorkspaceImage` (or `resolveContentLink`). `Files.open` already resolves the path. |
| `IOSMachineInformationPresentation`, `IOSProviderQuotaView` helpers, the "5 MB/6 MB" attachment limits | `SharedRules.machine*`, `bytes`, `QuotasSlice.groupRows`, `quotaResetText`, `attachmentLimitError` |
| File labels and icons | `FilesSlice.documentKey/languageName/typeLabel`, `SharedRules.fileRenderer/fileIconKind` |
| Fixed `"ios-files"` / `"ios-terminals"` scopes | Per-view surface scopes, like Mac's `FilesModel` / `TerminalsModel`, so closed views release their surfaces |
| Hand-built `DieterShared(SharedConfiguration…, SharedExtensions…)` in `IOSCoreStore` | Extend `CoreHost` to accept a `NativeSecureStore` and per-platform options, so iOS and Mac share one host setup |

Any rule that turns out to have no core equivalent goes into the core first, with a core test, following the "Adding a rule" section in `apps/core/README.md`. It doesn't stay in Swift.

## 7. Phase 4: Clean up and lock in

1. Delete the Swift helpers only iOS used: `MachinePresenceText` (in `DieterEndpoint.swift`), `ProviderOptionValues` (`HarnessSelection.swift`), `ProviderStatusPresentation.swift`, `RemoteWorkspaceImage.swift`, and `DieterClient/DieterCredentialStore.swift`. Then check whether `DieterCore` / `DieterClient` still have any non-test, non-smoke user.
2. Tighten `IOSArchitectureTests`: forbid `import DieterClient`, the deleted type names, and Swift-side wording tables. Match whatever architecture gate the Mac uses.
3. Update the docs: `apps/core/README.md` (iOS in the parity matrix, deviations), `apps/ios/README.md`, `AGENTS.md`, and mark this plan as built. Update the KMP memory note: iOS is on the core, and there is no legacy import on any platform.
4. Re-measure iOS binary size with the core linked. The 5.0 MB estimate came from the gomobile comparison.
5. CI: confirm `tools/e2e` selects the iOS cases on `apps/core` changes, the same way it selects the Mac and Android cases. If it doesn't, add it, because core changes now affect all three clients.

## 8. Risks

- **Moving target.** The local tree is still being edited. Phase 2 has to start from the committed `main`, not from a live tree. Otherwise the proto drift seen today (`has_earlier`) shows up again in the iOS build.
- **Proto field reuse.** Removed `client.proto` fields aren't marked `reserved`. That's harmless while the framework and app ship together. Reserve them anyway once iOS links the framework, because the façade promises that an old framework never crashes a newer app.
- **Keychain reset.** With D2, every existing iOS install signs out once. Say so in the release notes.
- **Shared Gradle builds.** Don't run `just core *` and an Android build at the same time (Android includes the core build), and never `--stop` the shared Gradle daemons.
