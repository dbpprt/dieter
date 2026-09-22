> **Historical engineering record.** This dated investigation or implementation
> report describes the state at the time it was written. For current behavior and
> setup, use the [documentation index](README.md).

# Mac chat scrolling fix

The timeline now relinquishes automatic following as soon as native upward
wheel input arrives. Deferred tail work checks cancellation, request identity,
and input generation before moving the viewport. This also covers phase-less
mouse wheels, whose input can precede SwiftUI's phase notifications.

Repeated downward input at the true tail no longer resets history or schedules
another return-to-latest operation. A tail correction also checks the native
edge before issuing `scrollTo`. Ordinary offset changes no longer trigger
automatic correction: the geometry path reacts to content height, viewport
height, or composer inset changes. Explicit jump-to-latest and transcript
projection updates retain their existing follow behavior.

History paging retains its bounded render window. After background preparation,
the timeline recaptures the currently visible message and pixel offset before
committing the replacement. If that message has moved outside the prepared
range, it prepares a range around the current anchor. Obsolete input generations
cannot restore an old position, restoration suppression is explicitly cleared,
and wheel direction prevents a restoration/bounce offset from paging in the
opposite direction.

The change preserves the existing eager timeline, native text selection, nested
scroller hit filtering, history-request deduplication, and automatic paging from
a rendered edge that is not the true conversation tail. No protocol, daemon,
CLI, or Android changes are involved.

## Regression coverage

The isolated AppKit fixtures now exercise:

- Repeated down-scroll and momentum at the true bottom: zero additional tail
  corrections and zero detached-state transitions.
- A one-pixel upward gesture arriving alongside queued streaming growth,
  followed by upward momentum: no forward snap or automatic tail correction.
- Continued streaming while detached: the visible message retains its pixel
  offset.
- Content growth and viewport resizing while following: the tail stays above
  the bottom inset.
- Phase-less wheel input: detach and rejoin both work.

The existing tests additionally cover delayed history requests, bounded-window
bottom traversal, monotonic upward paging, and evicted history pages. All eight
focused tests passed. Changed Swift files also pass strict formatting lint and
`git diff --check`.

## Validation status

The repository-selected full Mac suite passed: **663 tests across 31 suites**.
Core and board packaged-app smoke suites completed without failures. The
conversation suite passed all viewport checks, including `live-tail`,
`manual-scroll-detaches`, `detached-stream-preserves-position`,
`jump-resumes-tail`, and `jump-resumed-stream-tail`.

`just check-changed` exited nonzero because the conversation suite's separate
`content-export-pdf` check failed. Its diagnostics show that the native Save
panel reverted the configured fixture destination to Documents when presented;
the fixture therefore did not accept the dialog or write a PDF. Export code was
not changed. This remains a validation limitation, not a passing check.

The board accessibility action was skipped because the in-process AX bridge did
not expose the control. Conversation smoke also skipped full HTML export
acceptance and its fresh-state bounded-history case; the focused native tests
cover bounded history separately.

Workspace smoke ran separately because the failed conversation suite stopped
the aggregate runner. It completed with one failure:
`project-inline-draft-persists` reported `entered=false` and `preserved=false`;
the fixture did not enter the commit draft. Its other project navigation,
staging, selection, merge, and diff checks passed. This is a second non-scroll
smoke failure; neither smoke suite is reported as fully green.

Evidence under `apps/mac/.build/smoke/`:

- `core-20260918-214547-e62decdf-b942-4344-b819-fa5d05e8361d/report.json`
- `board-20260918-215009-50672231-1137-4141-8d1d-93d10c7eba8b/report.json`
- `conversation-20260918-215213-e98810a1-360b-402f-9f68-bbf57a3f3b3e/report.json`
- `workspace-20260918-215749-7b119d1a-7e13-4223-a57b-153e48a35ff2/report.json`

The conversation captures `07c-live-tail.png`,
`07d-manual-scroll-detached.png`, `07e-detached-stream-growth.png`, and
`07f-jump-resumed-tail.png` were inspected. The detached pair preserves the same
visible lines at the same positions; the tail captures show the final message
above the composer. These in-process captures do not reproduce all native glass
compositing (including the sidebar), so they are evidence of row positioning,
not complete compositor-level visual verification.

Validation uses synthetic native events and isolated fixtures. It does not
constitute a physical-trackpad recording of the originally reported incident.
The operator daemon has not been restarted or replaced.


## Final lifecycle

The debug bundle is `apps/mac/build/Dieter.app`. Build and test commands used
`apps/mac/.build/dieter-local` and `apps/mac/.build/dieter-tests`; neither cache
was cleaned or replaced with an alternate scratch path. Dependencies were
rebuilt as required, and the subsequent focused build reused the cached app
sources. The bundle passed signature verification.

Final `just mac status`: **no DieterMac process running**. All smoke-owned app
instances exited. The operator daemon was not stopped, restarted, or replaced.
No remote publishing was performed.

Command logs are `apps/mac/.build/chat-scroll-focused.log`,
`apps/mac/.build/chat-scroll-checks.log`, and
`apps/mac/.build/chat-scroll-workspace.log`. The final changed-check dry run
selected the same full Mac suite and four smoke suites, and the final diff
whitespace check passed.
