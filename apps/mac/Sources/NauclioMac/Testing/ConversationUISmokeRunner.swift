import AppKit
import Foundation
import NauclioAPI

/// An in-process smoke driver for the conversation transcript.
///
/// It opens a real conversation that contains reasoning and tool parts, then
/// toggles the reasoning visibility the way the composer brain chip does and
/// records the timeline grouping before and after. The run proves that hiding
/// reasoning collapses adjacent tool calls into one group and that the toggle
/// cannot take the app down.
@MainActor
enum ConversationUISmokeRunner {
    static func run(store: NauclioStore) async {
        let output = outputDirectory()
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        var results: [String: String] = [:]
        var waited = 0
        progress("runner started, phase \(store.phase.label)", in: output)
        while !store.phase.isConnected && waited < 30 {
            try? await NauclioTaskSleep.seconds(1)
            waited += 1
        }
        progress("wait finished after \(waited)s, phase \(store.phase.label)", in: output)
        guard store.phase.isConnected else {
            results["connection"] = "failed: daemon connection did not become ready"
            writeReport(results, to: output)
            return
        }
        try? await NauclioTaskSleep.seconds(2)

        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title == "Nauclio" })
            ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            writeReport(["window": "failed: Nauclio window not found"], to: output)
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
        try? await NauclioTaskSleep.seconds(1)

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
        try? await NauclioTaskSleep.seconds(1)
        capture(window, to: output.appending(path: "01-reasoning-on.png"))

        store.showReasoning = false
        try? await NauclioTaskSleep.seconds(1)
        capture(window, to: output.appending(path: "02-reasoning-off.png"))

        store.showReasoning = true
        try? await NauclioTaskSleep.milliseconds(400)
        store.showReasoning = false
        try? await NauclioTaskSleep.milliseconds(400)
        store.showReasoning = true
        try? await NauclioTaskSleep.seconds(1)
        capture(window, to: output.appending(path: "03-reasoning-on-again.png"))
        results["reasoning-toggle"] = "passed"

        writeReport(results, to: output)
    }

    /// Opens recently updated conversations until one contains both reasoning
    /// and tool parts, preferring the transcript a person would have open.
    private static func openConversationWithReasoningAndTools(_ store: NauclioStore) async -> String? {
        let candidates = (store.state.cards + store.chats)
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(\.id)
        for cardID in candidates.prefix(12) {
            progress("opening \(cardID)", in: outputDirectory())
            await store.openConversation(cardID: cardID)
            var waited = 0
            while store.conversationLoading && waited < 20 {
                try? await NauclioTaskSleep.milliseconds(500)
                waited += 1
            }
            let parts = (store.conversation?.conversation.messages ?? []).flatMap(\.parts)
            let reasoning = parts.filter { ["reasoning", "thinking"].contains($0.type.lowercased()) && !$0.text.isEmpty }
            let tools = parts.filter(ConversationMessagePartGroup.isToolCall)
            if !reasoning.isEmpty && tools.count >= 2 { return cardID }
        }
        return nil
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
        return URL(filePath: NSTemporaryDirectory()).appending(path: "nauclio-conversation-ui-smoke", directoryHint: .isDirectory)
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
