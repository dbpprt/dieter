**Dieter Mac responsiveness assessment — 8 September 2026**

Dieter was upgraded through Homebrew from **0.4.78 to 0.4.101 (101)** before the final live assessment. The latest app connects successfully to API 3. The earlier API mismatch is resolved and is not counted as an outstanding finding below.

The latest app has real loading and presentation defects, plus synchronous work that can cause intermittent hitches. The evidence does **not** establish a continuously overloaded main thread. The first improvements should make every interaction acknowledge immediately, distinguish loading from failure, and eliminate unnecessary content resets. Adding animation alone would leave several broken states intact.

Homebrew metadata was refreshed and only `dbpprt/tap/dieter-app` was upgraded. Bundle version and signature were verified at `/Applications/Dieter.app`. The release tag `v0.4.101` resolves to `2ecacfa9`, matching this checkout's HEAD. Existing uncommitted chat-disclosure changes were preserved; the measured projection function and the other cited implementations match the release. No daemon upgrade, restart, or installation was performed. The local daemon remained v0.4.99 / API 3.

The live journey covered All chats, two populated conversations, the 87-card Dieter board, Files and two text files, Schedules, project Changes and diff selection, Terminals, local and remote machine information, Settings/Prompts, and the Screens landing page. It used normal native controls. No messages, agent starts, Git mutations, terminal creation/closure, schedule changes, preference changes, or screen-sharing sessions were submitted. Normal navigation did update selection/read markers and sidebar disclosure state.

**What the measurements establish**

Two release stack samples were captured during conversation navigation. The first included accessibility-tree inspection: `_XCopyHierarchy` accounted for 4,108 of 14,820 main-thread samples (27.7%), with substantial SwiftUI accessibility/focus traversal beneath it. This is an important accessibility cost, but it also contaminates automated timing. The duration of a computer-use tool call is not a click-to-paint measurement.

The second ten-second sample omitted accessibility-tree polling during the measurement window. The main thread was waiting in `mach_msg2_trap` in 8,093 of 8,316 samples (**97.3%**), with no `_XCopyHierarchy` stack. This rules against a sustained busy loop in that sampled journey; it does not rule out short layout hitches or other workloads. The first sample's physical footprint was 286.3 MB, peak 287.5 MB. These observations do not establish a leak.

Synthetic probes used the canonical **debug** test cache, seven samples for data transformations and three for rendering. Rendering used `ImageRenderer` and the actual Markdown/message views. It is synchronous layout/rasterization cost, not live scroll FPS or release p95 latency. The eager-stack probe is a representative message stack, not the entire conversation screen. The fixtures contain synthetic text and do not access the daemon.

| Probe | Median | Interpretation |
|---|---:|---|
| Chat projection, 100 chats | 0.15 ms | Small directory filtering is cheap here. |
| Chat projection, 1,000 chats | 2.80 ms | Still relatively small; keep off repeated body paths where practical. |
| Chat projection, 10,000 chats | 23.69 ms | Large-directory scaling risk. |
| Apply global snapshot with one changed chat, 100 chats | 0.68 ms | Not a convincing explanation for severe lag at a small directory size. |
| Same operation, 1,000 chats | 8.88 ms | Consumes a meaningful frame budget. |
| Same operation, 10,000 chats | 88.95 ms | Whole-directory work becomes a clear hitch. |
| Decode inactive-machine cache, 24 × 30 messages, 762 KB serialized | 110.87 ms | Entire cache is decoded to retrieve one conversation. |
| Same cache, 7.40 MB serialized | 1,069.65 ms | Strong reason to remove this synchronous path; debug timing is not a release claim. |
| Render Markdown table, 50 rows × 5 columns | 53.39 ms | Eager rows and repeatedly computed column widths. |
| Render Markdown table, 100 rows × 5 columns | 162.36 ms | Superlinear growth in the tested table view. |
| Render eager stack, 30 formatted messages | 22.43 ms | Even bounded message counts do not guarantee cheap rendering. |
| Render eager stack, 180 formatted messages | 132.65 ms | The maximum retained view window is substantial. |

The host had 16 GB RAM and approximately 20.68 GiB of allocated swap. A five-second follow-up recorded **zero swap-ins and zero swap-outs**, so allocated swap alone is not evidence that active paging caused the observed behavior. No applications were stopped to alter the host load.

**1. P1 — Files can finish loading into a permanently blank editor. Observed and reproduced.**

On 0.4.101, opening README.md showed its 16 KB size and 421-line count, but no editor content. Opening go.mod reproduced it with 2 KB and 56 lines. This is a presentation failure, not an unfinished download.

`FilesView` calls `editorSession.prepare` when the document revision changes. `prepare` records the document key even if no text view is attached. The new editor then calls `attach`, which returns early when that key already matches, leaving the new `NSTextView` empty. A synthetic reproduction supplied 17 characters, reported two lines, and left the editor with **zero characters**. Recreating the editor through its document/revision identity makes this lifecycle significant.

Fix the ownership of the initial text buffer: a newly attached text view must receive the current document even when the session's key is already prepared. Preserve unsaved content when the native view is recreated, and verify opening A → B → A, revision changes, saves, and leaving/re-entering Files. Do not try to mask this with a spinner.

Sources: [FileEditorSession.attach/prepare](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/FileEditorSession.swift:17), [Files document preparation](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/FilesView.swift:179), [editor creation](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/SyntaxHighlightedEditor.swift:168).

**2. P1 — Loading, failure, and no selection are not consistently represented. Source-confirmed, with live examples.**

| Surface | Current behavior | Required behavior |
|---|---|---|
| Files directory | Initial load/refresh has no visible pending state; the navigation boolean only covers some paths. | Immediate destination/path selection, labeled initial loading, small refresh indicator when content exists. |
| File preview | `openFile` clears the document; the UI says “Select a file” during the outstanding read. There is no selected-path loading state. | Keep the selected filename visible and show its cached document or “Loading filename…”. |
| Chats | Refreshes without an initial loading flag or refreshing indicator. | Distinguish first load, cached refresh, empty result, and error. |
| Archive | Fetches into a list without initial-load feedback. | Same load-state contract as Chats. |
| Conversation | The network loading flag clears before the detached timeline projection has populated its rows. | Keep preparation feedback until renderable rows are ready; preserve an existing same-conversation timeline during refresh. |
| Schedules | Has a spinner, but `!isLoaded` always resolves to loading, even when the request has failed and `isLoading` is false. | A persistent inline error/retry state after cold-load failure. |
| Machine information | Remote panel displayed an RPC error while its subtitle still said “Connecting…”. | Derive subtitle and body from one state; explain the failure and retry coherently. |
| Global reconnect | Uses a static circular-arrow icon and disables the workspace. | A consistent progress treatment while retaining safe local interaction. |

The local machine information panel did load normally; the remote machine error is not evidence that every telemetry request fails. Likewise, the observed empty Schedules and Terminals pages loaded successfully, but their failure/pending paths still require coverage.

Sources: [file reads](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/DieterStore+FilesAndSettings.swift:20), [file placeholder](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/FilesView.swift:173), [conversation preparation](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/ConversationView.swift:530), [schedule state](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/SchedulesView.swift:9), [machine subtitle](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/MachinesView.swift:261), [reconnect banner](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/DieterRootView.swift:197).

**3. P1 — Connection loss disables safe local navigation within the whole workspace. Source-confirmed.**

The root applies `.disabled(workspaceSurfaceTreatment.blocksInteraction)` around the complete selected destination. Both reconnecting and offline states block interaction. Cached chat buttons, searching, filtering, and other safe controls inherit that disabled state alongside mutations. That produces a frozen-feeling workspace even when rendering and the main run loop are healthy. This was directly visible on the old incompatible app; the same disabling rule remains in the verified 0.4.101 source. No connection failure was intentionally injected into the latest live service.

Keep navigation, search, cached transcript reading, and local disclosure responsive. Gate operations requiring a live daemon at their own controls, and label which machine is unavailable. Retain one stable banner without washing out and disabling the entire destination. Preserve existing outbox semantics and do not silently retry uncertain mutations.

Source: [workspace treatment and root disabling](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/DieterRootView.swift:5).

**4. P2 — Navigation has redundant fetch owners and unnecessary dependencies. Source-confirmed.**

Opening Chats calls `refreshChats`, and mounting `ChatsView` calls it again. Opening Schedules eventually calls `loadSchedules`, while the new view also starts it. Opening empty Terminals similarly has two load paths. Generations reject some stale replies, but they do not avoid the duplicate requests or cancel their transport work.

`openProject` selects its destination promptly, which is good. However, Files and Schedules still wait for connection preparation and a full `refreshState` before their navigation-owned data load. The mounted Schedules task can run earlier, against the old connection during a cross-machine switch. Changes already avoids the unrelated board/files dependency and provides a better pattern.

Give each destination one owned read task keyed by connection identity and target. A navigation action should select the destination synchronously; that destination should request only its data. Coalesce repeated refresh requests, cancel superseded reads, and retain cached data by target. The terminal loader also needs response ownership checks: currently it can assign results and clear `terminalLoading` after another load or target has taken over.

Sources: [navigation](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/DieterStore+Navigation.swift:50), [Chats mount](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/ChatsView.swift:159), [Schedules mount](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/SchedulesView.swift:108), [Terminals mount](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/TerminalsView.swift:96), [terminal loader](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/DieterStore+Navigation.swift:290).

**5. P2 — Several user-visible reads have no explicit client deadline. Source-confirmed.**

State, Chats, and initial configuration reads use a 15-second bounded unary option. Conversation reads use attachment size options without a timeout. Files, terminal listing, schedules, and prompt-settings reads use default options without a timeout set here. Watch streams appropriately have different lifetime semantics, but unary view loads should not depend solely on eventual transport failure.

Add explicit deadlines to view reads, an owned cancellation path, and an inline retry state. A timeout must stop the read and its loading feedback without stopping an agent or daemon-owned execution. Preserve the existing larger message-size allowance for conversations.

Sources: [RPC options](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Networking/DieterRPC.swift:30), [conversation read](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Networking/DieterRPC.swift:388), [file and terminal reads](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Networking/DieterRPC.swift:525), [schedule reads](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Networking/DieterRPC.swift:634).

**6. P2 — Cached conversation lookup can decode a whole machine snapshot on the main actor. Measured in debug.**

`projectedConversation` uses an already-decoded active snapshot, but decodes the entire serialized snapshot for an inactive endpoint before finding one card. Startup restoration and endpoint activation also perform protobuf decoding in main-actor store methods. The disk read being asynchronous does not move the subsequent decoding off the main actor.

The cache probes above demonstrate scaling from roughly 111 ms to 1.07 seconds in debug. These numbers are not claimed for the optimized Homebrew binary, and this path was not a dominant stack in the sampled release switches. Nevertheless, it is avoidable work directly before useful content can appear.

Decode and index snapshots away from the main actor, retain bounded per-endpoint/per-conversation caches, and publish only the selected result. Check request generation after the worker returns. Start view feedback before any uncached preparation.

Sources: [inactive lookup](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/DieterStore+Sync.swift:293), [startup and activation](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/DieterStore+Sync.swift:11).

**7. P2 — The timeline bounds messages, but not the amount of layout inside them. Measured synthetic risk.**

The timeline deliberately uses an eager `VStack` to avoid a documented macOS lazy-stack/text-selection layout cycle. Replacing it blindly with `LazyVStack` would disregard an existing correctness constraint. Its 180-message window still permits many paragraphs, code blocks, table cells, expanded tools, and plan rows. One very large message can be expensive on its own.

The background timeline projection groups messages, but Markdown block parsing and attributed-string cache misses still occur from view construction on the main actor. Streaming changes create new source-string cache keys. The table's `columnWidths` accessor scans all columns and rows, and each cell accesses that computed property again. At R rows and C columns, that width calculation can repeat on the order of R²C² cell visits per body/layout construction, before text layout costs.

Precompute Markdown blocks, inline formatting, and table widths as stable presentation data. Bound rendering by block/cell/text complexity as well as message count. Keep offscreen-heavy content folded or paged; investigate an AppKit-backed virtualized transcript only with the existing selection/scroll regressions covered. Preserve render projections across warm revisits. Use cooperative cancellation or one latest-pending worker so superseded detached projections do not continue competing for CPU.

Sources: [eager timeline](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/ConversationView.swift:376), [window bound](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/ConversationPresentation.swift:128), [Markdown cache](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/ConversationRenderCache.swift:29), [repeated table widths](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/ConversationMarkdownView.swift:60).

**8. P2 — The displayed chat directory is not stable across refresh sources. Observed; precise live accounting remains to be verified.**

The All chats badge repeatedly moved between **30 and 54** during the latest-release journey. The Chats title also displayed both totals without a user archive/filter change. Settings exposed many old failed queued creations for missing projects. No such entries were retried or discarded.

There is a concrete source inconsistency to test: `rebuildOutboxOverlays` inserts failed/pending local chats, including ones whose projects no longer exist. `MachineDirectoryReducer.merging` drops chats whose project is absent from its retained/refreshed directory, and `refreshMachineDirectory` does not rebuild those overlays afterward. State/chat refresh paths do rebuild them. This can alternately remove and restore local entries. It is a plausible explanation for the observed count difference, but the exact 24-entry correspondence was not established by reading private central storage.

Maintain an authoritative machine directory and a separate, stable local-outbox projection, with one deterministic composition policy. Missing-project failures should stay reachable in a clearly labeled recovery surface and should not make the global count oscillate. Verify the counts and visible IDs through alternating sync, unary refresh, and inactive-machine refreshes.

Sources: [outbox overlays](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/DieterStore+Sync.swift:363), [directory reducer](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/DieterStoreSupport.swift:154), [directory refresh](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/DieterStore+Connection.swift:669).

**9. P2 — Main-actor projection work scales with whole collections. Measured, but lower priority at this live dataset size.**

Workspace-changing sync deltas run the global reducer and full snapshot application on the main actor. That rebuilds dictionaries, sorts chats, reconciles optimistic values, updates selected state, and checks Island activity. `refreshChats` mutates `chats` several times, triggering its observer repeatedly. Chats also computes its list projection in `body`; search changes recompute it synchronously.

The small fixtures were inexpensive, while 10,000-chat updates exceeded a frame by a wide margin. Address this incrementally: compute once per relevant revision, batch publication, preserve equality guards, and move large pure transformations to a worker. Observation is property-aware; the mere existence of one `@Observable` store does not prove every view redraws on every property change. Profile actual dependencies before proposing a wholesale store rewrite.

Sources: [sync application](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/DieterStore+Sync.swift:132), [snapshot application](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/DieterStore+Sync.swift:188), [chat refresh](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/DieterStore+Conversation.swift:11).

**What should remain**

The current code already has useful performance foundations: cached board selection before the RPC, indexed/paged board rendering, detached conversation and diff projections, incremental editor line counting and background highlighting, attachment processing on an actor, terminal frame coalescing, and debounced/coalesced persistence. Project Changes now has an owned model, guarded diff requests, cache reuse, separate errors, and reconciliation phases. Its live diff selection worked. The previous day's already-fixed Changes findings should not be reintroduced as current defects.

The inspected Screens landing page correctly surfaced missing capture permission; no stream was started. Terminal throughput, screen-video performance, active agent streaming, image-heavy conversations, and resize/scroll frame distributions were not exhaustively exercised in this live session. Attachment thumbnails and Files image previews still have synchronous image-construction paths worth profiling with large fixtures, but those are candidates, not measured causes here.

**Recommended implementation order and acceptance criteria**

1. Fix the blank editor and add a desired-behavior lifecycle regression. Unify initial loading, refresh, empty, offline, and error states. Correct the contradictory machine subtitle and the Schedules cold-error spinner.
2. Remove blanket interaction disabling. Give each destination one owned fetch path with target identity, cancellation, deadlines, and stable cached content. Resolve outbox/directory count churn.
3. Move cached snapshot decoding and Markdown preparation off the main actor. Precompute table widths; bound transcript rendering complexity and preserve useful presentation state on revisits.
4. Optimize larger directory updates only after traces identify the dominant cost. Retain working caches and equality checks.

Use the same feedback policy throughout: selection/highlight responds immediately; cached content remains visible during a same-target refresh; cold loads have a named loading state; failures replace loading with a persistent retry state. A small spinner may be delayed approximately 100–150 ms to avoid flashing for very fast reads. Once shown, it must keep advancing and must not end before renderable content is ready. Avoid artificial delays in navigation or large animated reflows. Respect Reduce Motion while retaining clear activity feedback.

Proposed release gates: p95 input-to-selection/feedback below 50 ms; cached navigation independent of network latency; no wrong-target publication under forced A → B → A reply ordering; no duplicate read from a single navigation; one active refresh plus at most one pending refresh per target; cold-load failures always reach retry; zero blank nonempty text documents. Track main-thread stalls over 50 ms and target UI work comfortably within the 16.7 ms / 8.3 ms frame intervals of 60 / 120 Hz displays.

Record click, selection committed, request started, response received, presentation ready, and first visible content with correlated signposts. Existing projection signposts and correctness tests do not measure that chain. Use release Instruments traces and a lightweight responsiveness probe; run accessibility coverage separately because full tree extraction materially affected the first profile. Test local/direct/relay routes with deterministic 50/250/1,000 ms delays and reordered responses in disposable fixtures, plus large Markdown tables, long messages, many projects/cards, and terminal output bursts. Do not impose fault injection on the operator's daemon.

**Verification and evidence**

Three existing targeted tests passed: board projection indexing, the 1,000-frame message-only sync replay, and conversation render-window bounds. The synthetic performance probe passed, and the separate editor probe reproduced the defect. The latter deliberately asserted the observed empty buffer as diagnostic evidence; it was not added as a permanent regression that would bless broken behavior. Temporary diagnostic source was removed from the test target and retained with its logs below. No product source was changed by this assessment.

The canonical `dieter-tests` cache was reused. The first targeted build took 21.57 seconds; the three tests took 2.13 seconds. No build cache was deleted. The Homebrew app was profiled as installed; it was not replaced by a local debug build. Full native smoke suites and repository-wide checks were not rerun for this assessment-only change; the earlier validation report is historical evidence, not a claim of fresh coverage.

- [Synthetic probe source](/tmp/dieter-mac-responsiveness-20260908/ResponsivenessAssessmentDiagnostic.swift)
- [Synthetic timings and test log](/tmp/dieter-mac-responsiveness-20260908/diagnostic-test.log)
- [Blank-editor reproduction](/tmp/dieter-mac-responsiveness-20260908/editor-reproduction.log)
- [Latest-release navigation sample, including accessibility overhead](/tmp/dieter-mac-responsiveness-20260908/latest-navigation.sample.txt)
- [Latest-release sample without accessibility-tree polling](/tmp/dieter-mac-responsiveness-20260908/latest-conversation-no-ax.sample.txt)
- [Host paging check](/tmp/dieter-mac-responsiveness-20260908/host-memory.json)
- [Prior Changes implementation/validation](/Users/dbpprt/Development/dieter/docs/mac-app-changes-validation-2026-09-07.md)

Native screenshots and accessibility observations are recorded in the task's tool history. They demonstrate the loaded blank editors, contradictory machine error state, working project diff, and successive chat totals. These screenshots were inspected; tool-call elapsed times were not treated as UI performance results.

Final lifecycle verification: the inspected 0.4.101 client was quit normally; zero `DieterMac` processes remained. Daemon PID 59650 was still running with its original 7 September 13:43:54 start time. The updated app remains installed. Existing user source changes were preserved; this assessment adds only this report to the repository.
