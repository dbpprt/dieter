# Mac board flicker follow-up — 23 September 2026

Read-only checks at 10:39, 12:09 and 13:06 UTC confirmed the installed app on
`mbp-office` is **0.4.281 (build 281)**, with one process (PID 85219) running
`/Applications/Dieter.app/Contents/MacOS/DieterMac` since 09:05:55 local time.
It started after that bundle was installed, so the reported flicker occurred
with the previous performance fixes present. It does not contain PR #107 or
this follow-up. The diagnostic terminal was closed after inspection.

## Reproduced causes

1. **Full cards were replaced by partial replicas.** Only a conversation's
   execution owner supplies its full prompt, rendered summary, workspace,
   subagents and usage. Other machines intentionally omit those fields. The
   Mac directory reducer replaced the whole card on every observation. Owner
   and peer refreshes therefore repeatedly removed and restored card content,
   changing card heights and the positions of every card below them. A route
   switch triggered by opening a card used the same destructive replacement.
   Read-only inspection of `mbp-office` confirmed its replica cards omit those
   fields. The new directory and route-switch tests failed on the original code.
2. **Connecting could select the daemon's default board.** Initial `GetState`
   describes a daemon's default project. Accepting that response temporarily
   published its boards and replaced the selected board, even when the user was
   opening a card in another project. The subsequent global sync restored the
   selected project's board, rebuilding the lane views in between.
3. **Metadata updates invalidated stable geometry.** A token-usage update
   discarded measured heights for all changed cards, including offscreen cards.
   The native regression observed a previously measured 130-point row reset to
   the 140-point estimate and three unnecessary height transactions over three
   token-only updates.

## Changes

- Preserve owner-only card details when applying peer observations. Shared
  title, placement, lifecycle, label and conflict fields still follow the peer
  projection. Empty fields received from the actual owner remain authoritative.
  Apply this rule to directory refresh, sync, state reads and card mutations.
- Preserve source identity when restoring cached projections before machine
  discovery, so cached owner snapshots can supply and clear their own details.
- Publish the selected project's merged state when accepting another machine's
  initial state; retain the selected board and conversation.
- Keep measured row heights until actual content measurement changes them.
  Recycled cells still measure current content and width. Metadata-only updates
  no longer reset offscreen geometry.

The native replica regression alternates full owner and partial peer snapshots
while changing card selection. It checks card values, native cell identity,
row frames, rich-card reevaluations and height transactions.

## Relationship to PR #107

PR #107, “Refine macOS conversation and workspace layout,” merged as
`a4fc1a11` at 10:54:58 UTC during this investigation. It changes pane layout and
sizing, but leaves the card directory reducer, initial-state board selection
and native row-height reset paths unchanged. This follow-up is based on that
merge and retains its layout work.

The first integrated full test run also exposed a resize regression in #107:
at a 980-point window width, the conversation stayed 191.6 points wider than
its adaptive target. The native split now reapplies its target once when the
available window width changes. A saved divider width is clamped temporarily
and restored when the window widens; native hosting views remain attached.

The integrated native scroll regressions also reproduced unwanted tail-following
while the reader scrolls upward. Stack sampling showed `clipBoundsDidChange`
interpreting a native layout translation as downward input, discarding its held
reading position and rejoining the live tail. The controller now distinguishes
wheel direction from opposite layout movement. New pointer or keyboard input
clears the wheel direction so other navigation remains independent.

The packaged sweep also found the global Quick Task button drawn under the
native titlebar after moving to Files. Native hit testing reached
`NSToolbarPrimaryTitleContainerView`, and the popover never opened. The button
now uses a native primary-action toolbar item instead of a negatively offset
content overlay. The Board and Chats pane controls are unchanged.

The narrow-pane journey exposed one further selection bug: opening Review
programmatically retained the workspace rail's old horizontal scroll position,
leaving its selected Changes tab clipped. Fixed-tab selection now reveals that
tab at the leading edge. Returning to Conversation also reveals its tab.

## Validation

- Final full Swift package suite: **794 Swift Testing cases plus 5 XCTest cases
  passed**. This includes the owner/peer arrival-order, cached-owner restore,
  default-board selection, native row geometry, saved divider, and transcript
  scroll regressions.
- The native alternating-replica test preserves row frames and cell identity,
  with **zero rich-card body evaluations, row configurations, and height
  transactions** across six owner/peer updates and card-selection changes.
- The offscreen-height test preserves the measured row height and viewport
  anchor across three token-only updates, with **zero height transactions**.
- The three initially failing scroll regressions pass with the controller fix;
  downward wheel, momentum, phaseless wheel, content growth and viewport resize
  also pass. The temporary stack instrumentation was removed.
- Updated two stale #107 test expectations for its Browser settings destination
  and intentionally single-line conversation header.
- Integrated the subsequent non-overlapping upstream iOS keyboard/harness
  changes at `a3bfa875`. The final partial-project-catalog case and native board
  checks pass in a **12-test** focused run; all **6 iOS screen-input tests** pass.
- Shared iOS Simulator build-for-testing passes. Its 15 smoke-runner unit tests
  pass, but device UI checks are unavailable: `xcrun simctl list runtimes` is
  empty and the runner reports `An installed iOS Simulator runtime is required`.
  This prevents both the iPhone and iPad UI journeys on this host.
- Core packaged journeys pass. The 100-card board mounts 20 rows, preserves
  native lanes on return, and opens cards with zero full reloads, row
  configurations or height transactions. Card-body reevaluations are limited
  to 0–2 on selection. Idle board rendering counters are all zero (2.07–2.74%
  of one core over the earlier 10-second debug samples; final run 2.11%). These
  counters do not measure compositor presentation. The final Board suite passes
  all functional assertions, with an explicit external-Accessibility skip. Its
  three card opens load in 615.4–713.6 ms, with zero project reads.
- Aligned smoke expectations with #107 pane controls and the native one-point
  divider. Fixed the isolated permission fixture shrinking to its one-line
  sentinel before permission revocation restored the full form. Popover smoke
  lookup now prefers the requested window and active presentation; editor focus
  cannot reactivate an older form from another window. Current pane journeys
  use the native split divider, fixed Changes tab, explicit single/split modes
  and Conversation tab selection. The working-indicator check measures its
  full native geometry through a smoke anchor instead of an accessibility child.
  In the 460-point pane, opening another file scrolls the previous tab out of
  view. The tab journey now sends native horizontal wheel input to reveal it
  before clicking. A pre-click capture and the native clip-view bounds confirmed
  that the old test clicked an offscreen anchor, accidentally toggling Kanban.
  The dirty-editor, close-confirmation and save assertions remain intact.
- Integrated upstream titlebar quota cleanup at `9e44f018`; the remaining
  native toolbar click, layout and draft-restoration journeys pass. Core, Board,
  Machine, Sidebar (including app restart), Terminal, Island and Workspace
  suites pass. Workspace verification covers native Changes selection, file
  staging, commits, discard, external refresh and merge conflict resolution.
  The final Conversation suite also passes, including narrow-tab scrolling,
  retained dirty Markdown, close/cancel, save/reopen, inline address clicks,
  selected Changes-tab visibility and pane alignment. All eight suites have
  passing results, with the explicit skips below.
- Swift formatting and `git diff --check` pass.

Explicit Mac skips are external Accessibility verification for the board card
action and system shortcut capture, final acceptance of the system Export HTML
and PDF Save dialogs, and bounded-history assertions in the fresh-state renderer
fixture. Native export menu, sheet and destination checks do run.

No installed operator app or daemon was replaced by this work. An external
daemon update to v0.4.284 interrupted one focused test run; that run was repeated
with retained workspace logs and subsequently passed. The final complete Swift,
app build and Conversation execution exited successfully. The smoke driver
closed its owned app and isolated daemons; `just mac status` confirms zero
remaining `DieterMac` processes on the test host. The office diagnostic terminal
was also closed.

## Remaining qualification

The installed office app was inspected without replacement. A new signed Mac
release containing this follow-up must be installed before the live office
workflow can verify these fixes. The broader performance card also retains its
previous Android frame qualification blocker: app p95 173 ms and matched native
control p95 170 ms exceed the unchanged 120 ms gate. This Mac follow-up does not
claim to resolve that device/renderer measurement.

## Local evidence

The debug bundle is `apps/mac/build/Dieter.app`, built with the reused
`apps/mac/.build/dieter-local` cache. Unit tests use the separate
`apps/mac/.build/dieter-tests` cache. Logs are retained under `apps/mac/.build`:

- `board-followup-final-checks.log`: full Swift suite and iOS build/runtime result.
- `board-followup-native-sweep.log`: focused final board/store and iOS checks.
- `board-followup-final-smoke.log`: packaged eight-suite pass/failure evidence.
- `board-followup-adapted-smoke.log`: current pane checks and passing Sidebar rerun.
- `board-followup-pane-smoke.log`: passing Workspace run and Conversation diagnostics.
- `board-followup-conversation-final.log`: initial native workspace tab diagnostics.
- `board-followup-tab-layout.log`: clipped-tab hierarchy and pre-click capture.
- `board-followup-visible-tabs-final.log`: native scroll, tab and editor verification.
- `board-followup-final-tab-checks.log`: complete Swift suite and packaged
  Conversation rerun after the selected fixed-tab reveal fix.

Smoke captures use AppKit offscreen rendering; transparent/material surfaces
can appear black or incomplete in those PNGs. Native geometry, accessibility,
actual control effects and daemon-side results are checked separately.
