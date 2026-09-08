**Dieter Mac responsiveness implementation — 8 September 2026**

This implements the concrete responsiveness and presentation fixes identified in the [assessment](mac-responsiveness-assessment-2026-09-08.md), against the 0.4.101 source. The Homebrew installation was updated to 0.4.101 before that assessment. Development and native tests use the separately packaged app at `apps/mac/build/Dieter.app` and disposable services; this change is not a published Homebrew release.

**Resulting behavior**

- Files initialize the native editor even when document preparation happens before view attachment. Unsaved text survives native-view recreation, and the last same-project file surface survives leaving and returning. Saving and A → B → A file selection have native interaction coverage. Syntax colors and the insertion cursor adapt to light and dark appearance.
- The Files navigator and preview use a stable resizable SwiftUI split. The former native split could lose its navigator after an active editor was replaced by an error. The new split retains a saved width and exposes an accessibility adjustment action. The regression checks that another file can actually be clicked and loaded after an error, in addition to inspecting screenshots.
- Files, Chats, Archive, Schedules, Terminals, and conversation preparation have explicit feedback. The shared component acknowledges immediately with text, delays its small spinner by 120 ms, and uses a static activity symbol under Reduce Motion. Errors persist with a Retry action. Cached same-target content remains visible during refresh. A missing file gets a concise explanation. A failed cold schedule request no longer displays a permanent spinner. Machine information no longer says “Connecting…” alongside an error.
- The root no longer disables and fades the entire cached workspace during reconnect/offline states. Safe reading, navigation, search, and disclosure remain available. Live mutations are gated at their controls, and board drag mutations reject unavailable/wrong-machine state. Existing offline message/outbox semantics remain intact, including explicit retry/discard handling.
- Duplicate loads share a surface-owned transport request; a new target cancels the superseded read. File, chat, schedule, terminal, and conversation results have ownership guards. Conversation selection generations also reject late results and stream updates after A → B → A navigation. Machine telemetry cannot replace the newest selection's loading state or restart the old selection's polling task.
- Chats and Terminals have one normal mounting load path. Schedules owns connection preparation before its load, preventing reads against the previous machine. Files loads its own data without first waiting for an unrelated full-state read. Changes retains its existing owned model and connection preparation.
- Unary conversation, file, terminal, schedule, prompt, archive, and tool-output reads receive explicit 15-second deadlines. Conversations retain their larger attachment message allowance. Watch streams keep their separate lifetime; cancelling a read does not stop remote agent work.
- Inactive snapshot decoding and conversation indexing run on a dedicated actor. The decoded cache is bounded to four endpoints and 16 MiB of serialized input, and validates the input bytes before reuse. Endpoint activation refuses to combine a newer cursor with older decoded bytes if a refresh won a race with decoding.
- Markdown blocks and inline formatting are prepared before the timeline publishes its rows. Cache storage supports worker access; cancellation propagates to background preparation and is checked between text blocks/cells. Table widths are computed once during parsing, and tables page through at most 20 rows and eight columns at once. The eager transcript is bounded to 60 messages, 16,000 text bytes, and 160 parts across messages. A single large text part has a 12,000-character/80-block preview and a selectable AppKit full-text viewer. Earlier/later controls keep retained messages reachable. The existing eager-layout strategy is retained to avoid the known lazy-stack/text-selection cycle.
- Chat refresh composes its collection before publication. Missing-project outbox failures stay available in Settings recovery and no longer reappear as phantom chat rows. Directory refresh reapplies the same overlay policy. Failed commands are neither deleted nor automatically retried by this fix.

**Measurements**

These are synthetic **debug** measurements on the same Mac, not release p95 frame times. Parsing/preparation runs before the measured render. `ImageRenderer` measures synchronous layout/rasterization of the actual message and Markdown views. Paging intentionally changes the amount simultaneously rendered; full content remains accessible.

| Workload | Assessment | After implementation |
|---|---:|---:|
| 50-row, five-column Markdown table | 53.39 ms median | 14.42 ms median for its visible 20-row page |
| 100-row, five-column Markdown table | 162.36 ms median | 14.07 ms median for its visible 20-row page |
| Eager formatted-message stack, 180 available messages | 132.65 ms median | 29.00 ms median for the 28 messages admitted by the text budget |
| 7.40 MB inactive snapshot lookup | 1,069.65 ms median, synchronous main-actor decode | 1,129.37 ms cold decode on the decoder actor; 0.0085 ms average warm indexed lookup |

Cold protobuf decoding still costs CPU time; the improvement is its executor and indexed reuse. The cache cannot make an uncached snapshot decode instantaneous.

The native file journey records event-dispatch-to-selection and event-dispatch-to-native-buffer readiness using a 5 ms polling interval, without extracting the full accessibility tree for each sample. The final run recorded selection at **57.6 / 13.3 / 25.1 ms**, with the loaded native text available at **92.4 / 32.1 / 47.8 ms**. These three samples are useful smoke evidence, not a p95 claim or a first-paint measurement. Initial navigation and a cold render can still cost more than a warm revisit.

Evidence: [measurement log](/tmp/dieter-responsiveness-tests-final.log), [retained diagnostic source](/tmp/dieter-mac-responsiveness-20260908/ResponsivenessValidationDiagnostic.swift), [file journey report](../apps/mac/.build/smoke/core-20260908-123421-10284ebc-7dfa-474f-b029-673fc5f66df9/report.json), [visible file-error recovery](../apps/mac/.build/smoke/core-20260908-123421-10284ebc-7dfa-474f-b029-673fc5f66df9/appearance-light/04b-file-read-error.png).

**Verification**

- `just harness install` completed with pinned dependencies.
- `just check` passed: protocol generation checks, Go race tests, vet, daemon/gateway builds, and all 43 harness runtime tests. Generation changed only four protoc-version comments; those incidental changes were removed.
- `just mac proto-check` passed.
- `just mac test` passed **225 permanent tests**, including two concurrent harness-catalog additions after the earlier 223-test pass. Responsiveness coverage includes editor lifecycle, shared/cancelled reads, 50/250/1,000 ms delayed schedule loads and failure recovery, stale result rejection, snapshot identity/indexing, cursor/decoded-byte ownership, Markdown preparation off the main thread, render bounds, and deterministic missing-project outbox composition.
- `just android test` passed using Android Studio's bundled JBR; Gradle reused up-to-date outputs. The existing Android edits were preserved.
- **All eight native suites passed** against the same final packaged executable. Expanded file-error coverage exposed the split-view defect described above. Its regression performs native click/edit/save/revisit and post-error recovery. The large-message test waits for transcript layout, uses real mouse clicks, verifies the mounted second-page label, and compares the native selectable text buffer with the entire 500-row source. Reports and relevant screenshots were inspected. The conversation suite's existing daemon-history check is explicitly skipped for its fresh synthetic renderer fixture; permanent tests cover render-window bounds.
- Native tests use the canonical `dieter-local` build cache and `dieter-tests` test cache. No build cache was deleted. The packaged app's ad-hoc signature is verified by the build recipe.
- Temporary benchmark code was removed from the permanent test target; its source and results remain in the evidence directory.

Logs: [permanent Mac regressions](/tmp/dieter-responsiveness-mac-tests-latest.log), [repository checks](/tmp/dieter-responsiveness-repository-check.log), [Android checks](/tmp/dieter-responsiveness-android-tests.log), [final native conversation suite](/tmp/dieter-responsiveness-conversation-verified.log), [remaining seven native suites](/tmp/dieter-responsiveness-native-remaining.log).

| Native suite | Final evidence |
|---|---|
| Core | [Report](../apps/mac/.build/smoke/core-20260908-123421-10284ebc-7dfa-474f-b029-673fc5f66df9/report.json) |
| Board | [Report](../apps/mac/.build/smoke/board-20260908-123606-25051f71-f9e3-461c-99a0-603767030e20/report.json) |
| Conversation | [Report](../apps/mac/.build/smoke/conversation-20260908-123324-0235ad3d-0e4b-43b7-9c85-aa210b04ed23/report.json), [paged table](../apps/mac/.build/smoke/conversation-20260908-123324-0235ad3d-0e4b-43b7-9c85-aa210b04ed23/03c-large-markdown-table.png) |
| Machine | [Report](../apps/mac/.build/smoke/machine-20260908-123620-d8bfdd09-4224-4ea6-b5b9-2ca77584e71c/report.json) |
| Sidebar | [Prepare](../apps/mac/.build/smoke/sidebar-20260908-123629-cdb9decc-3d70-4ad6-886d-d2e4dc3425c7/prepare/report.json), [relaunch](../apps/mac/.build/smoke/sidebar-20260908-123629-cdb9decc-3d70-4ad6-886d-d2e4dc3425c7/verify/report.json) |
| Terminal | [Report](../apps/mac/.build/smoke/terminal-20260908-123643-6e0eb41d-3345-4954-b6db-c8fd4ae7d556/report.json) |
| Island | [Report](../apps/mac/.build/smoke/island-20260908-123654-2bee2799-f326-4541-9cbb-5dcba14a6b06/report.json) |
| Workspace | [Report](../apps/mac/.build/smoke/workspace-20260908-123659-c5aceb6c-ca97-47a7-a297-896bcf445102/report.json) |

The final native validation uses one debug executable, SHA-256 `40a00f030132fb8a71f1b8b9b56b5cf3a77150c048404ed13b487f2faac650f3`. Additional harness-catalog and failed-creation presentation edits arrived in the shared workspace during validation; they were preserved and are included in this packaged binary. The responsiveness changes do not claim authorship of that concurrent work.

**Practical limits**

This removes the observed broken states and several measured hitch paths. It does not establish a universal sub-50 ms p95 response time or 120 Hz frame compliance. A release Instruments trace across more hardware, very large directories, image-heavy conversations, and sustained screen video remains useful performance work. The existing whole-workspace reducer and the Chats list projection still have scaling costs at thousands of entries; this change batches chat publication without replacing the entire observable store. The assessment did not establish that those costs explain severe lag at the live 30–54-chat dataset size.

Final process inventory: **zero DieterMac processes**. The operator's daemon remains PID **59650**, started **7 September 2026 at 13:43:54**, running `/opt/homebrew/opt/dieter/bin/dieter daemon start --service`. It has not been upgraded, restarted, replaced, or stopped. UI mutations performed by native suites are confined to disposable fixtures. The existing chat-disclosure work, Android changes, and concurrent harness work were preserved.
