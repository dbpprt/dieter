> **Historical engineering record.** This dated investigation or implementation
> report describes the state at the time it was written. For current behavior and
> setup, use the [documentation index](README.md).

# Chat scrolling assessment and fix plan

Scope: native macOS conversation timeline, assumed from the desktop context.
This is a source assessment, not a visually reproduced diagnosis. `just mac
status` reported no DieterMac process. No application, daemon, or implementation
was changed; existing unrelated working-tree changes were left alone. Tests
were inspected, not executed.

## Assessment

The strongest explanation is competing scroll corrections around native input
and asynchronous layout. Fix ownership and timing before changing rendering
technology or tuning animation.

### 1. Redundant tail corrections at the bottom — high-confidence code finding

`ConversationTimeline.swift:535` handles a downward wheel event at the true
bottom by calling `returnToLatest()`, even when already following the latest
message. That resets history through the model and schedules a tail scroll.
Geometry and phase callbacks also call `updateViewportAfterUserScroll()`, which
returns to latest whenever the viewport is at the end (`:464`).

Separately, the geometry callback requests a correction whenever it observes
an off-bottom position while following and outside a reported user gesture
(`:268`). Requests are coalesced while pending, but can recur across frames.
This provides a plausible mechanism for corrections fighting elastic scrolling
or its settling phase. Whether it causes the reported visible flicker still
requires a native reproduction.

### 2. Upward intent does not immediately relinquish tail following

The native event probe forwards only a vertical delta
(`ConversationViewport.swift:383`). At the bottom, an upward wheel event fails
the *earlier-edge* check in `handleUserScrollIntent`, so that callback does not
detach. Detachment waits for SwiftUI phase/geometry observations. Meanwhile,
the pending tail task checks `userScrollInProgress` after a yield, but does not
explicitly check cancellation or a gesture generation before scrolling (`:414`).
This creates an ordering risk during rapid input and streaming; it is not proof
that every upward gesture is mishandled.

The end tolerance is only two points (`ConversationViewport.swift:90`), and the
same threshold determines leaving and rejoining the tail. Small movement can
toggle follow state and the Jump to latest overlay. Stable intent rules should
precede any tolerance adjustment.

### 3. History replacement can restore an outdated reading position

The timeline deliberately renders bounded windows: up to 60 messages, 16,000
text bytes, and 160 parts (`ConversationPresentation.swift:131`). At their
edges, it replaces rows and restores a message/pixel anchor.

`moveRenderWindow` captures the anchor before background projection preparation.
While that work runs, native scrolling continues but geometry/intent handling
returns early because `windowChangeInFlight` is true. The projection task then
restores the earlier anchor after a `Task.yield()` (`ConversationTimeline.swift:361`).
That can undo movement made during preparation. Network history loading does
recapture after the request finishes, which is good, but still precedes the
subsequent asynchronous projection step.

Restoration success means a registered view exists, not that its final layout
has settled. A failed restore is not retried before the pending anchor is
cleared. `restoringOffset` also suppresses geometry handling until a matching
offset or phase transition arrives. These are additional continuity risks.

### 4. Current tests miss the most relevant input sequences

`ConversationAutomaticScrollLayoutTests.swift` tests delayed network paging,
advancing from a bounded bottom, and monotonic upward progress. Its wheel helper
sets scroll phases but not momentum phases. Assertions largely inspect settled
positions/message order, so transient backward motion can escape detection.
The main timeline fixture also omits the full floating-composer container.
Anchor unit tests separately cover bottom insets.

## Implementation plan

1. **Reproduce and measure before changing behavior.** Extend the isolated
   native fixture to record wheel/phase/momentum events, offset, document height,
   bottom inset, follow mode, projection generation, anchor restoration, and
   every programmatic scroll reason. Use bounded test/debug tracing. Exercise
   repeated downward gestures at the true bottom, a tiny upward gesture,
   immediate direction reversal, momentum, and concurrent streaming. Capture
   successive viewport positions rather than only the final result.

2. **Make user input authoritative.** Centralize viewport transitions in one
   testable coordinator. Upward transcript intent immediately detaches and
   invalidates pending tail work. Track gesture and momentum lifecycle through
   completion, retaining the existing nested-scroller/composer hit filtering.
   Check task cancellation and conversation/gesture/projection generations
   immediately before any deferred correction. Include mouse wheels without
   phases, keyboard scrolling, and scrollbar dragging in the policy.

3. **Make following and rejoining distinct, idempotent operations.** A downward
   event at the true bottom while already following should schedule no corrective
   scroll and perform no history reset. Returning from history performs cleanup
   once. Preserve downward paging at the bottom of a window that is not the true
   tail. Follow actual content/inset changes only when no user gesture or anchor
   restoration owns the viewport; avoid treating every geometry deviation as a
   reason to scroll. Define separate detach/rejoin rules so bounce cannot toggle
   state. Explicit Jump to latest remains a deliberate request.

4. **Commit window replacement and anchor restoration together.** Prepare the
   next projection while retaining the old rows. Recapture the visible anchor
   immediately before committing it; retain that message in the replacement
   range, or recompute/defer the replacement if input moved beyond its overlap.
   Restore against the committed layout generation, with bounded handling for
   missing/unsettled anchors. Clear suppression explicitly on completion,
   cancellation, or failure. Never restore an obsolete gesture position.
   Retain bounded rendering and existing history-request deduplication.

5. **Verify full conversation layout and visual behavior.** Cover streaming
   text growth, tool-group expansion, working-indicator removal, composer growth,
   sidebar/workspace resizing, long messages, and short unscrollable transcripts.
   While following, the last row remains above the composer; while detached,
   updates preserve the reading anchor. If flicker remains with stable offsets,
   isolate the bottom soft edge effect and compositing as a separate visual cause.

## Acceptance criteria and checks

- Repeated down-scroll at the true tail causes no redundant tail corrections,
  follow-mode flapping, or visible snap/flicker, including momentum settling.
- Upward input starts moving immediately and cannot be undone by queued tail
  work, streaming, or a stale projection.
- Paging preserves the current message's pixel offset within two points after
  layout settles; frame samples show no backward snap from stale restoration.
- Reading through bounded windows stays monotonic in the requested direction;
  the true tail remains reachable after cache eviction and delayed network pages.
- Jump to latest reliably rejoins following; nested text/code scrolling and
  selection remain functional.
- Add focused native regression tests to the existing scroll/layout suites and
  policy tests for coordinator transitions. Use the full composer container for
  inset cases, and cover cancellation/conversation switching during preparation.
- For implementation, run `just check-changed --dry-run`, then
  `just check-changed` and affected Mac tests. Review the dry run because unrelated
  changes are already present. Run the conversation smoke suite with isolated
  fixtures and inspect its evidence; do not disrupt an operator app or daemon.

Suggested order: reproduce → input ownership and idempotent following → atomic
window handoff → full-layout verification. No API, daemon, CLI, or Android change
is indicated by this Mac-specific assessment.
