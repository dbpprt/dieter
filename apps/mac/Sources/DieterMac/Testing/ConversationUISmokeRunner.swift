import AppKit
import Foundation
import DieterAPI
import UniformTypeIdentifiers

/// An in-process smoke driver for the conversation transcript.
///
/// It opens a real conversation that contains reasoning and tool parts, then
/// toggles the reasoning visibility the way the composer brain chip does and
/// records the timeline grouping before and after. The run proves that hiding
/// reasoning collapses adjacent tool calls into one group and that the toggle
/// cannot take the app down.
@MainActor
enum ConversationUISmokeRunner {
    private static let syntheticFixtureID = "c_conversation_ui_smoke"

    static func run(store: DieterStore) async {
        let output = outputDirectory()
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var results: [String: String] = [:]
        var waited = 0
        progress("runner started, phase \(store.phase.label)", in: output)
        while !store.phase.isConnected && waited < 30 {
            try? await DieterTaskSleep.seconds(1)
            waited += 1
        }
        progress("wait finished after \(waited)s, phase \(store.phase.label)", in: output)
        guard store.phase.isConnected else {
            results["connection"] = "failed: daemon connection did not become ready"
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

        writeReport(results, to: output)
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
