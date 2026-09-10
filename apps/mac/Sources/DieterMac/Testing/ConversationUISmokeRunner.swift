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
            await runPasteChecks(store: store, window: window, results: &results, output: output)
            if cardID == syntheticFixtureID {
                results["history-bounded"] = "skipped: fresh-state renderer fixture"
            } else {
                await runHistoryChecks(store: store, window: window, results: &results, output: output)
            }
            await runActivityIndicatorCheck(
                store: store, window: window, results: &results, output: output)
            await runQueuedMessageCheck(store: store, window: window, results: &results, output: output)
            await runViewportChecks(store: store, window: window, results: &results, output: output)
            await runTurnFailureCheck(store: store, window: window, results: &results, output: output)

            writeReport(results, to: output)
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
            try? await DieterTaskSleep.milliseconds(400)
            let opened = NativeUIAccessibility.press("conversation.full-text", in: window)
            let fullText = await NativeUIAccessibility.wait {
                guard let sheet = window.attachedSheet else { return false }
                return nativeTextViews(in: sheet.contentView).contains {
                    $0.string == text.text && $0.isSelectable
                }
            }
            results["large-message-full-text"] =
                opened && fullText
                ? "passed"
                : "failed: complete message unavailable (open action=\(opened), sheet=\(window.attachedSheet != nil))"
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

            // Resolve the live control instead of assuming screen-sized coordinates.
            _ = NativeUIAccessibility.click("conversation.failure.view-log", in: window)
            _ = await NativeUIAccessibility.wait {
                NSApp.windows.contains { $0.isSheet && $0.isVisible && $0.contentLayoutRect.width >= 620 }
            }
            if let sheet = NSApp.windows.first(where: {
                $0.isSheet && $0.isVisible && $0.contentLayoutRect.width >= 620
            }) {
                results["turn-failure-log-action"] = "passed"
                capture(sheet, to: output.appending(path: "09-turn-failure-log.png"))
                sheet.sheetParent?.endSheet(sheet)
            } else {
                results["turn-failure-log-action"] = "failed: View log did not open the diagnostic sheet"
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

            snapshot = store.conversation ?? snapshot
            snapshot.conversation.messages.append(
                longTextMessage(
                    id: "message_streamed_growth_two",
                    prefix: "Second streamed model answer"
                ))
            snapshot.conversation.lastSeq += 1
            store.conversation = snapshot
            try? await DieterTaskSleep.milliseconds(800)
            let preservedReadingPosition =
                viewportConversationID == syntheticTailChatFixtureID
                && !viewportIsAtLatest
                && !viewportFollowsLatest
                && jumpToLatestVisible
            capture(window, to: output.appending(path: "07e-detached-stream-growth.png"))
            results["detached-stream-preserves-position"] =
                preservedReadingPosition
                ? "passed"
                : "failed: streamed growth forced a detached viewport back to the tail"
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
            let widths: [CGFloat] = scope == "card" ? [460, 320] : [originalWidth]
            let harness = store.harnessCatalog.harnesses.first { $0.id == store.composerProvider }
            let model = harness?.models.first { $0.id == store.composerModel }
            var identifiers = [
                "conversation.composer", "conversation.attach", "conversation.provider",
                "conversation.model", "conversation.stop", "conversation.send",
            ]
            if model?.efforts.isEmpty == false { identifiers.append("conversation.reasoning") }
            if !ProviderOptionValues.options(for: harness, model: store.composerModel).isEmpty {
                identifiers.append("conversation.provider-options")
            }

            for width in widths {
                if scope == "card" { setColumnWidth(width, split: split, column: column) }
                let resized = await NativeUIAccessibility.wait(timeout: 5) {
                    abs(column.frame.width - width) < 2
                }
                let settled = await waitForStableControl("conversation.composer-shell", in: window)
                let resultKey = "\(scope)-composer-layout-\(Int(width))"
                guard resized, settled,
                    let frame = NativeUIAccessibility.find("conversation.composer-shell", in: window)?.recordedFrame
                else {
                    results[resultKey] = "failed: requested width \(width), actual \(column.frame.width)"
                    continue
                }
                let columnFrame = window.convertToScreen(column.convert(column.bounds, to: nil))
                var failures: [String] = []
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
                }
                results[resultKey] = failures.isEmpty ? "passed" : "failed: " + failures.joined(separator: "; ")
                capture(window, to: output.appending(path: "07-\(scope)-composer-\(Int(width)).png"))
                await runAttachmentPopoverChecks(
                    window: window, prefix: "\(scope)-attachment-\(Int(width))", results: &results)
            }
            if scope == "card" {
                setColumnWidth(originalWidth, split: split, column: column)
                _ = await waitForStableControl("conversation.composer-shell", in: window)
            }
        }

        private static func conversationColumn(containing anchor: NSView) -> (NSSplitView, NSView)? {
            var ancestor = anchor.superview
            while let view = ancestor {
                if let split = view as? NSSplitView, split.isVertical,
                    let column = split.arrangedSubviews.first(where: { anchor.isDescendant(of: $0) })
                {
                    return (split, column)
                }
                ancestor = view.superview
            }
            return nil
        }

        private static func runBoardConversationOverlayChecks(
            store: DieterStore, window: NSWindow, results: inout [String: String], output: URL
        ) async {
            guard let shell = NativeUIAccessibility.find("conversation.composer-shell", in: window),
                let anchor = shell.object as? NSView,
                let (split, column) = conversationColumn(containing: anchor),
                let controller = split.delegate as? BoardConversationSplitController,
                let boardFrame = NativeUIAccessibility.find("board.canvas", in: window)?.recordedFrame
            else {
                results["board-conversation-native-resize"] = "failed: native overlay unavailable"
                return
            }
            let originalWidth = column.frame.width
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
            let targetWidth: CGFloat = originalWidth < 580 ? originalWidth + 80 : originalWidth - 80
            postDividerDrag(split: split, targetWidth: targetWidth, in: window)
            let resized = await NativeUIAccessibility.wait(timeout: 5) {
                abs(column.frame.width - targetWidth) < 2
            }
            let boardStayedFullWidth =
                NativeUIAccessibility.find("board.canvas", in: window)?.recordedFrame == boardFrame
            results["board-conversation-native-resize"] =
                resized && boardStayedFullWidth && store.composerText == draft
                ? "passed"
                : "failed: drag width=\(column.frame.width), expected=\(targetWidth), board unchanged=\(boardStayedFullWidth)"
            capture(window, to: output.appending(path: "07-card-conversation-resized.png"))

            let settled = await waitForStableControl("board.conversation-maximize", in: window)
            let expanded = settled && NativeUIAccessibility.click("board.conversation-maximize", in: window)
            let maximized = await NativeUIAccessibility.wait(timeout: 5) {
                controller.maximized && abs(column.frame.width - boardFrame.width) < 2
            }
            results["board-conversation-maximize"] =
                expanded && maximized && store.selectedCardID == selectedID && store.composerText == draft
                    && controller.conversationHost === host
                ? "passed"
                : "failed: expand=\(expanded), maximized=\(maximized), state=\(controller.maximized), collapsed=\(controller.splitViewItems.map(\.isCollapsed)), split=\(split.bounds), column=\(column.frame), board=\(boardFrame.width)"
            capture(window, to: output.appending(path: "07-card-conversation-maximized.png"))

            let restoreSettled = await waitForStableControl("board.conversation-maximize", in: window)
            let restoredClick = restoreSettled && NativeUIAccessibility.click("board.conversation-maximize", in: window)
            let restored = await NativeUIAccessibility.wait(timeout: 5) {
                !controller.maximized && abs(column.frame.width - targetWidth) < 2
            }
            results["board-conversation-restore"] =
                restoredClick && restored && store.selectedCardID == selectedID && store.composerText == draft
                    && controller.conversationHost === host
                ? "passed"
                : "failed: restore=\(restoredClick), settled=\(restored), maximized=\(controller.maximized), restored width=\(column.frame.width), expected=\(targetWidth), selection=\(store.selectedCardID == selectedID), draft=\(store.composerText == draft), host=\(controller.conversationHost === host)"
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

        private static func setColumnWidth(_ width: CGFloat, split: NSSplitView, column: NSView) {
            guard let index = split.arrangedSubviews.firstIndex(of: column) else { return }
            if index == split.arrangedSubviews.count - 1, index > 0 {
                let position = split.bounds.maxX - width
                split.setPosition(
                    split is BoardConversationSplitView ? position : position - split.dividerThickness,
                    ofDividerAt: index - 1)
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

            let clickedOutside = NativeUIAccessibility.click("conversation.composer", in: window)
            let dismissed = await NativeUIAccessibility.wait(timeout: 5) {
                !attachmentChoicesVisible(in: window)
            }
            let resettled = await waitForStableControl("conversation.attach", in: window)
            let reopened = dismissed && resettled && NativeUIAccessibility.click("conversation.attach", in: window)
            let choicesRestored = await NativeUIAccessibility.wait(timeout: 5) {
                attachmentChoicesVisible(in: window)
            }
            results["\(prefix)-source-popover-reopens"] =
                clickedOutside && dismissed && reopened && choicesRestored
                ? "passed"
                : "failed: outside click=\(clickedOutside), dismissed=\(dismissed), reopened=\(reopened), choices=\(choicesRestored)"
            _ = NativeUIAccessibility.click("conversation.composer", in: window)
            _ = await NativeUIAccessibility.wait(timeout: 5) { !attachmentChoicesVisible(in: window) }
        }

        private static func attachmentChoicesVisible(in window: NSWindow) -> Bool {
            ["conversation.attach.upload", "conversation.attach.capture"].allSatisfy { identifier in
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

            guard await openAttachmentUploadChoice(in: window) else {
                results["attachment-upload-picker"] = "failed: Upload choice unavailable"
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
            guard cancelled, await openAttachmentUploadChoice(in: window) else {
                results["attachment-upload-navigation"] = "failed: Upload choice did not reopen after cancellation"
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

        private static func openAttachmentUploadChoice(in window: NSWindow) async -> Bool {
            if attachmentChoicesVisible(in: window) {
                return await waitForStableControl("conversation.attach.upload", in: window)
            }
            guard await prepareComposerWindow(window),
                await waitForStableControl("conversation.attach", in: window),
                NativeUIAccessibility.click("conversation.attach", in: window),
                await NativeUIAccessibility.wait(timeout: 5, until: { attachmentChoicesVisible(in: window) })
            else { return false }
            return await waitForStableControl("conversation.attach.upload", in: window)
        }

        private static func prepareComposerWindow(_ window: NSWindow) async -> Bool {
            // App activation and sheet dismissal are asynchronous. A native
            // first click may only activate a window, so establish focus first.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return await NativeUIAccessibility.wait(timeout: 5) {
                NSApp.isActive && window.isKeyWindow && window.attachedSheet == nil
            }
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
            try? await DieterTaskSleep.milliseconds(500)
            _ = NativeUIAccessibility.click("conversation.composer", in: window)
            try? await DieterTaskSleep.milliseconds(300)
            progress(
                "paste check focused responder: \(String(describing: window.firstResponder))", in: output)
            pasteboard.clearContents()
            pasteboard.setString(pastedText, forType: .string)
            let before = store.composerAttachments.count
            postCommandV(window)
            try? await DieterTaskSleep.milliseconds(600)
            progress("paste check inserted \(store.composerText.count) characters", in: output)
            results["paste-text-passes-through"] =
                store.composerAttachments.count == before
                ? "passed"
                : "failed: text paste changed attachments"
            postCharacter(typedSuffix, keyCode: 7, in: window)
            try? await DieterTaskSleep.milliseconds(600)
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
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown,
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
            else { return }
            NSApp.postEvent(event, atStart: false)
        }

        private static func postCharacter(_ character: String, keyCode: UInt16, in window: NSWindow) {
            guard
                let event = NSEvent.keyEvent(
                    with: .keyDown,
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
            else { return }
            NSApp.postEvent(event, atStart: false)
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

        private static func postScrollUp(_ window: NSWindow) async {
            guard let content = window.contentView else { return }
            window.makeKeyAndOrderFront(nil)
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
            guard let scroll = candidates.max(by: { $0.contentSize.height < $1.contentSize.height }) else {
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
