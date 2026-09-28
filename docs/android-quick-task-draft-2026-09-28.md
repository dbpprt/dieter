# Android Quick Task draft retention

## Root cause

`BoardList` owned the Quick Task story in `rememberSaveable(selectedBoardId)`.
More options closed that sheet and opened `AppSurface.NEW_CARD` without passing
its story. `NewConversationScreen` then initialized a separate empty title and
prompt with `remember`. Leaving the board composition also removed the original
story owner. Returning to either editor could therefore lose the draft.

The expanded editor separately remembered agent settings, lane, labels and
attachments. Those values did not survive removing its composition or Activity
recreation. Settings keyed to catalog/default objects could reset when the
catalog refreshed. Finally, `createQuickTask` rebuilt a request from defaults,
empty labels and no attachments, so returning to the sheet could discard expanded
settings even if the story itself survived.

## Change

One `CardCreationDraft` belongs to the Activity's `DieterViewModel`, keyed by
gateway, project and board. Both editors read and edit that instance. It owns
text, agent/model/effort/options, lane, workspace mode, labels, attachments and
sheet visibility. Closing either editor only changes visibility. Activity
recreation retains the ViewModel and its drafts; ordinary recomposition and
navigation cannot replace them. Checkout selection continues to live in the
existing ViewModel UI state.

Lane/workspace defaults initialize when an editor first opens; agent defaults
initialize once a matching catalog exists. A delayed catalog cannot overwrite
early lane/workspace edits. Subsequent catalog refreshes do not overwrite edits. Explicit provider/model changes still reset
dependent settings. Unsupported selections disable submission instead of being
silently replaced. The first expansion seeds the required card title from the
story; later openings never overwrite an edited or deliberately cleared title.

Both Save and Add task submit the same fields through the existing creation
queue and duplicate-admission guard. Only successful queue admission removes
the submitted draft. Closing, navigation or an admission failure does not clear
it. Submission keeps the existing whitespace normalization and lane/start
policy. Draft storage is Activity-session state, not new disk persistence. Standalone
chat retains its existing composition-local state and defaulting behavior.

## Regression coverage

- JVM: all editable fields survive repeated expansion and catalog refresh;
  delayed catalogs preserve early typing and lane/workspace edits; explicit model changes reset only
  dependent settings; a cleared title stays cleared.
- Compose component: type a Quick Task, close/reopen, expand into the real card
  form, edit settings, remove/recreate that form, and expand again.
- Activity plus isolated gateway/daemon: type before More options; toolbar Back,
  system Back, close/reopen, and recreate the Activity in both editors; assert
  title, multiline story, agent selection/options, workspace, label and attachment;
  submit via both Save and Add task; inspect authoritative task and attachment
  data; verify a successfully submitted draft starts empty. The attachment uses
  the same MessagePart as the file-picker result, supplied at that boundary.
  Existing next-chat preference assertions remain in the journey.

## Verification

The original implementation was reproduced on `Pixel_9_API_37_1`,
`emulator-5554`, using the isolated E2E application. The story was visibly
`Preserve the quick task draft` before More options. Afterwards,
`conversation-prompt` had `EditableText = ''`; the regression assertion failed
at that exact check. Captures and the failure log are under
`tmp/quick-task-baseline-warm/conversation.conversation-creation-preferences-end-to-end-test/`.
The preceding cold build exceeded the runner's 20-minute limit; the warm retry
completed and produced the actual UI reproduction above.

The AVD initially had a corrupt `default_boot` snapshot (missing VM section
footer). Only that snapshot and its stale locks were quarantined with suffix
`.quarantine-quick-task-20260928`; userdata was preserved. A normal recovery
boot, explicit snapshot save and normal reload all completed, with host Apple
GLES, launcher hierarchy and 1080×2424 screenshots verified. No operator daemon
or app was replaced for the tests.

The fixed journey passed on the same visible AVD. Evidence is under
`tmp/quick-task-final/conversation.conversation-creation-preferences-end-to-end-test/`:
`captures/quick-task-after-options.png` visibly retains the story in both the
seeded title and Agent task. The native test completed both submission paths,
including daemon-confirmed settings and attachment equality, and the existing
next-chat preferences assertions (1 requested, 1 passed, 0 failed/unavailable).
The complete JVM suite passed 416 tests. The Quick Task/terminal Compose
component case passed. `just android build` produced the debug APK successfully.

During test development, nested horizontal controls required scrolling their
outer form section before clicking. API 37's Espresso keyboard dismissal timed
out, so the test uses the repository's Activity Back dispatcher pattern. A
submission observation can contain both the optimistic card and its confirmed
replacement; the test selects the daemon-owned result for authoritative checks.
These driver corrections retain the lifecycle and field assertions.

`just check-changed --dry-run` and `just check-changed` were invoked. The latter
passed catalog validation (66 cases) and iOS preparation, then selected Mac tests
because another task had uncommitted Mac changes in this shared checkout. That
unrelated Mac run stopped advancing and was explicitly canceled; it is not
reported as passed. Android's complete JVM suite was run directly afterwards:
416 tests, zero failures, errors or skips. No operator app or daemon was stopped.

The affected Android functional suite completed successfully:
`just e2e run --platform android --suite functional --changed --output tmp/quick-task-functional`.
All 41 requested cases passed, with zero failed or unavailable cases. This
includes a second successful run of the full draft/submission regression,
the Quick Task component case, creation outbox and draft queue tests, and
adjacent activity, navigation, screen, schedule, terminal and workspace coverage.
The run's JSON/JUnit results and per-case evidence are retained in that directory.
