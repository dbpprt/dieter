# Android task capture: design and acceptance

Status: Approved by the requester on 2026-09-28; implemented and automated qualification passed on 2026-09-28.

## Decision

Use one task-composer controller and durable draft, with Quick Task as its compact
view and New Task / More Options as its expanded view. Sharesheet and Inbox open
**New Task after choosing a project**; the board FAB retains Quick Task. Reusing
the current board-specific popover as the navigation flow would couple global
capture to board state. Share its state, validation, attachment controls and
submission instead.

At design time, the code already provided `CardCreationDraft`, New Task attachment controls,
`ComposerAttachments` limits/previews, and attachment-bearing creation requests.
Quick Task passed draft attachments but could not add them and rejected empty text.
Drafts lived in an Activity ViewModel map, so process death loses them.
`enqueueConversation` durably queues request bytes with client/command IDs; use
this existing upload and receipt path rather than a second attachment service.
Relevant files are under `apps/android/app/src/main/java/com/dbpprt/dieter/`:
`ui/{BoardScreen,CreationScreens,CardCreationDraft,ComposerAttachments,DieterViewModel}.kt`
and `connection/DieterConnectionManager.kt`. The manifest had no share receiver.

## Entry points and interaction

| Entry | Flow |
| --- | --- |
| Android Sharesheet | Dieter → Choose project → resolve board/checkout → New Task with imported attachments and shared text |
| Inbox | Bottom-right “New task” FAB → same destination chooser → New Task |
| Board FAB | Quick Task with current board/checkout → Create, or More Options → New Task |
| Existing New Task | Same composer/controller and validation as every other entry |

The chooser lists accessible projects with machine/availability context and search.
Select the last valid board/checkout for that project; require an explicit choice
when ambiguous and show the final destination before creation. Never silently
redirect to another owner. Retired boards cannot receive tasks. No projects,
missing checkout, or no active board shows an actionable empty/error state and
preserves the draft. Existing board creation can be offered without creating a
board automatically. Shared content can be staged before sign-in; creation waits
for authentication and destination validation.

Quick Task and New Task both offer Photos and Files, attachment tiles, removal,
and the same errors. More Options and return to Quick Task preserve exact prompt,
attachment order, title edits, labels and agent/workspace choices. Blank title
means automatic title; attachment-only tasks are allowed with a filename-based
fallback title. A user-entered title is never replaced. No implicit agent start:
retain existing lane/deferred-start semantics.

A second incoming share gets a new capture identity. If a draft is open, offer
“Add to current draft” or “Keep draft and start new”; never overwrite it. Intent
redelivery on rotation/recreation must not import twice. A deliberate later share
of the same file remains a new event. Switching destinations keeps content and
revalidates destination-specific choices, displaying incompatible selections.

## Attachment contract

- Accept `ACTION_SEND` and `ACTION_SEND_MULTIPLE`, including mixed MIME shares,
  stream extras and ClipData. Deduplicate repeated URIs within one share. Import
  plain text and URLs into the prompt, treating URLs as text without fetching.
  HTML-only text is converted to plain text. Ignore unrelated extras.
- Accept readable nonempty file content of any MIME type, matching the existing
  Files/daemon contract: screenshots/images, PDF, text/source files and other
  binary documents. Unknown MIME falls back to `application/octet-stream`.
  Images get sampled thumbnails and an enlarged preview; other files show name,
  type and size. Unsupported image decoding uses the file tile. No promise that
  every model can interpret every file, and no embedded execution or rendering
  of active document content.
- Keep existing exact limits: **4 files, 5 MiB each, 6 MiB total**. Display these
  consistently. Enforce count before opening streams and byte limits during
  streaming even with absent/incorrect metadata. Never silently resize/truncate.
  Process imports sequentially in source order; keep valid items and show each
  rejected item with its reason. Failed items must be retried or removed before
  submission, so a task cannot silently omit intended content.
- Use Android URI read grants, Photo Picker and Storage Access Framework; no
  broad storage/media or camera permission is needed. Accept granted content
  URIs, reject arbitrary filesystem/network URI reads. Handle SecurityException,
  revoked/missing providers, empty streams, malformed intent data and disk-full.
- Immediately copy granted bytes off the main thread into private Android draft
  storage with generated filenames and atomic completion. Persistable grants are
  optional; successful imports must survive expiry of the original grant. Do not
  depend on cache files or place bytes in saved-state Bundles. Bound copy time
  (30 seconds per item), cancel cooperatively, and cap thumbnail dimensions.
- Each item has importing, ready or failed state. Show progress without fabricated
  percentages. Retry reopens an available URI; if its grant is gone, offer Choose
  again. Removal cancels pending work and frees unreferenced staged bytes.

## Draft durability, submission and recovery

Persist a versioned, account-scoped draft record keyed by stable draft ID, with
origin, destination, fields, attachment metadata/references and submission identity.
Use Android private durable storage alongside existing native persistence (daemon
records remain under DIETER_HOME; no project-repository metadata). Atomically save
edits and flush on navigation/backgrounding; save imported files before marking
ready. SavedStateHandle needs only draft/navigation IDs. Restore the last capture
and offer retained drafts on reopening capture; interrupted imports become a
recoverable error, while completed imports survive process death. Bound retained
drafts to 20 and 120 MiB total; at capacity require explicit discard, never evict
an unsent draft silently. Clean incomplete/unreferenced staging on recovery.

Back/close keeps a nonempty draft and returns to its source. Explicit Discard asks
for confirmation and deletes only that draft's unreferenced files. Canceling a
picker changes nothing; canceling project selection creates no task. Logout
clears account-local drafts/staging with the existing account-data lifecycle.

One controller validates destination, catalog/model, prompt-or-attachments and
limits. Disable submission during import and after admission; prevent rapid taps.
Convert staged bytes into existing `CreateConversationRequest.attachments` only
at submission. Upload occurs through the authenticated creation RPC to the owning
daemon, persisted by the existing outbox and daemon conversation attachment path.
Show “Queued”, “Sending” and “Needs attention” distinctly from server acceptance.
No standalone upload API, background upload worker or gateway file storage.

Transfer draft ownership to the durable outbox before clearing the editor. Persist
one submission identity before admission and reconcile it after a crash between
outbox persistence and draft cleanup. Retries must reuse the same payload and
client/command ID, never re-enqueue as a new task after an uncertain response.
Confirm existing daemon receipts enforce this through local, direct TLS and relay.
If the outbox must change to support this handoff, include those regression tests.

Offline imports and editing work. Queue only when cached destination and agent
selection can be validated and the owner is known; otherwise keep the draft and
explain what needs reconnection. Reuse bounded outbox retries for transient
transport errors. Permanent rejection preserves content and shows a specific
fix/retry action. Editing a rejected submission creates a new command only after
the prior command is known not to have committed. Closing UI never cancels an
admitted task or agent turn; no new post-admission cancellation contract is added.

## Acceptance and automated verification

| ID | Required evidence |
| --- | --- |
| A1 | Real Android Sharesheet screenshot → Dieter → project → New Task shows the correct preview; create → daemon task contains identical attachment bytes. Cold and warm app entry both pass. |
| A2 | Inbox FAB is bottom-right, respects system/IME insets, and works in empty/populated Inbox; project selection routes to the chosen board/owner. |
| A3 | Quick Task can add/remove/preview Photos and Files; Quick → More Options → Quick retains all text, options and attachments. Attachment-only and text-only creation pass. |
| A4 | Single/multiple/mixed shares, ClipData duplicates, shared text/URL, second share, canceled picker and canceled chooser behave as specified. |
| A5 | Exactly-at-limit files succeed; one byte over, fifth file, combined overflow, unknown/lying size, empty file and huge image dimensions fail safely without losing other content. |
| A6 | Rotation and actual process kill/relaunch restore text and completed imports without duplication. Revoked URI, provider failure, interrupted copy and disk-full have actionable retry/removal states. |
| A7 | Offline editing/queueing, reconnect, permanent rejection, transient failure and lost acknowledgement retain bytes and create exactly one task. Crash during draft/outbox handoff and repeated submit are covered. |
| A8 | Deferred Todo task retains attachments across daemon reload and delivers them on start; immediate-start task receives the same payload. Removal/discard cleans only unreferenced bytes. |
| A9 | TalkBack labels, 48dp touch targets, large font, keyboard/back behavior, portrait/landscape and narrow/wide layout keep destination, errors and actions accessible. |

Add JVM controller/storage/validation tests; Compose component tests for view
transitions and accessibility; native instrumentation with a controlled content
provider/share sender for grants, sizes and failures; catalogued E2E journeys
against disposable authenticated daemon/gateway fixtures for submission,
persistence, routing and retry. Include a genuine system Sharesheet journey,
not only direct intent injection. Use the existing YAML/native test catalog.

After approval: implement shared draft/controller first, then attachment ingress
and UI, then Sharesheet/Inbox routing and regressions. Run `just check-changed
--dry-run`, `just check-changed`, affected JVM tests and required E2E cases on the
visible `Pixel_9_API_37_1` (`emulator-5554`), sequentially. Capture screenshots,
UI hierarchy and structured test results. Reuse the emulator and isolated E2E app;
never replace/restart the operator daemon or wipe operator app data.

## Approval and execution boundary

Approval covers the shared composer approach, full New Task landing for global
entry points, attachment-only submission, limits, local retained drafts, and
outbox-based upload/retry contract above. Implementation was authorized after this document was presented and the requester
said “ok implement end to end.” Any required protocol change must include proto,
gRPC/Connect, CLI/help/docs parity and generated clients in the same change.

The request names the mini-home checkout. This session is explicitly assigned
`/Users/dbpprt/Development/dieter` on `main`; all current work stays there with no
parallel worktree. If mini-home denotes another host/path, Board must reassign the
session before implementation there. Keep the card Running while approval and
implementation are outstanding; move to Review only after implementation and
relevant checks pass.


## Implementation and verification evidence

Implemented one retained task draft and submission path for Quick Task, More
Options, Sharesheet and Inbox capture. Attachments are copied into atomic private
Android draft records under `noBackupFilesDir/task-capture`; the existing durable
outbox transfers them to the owning daemon. The gateway does not store files.
No new RPC or CLI operation was required.

Verification on visible `Pixel_9_API_37_1`, serial `emulator-5554`:

- `just check-changed --dry-run` selected catalog checks, the complete Android
  unit suite and the affected functional emulator suite.
- `just check-changed` passed: 419 unit tests, no failures or skips; all 43
  requested emulator cases passed, none failed or unavailable.
- `conversation.task-capture` exercised the real system Sharesheet, destination
  selection, screenshot preview, Quick Task/More Options preservation, Activity
  recreation, Inbox FAB creation and exact daemon attachment bytes.
- `conversation.task-capture-store` passed all seven methods, including real
  process kill/restart, expired source recovery, denied/missing URI retry,
  unknown-size byte limits, duplicate streams, interrupted import recovery,
  retained-draft capacity and storage failure.
- The creation outbox regression exercised offline enqueue, repeated submission,
  reconnect and replay after acknowledgement, retaining one task and exact bytes.
- `git diff --check` passed.

Full structured results and native logs are in
`tmp/e2e-465397389/results.json`. Screenshots and semantic hierarchies are in
`tmp/e2e-465397389/conversation.task-capture/captures/`, including
`capture-system-sharesheet.png`, `capture-project-picker.png`,
`capture-shared-attachment.png` and `capture-inbox-composer.png`.
These paths are local generated evidence, not committed product assets.

The qualification used disposable authenticated fixtures and the separate E2E
application. The operator daemon and physical phone were not modified. This is
emulator qualification; it does not claim physical-device or manual TalkBack
certification, or every combination in the acceptance matrix above.
