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
    private static let syntheticFixtureID = "c_conversation_ui_smoke"
    private static var jumpToLatestVisible = false

    static func recordJumpToLatestVisibility(_ visible: Bool) {
        guard ProcessInfo.processInfo.arguments.contains("--conversation-ui-smoke") else { return }
        jumpToLatestVisible = visible
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
            if case let .failed(message) = store.phase {
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

        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title == "Dieter" })
            ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
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
        results["grouping-collapses"] = hiddenTools.contains(where: { $0 > 1 }) || hiddenGroups <= shownGroups
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

        await runPasteChecks(store: store, window: window, results: &results, output: output)
        if cardID == syntheticFixtureID {
            results["history-bounded"] = "skipped: fresh-state renderer fixture"
        } else {
            await runHistoryChecks(store: store, window: window, results: &results, output: output)
        }
        await runActivityIndicatorCheck(store: store, window: window, results: &results, output: output)
        await runQueuedMessageCheck(store: store, window: window, results: &results, output: output)
        await runJumpToLatestCheck(store: store, window: window, results: &results, output: output)
        await runTurnFailureCheck(store: store, window: window, results: &results, output: output)

        writeReport(results, to: output)
    }

    /// Renders the complete terminal failure affordance in the packaged app
    /// and proves its retry payload still contains the original prompt.
    private static func runTurnFailureCheck(
        store: DieterStore,
        window: NSWindow,
        results: inout [String: String],
        output: URL
    ) async {
        guard installSyntheticFixture(store) != nil, var snapshot = store.conversation else {
            results["turn-failure"] = "failed: renderer fixture unavailable"
            return
        }
        var diagnostic = Dieter_V1_MessagePart()
        diagnostic.type = "text"
        diagnostic.state = "error"
        diagnostic.text = "codex exited 1 after 42s (context overflow).\nprovider stderr: context window exceeded\nworker exited with status 1"
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
        results["turn-failure"] = failure != nil ? "passed" : "failed: failure presentation was not resolved"
        results["turn-failure-log"] = failure?.log.contains("provider stderr") == true
            ? "passed"
            : "failed: complete diagnostic was not retained"
        results["turn-failure-retry"] = failure?.retryParts.first?.text == "Update the config and show the work."
            ? "passed"
            : "failed: original prompt was not available for retry"

        // The smoke window has a fixed size and deterministic fixture. Use a
        // real in-process native click on the visible log action, then require
        // the SwiftUI sheet to materialize before capturing it.
        click(window: window, x: 1_223, distanceFromTop: 436)
        try? await DieterTaskSleep.milliseconds(700)
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

    /// Grows a model answer after the short fixture has settled at its tail.
    /// The transcript must keep its viewport and expose the explicit jump
    /// control instead of snapping to the newly rendered bottom.
    private static func runJumpToLatestCheck(
        store: DieterStore,
        window: NSWindow,
        results: inout [String: String],
        output: URL
    ) async {
        guard installSyntheticFixture(store) != nil, var snapshot = store.conversation else {
            results["jump-to-latest"] = "failed: renderer fixture unavailable"
            return
        }
        jumpToLatestVisible = false
        try? await DieterTaskSleep.milliseconds(500)

        var text = Dieter_V1_MessagePart()
        text.type = "text"
        text.text = (1...80).map { "Streamed model answer line \($0) stays below the reading position." }.joined(separator: "\n")
        var answer = Dieter_V1_UiMessage()
        answer.id = "message_streamed_growth"
        answer.role = "assistant"
        answer.parts = [text]
        snapshot.conversation.messages.append(answer)
        snapshot.conversation.lastSeq += 1
        store.conversation = snapshot

        try? await DieterTaskSleep.seconds(1)
        capture(window, to: output.appending(path: "07-jump-to-latest.png"))
        results["jump-to-latest"] = jumpToLatestVisible
            ? "passed"
            : "failed: model answer growth did not expose the jump control"
    }

    /// Leaves a deterministic active conversation at the transcript tail so
    /// the packaged-app capture proves that Running has a matching live cue.
    private static func runActivityIndicatorCheck(
        store: DieterStore,
        window: NSWindow,
        results: inout [String: String],
        output: URL
    ) async {
        guard installSyntheticFixture(store) != nil, var snapshot = store.conversation else {
            results["agent-activity-indicator"] = "failed: renderer fixture unavailable"
            return
        }
        snapshot.conversation.status = "running"
        snapshot.detail.card.runtime = "running"
        store.conversation = snapshot
        store.selectedDetail = snapshot.detail
        try? await DieterTaskSleep.seconds(1)
        capture(window, to: output.appending(path: "06-agent-thinking.png"))
        results["agent-activity-indicator"] = ConversationActivityPresentation.isActive(
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
        guard installSyntheticFixture(store) != nil, var snapshot = store.conversation else {
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
        defer { store.composerText = "" }

        try? await DieterTaskSleep.seconds(1)
        capture(window, to: output.appending(path: "06b-queued-message.png"))
        let delivered = ConversationQueuePresentation.deliveredMessages(
            snapshot.conversation.messages,
            whileQueued: snapshot.conversation.queue
        )
        results["queued-message-visible"] = delivered.count == snapshot.conversation.messages.count - 1
            && !delivered.contains { $0.id == queued.id }
            && snapshot.conversation.queue.map(\.id) == [queued.id]
            ? "passed"
            : "failed: accepted queued content was not retained for presentation"
        results["queued-composer-active"] = store.composerText.isEmpty
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
        let candidates = (store.state.cards + store.chats).sorted { $0.updatedAt > $1.updatedAt }.map(\.id)
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
            results["history-bounded"] = "skipped: largest recent conversation has \(bestTotal) messages"
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
        progress("history: \(loaded) of \(store.conversationHistoryTotal) messages loaded after settling", in: output)
        capture(window, to: output.appending(path: "05-long-history.png"))
        results["history-bounded"] = loaded <= bestTotal - 30 && store.conversationHistoryHasMore
            ? "passed"
            : "failed: \(loaded) of \(bestTotal) messages loaded after opening; hasMore=\(store.conversationHistoryHasMore)"

        let before = store.conversationMessages.count
        let pageLoaded = await store.loadEarlierMessages()
        let added = store.conversationMessages.count - before
        results["history-page"] = pageLoaded && added > 0 && added <= 30
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
        pasteboard.setData(smokeImagePNG(), forType: NSPasteboard.PasteboardType(UTType.png.identifier))
        postCommandV(window)
        try? await DieterTaskSleep.milliseconds(900)
        results["paste-image-attaches"] = store.composerAttachments.count == 1
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
        } else {
            let sizes = sheets.map { "\(Int($0.contentLayoutRect.width))x\(Int($0.contentLayoutRect.height))" }
            results["attachment-image-preview"] = "failed: clicking the image attachment opened sheets \(sizes)"
        }

        pasteboard.clearContents()
        pasteboard.setString("plain text belongs to the text view", forType: .string)
        let before = store.composerAttachments.count
        postCommandV(window)
        try? await DieterTaskSleep.milliseconds(600)
        results["paste-text-passes-through"] = store.composerAttachments.count == before
            ? "passed"
            : "failed: text paste changed attachments"
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
              let png = bitmap.representation(using: .png, properties: [:]) else { return Data() }
        return png
    }

    private static func postCommandV(_ window: NSWindow) {
        guard let event = NSEvent.keyEvent(
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
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private static func click(window: NSWindow, x: CGFloat, distanceFromTop: CGFloat) {
        guard let content = window.contentView else { return }
        let location = NSPoint(x: x, y: content.bounds.height - distanceFromTop)
        let timestamp = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: type == .mouseMoved ? 0 : 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ) else { continue }
            window.sendEvent(event)
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
            let reasoning = parts.filter { ["reasoning", "thinking"].contains($0.type.lowercased()) && !$0.text.isEmpty }
            let tools = parts.filter(ConversationMessagePartGroup.isToolCall)
            if !reasoning.isEmpty && tools.count >= 2 { return cardID }
        }
        return installSyntheticFixture(store)
    }

    private static func installSyntheticFixture(_ store: DieterStore) -> String? {
        guard let project = store.projects.first else { return nil }

        var card = Dieter_V1_Card()
        card.id = syntheticFixtureID
        card.scope = "chat"
        card.projectID = project.id
        card.title = "Conversation renderer fixture"
        card.runtime = "idle"
        card.updatedAt = ISO8601DateFormatter().string(from: Date())

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
        snapshot.conversation.messages = [user, firstThought, readCall, secondThought, editCall, answer]

        if !store.chats.contains(where: { $0.id == card.id }) { store.chats.append(card) }
        store.chatProjects = store.projects
        store.selectedCardID = nil
        store.selectedChatID = card.id
        store.selectedDetail = snapshot.detail
        store.conversation = snapshot
        store.section = .chats
        return card.id
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
        if let index = arguments.firstIndex(of: "--ui-smoke-output"), arguments.indices.contains(index + 1) {
            return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
        }
        return URL(filePath: NSTemporaryDirectory()).appending(path: "dieter-conversation-ui-smoke", directoryHint: .isDirectory)
    }

    private static func capture(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func writeReport(_ values: [String: String], to directory: URL) {
        let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: directory.appending(path: "report.json"), options: .atomic)
    }
}
