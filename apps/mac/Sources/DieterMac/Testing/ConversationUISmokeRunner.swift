#if DIETER_UI_SMOKE
    import AppKit
    import Foundation
    import DieterAPI
    import UniformTypeIdentifiers

    /// An in-process smoke driver for the conversation transcript.
    ///
    /// It opens a real conversation that contains reasoning and tool parts, then
    /// toggles the reasoning visibility backed by the conversation setting and
    /// records the timeline grouping before and after. The run proves that hiding
    /// reasoning collapses adjacent tool calls into one group and that the toggle
    /// cannot take the app down.
    @MainActor
    enum ConversationUISmokeRunner {
        static let openAttachmentPreviewNotification = Notification.Name(
            "dieter.smoke.open-attachment-preview")
        private static let syntheticFixtureID = "c_conversation_ui_smoke"
        private static let syntheticTailChatFixtureID = "c_conversation_chat_tail_ui_smoke"
        private static let syntheticCardFixtureID = "c_conversation_card_ui_smoke"
        private static var jumpToLatestVisible = false
        private static var viewportConversationID = ""
        private static var expectedViewportConversationID = ""
        private static var viewportIsAtLatest = false
        private static var viewportFollowsLatest = false
        private static var viewportInitialPositionComplete = false

        static func recordJumpToLatestVisibility(_ visible: Bool, conversationID: String) {
            guard ProcessInfo.processInfo.arguments.contains("--conversation-ui-smoke") else { return }
            guard expectedViewportConversationID.isEmpty || conversationID == expectedViewportConversationID else {
                return
            }
            jumpToLatestVisible = visible
        }

        static func recordViewportObservation(
            conversationID: String,
            isAtLatest: Bool,
            followsLatest: Bool,
            initialPositionComplete: Bool
        ) {
            guard ProcessInfo.processInfo.arguments.contains("--conversation-ui-smoke") else { return }
            guard expectedViewportConversationID.isEmpty || conversationID == expectedViewportConversationID else {
                return
            }
            viewportConversationID = conversationID
            viewportIsAtLatest = isAtLatest
            viewportFollowsLatest = followsLatest
            viewportInitialPositionComplete = initialPositionComplete
        }

        static func run(store: DieterStore) async {
            let output = outputDirectory()
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let originalShowReasoning = store.showReasoning
            defer { store.showReasoning = originalShowReasoning }

            var results: [String: String] = [:]
            var waited = 0
            progress("runner started, phase \(store.phase.label)", in: output)
            while !store.phase.isConnected && waited < 30 {
                try? await DieterTaskSleep.seconds(1)
                waited += 1
            }
            progress("wait finished after \(waited)s, phase \(store.phase.label)", in: output)
            guard store.phase.isConnected else {
                let detail: String
                if case .failed(let message) = store.phase {
                    detail = message
                } else {
                    detail = store.phase.label
                }
                results["connection"] = "failed: daemon connection did not become ready (\(detail))"
                writeReport(results, to: output)
                return
            }
            results["connection"] = "passed"
            try? await DieterTaskSleep.seconds(2)

            guard
                let window = NSApp.windows.first(where: {
                    $0.isVisible && $0.contentView != nil && $0.title == "Dieter"
                })
                    ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
            else {
                writeReport(["window": "failed: Dieter window not found"], to: output)
                return
            }
            let windowTrace = NativeUIWindowLifecycleTrace(
                window: window, output: output.appending(path: "window-lifecycle.log"))
            defer { windowTrace.stop() }
            window.setContentSize(NSSize(width: 1_380, height: 870))
            window.center()
            window.makeKeyAndOrderFront(nil)

            guard let cardID = await openConversationWithReasoningAndTools(store) else {
                results["conversation"] = "failed: no conversation with reasoning and tool parts found"
                writeReport(results, to: output)
                return
            }
            results["conversation"] = cardID
            try? await DieterTaskSleep.seconds(1)

            let messages = store.conversation?.conversation.messages ?? []
            let shownItems = ConversationTimelineItem.group(messages, showReasoning: true)
            let hiddenItems = ConversationTimelineItem.group(messages, showReasoning: false)
            let shownGroups = shownItems.filter(\.isToolCallGroup).count
            let hiddenGroups = hiddenItems.filter(\.isToolCallGroup).count
            let hiddenTools = hiddenItems.filter(\.isToolCallGroup).map { $0.toolCalls.count }
            results["grouping-shown"] = "\(shownGroups) tool groups of \(shownItems.count) items"
            results["grouping-hidden"] = "\(hiddenGroups) tool groups of \(hiddenItems.count) items"
            results["grouping-collapses"] =
                hiddenTools.contains(where: { $0 > 1 }) || hiddenGroups <= shownGroups
                ? "passed"
                : "failed: hiding reasoning did not consolidate tool calls"

            store.showReasoning = true
            try? await DieterTaskSleep.seconds(1)
            capture(window, to: output.appending(path: "01-reasoning-on.png"))

            store.showReasoning = false
            try? await DieterTaskSleep.seconds(1)
            capture(window, to: output.appending(path: "02-reasoning-off.png"))

            store.showReasoning = true
            try? await DieterTaskSleep.milliseconds(400)
            store.showReasoning = false
            try? await DieterTaskSleep.milliseconds(400)
            store.showReasoning = true
            try? await DieterTaskSleep.seconds(1)
            capture(window, to: output.appending(path: "03-reasoning-on-again.png"))
            results["reasoning-toggle"] = "passed"

            await runMarkdownTableCheck(store: store, window: window, results: &results, output: output)
            checkpoint(results, after: "Markdown tables", output: output)
            await runPasteChecks(store: store, window: window, results: &results, output: output)
            checkpoint(results, after: "paste", output: output)
            if cardID == syntheticFixtureID {
                results["history-bounded"] = "skipped: fresh-state renderer fixture"
            } else {
                await runHistoryChecks(store: store, window: window, results: &results, output: output)
            }
            await runActivityHeaderClickCheck(store: store, window: window, results: &results, output: output)
            checkpoint(results, after: "activity disclosure", output: output)
            await runActivityIndicatorCheck(
                store: store, window: window, results: &results, output: output)
            await runQueuedMessageCheck(store: store, window: window, results: &results, output: output)
            await runQueueRecallChecks(store: store, window: window, results: &results, output: output)
            checkpoint(results, after: "activity and queued messages", output: output)
            await runMessageFooterChecks(store: store, window: window, results: &results, output: output)
            checkpoint(results, after: "message footers", output: output)
            await runViewportChecks(store: store, window: window, results: &results, output: output)
            checkpoint(results, after: "viewport and card composer", output: output)
            await ConversationContentUISmoke.run(store: store, window: window, results: &results, output: output)
            checkpoint(results, after: "linked content", output: output)
            await runTurnFailureCheck(store: store, window: window, results: &results, output: output)
            checkpoint(results, after: "turn failure", output: output)
            await runNewChatComposerChecks(store: store, window: window, results: &results, output: output)

            writeReport(results, to: output)
        }

        private static func checkpoint(_ results: [String: String], after phase: String, output: URL) {
            let failures = results.filter { $0.value.hasPrefix("failed:") }
            progress("Completed \(phase): \(results.count) results, \(failures.count) failures", in: output)
            // report.json is the driver's completion signal. Preserve partial
            // assertions separately so timeout diagnostics cannot end a run early.
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output.appending(path: "progress-report.json"), options: .atomic)
            }
        }

        /// Click the summary's text, not the chevron or an accessibility action.
        /// The mounted content and row geometry prove that native input really
        /// expands and collapses the disclosure under transcript text selection.
        private static func runActivityHeaderClickCheck(
            store: DieterStore,
            window: NSWindow,
            results: inout [String: String],
            output: URL
        ) async {
            guard await installSyntheticFixture(store) != nil else {
                results["activity-header-text-click"] = "failed: renderer fixture unavailable"
                return
            }
            store.showReasoning = true
            let identifier = "conversation.activity.message:message_reasoning_one"
            let labelID = identifier + ".label"
            let contentID = identifier + ".content"
            let ready = await prepareComposerWindow(window)
            let settled = await waitForStableControl(labelID, in: window)
            guard ready, settled,
                let label = NativeUIAccessibility.find(labelID, in: window)?.recordedFrame,
                window.frame.contains(NSPoint(x: label.midX, y: label.midY)),
                let initial = NativeUIAccessibility.find(identifier, in: window)?.recordedFrame,
                NativeUIAccessibility.find(contentID, in: window) == nil
            else {
                results["activity-header-text-click"] =
                    "failed: collapsed summary was not visible (ready=\(ready), settled=\(settled))"
                return
            }

            let opened = NativeUIAccessibility.click(labelID, in: window)
            let expanded = await NativeUIAccessibility.wait(timeout: 5) {
                guard let content = NativeUIAccessibility.find(contentID, in: window)?.recordedFrame,
                    let disclosure = NativeUIAccessibility.find(identifier, in: window)?.recordedFrame
                else { return false }
                return content.width > 0 && content.height > 30 && disclosure.height > initial.height + 30
            }
            capture(window, to: output.appending(path: "03c-activity-header-expanded.png"))

            let closeSettled = await waitForStableControl(labelID, in: window)
            let closed = closeSettled && NativeUIAccessibility.click(labelID, in: window)
            let collapsed = await NativeUIAccessibility.wait(timeout: 5) {
                guard let disclosure = NativeUIAccessibility.find(identifier, in: window)?.recordedFrame else {
                    return false
                }
                return NativeUIAccessibility.find(contentID, in: window) == nil
                    && abs(disclosure.height - initial.height) < 1
            }
            capture(window, to: output.appending(path: "03d-activity-header-collapsed.png"))
            results["activity-header-text-click"] =
                opened && expanded && closed && collapsed
                ? "passed"
                : "failed: text open=\(opened), rendered expansion=\(expanded), text close=\(closed), collapsed=\(collapsed)"
        }

        /// Exercises the model-output path with the compact pipe-table shape that
        /// commonly arrives in final assistant messages, including numeric alignment.
        private static func runMarkdownTableCheck(
            store: DieterStore,
            window: NSWindow,
            results: inout [String: String],
            output: URL
        ) async {
            guard await installSyntheticFixture(store) != nil, var snapshot = store.conversation else {
                results["markdown-table"] = "failed: renderer fixture unavailable"
                return
            }
            var text = Dieter_V1_MessagePart()
            text.type = "text"
            text.text = """
                Snapshot at 21:33 CEST:
                | Node | CPU | GPU | Unified RAM |
                |---|---:|---:|---:|
                | `gx10-c674` | ~6% | 96% | 115.7 / 121.6 GiB |
                | `gx10-d6c4` | ~10% | 96% | 114.8 / 121.6 GiB |
                Available RAM remains low.
                """
            var assistant = Dieter_V1_UiMessage()
            assistant.id = "message_markdown_table"
            assistant.role = "assistant"
            assistant.parts = [text]
            snapshot.conversation.messages.append(assistant)
            store.conversation = snapshot
            store.selectedDetail = snapshot.detail
            try? await DieterTaskSleep.seconds(1)
            capture(window, to: output.appending(path: "03b-markdown-table.png"))

            let tables = ConversationMarkdownParser.parse(text.text).compactMap { block in
                if case .table(let table) = block { return table }
                return nil
            }
            results["markdown-table"] =
                tables.first?.rows.count == 2
                ? "passed"
                : "failed: model pipe table was not promoted to a table block"

            text.text =
                "| Row | Content |\n| --- | --- |\n"
                + (0..<500).map {
                    "| Row \($0) | **Formatted content** for large-table responsiveness testing. |"
                }.joined(separator: "\n")
            assistant.id = "message_large_markdown_table"
            assistant.parts = [text]
            snapshot.conversation.messages = [assistant]
            store.conversation = snapshot
            // Large tables now share the native selectable message surface.
            // Verify rendered table cells rather than removed pagination controls.
            let renderedTable = await NativeUIAccessibility.wait {
                nativeTextViews(in: window.contentView).contains { view in
                    let firstRow = (view.string as NSString).range(of: "Row 0")
                    guard view.isSelectable, firstRow.location != NSNotFound,
                        view.string.contains("Row 100"),
                        view.string.contains("Formatted content"),
                        !view.string.contains("**Formatted content**"),
                        let style = view.textStorage?.attribute(
                            .paragraphStyle, at: firstRow.location, effectiveRange: nil) as? NSParagraphStyle
                    else { return false }
                    return style.textBlocks.contains { $0 is NSTextTableBlock }
                }
            }
            results["large-markdown-table-selection"] =
                renderedTable ? "passed" : "failed: selectable native table preview was absent"
            capture(window, to: output.appending(path: "03c-large-markdown-table.png"))
            if let target = NativeUIAccessibility.find("conversation.full-text", in: window)?.object as? NSView {
                target.scrollToVisible(target.bounds)
            }
            let ready = await prepareComposerWindow(window)
            let settled = await waitForStableControl("conversation.full-text", in: window)
            let opened = ready && settled && NativeUIAccessibility.click("conversation.full-text", in: window)
            let fullText = await NativeUIAccessibility.wait {
                guard let sheet = window.attachedSheet else { return false }
                return nativeTextViews(in: sheet.contentView).contains {
                    $0.string == text.text && $0.isSelectable
                }
            }
            results["large-message-full-text"] =
                opened && fullText
                ? "passed"
                : "failed: complete message unavailable (ready=\(ready), settled=\(settled), open action=\(opened), active=\(NSApp.isActive), key=\(window.isKeyWindow), sheet=\(window.attachedSheet != nil))"
            if let sheet = window.attachedSheet {
                capture(sheet, to: output.appending(path: "03d-full-message.png"))
                _ = NativeUIAccessibility.click("conversation.full-text.done", in: sheet)
                _ = await NativeUIAccessibility.wait { window.attachedSheet == nil }
            }
        }

        private static func nativeTextViews(in view: NSView?) -> [NSTextView] {
            guard let view else { return [] }
            return (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { nativeTextViews(in: $0) }
        }

        /// Renders the complete terminal failure affordance in the packaged app
        /// and proves its retry payload still contains the original prompt.
        private static func runTurnFailureCheck(
            store: DieterStore,
            window: NSWindow,
            results: inout [String: String],
            output: URL
        ) async {
            guard await installSyntheticFixture(store) != nil, var snapshot = store.conversation else {
                results["turn-failure"] = "failed: renderer fixture unavailable"
                return
            }
            var diagnostic = Dieter_V1_MessagePart()
            diagnostic.type = "text"
            diagnostic.state = "error"
            diagnostic.text =
                "codex exited 1 after 42s (context overflow).\nprovider stderr: context window exceeded\nworker exited with status 1"
            var assistant = Dieter_V1_UiMessage()
            assistant.id = "message_failure"
            assistant.role = "assistant"
            assistant.parts = [diagnostic]
            snapshot.conversation.messages.append(assistant)
            snapshot.conversation.status = "failed"
            snapshot.detail.card.runtime = "failed"
            store.conversation = snapshot
            store.selectedDetail = snapshot.detail
            try? await DieterTaskSleep.seconds(1)
            capture(window, to: output.appending(path: "08-turn-failed.png"))

            let failure = ConversationTurnFailure.resolve(
                messages: snapshot.conversation.messages,
                conversationStatus: snapshot.conversation.status,
                cardRuntime: snapshot.detail.card.runtime
            )
            results["turn-failure"] =
                failure != nil ? "passed" : "failed: failure presentation was not resolved"
            results["turn-failure-log"] =
                failure?.log.contains("provider stderr") == true
                ? "passed"
                : "failed: complete diagnostic was not retained"
            results["turn-failure-retry"] =
                failure?.retryParts.first?.text == "Update the config and show the work."
                ? "passed"
                : "failed: original prompt was not available for retry"

            let ready = await prepareComposerWindow(window)
            let settled = await waitForStableControl("conversation.failure.view-log", in: window)
            // This check verifies the diagnostic action and resulting sheet.
            // Invoke its native accessibility action; pointer interactions are
            // exercised separately by the composer and attachment checks.
            let clicked = ready && settled && NativeUIAccessibility.press("conversation.failure.view-log", in: window)
            _ = await NativeUIAccessibility.wait {
                guard let sheet = window.attachedSheet, sheet.isVisible else { return false }
                return NativeUIAccessibility.find("conversation.failure.log-sheet", in: sheet)?.recordedWindow === sheet
            }
            if clicked,
                let sheet = window.attachedSheet, sheet.isVisible, sheet.isSheet,
                NativeUIAccessibility.find("conversation.failure.log-sheet", in: sheet)?.recordedWindow === sheet
            {
                results["turn-failure-log-action"] = "passed"
                capture(sheet, to: output.appending(path: "09-turn-failure-log.png"))
                var previousFrame: CGRect?
                var stableSamples = 0
                let doneReady = await NativeUIAccessibility.wait {
                    guard
                        let done = NativeUIAccessibility.find("conversation.failure.done", in: sheet),
                        done.recordedWindow === sheet, let frame = done.recordedFrame,
                        frame.width > 0, frame.height > 0, sheet.frame.contains(frame)
                    else { stableSamples = 0; return false }
                    stableSamples = frame == previousFrame ? stableSamples + 1 : 0
                    previousFrame = frame
                    return stableSamples >= 3
                }
                let closed =
                    doneReady
                    && NativeUIAccessibility.press("conversation.failure.done", in: sheet)
                let dismissed = await NativeUIAccessibility.wait { !sheet.isVisible && window.attachedSheet == nil }
                results["turn-failure-log-dismisses"] =
                    closed && dismissed ? "passed" : "failed: Done did not dismiss the diagnostic sheet"
            } else {
                let probes = NativeUISmokeTargets.frames["conversation.failure.view-log", default: []].compactMap {
                    $0.view
                }.map { view in
                    "host=\(view.window?.windowNumber ?? -1), hidden=\(view.isHiddenOrHasHiddenAncestor), visible=\(view.visibleRect), screen=\(view.window?.convertToScreen(view.convert(view.bounds, to: nil)) ?? .zero)"
                }
                let native = NativeUIAccessibility.elements(in: window).filter {
                    $0.identifier == "conversation.failure.view-log"
                }.map { "\(type(of: $0.object)): \($0.frame)" }
                progress(
                    "View log probes=\(probes), native=\(native), sheet=\(String(describing: window.attachedSheet))",
                    in: output)
                results["turn-failure-log-action"] =
                    "failed: View log did not open the diagnostic sheet (ready=\(ready), settled=\(settled), clicked=\(clicked))"
            }
        }

        /// Proves both navigation scopes open at the tail, live output keeps
        /// following while attached, a real wheel gesture detaches the reader,
        /// and the visible jump action restores live following.
        private static func runViewportChecks(
            store: DieterStore,
            window: NSWindow,
            results: inout [String: String],
            output: URL
        ) async {
            for (scope, id, chat) in [
                ("chat", syntheticTailChatFixtureID, true),
                ("card", syntheticCardFixtureID, false),
            ] {
                resetViewportObservation(conversationID: id)
                guard await installLongViewportFixture(store, id: id, chat: chat) != nil else {
                    results["\(scope)-opens-at-latest"] = "failed: renderer fixture unavailable"
                    continue
                }
                let positioned = await waitForViewport(
                    conversationID: id,
                    isAtLatest: true,
                    followsLatest: true,
                    initialPositionComplete: true
                )
                capture(window, to: output.appending(path: "07-\(scope)-opens-at-latest.png"))
                results["\(scope)-opens-at-latest"] =
                    positioned
                    ? "passed"
                    : "failed: initial projection did not settle at the transcript tail"
                await runComposerLayoutChecks(
                    store: store, window: window, scope: scope, results: &results, output: output)
                if scope == "card" {
                    await runBoardConversationOverlayChecks(
                        store: store, window: window, results: &results, output: output)
                    await runAttachmentImportChecks(store: store, window: window, results: &results)
                    await runOtherProviderOptionsChecks(store: store, window: window, results: &results, output: output)
                }
            }

            resetViewportObservation(conversationID: syntheticTailChatFixtureID)
            guard
                await installLongViewportFixture(
                    store,
                    id: syntheticTailChatFixtureID,
                    chat: true
                ) != nil, var snapshot = store.conversation
            else {
                results["live-tail"] = "failed: renderer fixture unavailable"
                return
            }
            _ = await waitForViewport(
                conversationID: syntheticTailChatFixtureID,
                isAtLatest: true,
                followsLatest: true,
                initialPositionComplete: true
            )

            snapshot.conversation.messages.append(
                longTextMessage(
                    id: "message_streamed_growth_one",
                    prefix: "First streamed model answer"
                ))
            snapshot.conversation.lastSeq += 1
            store.conversation = snapshot
            let firstGrowthRendered = await NativeUIAccessibility.wait {
                nativeTextViews(in: window.contentView).contains { $0.string.contains("First streamed model answer") }
            }
            progress(
                "First growth rendered=\(firstGrowthRendered), model messages=\(store.conversationMessages.count), snapshot messages=\(store.conversation?.conversation.messages.count ?? 0)",
                in: output)
            try? await DieterTaskSleep.milliseconds(350)
            let tailedFirstGrowth = await waitForViewport(
                conversationID: syntheticTailChatFixtureID,
                isAtLatest: true,
                followsLatest: true,
                initialPositionComplete: true
            )
            capture(window, to: output.appending(path: "07c-live-tail.png"))
            results["live-tail"] =
                firstGrowthRendered && tailedFirstGrowth && !jumpToLatestVisible
                ? "passed"
                : "failed: streamed growth detached a viewport that was following the tail"

            progress(
                "Before wheel id=\(viewportConversationID), latest=\(viewportIsAtLatest), follows=\(viewportFollowsLatest), initial=\(viewportInitialPositionComplete)",
                in: output)
            await postScrollUp(window)
            let detached = await waitForViewport(
                conversationID: syntheticTailChatFixtureID,
                isAtLatest: false,
                followsLatest: false,
                initialPositionComplete: true
            )
            capture(window, to: output.appending(path: "07d-manual-scroll-detached.png"))
            results["manual-scroll-detaches"] =
                detached && jumpToLatestVisible
                ? "passed"
                : "failed: manual upward scrolling did not expose Jump to latest"

            let readingOffset = streamedConversationScrollView(window)?.documentVisibleRect.origin.y
            let readingMessageOrigin = streamedReadingMessageOrigin(window)
            snapshot = store.conversation ?? snapshot
            snapshot.conversation.messages.append(
                longTextMessage(
                    id: "message_streamed_growth_two",
                    prefix: "Second streamed model answer"
                ))
            snapshot.conversation.lastSeq += 1
            store.conversation = snapshot
            let secondGrowthPresented = await NativeUIAccessibility.wait {
                nativeTextViews(in: window.contentView).contains { $0.string.contains("Second streamed model answer") }
                    || NativeUIAccessibility.find("conversation.history.later", in: window) != nil
            }
            try? await DieterTaskSleep.milliseconds(800)
            let updatedReadingOffset = streamedConversationScrollView(window)?.documentVisibleRect.origin.y
            let updatedMessageOrigin = streamedReadingMessageOrigin(window)
            let offsetPreserved =
                readingOffset.map { before in
                    updatedReadingOffset.map { abs($0 - before) < 2 } ?? false
                } ?? false
            let messagePositionPreserved =
                readingMessageOrigin.map { before in
                    updatedMessageOrigin.map { abs($0 - before) < 2 } ?? false
                } ?? false
            let preservedReadingPosition =
                secondGrowthPresented && offsetPreserved && messagePositionPreserved
                && viewportConversationID == syntheticTailChatFixtureID
                && !viewportIsAtLatest
                && !viewportFollowsLatest
                && jumpToLatestVisible
            capture(window, to: output.appending(path: "07e-detached-stream-growth.png"))
            results["detached-stream-preserves-position"] =
                preservedReadingPosition
                ? "passed"
                : "failed: streamed growth moved detached viewport; offset=\(String(describing: readingOffset))->\(String(describing: updatedReadingOffset)), messageOrigin=\(String(describing: readingMessageOrigin))->\(String(describing: updatedMessageOrigin)), presented=\(secondGrowthPresented), latest=\(viewportIsAtLatest), follows=\(viewportFollowsLatest), jump=\(jumpToLatestVisible)"
            progress("viewport: detached stream growth recorded", in: output)

            _ = NativeUIAccessibility.click("conversation.jump-to-latest", in: window)
            progress("viewport: posted Jump to latest click", in: output)
            let jumped = await waitForViewport(
                conversationID: syntheticTailChatFixtureID,
                isAtLatest: true,
                followsLatest: true,
                initialPositionComplete: true
            )
            progress("viewport: jump wait finished (jumped=\(jumped))", in: output)
            results["jump-resumes-tail"] =
                jumped && !jumpToLatestVisible
                ? "passed"
                : "failed: Jump to latest did not restore live following"

            snapshot = store.conversation ?? snapshot
            snapshot.conversation.messages.append(
                longTextMessage(
                    id: "message_streamed_growth_three",
                    prefix: "Third streamed model answer"
                ))
            snapshot.conversation.lastSeq += 1
            store.conversation = snapshot
            progress("viewport: appended post-jump stream growth", in: output)
            _ = await NativeUIAccessibility.wait {
                nativeTextViews(in: window.contentView).contains { $0.string.contains("Third streamed model answer") }
            }
            let resumedTail = await waitForViewport(
                conversationID: syntheticTailChatFixtureID,
                isAtLatest: true,
                followsLatest: true,
                initialPositionComplete: true
            )
            progress("viewport: post-jump tail wait finished (tailed=\(resumedTail))", in: output)
            capture(window, to: output.appending(path: "07f-jump-resumed-tail.png"))
            results["jump-resumed-stream-tail"] =
                resumedTail && !jumpToLatestVisible
                ? "passed"
                : "failed: streaming did not continue to tail after the jump action"
        }

        /// Exercises the actual native column widths that expose composer overflow.
        /// These fixtures are local projections; resizing and opening an attachment
        /// menu never dispatches a message or starts an agent.
        private static func runComposerLayoutChecks(
            store: DieterStore,
            window: NSWindow,
            scope: String,
            results: inout [String: String],
            output: URL
        ) async {
            guard await waitForStableControl("conversation.composer-shell", in: window),
                let shell = NativeUIAccessibility.find("conversation.composer-shell", in: window),
                let anchor = shell.object as? NSView,
                let (split, column) = conversationColumn(containing: anchor)
            else {
                results["\(scope)-composer-layout"] = "failed: native conversation column unavailable"
                return
            }
            let originalWidth = column.frame.width
            let widths: [CGFloat] =
                scope == "card" ? [460, 320] : [conversationContentWidth(split: split, column: column)]
            let harness = store.harnessCatalog.harnesses.first { $0.id == store.composerProvider }
            let model = harness?.models.first { $0.id == store.composerModel }
            var identifiers = [
                "conversation.composer", "conversation.attach", "conversation.provider",
                "conversation.model", "conversation.stop", "conversation.send",
            ]
            if model?.efforts.isEmpty == false { identifiers.append("conversation.reasoning") }
            let options = ProviderOptionValues.options(for: harness, model: store.composerModel)
            if options.contains(where: { $0.id == "fast_mode" }) { identifiers.append("conversation.fast-mode") }
            if options.contains(where: { $0.id != "fast_mode" }) {
                identifiers.append("conversation.additional-options")
            }

            for width in widths {
                if scope == "card" { setConversationContentWidth(width, split: split, column: column) }
                let resized = await NativeUIAccessibility.wait(timeout: 5) {
                    abs(conversationContentWidth(split: split, column: column) - width) < 2
                }
                let settled = await waitForStableControl("conversation.composer-shell", in: window)
                let resultKey = "\(scope)-composer-layout-\(Int(width))"
                guard resized, settled,
                    let frame = NativeUIAccessibility.find("conversation.composer-shell", in: window)?.recordedFrame
                else {
                    results[resultKey] =
                        "failed: requested content width \(width), actual \(conversationContentWidth(split: split, column: column)), pane=\(column.frame.width)"
                    continue
                }
                let columnFrame = window.convertToScreen(column.convert(column.bounds, to: nil))
                var failures: [String] = []
                var toolbarFrames: [String: CGRect] = [:]
                if !columnFrame.insetBy(dx: -1, dy: -1).contains(frame) {
                    failures.append("composer \(frame) outside column \(columnFrame)")
                }
                for identifier in identifiers {
                    guard let target = NativeUIAccessibility.find(identifier, in: window),
                        let controlFrame = target.recordedFrame,
                        target.recordedWindow === window,
                        controlFrame.width > 0, controlFrame.height > 0
                    else {
                        failures.append("\(identifier) missing")
                        continue
                    }
                    if !frame.insetBy(dx: -1, dy: -1).contains(controlFrame) {
                        failures.append("\(identifier) \(controlFrame) outside composer \(frame)")
                    }
                    if identifier != "conversation.composer" { toolbarFrames[identifier] = controlFrame }
                }
                results[resultKey] = failures.isEmpty ? "passed" : "failed: " + failures.joined(separator: "; ")
                let centers = toolbarFrames.values.map(\.midY)
                let sameRow = (centers.max() ?? 0) - (centers.min() ?? 0) <= 2
                let orderedFrames = toolbarFrames.values.sorted { $0.minX < $1.minX }
                let noOverlap = zip(orderedFrames, orderedFrames.dropFirst()).allSatisfy { pair in
                    pair.0.maxX <= pair.1.minX + 1
                }
                results["\(scope)-composer-single-row-\(Int(width))"] =
                    toolbarFrames.count == identifiers.count - 1 && sameRow && noOverlap
                    ? "passed" : "failed: toolbar frames=\(toolbarFrames)"
                let helpFailures = immediateComposerHelpFailures(controls: toolbarFrames, root: column, window: window)
                results["\(scope)-composer-quick-help-\(Int(width))"] =
                    helpFailures.isEmpty ? "passed" : "failed: " + helpFailures.joined(separator: "; ")
                capture(window, to: output.appending(path: "07-\(scope)-composer-\(Int(width)).png"))
                await runAttachmentPopoverChecks(
                    window: window, prefix: "\(scope)-attachment-\(Int(width))", results: &results)
            }
            if scope == "card" {
                setColumnWidth(originalWidth, split: split, column: column)
                _ = await waitForStableControl("conversation.composer-shell", in: window)
            }
        }

        private static func quickComposerHelpViews(in root: NSView) -> [QuickHelpView] {
            var pending = [root]
            var result: [QuickHelpView] = []
            while let view = pending.popLast() {
                if let help = view as? QuickHelpView { result.append(help) }
                pending.append(contentsOf: view.subviews)
            }
            return result
        }

        /// Exercise the actual mounted hover handlers synchronously: a delayed
        /// timer would fail here, while native menu/attachment clicks remain
        /// separate pointer-driven assertions below.
        private static func immediateComposerHelpFailures(
            controls: [String: CGRect], root: NSView, window: NSWindow
        ) -> [String] {
            let titles: [String: Set<String>] = [
                "attach": ["Attach"], "provider": ["Provider"], "model": ["Model"],
                "reasoning": ["Reasoning"], "fast-mode": ["Fast mode"],
                "additional-options": ["Provider options"], "stop": ["Stop"],
                "send": ["Send", "Queue"], "project": ["Project"], "workspace": ["Workspace"],
            ]
            let views = quickComposerHelpViews(in: root)
            var failures: [String] = []
            for (identifier, frame) in controls.sorted(by: { $0.key < $1.key }) {
                let center = CGPoint(x: frame.midX, y: frame.midY)
                let expected = titles[String(identifier.split(separator: ".").last ?? "")]
                guard
                    let help = views.first(where: { help in
                        guard help.window === window, !help.isHiddenOrHasHiddenAncestor,
                            expected?.contains(help.title) == true, help.toolTip == nil
                        else { return false }
                        return window.convertToScreen(help.convert(help.bounds, to: nil))
                            .insetBy(dx: -1, dy: -1).contains(center)
                    }),
                    let event = NSEvent.enterExitEvent(
                        with: .mouseEntered, location: window.convertPoint(fromScreen: center), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
                else {
                    failures.append("\(identifier) has no short hover label")
                    continue
                }
                let originalKey = NSApp.keyWindow
                let originalMain = NSApp.mainWindow
                let originalResponder = window.firstResponder
                help.mouseEntered(with: event)
                guard let panel = help.helpWindow else {
                    failures.append("\(identifier) did not show immediately")
                    help.dismissHelp()
                    continue
                }
                if !panel.isVisible || panel.parent !== window || panel.frame.width <= 0 || panel.frame.height <= 0
                    || !panel.ignoresMouseEvents || panel.canBecomeKey || panel.canBecomeMain
                    || panel.isAccessibilityElement() || NSApp.keyWindow !== originalKey
                    || NSApp.mainWindow !== originalMain || window.firstResponder !== originalResponder
                {
                    failures.append("\(identifier) hover panel is hidden, interactive, or stole focus")
                }
                help.mouseExited(with: event)
                if help.helpWindow != nil || panel.isVisible || panel.parent != nil {
                    failures.append("\(identifier) hover panel did not dismiss")
                }
            }
            return failures
        }

        /// Navigate the isolated fixture to the real new-chat surface without
        /// submitting anything. Context stays above the prompt while the shared
        /// agent controls remain in one bounded row at both window widths.
        private static func runNewChatComposerChecks(
            store: DieterStore, window: NSWindow, results: inout [String: String], output: URL
        ) async {
            guard let project = store.projects.first(where: { !$0.archived }) else {
                results["new-chat-composer"] = "failed: no fixture project"
                return
            }
            let originalSize = window.contentLayoutRect.size
            defer { window.setContentSize(originalSize) }
            store.beginStandaloneChat(projectID: project.id)
            guard await waitForStableControl("chats.new.composer-shell", in: window),
                await NativeUIAccessibility.wait(
                    timeout: 10,
                    until: {
                        NativeUIAccessibility.find("chats.new.harness-loading", in: window) == nil
                            && NativeUIAccessibility.find("chats.new.harness-error", in: window) == nil
                    })
            else {
                results["new-chat-composer"] = "failed: destination composer did not settle"
                return
            }
            for width in [originalSize.width, CGFloat(860)] {
                window.setContentSize(NSSize(width: width, height: originalSize.height))
                let stable = await waitForStableControl("chats.new.composer-shell", in: window)
                let key = "new-chat-composer-\(Int(width))"
                guard stable, let shell = NativeUIAccessibility.find("chats.new.composer-shell", in: window),
                    let shellFrame = shell.recordedFrame, let anchor = shell.object as? NSView,
                    let (_, column) = conversationColumn(containing: anchor)
                else {
                    results[key] = "failed: composer unavailable after resize"
                    continue
                }
                let columnFrame = window.convertToScreen(column.convert(column.bounds, to: nil))
                var failures: [String] = []
                var frames: [String: CGRect] = [:]
                var names = ["prompt", "attach", "provider", "model", "send", "project", "workspace", "destination"]
                for optional in ["reasoning", "fast-mode", "additional-options"] {
                    if NativeUIAccessibility.find("chats.new.\(optional)", in: window) != nil { names.append(optional) }
                }
                if !columnFrame.insetBy(dx: -1, dy: -1).contains(shellFrame) {
                    failures.append("composer outside its column")
                }
                for name in names {
                    let identifier = "chats.new.\(name)"
                    guard let control = NativeUIAccessibility.find(identifier, in: window),
                        control.recordedWindow === window, let frame = control.recordedFrame,
                        frame.width > 0, frame.height > 0, shellFrame.insetBy(dx: -1, dy: -1).contains(frame)
                    else {
                        failures.append("\(name) missing or outside composer")
                        continue
                    }
                    frames[identifier] = frame
                }
                let contextual = Set(["chats.new.project", "chats.new.workspace", "chats.new.destination"])
                let toolbar = frames.filter { !contextual.contains($0.key) && $0.key != "chats.new.prompt" }
                let ordered = toolbar.values.sorted { $0.minX < $1.minX }
                let centers = ordered.map(\.midY)
                if (centers.max() ?? 0) - (centers.min() ?? 0) > 2
                    || !zip(ordered, ordered.dropFirst()).allSatisfy({ $0.0.maxX <= $0.1.minX + 1 })
                {
                    failures.append("agent controls overlap or wrap")
                }
                if let prompt = frames["chats.new.prompt"] {
                    for name in contextual {
                        if let frame = frames[name], frame.minY < prompt.maxY - 1 {
                            failures.append("\(name) overlaps the prompt")
                        }
                    }
                }
                let hoverControls = frames.filter { $0.key != "chats.new.prompt" && $0.key != "chats.new.destination" }
                failures += immediateComposerHelpFailures(controls: hoverControls, root: column, window: window)
                results[key] = failures.isEmpty ? "passed" : "failed: " + failures.joined(separator: "; ")
                capture(window, to: output.appending(path: "10-new-chat-composer-\(Int(width)).png"))
            }
        }

        /// OMP's real Advisor setting and synthetic choice/text fields must fit
        /// through the same bounded options popover at the narrowest chat width.
        private static func runOtherProviderOptionsChecks(
            store: DieterStore, window: NSWindow, results: inout [String: String], output: URL
        ) async {
            guard let index = store.harnessCatalog.harnesses.firstIndex(where: { $0.id == "omp" }),
                store.harnessCatalog.harnesses[index].options.contains(where: { $0.id == "advisor" }),
                let anchor = NativeUIAccessibility.find("conversation.composer-shell", in: window)?.object as? NSView,
                let (split, column) = conversationColumn(containing: anchor)
            else {
                results["omp-provider-options"] = "failed: Advisor or native conversation fixture unavailable"
                return
            }
            let originalCatalog = store.harnessCatalog
            let originalSelection = store.composer.draft.selection
            let originalWidth = column.frame.width
            defer {
                window.makeFirstResponder(nil)
                store.harnessCatalog = originalCatalog
                store.composer.draft.selection = originalSelection
                setColumnWidth(originalWidth, split: split, column: column)
            }
            var mode = Dieter_V1_ProviderOption()
            mode.id = "smoke_mode"
            mode.name = "Review mode"
            mode.type = "enum"
            mode.mutable = true
            mode.defaultValue = "quick"
            mode.choices = ["quick", "thorough"].map { value in
                var choice = Dieter_V1_ProviderOptionChoice()
                choice.value = value
                choice.name = value.capitalized
                return choice
            }
            var note = Dieter_V1_ProviderOption()
            note.id = "smoke_note"
            note.name = "Review note"
            note.type = "string"
            note.mutable = true
            // Also exercise Fast + the options button simultaneously. These
            // catalog additions exist only in this in-memory rendering fixture.
            var fast = Dieter_V1_ProviderOption()
            fast.id = "fast_mode"
            fast.name = "Fast mode"
            fast.type = "boolean"
            fast.defaultValue = "false"
            fast.mutable = true
            store.harnessCatalog.harnesses[index].options.append(contentsOf: [mode, note, fast])
            let harness = store.harnessCatalog.harnesses[index]
            store.composerProvider = harness.id
            store.composerModel = harness.defaultModel
            store.composerEffort = harness.models.first(where: { $0.id == harness.defaultModel })?.defaultEffort ?? ""
            store.composerProviderOptions = ["fast_mode": "false"]
            setConversationContentWidth(320, split: split, column: column)
            let resized = await NativeUIAccessibility.wait(timeout: 5) {
                abs(conversationContentWidth(split: split, column: column) - 320) < 2
            }
            guard resized else {
                results["omp-provider-options"] =
                    "failed: narrow content width=\(conversationContentWidth(split: split, column: column)), pane=\(column.frame.width)"
                return
            }
            await runComposerLayoutChecks(
                store: store, window: window, scope: "omp-options", results: &results, output: output)
            let ready = await prepareComposerWindow(window)
            let settled = await waitForStableControl("conversation.additional-options", in: window)
            let opened = ready && settled && NativeUIAccessibility.click("conversation.additional-options", in: window)
            let fieldIDs = ["advisor", "smoke_mode", "smoke_note"]
            let fieldsVisible = await NativeUIAccessibility.wait(timeout: 5) {
                fieldIDs.allSatisfy { id in
                    guard let field = NativeUIAccessibility.find("conversation.other-option.\(id)", in: window),
                        let frame = field.recordedFrame, let host = field.recordedWindow, host.isVisible
                    else { return false }
                    return frame.width > 0 && frame.height > 0 && host.frame.insetBy(dx: -1, dy: -1).contains(frame)
                }
            }
            results["omp-provider-options"] =
                opened && fieldsVisible ? "passed" : "failed: opened=\(opened), native fields=\(fieldsVisible)"
            if fieldsVisible,
                let popover = NativeUIAccessibility.find("conversation.other-option.advisor", in: window)?
                    .recordedWindow
            {
                capture(popover, to: output.appending(path: "07-omp-provider-options.png"))
            }
            _ = NativeUIAccessibility.click("conversation.composer", in: window)
            let dismissed = await NativeUIAccessibility.wait(timeout: 5) {
                NativeUIAccessibility.find("conversation.other-option.advisor", in: window)?.recordedWindow?.isVisible
                    != true
            }
            results["omp-provider-options-dismisses"] =
                dismissed ? "passed" : "failed: options popover remained visible"
        }

        private static func conversationColumn(containing anchor: NSView) -> (NSSplitView, NSView)? {
            var ancestor = anchor.superview
            var fallback: (NSSplitView, NSView)?
            while let view = ancestor {
                if let split = view as? NSSplitView, split.isVertical,
                    let column = split.arrangedSubviews.first(where: { anchor.isDescendant(of: $0) })
                {
                    // The content renderer adds an inner split. Width/maximize
                    // checks belong to the outer board inspector, not that split.
                    if split is BoardConversationSplitView { return (split, column) }
                    if split.arrangedSubviews.count > 1, fallback == nil { fallback = (split, column) }
                }
                ancestor = view.superview
            }
            return fallback
        }

        private static func runBoardConversationOverlayChecks(
            store: DieterStore, window: NSWindow, results: inout [String: String], output: URL
        ) async {
            guard let shell = NativeUIAccessibility.find("conversation.composer-shell", in: window),
                let anchor = shell.object as? NSView,
                let (split, column) = conversationColumn(containing: anchor),
                let controller = split.delegate as? BoardConversationSplitController
            else {
                results["board-conversation-native-resize"] = "failed: native overlay unavailable"
                return
            }
            let originalWidth = column.frame.width
            let originalBoardFrame = controller.boardHost.convert(controller.boardHost.bounds, to: split)
            let originalComposerDraft = store.composer.draft
            let originalDraft = originalComposerDraft.text
            let selectedID = store.selectedCardID
            let host = controller.conversationHost
            let draft = "Keep this draft while resizing and expanding the conversation"
            defer {
                window.makeFirstResponder(nil)
                originalComposerDraft.text = originalDraft
            }
            // Seed through the editor like a user. Replacing a focused native
            // field's binding can leave an older editing buffer to commit later.
            window.makeFirstResponder(nil)
            originalComposerDraft.text = ""
            let inputSettled = await waitForStableControl("conversation.composer", in: window)
            let focused = inputSettled && NativeUIAccessibility.click("conversation.composer", in: window)
            let editorReady = await NativeUIAccessibility.wait(timeout: 5) {
                guard let editor = window.firstResponder as? NSTextView else { return false }
                return editor.isEditable && editor.string.isEmpty
            }
            if focused, editorReady { await NativeUIAccessibility.type(draft, in: window) }
            let entered = await NativeUIAccessibility.wait(timeout: 5) {
                store.composerText == draft && store.selectedCardID == selectedID
            }
            results["board-conversation-draft-input"] =
                focused && editorReady && entered
                ? "passed"
                : "failed: focus=\(focused), editor ready=\(editorReady), typed draft=\(entered)"
            guard focused, editorReady, entered else { return }
            let maximumRegularWidth = min(
                BoardConversationSizing.maximumWidth,
                split.bounds.width * BoardConversationSizing.maximizeFraction - 32)
            let targetWidth = max(
                BoardConversationSizing.minimumWidth,
                originalWidth + 80 <= maximumRegularWidth ? originalWidth + 80 : originalWidth - 80)
            postDividerDrag(split: split, targetWidth: targetWidth, in: window)
            let resized = await NativeUIAccessibility.wait(timeout: 5) {
                abs(column.frame.width - targetWidth) < 2
            }
            let resizedBoardFrame = controller.boardHost.convert(controller.boardHost.bounds, to: split)
            let boardResized =
                abs(
                    resizedBoardFrame.width - (originalBoardFrame.width + originalWidth - targetWidth)) < 2
                && resizedBoardFrame.maxX <= column.frame.minX + 1
            results["board-conversation-native-resize"] =
                resized && boardResized && store.composerText == draft
                ? "passed"
                : "failed: drag width=\(column.frame.width), expected=\(targetWidth), board shrank=\(boardResized), board=\(resizedBoardFrame)"
            capture(window, to: output.appending(path: "07-card-conversation-resized.png"))

            let settled = await waitForStableControl("board.conversation-maximize", in: window)
            let expanded = settled && NativeUIAccessibility.click("board.conversation-maximize", in: window)
            let maximized = await NativeUIAccessibility.wait(timeout: 5) {
                controller.maximized && abs(controller.conversationFrame.width - split.bounds.width) < 2
            }
            results["board-conversation-maximize"] =
                expanded && maximized && store.selectedCardID == selectedID && store.composerText == draft
                    && controller.conversationHost === host
                ? "passed"
                : "failed: expand=\(expanded), maximized=\(maximized), state=\(controller.maximized), collapsed=\(controller.splitViewItems.map(\.isCollapsed)), split=\(split.bounds), column=\(column.frame)"
            capture(window, to: output.appending(path: "07-card-conversation-maximized.png"))

            let restoreSettled = await waitForStableControl("board.conversation-maximize", in: window)
            let restoredClick = restoreSettled && NativeUIAccessibility.click("board.conversation-maximize", in: window)
            let restored = await NativeUIAccessibility.wait(timeout: 5) {
                !controller.maximized && abs(controller.conversationFrame.width - targetWidth) < 2
                    && host.window === window && host.isDescendant(of: split)
            }
            results["board-conversation-restore"] =
                restoredClick && restored && store.selectedCardID == selectedID && store.composerText == draft
                    && controller.conversationHost === host
                ? "passed"
                : "failed: restore=\(restoredClick), settled=\(restored), maximized=\(controller.maximized), restored width=\(controller.conversationFrame.width), expected=\(targetWidth), selection=\(store.selectedCardID == selectedID), draft=\(store.composerText == draft), host=\(controller.conversationHost === host)"
            if !controller.maximized {
                setColumnWidth(originalWidth, split: split, column: column)
                _ = await waitForStableControl("conversation.composer-shell", in: window)
                controller.rememberRegularWidth()
            }
        }

        private static func postDividerDrag(split: NSSplitView, targetWidth: CGFloat, in window: NSWindow) {
            guard let native = split as? BoardConversationSplitView else { return }
            let rect = native.dividerTrackingRect
            let start = split.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let end = split.convert(
                NSPoint(x: split.bounds.width - targetWidth - split.dividerThickness / 2, y: rect.midY), to: nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            let timestamp = ProcessInfo.processInfo.systemUptime
            for step in 0...12 {
                let type: NSEvent.EventType =
                    step == 0 ? .leftMouseDown : (step == 12 ? .leftMouseUp : .leftMouseDragged)
                let fraction = CGFloat(step) / 12
                let location = NSPoint(x: start.x + (end.x - start.x) * fraction, y: start.y)
                guard
                    let event = NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [], timestamp: timestamp + Double(step) * 0.016,
                        windowNumber: window.windowNumber, context: nil, eventNumber: step, clickCount: 1,
                        pressure: step == 12 ? 0 : 1)
                else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }

        /// Native sidebars add system chrome outside their hosting view. Exercise
        /// the actual width offered to the composer, independently of that inset.
        private static func conversationContentWidth(split: NSSplitView, column: NSView) -> CGFloat {
            if let controller = split.delegate as? BoardConversationSplitController {
                return controller.conversationHost.bounds.width
            }
            return column.frame.width
        }

        private static func setConversationContentWidth(_ width: CGFloat, split: NSSplitView, column: NSView) {
            let nativeChrome: CGFloat
            if let controller = split.delegate as? BoardConversationSplitController {
                nativeChrome = max(0, controller.conversationFrame.width - controller.conversationHost.bounds.width)
            } else {
                nativeChrome = 0
            }
            setColumnWidth(width + nativeChrome, split: split, column: column)
        }

        private static func setColumnWidth(_ width: CGFloat, split: NSSplitView, column: NSView) {
            if split is BoardConversationSplitView {
                // This native split is RTL: its first logical item is the
                // physical right sidebar, and divider position is its width.
                split.setPosition(width, ofDividerAt: 0)
                return
            }
            guard let index = split.arrangedSubviews.firstIndex(of: column) else { return }
            if index == split.arrangedSubviews.count - 1, index > 0 {
                let position = split.bounds.maxX - width
                split.setPosition(position - split.dividerThickness, ofDividerAt: index - 1)
            } else if index < split.arrangedSubviews.count - 1 {
                split.setPosition(column.frame.minX + width, ofDividerAt: index)
            }
        }

        /// Accessibility activation bypasses hit testing. Always open this menu
        /// with a pointer gesture so decorative overlays cannot hide a regression.
        private static func runAttachmentPopoverChecks(
            window: NSWindow, prefix: String, results: inout [String: String]
        ) async {
            let ready = await prepareComposerWindow(window)
            let settled = await waitForStableControl("conversation.attach", in: window)
            let opened = ready && settled && NativeUIAccessibility.click("conversation.attach", in: window)
            let choicesVisible = await NativeUIAccessibility.wait(timeout: 5) {
                attachmentChoicesVisible(in: window)
            }
            results["\(prefix)-source-popover"] =
                opened && choicesVisible
                ? "passed"
                : "failed: pointer click did not expose choices (ready=\(ready), settled=\(settled), active=\(NSApp.isActive), key=\(window.isKeyWindow), sheet=\(window.attachedSheet != nil))"
            guard opened, choicesVisible else { return }

            let popoverWindows = attachmentChoiceWindows(in: window)
            let clickedOutside = NativeUIAccessibility.click("conversation.composer", in: window)
            let dismissed = await NativeUIAccessibility.wait(timeout: 5) {
                attachmentPopoverDismissed(popoverWindows, in: window)
            }
            let refocused = dismissed ? await prepareComposerWindow(window) : false
            let resettled = await waitForStableControl("conversation.attach", in: window)
            let reopened = refocused && resettled && NativeUIAccessibility.click("conversation.attach", in: window)
            let choicesRestored = await NativeUIAccessibility.wait(timeout: 5) {
                attachmentChoicesVisible(in: window)
            }
            results["\(prefix)-source-popover-reopens"] =
                clickedOutside && dismissed && reopened && choicesRestored
                ? "passed"
                : "failed: outside click=\(clickedOutside), dismissed=\(dismissed), refocused=\(refocused), reopened=\(reopened), choices=\(choicesRestored)"
            let reopenedWindows = attachmentChoiceWindows(in: window)
            _ = NativeUIAccessibility.click("conversation.composer", in: window)
            _ = await NativeUIAccessibility.wait(timeout: 5) {
                attachmentPopoverDismissed(reopenedWindows, in: window)
            }
        }

        private static let attachmentChoiceIDs = ["conversation.attach.upload", "conversation.attach.capture"]

        private static func attachmentChoiceWindows(in window: NSWindow) -> [NSWindow] {
            attachmentChoiceIDs.compactMap { NativeUIAccessibility.find($0, in: window)?.recordedWindow }
                .filter { $0 !== window }
        }

        /// A disappearing choice alone does not mean AppKit finished dismissing
        /// its popover. Reopening before the native window closes races SwiftUI's
        /// presentation binding; wait for the original hosts and both choices.
        private static func attachmentPopoverDismissed(_ popovers: [NSWindow], in window: NSWindow) -> Bool {
            !popovers.isEmpty && popovers.allSatisfy { !$0.isVisible }
                && attachmentChoiceIDs.allSatisfy {
                    NativeUIAccessibility.find($0, in: window)?.recordedWindow?.isVisible != true
                }
        }

        private static func attachmentChoicesVisible(in window: NSWindow) -> Bool {
            attachmentChoiceIDs.allSatisfy { identifier in
                guard let target = NativeUIAccessibility.find(identifier, in: window),
                    target.recordedWindow?.isVisible == true, let frame = target.recordedFrame
                else { return false }
                return frame.width > 0 && frame.height > 0
            }
        }

        /// Exercise the actual upload action and the navigation race after its
        /// mouse-up. Both conversations are local fixtures; no message is sent.
        private static func runAttachmentImportChecks(
            store: DieterStore, window: NSWindow, results: inout [String: String]
        ) async {
            guard let originalID = store.selectedCardID, let originalSnapshot = store.conversation else {
                results["attachment-upload-picker"] = "failed: card fixture unavailable"
                return
            }
            // Finish the previous resize check's native editing session before
            // seeding either draft. A field editor can otherwise commit its old
            // buffer when Attach takes focus, invalidating this fixture mid-click.
            window.makeFirstResponder(nil)
            let originalDraft = store.composer.draft
            let originalText = originalDraft.text
            let originalAttachments = originalDraft.attachments
            var marker = Dieter_V1_MessagePart()
            marker.type = "file"
            marker.filename = "existing-draft.txt"
            marker.mediaType = "text/plain"
            marker.data = Data("Keep this attachment".utf8)
            originalDraft.text = "Keep the upload source draft"
            originalDraft.attachments = [marker]

            let targetID = "c_upload_navigation_\(UUID().uuidString.lowercased())"
            var targetSnapshot = originalSnapshot
            targetSnapshot.detail.card.id = targetID
            targetSnapshot.detail.card.title = "Upload navigation target"
            targetSnapshot.conversation.cardID = targetID
            store.state.cards.append(targetSnapshot.detail.card)
            store.selectedCardID = targetID
            let targetDraft = store.composer.draft
            targetDraft.text = "Keep the upload destination draft"
            targetDraft.attachments = [marker]
            store.selectedCardID = originalID
            defer {
                nativeUploadPanel(in: window)?.cancel(nil)
                window.makeFirstResponder(nil)
                originalDraft.text = originalText
                originalDraft.attachments = originalAttachments
                store.selectedCardID = originalID
                store.selectedDetail = originalSnapshot.detail
                store.conversation = originalSnapshot
                store.state.cards.removeAll { $0.id == targetID }
            }

            func draftsIntact() -> Bool {
                originalDraft.text == "Keep the upload source draft" && originalDraft.attachments == [marker]
                    && targetDraft.text == "Keep the upload destination draft" && targetDraft.attachments == [marker]
            }

            guard await waitForStableControl("conversation.composer-shell", in: window) else {
                results["attachment-upload-picker"] = "failed: seeded composer did not settle"
                return
            }
            if let failure = await openAttachmentUploadChoice(in: window) {
                results["attachment-upload-picker"] = "failed: \(failure)"
                return
            }
            let uploaded = NativeUIAccessibility.click("conversation.attach.upload", in: window)
            let opened = await NativeUIAccessibility.wait(timeout: 5) { nativeUploadPanel(in: window) != nil }
            results["attachment-upload-picker"] =
                uploaded && opened ? "passed" : "failed: Upload did not open a native file picker"
            guard uploaded, opened, let panel = nativeUploadPanel(in: window) else { return }
            panel.cancel(nil)
            let cancelled = await NativeUIAccessibility.wait(timeout: 5) {
                nativeUploadPanel(in: window) == nil && window.attachedSheet == nil
            }
            window.makeKeyAndOrderFront(nil)
            results["attachment-upload-cancel"] =
                cancelled && draftsIntact()
                ? "passed" : "failed: Cancel left the picker open or changed an existing draft"
            guard cancelled else { return }
            if let failure = await openAttachmentUploadChoice(in: window) {
                results["attachment-upload-navigation"] = "failed: after cancellation, \(failure)"
                return
            }

            let clicked = NativeUIAccessibility.click("conversation.attach.upload", in: window)
            // Observe the action's popover dismissal before navigating. Native
            // button tracking consumes mouse-up itself, bypassing event monitors.
            let uploadDispatched = await NativeUIAccessibility.wait(timeout: 5) {
                !attachmentChoicesVisible(in: window)
            }
            store.selectedCardID = targetID
            store.selectedDetail = targetSnapshot.detail
            store.conversation = targetSnapshot
            let pickerDismissed = await NativeUIAccessibility.wait(timeout: 5) {
                nativeUploadPanel(in: window) == nil
            }
            // Observe beyond the delayed presentation, including its animation.
            var pickerAppeared = false
            for _ in 0..<20 {
                pickerAppeared = pickerAppeared || nativeUploadPanel(in: window) != nil
                try? await DieterTaskSleep.milliseconds(50)
            }
            results["attachment-upload-navigation"] =
                clicked && uploadDispatched && pickerDismissed && !pickerAppeared && draftsIntact()
                    && store.selectedCardID == targetID && store.composer.draft === targetDraft
                ? "passed"
                : "failed: click=\(clicked), dispatched=\(uploadDispatched), dismissed=\(pickerDismissed), picker=\(pickerAppeared), drafts intact=\(draftsIntact())"
        }

        /// Return the failed native stage rather than hiding activation, layout,
        /// and hit-testing failures behind a missing Upload choice. Keep a single
        /// pointer gesture so retries cannot mask an unresponsive attachment UI.
        private static func openAttachmentUploadChoice(in window: NSWindow) async -> String? {
            if attachmentChoicesVisible(in: window) {
                return await waitForStableControl("conversation.attach.upload", in: window)
                    ? nil : "existing Upload choice did not settle"
            }
            guard await prepareComposerWindow(window) else {
                return
                    "composer window not ready (active=\(NSApp.isActive), key=\(window.isKeyWindow), sheet=\(window.attachedSheet != nil))"
            }
            guard await waitForStableControl("conversation.attach", in: window) else {
                return "Attach control did not settle"
            }
            guard let target = NativeUIAccessibility.find("conversation.attach", in: window),
                let frame = target.recordedFrame, let host = target.recordedWindow,
                host.frame.insetBy(dx: -1, dy: -1).contains(frame)
            else {
                return "Attach control is outside its window"
            }
            guard NativeUIAccessibility.click("conversation.attach", in: window) else {
                return "Attach pointer gesture could not be delivered"
            }
            guard await NativeUIAccessibility.wait(timeout: 5, until: { attachmentChoicesVisible(in: window) }) else {
                let currentFrame = NativeUIAccessibility.find("conversation.attach", in: window)?.recordedFrame
                return
                    "Attach pointer gesture did not expose choices (before=\(frame), after=\(String(describing: currentFrame)), active=\(NSApp.isActive), key=\(window.isKeyWindow), sheet=\(window.attachedSheet != nil))"
            }
            return await waitForStableControl("conversation.attach.upload", in: window)
                ? nil : "Upload choice appeared but did not settle"
        }

        private static func prepareComposerWindow(_ window: NSWindow) async -> Bool {
            // App activation and sheet dismissal are asynchronous. A native
            // first click may only activate a window, so establish stable focus
            // before the single action. Only activation requests are repeated.
            let deadline = Date().addingTimeInterval(8)
            var nextActivation = Date.distantPast
            var stableSamples = 0
            while Date() < deadline {
                if NSApp.isActive && window.isKeyWindow && window.attachedSheet == nil {
                    stableSamples += 1
                    if stableSamples >= 3 { return true }
                } else {
                    stableSamples = 0
                    if window.attachedSheet == nil, Date() >= nextActivation {
                        _ = NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
                        NSApp.activate(ignoringOtherApps: true)
                        window.makeKeyAndOrderFront(nil)
                        nextActivation = Date().addingTimeInterval(1)
                    }
                }
                try? await DieterTaskSleep.milliseconds(50)
            }
            return false
        }

        private static func nativeUploadPanel(in window: NSWindow) -> NSOpenPanel? {
            NSApp.windows.compactMap { $0 as? NSOpenPanel }.first {
                $0.isVisible && ($0.sheetParent === window || window.attachedSheet === $0)
            }
        }

        private static func waitForStableControl(_ identifier: String, in window: NSWindow) async -> Bool {
            var previousFrame: CGRect?
            var stableSamples = 0
            return await NativeUIAccessibility.wait(timeout: 5) {
                guard let target = NativeUIAccessibility.find(identifier, in: window),
                    target.recordedWindow?.isVisible == true, let frame = target.recordedFrame,
                    frame.width > 0, frame.height > 0
                else {
                    stableSamples = 0
                    return false
                }
                stableSamples = frame == previousFrame ? stableSamples + 1 : 0
                previousFrame = frame
                return stableSamples >= 4
            }
        }

        /// Leaves a deterministic active conversation at the transcript tail so
        /// the packaged-app capture proves that Running has a matching live cue.
        private static func runActivityIndicatorCheck(
            store: DieterStore,
            window: NSWindow,
            results: inout [String: String],
            output: URL
        ) async {
            guard await installSyntheticFixture(store) != nil, var snapshot = store.conversation else {
                results["agent-activity-indicator"] = "failed: renderer fixture unavailable"
                return
            }
            snapshot.conversation.status = "running"
            snapshot.detail.card.runtime = "running"
            store.conversation = snapshot
            store.selectedDetail = snapshot.detail
            try? await DieterTaskSleep.seconds(1)
            capture(window, to: output.appending(path: "06-agent-thinking.png"))
            results["agent-activity-indicator"] =
                ConversationActivityPresentation.isActive(
                    conversationStatus: snapshot.conversation.status,
                    cardRuntime: snapshot.detail.card.runtime
                ) ? "passed" : "failed: active fixture was not presented as working"
        }

        /// Keeps a server-accepted follow-up visible while the active turn is
        /// running, and captures the separate Stop and Queue composer actions.
        private static func runQueuedMessageCheck(
            store: DieterStore,
            window: NSWindow,
            results: inout [String: String],
            output: URL
        ) async {
            guard await installSyntheticFixture(store) != nil, var snapshot = store.conversation else {
                results["queued-message-visible"] = "failed: renderer fixture unavailable"
                return
            }
            var text = Dieter_V1_MessagePart()
            text.type = "text"
            text.text = "Keep this follow-up queued until the current turn finishes."
            var queued = Dieter_V1_QueuedMessage()
            queued.id = "message_queued_follow_up"
            queued.text = text.text
            queued.parts = [text]
            var optimistic = Dieter_V1_UiMessage()
            optimistic.id = queued.id
            optimistic.role = "user"
            optimistic.parts = queued.parts
            snapshot.conversation.messages.append(optimistic)
            snapshot.conversation.queue = [queued]
            snapshot.conversation.status = "running"
            snapshot.detail.card.runtime = "running"
            store.conversation = snapshot
            store.selectedDetail = snapshot.detail
            store.composerText = "Queue one more follow-up"
            let originalTheme = store.themeSelection
            defer {
                store.composerText = ""
                store.themeSelection = originalTheme
            }

            for appearance in [DieterAppearance.light, .dark] {
                store.themeSelection.appearance = appearance
                try? await DieterTaskSleep.milliseconds(600)
                capture(window, to: output.appending(path: "06b-queued-message-\(appearance.rawValue).png"))
            }
            let delivered = ConversationQueuePresentation.deliveredMessages(
                snapshot.conversation.messages,
                whileQueued: snapshot.conversation.queue
            )
            results["queued-message-visible"] =
                delivered.count == snapshot.conversation.messages.count - 1
                    && !delivered.contains { $0.id == queued.id }
                    && snapshot.conversation.queue.map(\.id) == [queued.id]
                ? "passed"
                : "failed: accepted queued content was not retained for presentation"
            results["queued-composer-active"] =
                store.composerText.isEmpty
                ? "failed: active composer did not retain a follow-up draft"
                : "passed"
        }

        /// Uses the actual focused input and Up Arrow. Only the isolated
        /// fixture's dequeue transport is substituted; draft restoration uses
        /// the same operation as the real queue's Edit command.
        private static func runQueueRecallChecks(
            store: DieterStore,
            window: NSWindow,
            results: inout [String: String],
            output: URL
        ) async {
            let context = store.conversationContext
            let originalRemove = context.onRemoveQueuedMessage
            defer {
                window.makeFirstResponder(nil)
                store.composerText = ""
                store.composerAttachments = []
                context.onRemoveQueuedMessage = originalRemove
            }
            for chat in [true, false] {
                let prefix = chat ? "chat" : "card"
                let fixtureID = "c_queue_recall_\(prefix)_ui_smoke"
                window.makeFirstResponder(nil)
                guard await installLongViewportFixture(store, id: fixtureID, chat: chat) != nil,
                    var snapshot = store.conversation
                else {
                    results["\(prefix)-queue-recall"] = "failed: fixture unavailable"
                    continue
                }
                var first = Dieter_V1_QueuedMessage()
                first.id = "queue_recall_first"; first.text = "An earlier queued message"
                var last = Dieter_V1_QueuedMessage()
                last.id = "queue_recall_last"; last.text = "Nevermind — edit this queued message"
                var text = Dieter_V1_MessagePart(); text.type = "text"; text.text = last.text
                var attachment = Dieter_V1_MessagePart()
                attachment.type = "file"; attachment.mediaType = "image/png"; attachment.filename = "recall.png"
                attachment.url = "data:image/png;base64,\(smokeImagePNG().base64EncodedString())"
                last.parts = [text, attachment]
                last.selection.provider = snapshot.detail.card.provider
                last.selection.model = snapshot.detail.card.model
                last.selection.effort = snapshot.detail.card.effort
                last.selection.providerOptions = snapshot.detail.card.providerOptions
                snapshot.conversation.queue = [first, last]
                store.conversation = snapshot
                store.composerText = ""; store.composerAttachments = []
                var removedIDs: [String] = []
                context.onRemoveQueuedMessage = { message, edit in
                    guard (store.selectedCardID ?? store.selectedChatID) == fixtureID else { return false }
                    do {
                        return try await store.composer.draft.removeQueuedMessage(message, edit: edit) { id in
                            guard var current = store.conversation,
                                let removed = current.conversation.queue.first(where: { $0.id == id })
                            else { throw CocoaError(.fileNoSuchFile) }
                            removedIDs.append(id)
                            current.conversation.queue.removeAll { $0.id == id }
                            store.conversation = current
                            return removed
                        }
                    } catch { return false }
                }

                let ready = await prepareComposerWindow(window)
                let settled = await waitForStableControl("conversation.composer", in: window)
                let clicked = ready && settled && NativeUIAccessibility.click("conversation.composer", in: window)
                let focused = await NativeUIAccessibility.wait {
                    guard let editor = window.firstResponder as? NSTextView else { return false }
                    return clicked && editor.isEditable && editor.string.isEmpty
                }
                guard focused else {
                    results["\(prefix)-queue-recall"] = "failed: composer did not receive focus"
                    continue
                }
                await NativeUIAccessibility.type("Keep this draft", in: window)
                let typed = await NativeUIAccessibility.wait { store.composerText == "Keep this draft" }
                var arrowDelivered = false
                let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
                    if event.windowNumber == window.windowNumber && event.keyCode == 126 { arrowDelivered = true }
                    return event
                }
                NativeUIAccessibility.arrow(down: false, in: window)
                let delivered = await NativeUIAccessibility.wait { arrowDelivered }
                if let monitor { NSEvent.removeMonitor(monitor) }
                results["\(prefix)-queue-recall-preserves-input"] =
                    typed && delivered && store.composerText == "Keep this draft" && removedIDs.isEmpty
                    ? "passed"
                    : "failed: typed=\(typed), delivered=\(delivered), removed=\(removedIDs), draft=\(store.composerText)"

                window.makeFirstResponder(nil)
                store.composerText = ""
                let emptySettled = await waitForStableControl("conversation.composer", in: window)
                let emptyClicked = emptySettled && NativeUIAccessibility.click("conversation.composer", in: window)
                let emptyFocused = await NativeUIAccessibility.wait {
                    guard let editor = window.firstResponder as? NSTextView else { return false }
                    return emptyClicked && editor.string.isEmpty && editor.isEditable
                }
                if emptyFocused { NativeUIAccessibility.arrow(down: false, in: window) }
                let recalled = await NativeUIAccessibility.wait {
                    store.composerText == last.text && store.composerAttachments == [attachment]
                        && store.conversation?.conversation.queue.map(\.id) == [first.id]
                        && (window.firstResponder as? NSTextView)?.string == last.text
                }
                results["\(prefix)-queue-recall"] =
                    emptyFocused && recalled && removedIDs == [last.id]
                    ? "passed"
                    : "failed: focused=\(emptyFocused), recalled=\(recalled), removed=\(removedIDs), attachments=\(store.composerAttachments.count)"
                capture(window, to: output.appending(path: "06c-queue-recall-\(prefix).png"))
                window.makeFirstResponder(nil)
                store.composerText = ""; store.composerAttachments = []
            }
        }

        private static func runMessageFooterChecks(
            store: DieterStore,
            window: NSWindow,
            results: inout [String: String],
            output: URL
        ) async {
            let pasteboard = NSPasteboard.general
            let savedClipboard = (pasteboard.pasteboardItems ?? []).map { item in
                item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
            }
            let savedPointer = NSEvent.mouseLocation
            let acceptedMouseMoves = window.acceptsMouseMovedEvents
            window.acceptsMouseMovedEvents = true
            defer {
                window.makeFirstResponder(nil)
                moveFooterPointer(to: savedPointer)
                window.acceptsMouseMovedEvents = acceptedMouseMoves
                pasteboard.clearContents()
                let items = savedClipboard.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { pasteboard.writeObjects(items) }
            }
            for chat in [true, false] {
                let prefix = chat ? "chat" : "card"
                window.makeFirstResponder(nil)
                progress("footer \(prefix): starting", in: output)
                guard await installLongViewportFixture(store, id: "c_footer_\(prefix)_ui_smoke", chat: chat) != nil,
                    var snapshot = store.conversation
                else {
                    results["\(prefix)-message-footer"] = "failed: fixture unavailable"
                    continue
                }
                let assistant = footerFixtureMessage(
                    id: "footer_\(prefix)_assistant", role: "assistant",
                    parts: ["**Assistant answer** with `formatting`.\n", "Second paragraph.  "])
                let user = footerFixtureMessage(
                    id: "footer_\(prefix)_user", role: "user",
                    parts: ["  **User request**\n", "```swift\nlet emoji = \"👋\"\n```\n\n"])
                snapshot.conversation.messages = [assistant, user]
                snapshot.conversation.queue = []
                snapshot.conversation.status = "idle"
                snapshot.detail.card.runtime = "idle"
                store.conversation = snapshot
                store.selectedDetail = snapshot.detail
                let ready = await prepareComposerWindow(window)
                let settled = await waitForStableControl("conversation.composer", in: window)
                if let frame = NativeUIAccessibility.find("conversation.composer", in: window)?.recordedFrame {
                    moveFooterPointer(to: NSPoint(x: frame.midX, y: frame.midY))
                }
                let initial = await NativeUIAccessibility.wait {
                    guard let older = footerProbe(assistant.id, in: window),
                        let latest = footerProbe(user.id, in: window)
                    else { return false }
                    return ready && settled && !older.timestampVisible && !older.actionsVisible
                        && latest.timestampVisible && !latest.actionsVisible
                        && footerTimestampRendered(user.id, in: window)
                        && !footerTimestampRendered(assistant.id, in: window)
                }
                results["\(prefix)-message-footer-latest-time"] =
                    initial ? "passed" : "failed: latest timestamp was hidden or older footer appeared without hover"
                progress("footer \(prefix): initial visibility=\(initial)", in: output)

                for message in [assistant, user] {
                    let role = message.role
                    let rowID = "conversation.message.row.\(message.id)"
                    let rowSettled = await waitForStableControl(rowID, in: window)
                    guard rowSettled,
                        let row = NativeUIAccessibility.find(rowID, in: window)?.recordedFrame,
                        window.frame.contains(NSPoint(x: row.midX, y: row.midY))
                    else {
                        results["\(prefix)-\(role)-message-footer-copy"] = "failed: visible message row unavailable"
                        continue
                    }
                    logFooterGeometry(message.id, in: window, stage: "before hover", output: output)
                    let hovered = moveFooterPointer(to: NSPoint(x: row.midX, y: row.midY))
                    let shown = await NativeUIAccessibility.wait {
                        guard let footer = footerProbe(message.id, in: window) else { return false }
                        return hovered && footer.actionsVisible && footer.timestampVisible
                            && footerTimestampRendered(message.id, in: window)
                    }
                    if !shown { logFooterGeometry(message.id, in: window, stage: "hover failed", output: output) }
                    let copyID = "conversation.message.copy.\(message.id)"
                    pasteboard.clearContents()
                    pasteboard.setString("Unchanged footer smoke clipboard", forType: .string)
                    if let copyFrame = NativeUIAccessibility.find(copyID, in: window)?.recordedFrame {
                        moveFooterPointer(to: NSPoint(x: copyFrame.midX, y: copyFrame.midY))
                    }
                    let clicked = shown && NativeUIAccessibility.click(copyID, in: window)
                    let expected = message.parts.map(\.text).joined(separator: "\n\n")
                    var copied = false
                    if clicked {
                        copied = await NativeUIAccessibility.wait {
                            pasteboard.string(forType: .string) == expected
                        }
                    }
                    results["\(prefix)-\(role)-message-footer-copy"] =
                        shown && clicked && copied
                        ? "passed"
                        : "failed: hover=\(hovered), shown=\(shown), clicked=\(clicked), exactMarkdown=\(copied)"
                    progress(
                        "footer \(prefix) \(role): hover=\(hovered), shown=\(shown), clicked=\(clicked), copied=\(copied)",
                        in: output)
                    capture(window, to: output.appending(path: "06d-footer-\(prefix)-\(role).png"))
                    window.makeFirstResponder(nil)
                }
            }
        }

        private static func footerFixtureMessage(id: String, role: String, parts: [String]) -> Dieter_V1_UiMessage {
            var message = Dieter_V1_UiMessage()
            message.id = id; message.role = role
            message.metadataJson = Data(#"{"createdAt":"2026-09-10T12:34:56Z"}"#.utf8)
            message.parts = parts.map { value in
                var part = Dieter_V1_MessagePart(); part.type = "text"; part.text = value
                return part
            }
            return message
        }

        private static func logFooterGeometry(_ messageID: String, in window: NSWindow, stage: String, output: URL) {
            var lines = ["footer \(messageID) \(stage), pointer=\(NSEvent.mouseLocation)"]
            func describe(_ view: NSView) -> String {
                let frame = view.window?.convertToScreen(view.convert(view.bounds, to: nil)) ?? .zero
                var ancestors: [String] = []
                var ancestor: NSView? = view
                while let next = ancestor, ancestors.count < 7 {
                    ancestors.append("\(type(of: next)) hidden=\(next.isHidden) frame=\(next.frame)")
                    ancestor = next.superview
                }
                return
                    "window=\(view.window?.windowNumber ?? -1) screen=\(frame) visible=\(view.visibleRect) hiddenAncestor=\(view.isHiddenOrHasHiddenAncestor) path=\(ancestors.joined(separator: " / "))"
            }
            for kind in ["row", "timestamp", "copy"] {
                let identifier = "conversation.message.\(kind).\(messageID)"
                for view in NativeUISmokeTargets.frames[identifier]?.compactMap(\.view) ?? [] {
                    lines.append("\(kind) \(describe(view))")
                }
            }
            if let root = window.contentView {
                var views = [root]
                while let view = views.popLast() {
                    if let probe = view as? MessageFooterSmokeProbe.Anchor, probe.messageID == messageID {
                        lines.append(
                            "probe timestamp=\(probe.timestampVisible) actions=\(probe.actionsVisible) \(describe(probe))"
                        )
                    }
                    views.append(contentsOf: view.subviews)
                }
                if let frame = NativeUIAccessibility.find("conversation.message.row.\(messageID)", in: window)?
                    .recordedFrame
                {
                    let point = root.convert(
                        window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY)), from: nil)
                    lines.append("row hit=\(root.hitTest(point).map(describe) ?? "nil")")
                }
            }
            progress(lines.joined(separator: "\n"), in: output)
        }

        private static func footerProbe(_ messageID: String, in window: NSWindow) -> MessageFooterSmokeProbe.Anchor? {
            guard let root = window.contentView else { return nil }
            var views = [root]
            while let view = views.popLast() {
                if let probe = view as? MessageFooterSmokeProbe.Anchor, probe.messageID == messageID,
                    probe.window === window, probe.bounds.width > 0, probe.bounds.height > 0
                {
                    return probe
                }
                views.append(contentsOf: view.subviews)
            }
            return nil
        }

        private static func footerTimestampRendered(_ messageID: String, in window: NSWindow) -> Bool {
            // In-process SwiftUI accessibility can omit mounted text entirely.
            // Require the live footer's visible state and its timestamp's actual
            // on-screen geometry; the copy assertion still uses native input.
            guard footerProbe(messageID, in: window)?.timestampVisible == true,
                let target = NativeUIAccessibility.find("conversation.message.timestamp.\(messageID)", in: window),
                target.recordedWindow === window,
                let frame = target.recordedFrame, frame.width > 0, frame.height > 0
            else { return false }
            return window.frame.contains(NSPoint(x: frame.midX, y: frame.midY))
        }

        @discardableResult
        private static func moveFooterPointer(to point: NSPoint) -> Bool {
            let location = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
            guard
                let event = CGEvent(
                    mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left)
            else { return false }
            guard CGWarpMouseCursorPosition(location) == .success else { return false }
            event.postToPid(ProcessInfo.processInfo.processIdentifier)
            return true
        }

        /// Proves a long transcript opens with a bounded page instead of
        /// chain-loading its full history, and that one explicit earlier-page
        /// request loads exactly one page.
        private static func runHistoryChecks(
            store: DieterStore,
            window: NSWindow,
            results: inout [String: String],
            output: URL
        ) async {
            var bestID: String?
            var bestTotal = 0
            let candidates = (store.state.cards + store.chats).sorted { $0.updatedAt > $1.updatedAt }.map(
                \.id)
            for cardID in candidates.prefix(12) {
                await store.openConversation(cardID: cardID)
                var waited = 0
                while store.conversationLoading && waited < 20 {
                    try? await DieterTaskSleep.milliseconds(500)
                    waited += 1
                }
                if store.conversationHistoryTotal > bestTotal {
                    bestTotal = store.conversationHistoryTotal
                    bestID = cardID
                }
            }
            guard let bestID, bestTotal >= 120 else {
                results["history-bounded"] =
                    "skipped: largest recent conversation has \(bestTotal) messages"
                return
            }
            await store.openConversation(cardID: bestID)
            var waited = 0
            while store.conversationLoading && waited < 20 {
                try? await DieterTaskSleep.milliseconds(500)
                waited += 1
            }
            // Give a runaway page chain time to manifest before judging.
            try? await DieterTaskSleep.seconds(5)
            let loaded = store.conversationMessages.count
            progress(
                "history: \(loaded) of \(store.conversationHistoryTotal) messages loaded after settling",
                in: output)
            capture(window, to: output.appending(path: "05-long-history.png"))
            results["history-bounded"] =
                loaded <= bestTotal - 30 && store.conversationHistoryHasMore
                ? "passed"
                : "failed: \(loaded) of \(bestTotal) messages loaded after opening; hasMore=\(store.conversationHistoryHasMore)"

            let before = store.conversationMessages.count
            let pageLoaded = await store.loadEarlierMessages()
            let added = store.conversationMessages.count - before
            results["history-page"] =
                pageLoaded && added > 0 && added <= 30
                ? "passed"
                : "failed: explicit earlier-page load added \(added) messages"
        }

        /// Proves ⌘V routes pasteboard images into the composer as attachment
        /// previews while plain text keeps flowing to the focused text view.
        private static func runPasteChecks(
            store: DieterStore,
            window: NSWindow,
            results: inout [String: String],
            output: URL
        ) async {
            await runAttachmentPopoverChecks(window: window, prefix: "attachment", results: &results)
            let pasteboard = NSPasteboard.general
            let saved = (pasteboard.pasteboardItems ?? []).map { item in
                item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { values, type in
                    values[type] = item.data(forType: type)
                }
            }
            defer {
                pasteboard.clearContents()
                let items = saved.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { pasteboard.writeObjects(items) }
            }

            store.composerAttachments = []
            pasteboard.clearContents()
            pasteboard.setData(
                smokeImagePNG(), forType: NSPasteboard.PasteboardType(UTType.png.identifier))
            postCommandV(window)
            try? await DieterTaskSleep.milliseconds(900)
            results["paste-image-attaches"] =
                store.composerAttachments.count == 1
                ? "passed"
                : "failed: \(store.composerAttachments.count) attachments after image paste"
            capture(window, to: output.appending(path: "04-pasted-attachment-preview.png"))

            // The packaged window has a fixed smoke size, so the attached image
            // tile is deterministic. Deliver a real native click and require the
            // SwiftUI preview sheet to appear.
            for sheet in NSApp.windows.filter({ $0.isSheet && $0.isVisible }) {
                sheet.sheetParent?.endSheet(sheet)
            }
            store.errorMessage = nil
            try? await DieterTaskSleep.milliseconds(300)
            click(window: window, x: 635, distanceFromTop: 680)
            try? await DieterTaskSleep.milliseconds(700)
            let sheets = NSApp.windows.filter { $0.isSheet && $0.isVisible }
            if let sheet = sheets.first(where: {
                $0.contentLayoutRect.width >= 600 && $0.contentLayoutRect.height >= 450
            }) {
                results["attachment-image-preview"] = "passed"
                capture(sheet, to: output.appending(path: "04b-attachment-image-preview.png"))
                sheet.sheetParent?.endSheet(sheet)
                try? await DieterTaskSleep.milliseconds(400)
            } else if let filename = store.composerAttachments.first?.filename {
                // SwiftUI occasionally declines injected mouse events outside an
                // interactive login session. Exercise the tile's accessibility
                // action path and retain the same presentation assertion.
                NotificationCenter.default.post(
                    name: openAttachmentPreviewNotification,
                    object: filename
                )
                try? await DieterTaskSleep.milliseconds(700)
                if let sheet = NSApp.windows.first(where: {
                    $0.isSheet && $0.isVisible
                        && $0.contentLayoutRect.width >= 600
                        && $0.contentLayoutRect.height >= 450
                }) {
                    results["attachment-image-preview"] = "accessibility action fallback passed"
                    capture(sheet, to: output.appending(path: "04b-attachment-image-preview.png"))
                    sheet.sheetParent?.endSheet(sheet)
                    try? await DieterTaskSleep.milliseconds(400)
                } else {
                    let sizes = NSApp.windows.filter { $0.isSheet && $0.isVisible }
                        .map { "\(Int($0.contentLayoutRect.width))x\(Int($0.contentLayoutRect.height))" }
                    results["attachment-image-preview"] = "failed: preview action opened sheets \(sizes)"
                }
            }

            let pastedText = Array(
                repeating: "A pasted paragraph should wrap naturally in the composer.", count: 8
            )
            .joined(separator: " ")
            let typedSuffix = "x"
            store.composerText = ""
            store.composerAttachments = []
            let ready = await prepareComposerWindow(window)
            let settled = await waitForStableControl("conversation.composer", in: window)
            let clicked = ready && settled && NativeUIAccessibility.click("conversation.composer", in: window)
            let focused = await NativeUIAccessibility.wait {
                guard let editor = window.firstResponder as? NSTextView else { return false }
                return clicked && NSApp.isActive && window.isKeyWindow && editor.isEditable && editor.string.isEmpty
            }
            progress(
                "paste check ready=\(ready), focused=\(focused), responder: \(String(describing: window.firstResponder))",
                in: output)
            pasteboard.clearContents()
            pasteboard.setString(pastedText, forType: .string)
            let before = store.composerAttachments.count
            postCommandV(window)
            let inserted = await NativeUIAccessibility.wait {
                store.composerText == pastedText
            }
            progress("paste check inserted \(store.composerText.count) characters", in: output)
            results["paste-text-passes-through"] =
                focused && inserted && store.composerAttachments.count == before
                ? "passed"
                : "failed: text paste did not insert the complete text unchanged (focused=\(focused), inserted=\(inserted))"
            postCharacter(typedSuffix, keyCode: 7, in: window)
            _ = await NativeUIAccessibility.wait { store.composerText == pastedText + typedSuffix }
            progress(
                "paste check typed suffix; composer now has \(store.composerText.count) characters",
                in: output)
            results["paste-text-continues-typing"] =
                store.composerText == pastedText + typedSuffix
                ? "passed"
                : "failed: composer lost the paste caret (\(store.composerText.count) characters; value=\(store.composerText.debugDescription))"
            capture(window, to: output.appending(path: "04c-pasted-text-continues.png"))
            store.composerText = ""
            store.composerAttachments = []
        }

        private static func smokeImagePNG() -> Data {
            let image = NSImage(size: NSSize(width: 24, height: 24))
            image.lockFocus()
            NSColor.systemTeal.setFill()
            NSRect(x: 0, y: 0, width: 24, height: 24).fill()
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            else { return Data() }
            return png
        }

        private static func postCommandV(_ window: NSWindow) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard
                    let event = NSEvent.keyEvent(
                        with: type,
                        location: NSPoint(x: 5, y: 5),
                        modifierFlags: [.command],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil,
                        characters: "v",
                        charactersIgnoringModifiers: "v",
                        isARepeat: false,
                        keyCode: 9
                    )
                else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }

        private static func postCharacter(_ character: String, keyCode: UInt16, in window: NSWindow) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard
                    let event = NSEvent.keyEvent(
                        with: type,
                        location: NSPoint(x: 5, y: 5),
                        modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber,
                        context: nil,
                        characters: character,
                        charactersIgnoringModifiers: character,
                        isARepeat: false,
                        keyCode: keyCode
                    )
                else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }

        private static func click(window: NSWindow, x: CGFloat, distanceFromTop: CGFloat) {
            guard let content = window.contentView else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            let location = NSPoint(x: x, y: content.bounds.height - distanceFromTop)
            let timestamp = ProcessInfo.processInfo.systemUptime
            for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                guard
                    let event = NSEvent.mouseEvent(
                        with: type,
                        location: location,
                        modifierFlags: [],
                        timestamp: timestamp,
                        windowNumber: window.windowNumber,
                        context: nil,
                        eventNumber: 0,
                        clickCount: type == .mouseMoved ? 0 : 1,
                        pressure: type == .leftMouseDown ? 1 : 0
                    )
                else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }

        /// Editable SwiftUI controls must receive their click from the application
        /// event queue. Sending it reentrantly from the smoke task can block while
        /// AppKit installs the field editor.
        private static func postClick(window: NSWindow, x: CGFloat, distanceFromTop: CGFloat) {
            guard let content = window.contentView else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            let location = NSPoint(x: x, y: content.bounds.height - distanceFromTop)
            let timestamp = ProcessInfo.processInfo.systemUptime
            for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                guard
                    let event = NSEvent.mouseEvent(
                        with: type,
                        location: location,
                        modifierFlags: [],
                        timestamp: timestamp,
                        windowNumber: window.windowNumber,
                        context: nil,
                        eventNumber: 0,
                        clickCount: type == .mouseMoved ? 0 : 1,
                        pressure: type == .leftMouseDown ? 1 : 0
                    )
                else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }

        /// Opens recently updated conversations until one contains both reasoning
        /// and tool parts, preferring the transcript a person would have open.
        private static func openConversationWithReasoningAndTools(_ store: DieterStore) async -> String? {
            let candidates = (store.state.cards + store.chats)
                .sorted { $0.updatedAt > $1.updatedAt }
                .map(\.id)
            for cardID in candidates.prefix(12) {
                progress("opening \(cardID)", in: outputDirectory())
                await store.openConversation(cardID: cardID)
                var waited = 0
                while store.conversationLoading && waited < 20 {
                    try? await DieterTaskSleep.milliseconds(500)
                    waited += 1
                }
                let parts = (store.conversation?.conversation.messages ?? []).flatMap(\.parts)
                let reasoning = parts.filter {
                    ["reasoning", "thinking"].contains($0.type.lowercased()) && !$0.text.isEmpty
                }
                let tools = parts.filter(ConversationMessagePartGroup.isToolCall)
                if !reasoning.isEmpty && tools.count >= 2 { return cardID }
            }
            return await installSyntheticFixture(store)
        }

        private static func installSyntheticFixture(_ store: DieterStore) async -> String? {
            guard let project = store.projects.first else { return nil }
            // The renderer fixture replaces the live conversation. Cancel its
            // transport lease so a late snapshot cannot overwrite the fixture.
            store.closeConversation()
            try? await DieterTaskSleep.milliseconds(500)

            var card = Dieter_V1_Card()
            card.id = syntheticFixtureID
            card.scope = "chat"
            card.projectID = project.id
            card.title = "Conversation renderer fixture"
            card.runtime = "idle"
            card.updatedAt = DieterTimestamp.string(from: Date())
            card.workspaceMode = "worktree"
            card.workspace.mode = "worktree"
            card.workspace.state = "ready"
            card.workspace.changedFiles = 3
            card.workspace.branch = "dieter/conversation-ui-smoke"

            var userText = Dieter_V1_MessagePart()
            userText.type = "text"
            userText.text = "Update the config and show the work."
            var user = Dieter_V1_UiMessage()
            user.id = "message_user"
            user.role = "user"
            user.parts = [userText]

            var reasoningOne = Dieter_V1_MessagePart()
            reasoningOne.type = "reasoning"
            reasoningOne.text = "Inspecting the current configuration."
            var read = Dieter_V1_MessagePart()
            read.type = "dynamic-tool"
            read.toolCallID = "tool_read"
            read.toolName = "Read"
            read.state = "output-available"
            var reasoningTwo = Dieter_V1_MessagePart()
            reasoningTwo.type = "reasoning"
            reasoningTwo.text = "One value needs changing."
            var edit = Dieter_V1_MessagePart()
            edit.type = "dynamic-tool"
            edit.toolCallID = "tool_edit"
            edit.toolName = "Edit"
            edit.state = "output-available"
            var result = Dieter_V1_MessagePart()
            result.type = "text"
            result.text = "Config updated. Nothing caught fire."
            var firstThought = Dieter_V1_UiMessage()
            firstThought.id = "message_reasoning_one"
            firstThought.role = "assistant"
            firstThought.parts = [reasoningOne]
            var readCall = Dieter_V1_UiMessage()
            readCall.id = "message_read"
            readCall.role = "assistant"
            readCall.parts = [read]
            var secondThought = Dieter_V1_UiMessage()
            secondThought.id = "message_reasoning_two"
            secondThought.role = "assistant"
            secondThought.parts = [reasoningTwo]
            var editCall = Dieter_V1_UiMessage()
            editCall.id = "message_edit"
            editCall.role = "assistant"
            editCall.parts = [edit]
            var answer = Dieter_V1_UiMessage()
            answer.id = "message_result"
            answer.role = "assistant"
            answer.parts = [result]

            var snapshot = Dieter_V1_ConversationSnapshot()
            snapshot.detail.card = card
            snapshot.detail.project = project
            snapshot.conversation.cardID = card.id
            snapshot.conversation.status = "idle"
            snapshot.conversation.messages = [
                user, firstThought, readCall, secondThought, editCall, answer,
            ]

            if !store.chats.contains(where: { $0.id == card.id }) { store.chats.append(card) }
            store.chatProjects = store.projects
            store.selectedCardID = nil
            store.selectedChatID = card.id
            store.selectedDetail = snapshot.detail
            store.conversation = snapshot
            store.section = .chats
            return card.id
        }

        private static func installLongViewportFixture(
            _ store: DieterStore,
            id: String,
            chat: Bool
        ) async -> String? {
            guard await installSyntheticFixture(store) != nil,
                var snapshot = store.conversation
            else { return nil }
            let project = snapshot.detail.project
            var card = snapshot.detail.card
            card.id = id
            card.scope = chat ? "chat" : "card"
            card.title = chat ? "Long standalone chat" : "Long board card"
            card.runtime = "running"
            card.updatedAt = DieterTimestamp.string(from: Date())

            if chat {
                card.boardID = ""
                if let index = store.chats.firstIndex(where: { $0.id == id }) {
                    store.chats[index] = card
                } else {
                    store.chats.append(card)
                }
                store.chatProjects = store.projects
            } else {
                var board =
                    store.state.boards.first(where: { $0.projectID == project.id }) ?? Dieter_V1_Board()
                if board.id.isEmpty {
                    board.id = "b_conversation_ui_smoke"
                    board.projectID = project.id
                    board.name = "Conversation UI smoke"
                    store.state.boards.append(board)
                }
                card.boardID = board.id
                snapshot.detail.board = board
                if let index = store.state.cards.firstIndex(where: { $0.id == id }) {
                    store.state.cards[index] = card
                } else {
                    store.state.cards.append(card)
                }
                store.selectedBoardID = board.id
            }

            snapshot.detail.card = card
            snapshot.conversation.cardID = id
            snapshot.conversation.status = "running"
            snapshot.conversation.messages.append(
                longTextMessage(
                    id: "message_long_baseline_\(chat ? "chat" : "card")",
                    prefix: chat ? "Standalone chat history" : "Board card history"
                ))

            store.selectedProjectID = project.id
            store.selectedCardID = chat ? nil : id
            store.selectedChatID = chat ? id : nil
            store.selectedDetail = snapshot.detail
            store.conversation = snapshot
            store.section = chat ? .chats : .board
            return id
        }

        private static func longTextMessage(id: String, prefix: String) -> Dieter_V1_UiMessage {
            var text = Dieter_V1_MessagePart()
            text.type = "text"
            text.text = (1...72).map {
                "\(prefix) line \($0) keeps the transcript taller than its viewport."
            }
            .joined(separator: "\n")
            var message = Dieter_V1_UiMessage()
            message.id = id
            message.role = "assistant"
            message.parts = [text]
            return message
        }

        private static func resetViewportObservation(conversationID: String) {
            expectedViewportConversationID = conversationID
            jumpToLatestVisible = false
            viewportConversationID = ""
            viewportIsAtLatest = false
            viewportFollowsLatest = false
            viewportInitialPositionComplete = false
        }

        private static func waitForViewport(
            conversationID: String,
            isAtLatest: Bool,
            followsLatest: Bool,
            initialPositionComplete: Bool
        ) async -> Bool {
            for _ in 0..<50 {
                if viewportConversationID == conversationID,
                    viewportIsAtLatest == isAtLatest,
                    viewportFollowsLatest == followsLatest,
                    viewportInitialPositionComplete == initialPositionComplete
                {
                    return true
                }
                try? await DieterTaskSleep.milliseconds(100)
            }
            return false
        }

        private static func streamedConversationScrollView(_ window: NSWindow) -> NSScrollView? {
            guard let content = window.contentView else { return nil }
            var views = [content]
            var candidates: [NSScrollView] = []
            while let view = views.popLast() {
                views.append(contentsOf: view.subviews)
                if let scroll = view as? NSScrollView {
                    if scroll.bounds.width > 100,
                        nativeTextViews(in: scroll.documentView).contains(where: {
                            $0.string.contains("First streamed model answer")
                        }),
                        (scroll.documentView?.frame.height ?? 0) > scroll.contentSize.height + 1
                    {
                        candidates.append(scroll)
                    }
                }
            }
            return candidates.max(by: { $0.contentSize.height < $1.contentSize.height })
        }

        private static func streamedReadingMessageOrigin(_ window: NSWindow) -> CGFloat? {
            guard let scroll = streamedConversationScrollView(window),
                let text = nativeTextViews(in: scroll.documentView).first(where: {
                    $0.string.contains("First streamed model answer")
                })
            else { return nil }
            return text.convert(text.bounds, to: scroll.documentView).minY
        }

        private static func postScrollUp(_ window: NSWindow) async {
            guard let content = window.contentView else { return }
            window.makeKeyAndOrderFront(nil)
            guard let scroll = streamedConversationScrollView(window) else {
                var pending = [content]
                var inventory: [String] = []
                while let view = pending.popLast() {
                    if let scroll = view as? NSScrollView {
                        inventory.append(
                            "\(type(of: view)) viewport=\(scroll.contentSize), document=\(scroll.documentView?.frame ?? .zero)"
                        )
                    }
                    pending.append(contentsOf: view.subviews)
                }
                progress(
                    "No native scroll view containing the streamed fixture: \(inventory.joined(separator: "; "))",
                    in: outputDirectory())
                return
            }
            let viewport = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
            progress(
                "Scroll viewport \(viewport), native bounds \(scroll.bounds), document \(scroll.documentView?.frame ?? .zero)",
                in: outputDirectory())
            let screenLocation = NSPoint(x: viewport.midX, y: (NSScreen.screens.first?.frame.maxY ?? 0) - viewport.midY)
            for index in 0..<10 {
                guard
                    let cgEvent = CGEvent(
                        scrollWheelEvent2Source: nil,
                        units: .pixel,
                        wheelCount: 1,
                        wheel1: 18,
                        wheel2: 0,
                        wheel3: 0
                    )
                else { continue }
                cgEvent.location = screenLocation
                cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                cgEvent.setIntegerValueField(
                    .mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
                cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cgEvent.setIntegerValueField(
                    .scrollWheelEventScrollPhase,
                    value: index == 0 ? 1 : (index == 9 ? 4 : 2)
                )
                if let event = NSEvent(cgEvent: cgEvent) {
                    if index == 0 {
                        progress(
                            "Wheel window=\(event.windowNumber), point=\(event.locationInWindow), phase=\(event.phase.rawValue), delta=\(event.scrollingDeltaY), clip=\(scroll.documentVisibleRect)",
                            in: outputDirectory())
                    }
                    // Direct native delivery bypasses the application's local
                    // event monitors. Exercise the transcript's edge intent too.
                    var pending = [content]
                    while let view = pending.popLast() {
                        (view as? ConversationScrollIntentProbe.MonitorView)?.handleScrollEvent(event)
                        pending.append(contentsOf: view.subviews)
                    }
                    scroll.scrollWheel(with: event)
                }
                try? await DieterTaskSleep.milliseconds(20)
            }
            progress(
                "Wheel completed clip=\(scroll.documentVisibleRect), atLatest=\(viewportIsAtLatest), following=\(viewportFollowsLatest)",
                in: outputDirectory())
        }

        static func progress(_ message: String, in directory: URL) {
            let url = directory.appending(path: "progress.log")
            let line = "\(Date()) \(message)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }

        static func outputDirectory() -> URL {
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "--ui-smoke-output"),
                arguments.indices.contains(index + 1)
            {
                return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
            }
            return URL(filePath: NSTemporaryDirectory()).appending(
                path: "dieter-conversation-ui-smoke", directoryHint: .isDirectory)
        }

        private static func capture(_ window: NSWindow, to url: URL) {
            guard let view = window.contentView,
                let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: representation)
            guard let data = representation.representation(using: .png, properties: [:]) else { return }
            try? data.write(to: url, options: .atomic)
        }

        private static func writeReport(_ values: [String: String], to directory: URL) {
            let data = try? JSONSerialization.data(
                withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: directory.appending(path: "report.json"), options: .atomic)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
#endif
