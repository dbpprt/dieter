# Mac Changes implementation and validation

7 September 2026. Implements the project-navigation, Changes, and asynchronous-state work identified in [the assessment](mac-app-assessment-2026-09-07.md).

## Delivered behavior

Changes is a dedicated destination inside each project's navigation: board(s), Files, Changes, Schedules. It selects the destination immediately from cached project information. Opening Changes no longer opens Files, lists a directory, or waits for a board-state request. Files is a file browser again.

The Changes page follows the supplied design reference: its title and inline commit composer sit above a compact, resizable file navigator, with staged files first, checkbox staging, inline directory labels, status badges, filtering, and arrow-key selection. The diff has a separate toolbar, coral stage/commit actions, green additions, red deletions, hunk counts and staging badges, context folding, and guarded pagination. Inline and split layouts use explicit appearance-aware controls. Split columns share horizontal code scrolling while keeping equal widths, gutters, and hunk headers in place. The narrow layout preserves the selected diff and offers Back to files. Loading, binary, error, clean, and reconciling states have distinct presentations. Discard identifies the file and explains the recovery copy. Failed commits retain their subject and description.

Project Changes now has one owned model for its current target. Requests capture their connection, project, selection, revision, and generation; obsolete responses cannot replace newer content. Different-file selection clears the old diff immediately. A bounded cache makes revisiting files inexpensive. Background refreshes coalesce, avoid reloading identical-revision diffs, and discover external changes while the surface is active. Leaving cancels client observation while daemon-owned Git operations continue.

Git actions become pending before their first suspension and remain disabled until the post-operation snapshot is accepted. Failed reconciliation remains visible and blocks further mutations. The client never retries an uncertain mutation automatically. File browsing remains available while actions run. Worktree Changes also gains owned/coalesced reads, bounded stale retries, protected pagination, guarded operation submission/reconciliation, and idle freshness polling. The misleading empty commit-history panel is hidden.

Directory listings, file reads/saves, state refreshes, and chat refreshes reject replies belonging to an obsolete request or target. File-scope resets invalidate in-flight reads and navigation history updates. Sidebar board counts scan their own project's cards, and unchanged state assignments are avoided.

## Backend performance and the index-lock race

Diff generation now resolves the workspace once and reuses it for revision validation and changeset construction. Worktree reads no longer refresh twice through Ensure plus Refresh. Untracked-file hashing and line counting stream their input instead of allocating the whole file.

The native stage/unstage journey reproduced an intermittent `index.lock` failure. Background `git status` and `git diff` could refresh the on-disk index while an explicit stage action was starting. Dieter's Git runner now uses `GIT_OPTIONAL_LOCKS=0` and `diff.autoRefreshIndex=false`. Required locks for actual mutations remain enabled. A regression test changes tracked-file timestamps, proves both background reads leave index bytes unchanged, and then verifies a real stage operation writes the edited content.

The same disposable service diagnostic used in the assessment was rerun with five warm samples per case:

| Fixture | Request | Git processes before → after | Median before → after |
|---|---|---:|---:|
| One untracked text file | File diff | 26 → 16 | 185.3 → 122.5 ms |
| 1,000 untracked text files | File diff | 26 → 16 | 237.1 → 155.9 ms |
| One untracked text file | Changeset | 15 → 15 | 102.2 → 113.0 ms |
| 1,000 untracked text files | Changeset | 15 → 15 | 140.6 → 157.6 ms |

This removes 38% of Git process launches per file diff; the final small-sample medians were about 34% lower. Host activity varied, and the unchanged changeset workload was slower in the final run. These are service timings, not UI frame-rate or release p95 measurements. Earlier intermediate runs measured 111.8/139.7 ms for the two diff fixtures. Sources: `/tmp/dieter-mac-assessment-cost.log`, `/tmp/dieter-changes-cost.log`, `/tmp/dieter-changes-cost-final.log`.

## Verification

- `just harness install` and `just check`: passed, including Go race tests, vet, generated-contract checks, builds, and 43 harness tests.
- `just android test`: passed.
- `just mac test`: the 215-test suite passed; live-daemon integration cases retain their normal skip behavior.
- `just mac proto-check`: passed.
- All eight native suites passed across the final successful runs listed below. The final Changes run completed with an empty stderr log and no AppKit reentrancy warnings.
- `git diff --check`: passed. Final inventory: zero running `DieterMac` processes.

New deterministic Mac tests force A → B → A replies out of order, switch target/client before an old reply arrives, verify unchanged-revision reuse, hold admission and reconciliation separately, reject duplicate submissions, retain failed commit drafts/errors, block actions after a failed reconciliation, and prevent duplicate diff-page appends. A parser test ensures a patch's final newline does not create a fictitious numbered line while real blank context/addition lines remain present.

The native workspace journey uses actual mouse/key events on visible controls and native scroll-wheel events on the diff scroll view. It verifies all four project destinations, file and keyboard selection, inline/split content, bulk and individual stage/unstage, selection following the staged file, typing a commit subject, staged-only commit, confirmed discard, the clean page, external edits, and narrow-window retention. Git state is checked separately against the isolated daemon and repository. The existing worktree merge/conflict flow remains covered.

The smoke driver gained geometry-only debug anchors where SwiftUI does not expose stable in-process accessibility elements. These anchors have no action hooks, are absent from release behavior, and are enabled only in isolated smoke runs. The driver resolves a control's actual window, queues native input, and asserts the resulting state. Native alerts use their real accessibility labels. Screenshots remain necessary visual evidence; a dispatched click alone is not success.

## Scope and evidence limits

Validation uses the canonical packaged debug app and the existing separate `dieter-local` / `dieter-tests` caches. It does not establish release Instruments frame-time or allocation budgets. The Git backend still generates a bounded complete patch before slicing pages; this change does not introduce a server patch cache or change diff-size contracts. Existing backend tests cover staged/unstaged separation, stale revisions, staged-only commit, and discard recovery artifacts.

All daemon/gateway/Git mutations occurred in disposable smoke fixtures. The operator's daemon was not stopped, restarted, replaced, or installed over. An OS inspection attempt opened `/Applications/Dieter.app` after the fixture app exited; that extra instance was immediately closed; no user-facing actions were taken in it.

## Mockup revision

The commit sheet was replaced with an always-visible composer. Draft subject and description survive diff-mode changes, file selection, staging reconciliation, and compact Back navigation. The header is now confined to the navigator; the diff toolbar starts at the same height. File rows are 32 points tall, stage checkboxes precede filenames, selected rows use a slim coral marker, and the bottom status bar includes the selected path. Background freshness polling no longer flashes a progress indicator on every read.

The richer native fixture contains a real Swift file with both index and working-tree edits, plus modified and deleted files. It verifies the staged patch separately from the working-tree patch, captures dark/light, inline/split and compact composer views, scrolls long lines with native wheel input, and checks the hunk header's screen position remains fixed. Parsing, line-width estimation, and hunk counts stay in the background projection; scroll updates do not reparse the patch.

Visual inspection exposed a Git status parser defect: `git diff --name-status -z` separates the status and paths with NUL, but the service expected a tab. Deleted/renamed/added files could therefore fall back to Modified. The parser now consumes the actual Git format; numstat parsing also preserves tabs inside paths. A real-repository regression verifies rename source, added/deleted statuses and line counts with tab/newline filenames. No RPC or CLI surface changed.

Final redesign verification: `just check`, `just mac test` (215 tests), targeted Go race tests for changesets/Git/workspaces, and the native workspace suite all passed. The workspace report includes the new mixed-staging, retained-draft, and pinned-header scroll assertions; stderr was empty. The other seven native-suite reports below are from the preceding implementation pass.

The reference's hunk-level staging, generated commit messages, and commit-history controls were not added: the existing changes API supports whole-file operations and intentionally returns local changes only. The implementation shows only functional controls.

## Final successful runs and visual evidence

- [Core report](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/core-20260907-152838-150f7cdf-b9a5-48cb-8d88-cc362584239e/report.json)
- [Board report](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/board-20260907-153020-7350e41c-7235-455e-89b0-48eee6475d66/report.json)
- [Conversation report](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/conversation-20260907-153332-6a88b6ff-96fb-40a8-9990-d9d04590da9f/report.json)
- [Machine report](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/machine-20260907-153455-cc63016c-1116-417c-b0ed-1f57d16ec196/report.json)
- [Sidebar report](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/sidebar-20260907-153503-20117155-d695-409b-8a2c-6e338921f616/verify/report.json)
- [Terminal report](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/terminal-20260907-153516-d96f561a-25cc-4af7-8356-47b78860e216/report.json)
- [Island report](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/island-20260907-153526-53517a49-e019-495c-abec-9f93420c9fe7/report.json)
- [Changes/workspace report](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/workspace-20260907-161441-4b7f56cf-233f-451f-8221-dc378aa2062e/report.json)

Every report was read and relevant screenshots were inspected. The board screenshot confirms ascending Todo fixture order and a bounded 40-of-65 page. The conversation renderer fixture retains its existing history-bound skip; its image-preview test reports its accessibility-action fallback. Neither qualification applies to the button-driven Changes journey.

- [Dark Changes](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/workspace-20260907-161441-4b7f56cf-233f-451f-8221-dc378aa2062e/11-design-dark-split.png)
- [Light Changes](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/workspace-20260907-161441-4b7f56cf-233f-451f-8221-dc378aa2062e/13-design-light.png)
- [Split diff](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/workspace-20260907-161441-4b7f56cf-233f-451f-8221-dc378aa2062e/11-design-dark-split.png)
- [Inline commit composer](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/workspace-20260907-161441-4b7f56cf-233f-451f-8221-dc378aa2062e/08c-project-commit-composer.png)
- [Horizontal scroll with pinned gutters](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/workspace-20260907-161441-4b7f56cf-233f-451f-8221-dc378aa2062e/11a-design-horizontal-scroll.png)
- [Compact composer](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/workspace-20260907-161441-4b7f56cf-233f-451f-8221-dc378aa2062e/15-design-compact-composer.png)
- [Clean checkout](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/workspace-20260907-161441-4b7f56cf-233f-451f-8221-dc378aa2062e/09-project-changes-clean.png)
- [Compact diff](/Users/dbpprt/Development/dieter/apps/mac/.build/smoke/workspace-20260907-161441-4b7f56cf-233f-451f-8221-dc378aa2062e/10-project-compact.png)

Tested bundle: `/Users/dbpprt/Development/dieter/apps/mac/build/Dieter.app` (debug). Build and test caches were reused; no cache was deleted. The installed application and running operator daemon were not replaced.
