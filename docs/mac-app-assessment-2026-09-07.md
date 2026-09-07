# Mac app performance and Changes assessment

Assessment of checkout `e9da649f`, 7 September 2026. App implementation is unchanged. This document records the assessment requested before implementation.

The strongest explanation for the app feeling slow is inconsistent ownership of asynchronous state, compounded by repeated Git work. Changes also has visible layout and interaction defects. Improving animation alone would leave the underlying problems intact.

## Evidence and confidence

I inspected project and worktree Changes, navigation, Files, global synchronization, connection switching, conversation rendering, board projections, terminal buffering, persistence, Git reads, and the native smoke drivers. I built the canonical debug app and ran all eight existing native smoke suites locally, plus the Mac unit suite. All test gates passed. Screenshots nevertheless exposed defects that the assertions do not cover.

Findings below distinguish **observed** behavior, **measured** service costs, **source-confirmed** implementation flaws, and **profiling candidates**. The asynchronous races are demonstrable from the response-acceptance logic, but were not reproduced with an injected delayed transport in this assessment. That is an explicit implementation acceptance requirement.

The local test used Swift 6.3.2 and the existing `dieter-local` build cache and separate `dieter-tests` cache. The initial app build was incremental, 9.32 seconds; 205 Mac tests passed in 6.59 seconds after a 15.15-second test build. Generated Swift clients passed `just mac proto-check`.

All daemon/gateway activity used disposable fixtures, random loopback ports, isolated preferences, and test credentials. Git commits, staging, discard, card creation, and fixture messages occurred only in these isolated tests. The operator's daemon was untouched.

## 1. Performance and synchronization findings

### P1 — Project Changes can show the wrong diff beneath the selected filename

**Source-confirmed.** Selecting a row changes `selectedPath` and `selectedSection` immediately, but leaves the previous `diff` visible. The eventual response is assigned without checking project, endpoint, revision, selection, cancellation, or request generation. Click A then B: if A finishes last, A's content appears beneath B's header. Switching the project creates another version of the same problem because the view's state survives while the project ID changes.

Worktree review checks the selected card/path/commit on success, but also leaves the previous diff visible during loading. It does not check revision or request generation, so A → B → A and overlapping same-file refreshes are still unsafe. Its error path is less guarded than its success path.

Fix: make selection synchronous and give each request an immutable target and generation. Accept results only for the current endpoint/connection, target, section, path, revision, and generation. A different selection must show its own cached result or a correctly labeled loading state. A same-selection background refresh may preserve the current content with a small updating indicator.

Sources: [project diff loading](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/ProjectChangesView.swift:272), [worktree diff loading](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/DieterStore+Workspace.swift:62).

### P1 — Git actions have an acknowledgment gap and an early-unlock gap

**Source-confirmed.** Project actions are disabled only after `startGitOperation` returns an active operation. Before that reply, repeated clicks can submit multiple requests. After a terminal reply, controls become available before the new changeset has finished loading, allowing another action against an obsolete revision. `loadChanges` reads an existing active operation only after loading the selected diff, further delaying accurate action availability.

The worktree `startGitOperation` similarly has no admission-in-flight guard. Server serialization and revision checks offer protection, but the UI still produces avoidable failures and uncertain feedback.

Fix: introduce explicit submitting, running, and reconciling phases. Lock the affected mutation controls before the first suspension and keep them locked until an authoritative post-operation snapshot is accepted. File browsing remains usable. Show the affected path and action immediately, preserve selection across staging, and report success only after reconciliation. Never infer success merely from a click or retry an uncertain mutation automatically.

Sources: [project operation flow](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/ProjectChangesView.swift:292), [worktree operation submission](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/DieterStore+Workspace.swift:158).

### P1 — Changes errors can be invisible or erased

**Source-confirmed.** The project error state is rendered only when there is no changeset. Most errors occur after one is loaded. Submission failures call `loadChanges`, which immediately clears the error. Operation completion does the same. A failed operation banner catches some failures, but not stale diff errors, admission errors, or interrupted monitoring. A commit sheet dismisses before the outcome is known, making this especially confusing.

Fix: separate initial-load, background-refresh, selected-diff, and operation errors. Keep actionable errors visible beside the relevant content. Preserve commit text on failure; clear it only after success. A rejected revision refreshes once and asks for a fresh action against the new state.

Source: [project state and error rendering](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/ProjectChangesView.swift:29).

### P1 — Refreshes are overlapping, expensive, and incomplete

**Source-confirmed.** Project Changes loads on project selection and explicit refresh, but has no external-file freshness loop, app-activation refresh, or transition handling when an agent finishes. A project marked volatile can remain disabled until manual refresh. Its button-created tasks have no view-owned cancellation handle; operation monitors can outlive the original surface.

Worktree review polls every five seconds only while the runtime or Git operation is active. A short agent turn that starts and finishes between polls can leave the last edits undiscovered. Every full refresh reloads workspace, changeset, SCM capabilities, comments, and the selected diff, even if the revision is unchanged. Overlapping refreshes are not coalesced, and the guard after the initial RPC tuple is not repeated after fetching comments.

The worktree stale-diff handler recursively calls `loadWorkspaceSurface`, which loads a diff again. A continuously changing workspace can keep that chain going without a retry bound. Multiple Load More clicks can request the same offset and append duplicate content.

Fix: one refresh owner per target, with requests coalesced into at most one follow-up refresh. Refresh on activation, reconnection, target changes, relevant runtime transitions, and completed operations. Use bounded visible-surface polling as a fallback for external Git edits. Fetch a new diff only when selection or revision changes. Refresh SCM capabilities independently and less often. Use one bounded stale-revision retry and one paging request per offset. Cancel observation when leaving a target without canceling the daemon-owned operation.

Sources: [worktree refresh chain](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/DieterStore+Workspace.swift:11), [five-second polling](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/WorkspaceChangesView.swift:131), [project polling](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/ProjectChangesView.swift:313).

### P1 — File selection performs a full repository read repeatedly

**Measured and source-confirmed.** A disposable diagnostic used the real changeset service and Git runner, with a counting wrapper. Five warm samples were taken for each case; setup and the preparatory revision lookup were excluded from each timed request.

| Fixture | Service request | Git processes per request | Median | Min–max |
|---|---|---:|---:|---:|
| One untracked text file | Changeset | 15 | 102.2 ms | 98.8–116.8 ms |
| One untracked text file | Selected file diff | 26 | 185.3 ms | 175.6–204.8 ms |
| 1,000 untracked text files | Changeset | 15 | 140.6 ms | 131.1–146.9 ms |
| 1,000 untracked text files | Selected file diff | 26 | 237.1 ms | 224.7–259.6 ms |

These are service times, excluding RPC transport and Mac rendering; five samples are not a release performance distribution. Other work was active on the host, so command counts are stronger evidence than small timing differences. Each untracked file contained 100 short lines.

`FileDiffTarget` calls `GetTarget`, then resolves the target again. Revision generation computes staged and unstaged binary patches and reads all untracked files. Changeset statistics read those untracked files again. Paging limits the returned patch to 1 MiB, but the entire patch is generated before slicing. Worktree target resolution repeats refresh work through both `Ensure` and `Refresh` as well.

Fix: remove duplicate target resolution first, then share one coherent repository snapshot across changeset construction and diff validation. Keep strict revision checks for mutations and define explicit invalidation before introducing any cache. Stream/hash large untracked content with bounded memory. Avoid regenerating the complete patch for every page. Verify external edits, index changes, renames, conflicts, and concurrent agents before changing revision semantics.

Sources: [changeset construction](/Users/dbpprt/Development/dieter/internal/changeset/service.go:48), [diff request](/Users/dbpprt/Development/dieter/internal/changeset/service.go:371), [revision computation](/Users/dbpprt/Development/dieter/internal/workspace/manager.go:249). [Diagnostic output](/tmp/dieter-mac-assessment-cost.log), [temporary test](/tmp/dieter-assessment-cost_test.go), [Go overlay](/tmp/dieter-assessment-overlay.json).

### P1 — Navigation and general file reads can accept obsolete responses

**Source-confirmed.** `openProjectChanges` calls `openProject(.files)`, waits for project-state refresh and directory listing, then switches a string-valued Files mode. The requested screen therefore depends on unrelated work and can visibly pass through Files.

Project navigation waits for connection preparation before selecting its destination, unlike cached board navigation. `refreshState` accepts a response without checking the initiating project or RPC identity. `loadFiles`, `openFile`, and `refreshChats` also lack complete response ownership checks. A slower earlier selection can overwrite later content or attribute a reply to the newly selected endpoint. Schedules already use request generations and endpoint/project guards, providing a useful pattern to extend.

Fix: introduce a real Changes route and select destinations immediately from the cached directory. Separate navigation from fetching. Apply generation and endpoint checks across project navigation, state refresh, directory listings, file opens, and chat refreshes. Prefer scoped updates from mutation responses and WatchSync over repeated full `refreshState` calls. Preserve each surface's selection and scroll state by target.

Sources: [navigation](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/DieterStore+Navigation.swift:50), [state refresh](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/DieterStore+Sync.swift:749), [Files reads and guarded Schedules implementation](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/DieterStore+FilesAndSettings.swift:12), [chat refresh](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/Model/DieterStore+Conversation.swift:11).

### P2 — Rendering and broad invalidation need targeted work

**Source-confirmed cost paths; runtime impact partly unmeasured.** Project Changes parses the entire patch inside SwiftUI's body. Any relevant state update can repeat parsing on the main thread. Worktree review already builds a diff projection off the main thread; that should become shared infrastructure.

Sidebar board badges flatten and filter the entire card directory for each board. Several project and machine accessors sort their collections on read. `acceptState` assigns broad observable state and triggers board/Island projection work even when an unchanged response would suffice. These are profiling candidates at realistic directory sizes, rather than evidence that every view requires rewriting.

Existing optimizations worth retaining: bounded board pages, background conversation timeline projection, cached Markdown, incremental/background editor highlighting, terminal frame coalescing, unchanged-projection guards, and asynchronous coalesced sync persistence. The 1,000-frame replay test already checks that message-only updates do not recompute Island output or force a persistence write per frame.

A brief sample during the isolated conversation suite found 1.4% CPU at the sampled instant, 93.2 MiB physical footprint (138.2 MiB peak), and a predominantly waiting main thread. It does not establish active scrolling performance or rule out intermittent hitches; it gives no evidence of a constant main-thread spin. [Sample](/tmp/dieter-mac-assessment.sample.txt).

Sources: [project parsing](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/ProjectChangesView.swift:204), [background worktree rendering](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/WorkspaceChangesView.swift:846), [sidebar badge scans](/Users/dbpprt/Development/dieter/apps/mac/Sources/DieterMac/UI/DieterRootView.swift:909), [existing performance tests](/Users/dbpprt/Development/dieter/apps/mac/Tests/DieterMacTests/PerformanceProjectionTests.swift:82).

## 2. Changes design and flow assessment

### Observed defects

The project page has two stacked navigation/title bars, tiny metadata, a disproportionately wide file list, raw Git headers competing with code, and no line-number gutters. In the captured short diff, content is centered vertically and horizontally in the large editor region. There is no proper distinction between loading, empty, stale, or failed diff states. The clean checkout says “Select a change” despite there being nothing to select.

[Current project Changes screenshot](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/workspace-20260907-140024-d1a6cef9-0f83-40d5-a841-7846f4053be8/08-project-changes.png). [Clean checkout screenshot](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/workspace-20260907-140024-d1a6cef9-0f83-40d5-a841-7846f4053be8/09-project-changes-clean.png).

The worktree surface looks more developed, but compact mode adds another Changes/Diff switch below the conversation tabs and Inline/Split controls. File clicks do open the compact diff pane, but the smoke runner selects a file through the store, bypassing that UI action. Its “inline” and “split” screenshots therefore capture the file navigator rather than either diff. A window resize can also hide the diff behind the remembered compact pane.

[Worktree screenshot mislabeled as inline coverage](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/workspace-20260907-140024-d1a6cef9-0f83-40d5-a841-7846f4053be8/01-changes-inline.png).

### Additional flow gaps

| Problem | Required behavior |
|---|---|
| Project Changes is a Files submode | A dedicated Changes item in each project's subnavigation, alongside its board, Files, and Schedules. |
| Project diff stops at 1 MiB without exposing truncation or pagination | Explain partial content and provide guarded Load More or an explicit large-file state. |
| Project file rows are buttons without list-selection keyboard semantics | Arrow-key navigation, visible focus, full path on demand, clear status, accessible action names. |
| Stage/Unstage and trash compete in every row | Make staging the primary row action; put discard in a context menu or secondary action with a precise confirmation. |
| Selection may jump to an unrelated first staged file after mutation | Follow the affected file to its new section, or choose its nearest neighbor if it disappears. Preserve scrolling. |
| Commit sheet closes before failure is known | Show submission progress, preserve the draft on failure, make staged file count and branch explicit. |
| Clean state still asks for selection | One clear “Working tree is clean” state with project and branch context. |
| Worktree Commits panel reads an always-empty collection from the local-only changeset service | Remove the misleading “No commits ahead” claim or source real history separately. Local-only changes must remain distinct from branch history. |
| Worktree and project implementations diverge | Share diff rendering, selection/loading primitives, file rows, and feedback components; retain their different target semantics. |

The commit-history mismatch is source-confirmed: `GetTarget` no longer populates commits, while the UI still derives its “No commits ahead” statement from that empty list. Restoring a separate history operation would require the repository's proto/core/Connect/CLI/help/native parity work; it should not be silently added to the local changeset contract.

### Proposed layout

Confirmed placement: Changes belongs in each project's existing subnavigation. A project with one board has four items: its board, Files, Changes, and Schedules. The project is determined by the clicked navigation item, so a separate project selector is unnecessary. Contextual “Open Project Changes” links use the same project-scoped route. Files becomes a pure file browser.

```text
Project subnavigation Changes toolbar
Project name          Project name · branch          +24 −8   Refresh
  Board               ─────────────────────────────────────────────
  Files               Files  [Filter…]       Selected file       Inline / Split
  Changes             Unstaged (4)            old  new  code
  Schedules           Staged (2)              line gutters + change backgrounds
                      ──────────────         ──────────────────────
                      Commit staged…         contextual progress / error
```

Use a resizable file list around 260–320 points wide, a top-left-aligned diff, filename first and directory second, readable code typography, subtle semantic backgrounds, old/new line numbers, useful hunk headers, text selection, and horizontal scrolling for long lines. Keep raw Git metadata secondary. Preserve theme support and communicate status using text/icons as well as color.

At narrow widths, selecting a file should open a detail pane with a clear Back to files action. Keep the current file visible when crossing the breakpoint. Consolidate review controls so that nested tab bars do not consume the top of the window. Render background progress in a stable location; refreshing must not push the content down or rebuild the split view.

## 3. Implementation order

1. **Introduce the Changes route and a testable target-owned model.** Typed target/selection identities, request generations, cancellable reads, bounded caches, separate loading/error phases, and an injectable RPC protocol following the Schedules pattern. Remove the Files detour.
2. **Repair operation and refresh ownership.** Immediate pending feedback, one operation admission per target, authoritative reconciliation, selection continuity, bounded retries, scoped errors, and activation/runtime completion refresh. Apply the same ownership checks to general navigation and Files.
3. **Unify and redesign the review surface.** Share the existing background diff projection, add project pagination and keyboard flows, rebuild clean/error/binary states, and correct compact navigation and the empty commit-history claim.
4. **Reduce daemon read cost.** First eliminate duplicate scans; then add bounded snapshot/diff reuse with explicit invalidation and concurrency tests. Measure command count, allocation, and end-to-end latency again.
5. **Profile broader rendering under load.** Precompute sidebar counts and stable directory order where traces justify it. Preserve the optimized conversation, editor, terminal, and persistence paths. Finish with release profiling and actual native interactions.

Client routing and presentation work can use the existing APIs. Any new freshness/history RPC must include authoritative proto, explicit core implementation, thin Connect adapter, CLI/help/docs/skill parity, regeneration, and local/direct-TLS/relay coverage. No web UI is involved.

## 4. Local acceptance plan

| Journey or stress case | Required assertions |
|---|---|
| Open Changes from each project's subnavigation and a conversation link | Correct project-scoped item is selected immediately; no intervening Files screen or directory-list request. |
| Click A/B/A rapidly; delay replies in reverse order | Highlight, header, content, error, and revision always belong to the latest selection. Repeat across projects and machines. |
| Stage one file, stage all, unstage, partially stage a file | Immediate pending feedback; exactly one submission; controls stay locked through reconciliation; file follows its section; correct counts. |
| Commit staged files while other edits remain | Subject/body preserved on failure; only staged content is committed; resulting file list and diff update without reopening the page. |
| Discard tracked/untracked/partially staged changes | Correct filename and scope in confirmation, recovery artifact present, final Git state and visible state agree. |
| Change files externally or finish an agent turn between polling ticks | Relevant view converges without manual refresh; no stale volatile lock; unchanged revision avoids another diff request. |
| Leave during load or operation; reconnect and return | Old responses cannot affect the new target; operation continues in the daemon; status resumes correctly without a second admission. |
| Empty, binary, renamed, conflicted, long-path, long-line, and >1 MiB patches | Correct state, no clipped actions, explicit truncation, no duplicate pages, readable inline/split rendering. |
| Narrow/wide windows, light/dark themes, keyboard-only use | Selected content remains reachable; focus and scroll survive; accessible names and line/status context are usable. |
| Large board, long streaming conversation, rapid file selections | No repeated whole-directory work per row; no unrelated view resets; frame and allocation traces captured. |

Proposed measurable targets: selection and pending feedback within 50 ms p95, zero stale-response commits under forced reordering, zero duplicate submissions from repeated clicks, zero identical-revision diff requests from background refresh, and at most one active refresh plus one coalesced follow-up per target. Establish release p50/p95 click-to-correct-diff and operation-to-reconciled-view measurements on standard small and 1,000-file fixtures; use those traces to set the final rendering/latency budgets. Do not treat the service-only medians above as UI measurements.

Drive the native controls for these tests and observe the UI after each action. Verify Git through the isolated daemon/CLI independently. A test must assert the selected path, rendered patch, enabled/disabled controls, and eventual state; dispatching a click, changing store state, or calling an RPC alone is insufficient. Replace fixed sleeps with state-based waits, retaining screenshots on failure. Use deterministic delayed-response unit tests for the races and packaged-app journeys for the full integration.

## 5. Baseline test record and remaining limits

All eight suites completed successfully: core, board, conversation, machine, sidebar, terminal, island, workspace. Reports and relevant screenshots were inspected. Sidebar verifies restored order/expansion/width; conversation verifies detached scrolling and return to live tail; terminal verifies durable session rendering after a client restart. The conversation report explicitly skips its history-bound check for the synthetic fresh-state renderer fixture. Board sort dispatch is not an automated assertion of sort correctness; the inspected screenshot shows the Todo cards in ascending fixture order and a bounded 40-of-65 page.

The workspace suite verifies real merge/conflict and project staging/commit/discard behavior, but project operations bypass the buttons and the clean-state screenshot is forced by recreating the Files submode. Its inline/split screenshots do not establish diff-rendering coverage. Therefore the passing baseline does not demonstrate that the reported UI synchronization problem is fixed.

Evidence roots:

- [Workspace](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/workspace-20260907-140024-d1a6cef9-0f83-40d5-a841-7846f4053be8/report.json)
- [Core](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/core-20260907-140211-15ee81d8-a04d-4ce9-a3e4-670ca3930252/report.json)
- [Board](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/board-20260907-140601-77db170d-02d4-4641-bf9a-f69b4dfa932e/report.json)
- [Conversation](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/conversation-20260907-140425-fb42d240-8524-4ec1-8f71-6d9f2f12fbc4/report.json)
- [Machine](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/machine-20260907-140626-27e4d1d5-3afd-4a3e-9db4-5e1dec5040a3/report.json)
- [Sidebar](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/sidebar-20260907-140401-5654ffc6-fe74-4845-8b4c-43d77ba22685/verify/report.json)
- [Terminal](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/terminal-20260907-140511-82640b4e-df3a-4bee-aae0-8a698b042bfb/report.json)
- [Island](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/island-20260907-140643-fa060e86-1cfa-4d30-bfb1-80f223a76520/report.json)
- [Mac unit test log](/tmp/dieter-mac-assessment-tests.log)

The bundle assessed was `/Users/dbpprt/Development/dieter/apps/mac/build/Dieter.app`, debug configuration. Final process inventory confirmed zero running `DieterMac` processes. No production feature changes or new permanent tests were made during assessment; the cost diagnostic used a temporary Go overlay. Full release Instruments traces, adversarial transport tests, large binary allocation tests, and the corrected button-driven Changes journeys remain implementation validation work.
