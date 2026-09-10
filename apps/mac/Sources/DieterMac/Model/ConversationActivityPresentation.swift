import DieterAPI
import Foundation

/// Describes activity the provider actually reported. It never fetches tool
/// payloads or derives a new summary from the conversation's prose.
enum ConversationActivityPresentation {
    private static let activeStatuses = Set(["starting", "running", "working", "streaming", "cancelling"])
    private static let runningToolStates = Set(["input-available", "running", "executing"])

    static func isActive(conversationStatus: String, cardRuntime: String) -> Bool {
        activeStatuses.contains(normalized(conversationStatus)) || activeStatuses.contains(normalized(cardRuntime))
    }

    static func turnStart(messages: [Dieter_V1_UiMessage], runtimeUpdatedAt: String) -> Date? {
        if let user = messages.last(where: { isUser($0) }),
            let metadata = try? JSONSerialization.jsonObject(with: user.metadataJson) as? [String: Any],
            let value = metadata["createdAt"] as? String,
            let date = DieterTimestamp.date(from: value)
        {
            return date
        }
        return DieterTimestamp.date(from: runtimeUpdatedAt)
    }

    static func liveLabel(
        messages: [Dieter_V1_UiMessage], pendingTools: [Dieter_V1_PendingTool], plans: [Dieter_V1_TaskPlan],
        showReasoning: Bool = true, conversationStatus: String = "", cardRuntime: String = ""
    ) -> String {
        if [conversationStatus, cardRuntime].contains(where: { normalized($0) == "cancelling" }) {
            return "Stopping…"
        }

        // The caller supplies the live snapshot, never an earlier history page
        // or queued composer messages. Previous turns can retain unfinished tools
        // and plans after an interruption; they must not describe this turn.
        let start = messages.lastIndex(where: { isUser($0) }).map { $0 + 1 } ?? messages.startIndex
        let assistants = messages[start...].filter { normalized($0.role) == "assistant" }
        let parts = assistants.flatMap(\.parts)
        let tools = parts.filter { ConversationMessagePartGroup.isToolCall($0) }
        if let approval = tools.last(where: { normalized($0.state) == "approval-requested" }) {
            return "Waiting for approval: \(toolTitle(approval.effectiveToolName))"
        }
        let running = tools.filter {
            runningToolStates.contains(normalized($0.state)) && !$0.hasOutput_p && $0.errorText.isEmpty
        }
        if let tool = running.last {
            let title = toolLabel(name: tool.effectiveToolName, input: tool.inputJson, preview: tool.inputPreview)
            return running.count > 1
                ? "\(title) · +\(running.count - 1) \(running.count == 2 ? "tool" : "tools")" : title
        }
        // Retain compatibility with providers that use the pending-tool list,
        // but never revive a tool whose terminal result is already in the turn.
        let finishedIDs = Set(tools.filter { !runningToolStates.contains(normalized($0.state)) }.map(\.toolCallID))
        if let tool = pendingTools.last(where: { $0.toolCallID.isEmpty || !finishedIDs.contains($0.toolCallID) }) {
            return toolLabel(name: tool.toolName, input: tool.inputJson, preview: tool.inputPreview)
        }

        let latest = parts.last { normalized($0.type) != "step-start" }
        if let latest {
            if normalized(latest.type) == "text", normalized(latest.state) == "streaming" {
                return "Writing response…"
            }
            if showReasoning, ConversationActivityGrouping.isReasoning(latest),
                let summary = reasoningSummary(latest.text)
            {
                return summary
            }
        }
        let currentMessageIDs = Set(assistants.map(\.id).filter { !$0.isEmpty })
        if let plan = plans.last(where: { currentMessageIDs.contains($0.messageID) && normalized($0.state) == "active" }
        ),
            let task = plan.phases.flatMap(\.tasks).first(where: { normalized($0.status) == "in_progress" })
        {
            let detail = task.activeForm.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = compact(detail.isEmpty ? task.content : detail)
            if !title.isEmpty { return title }
        }
        if [conversationStatus, cardRuntime].contains(where: { normalized($0) == "starting" }), parts.isEmpty {
            return "Starting agent…"
        }
        return "Thinking…"
    }

    private static func toolLabel(name: String, input: Data, preview: String) -> String {
        // Snapshot payloads are deliberately omitted. inputPreview may be a
        // preferred plain-text field or bounded JSON, not necessarily full JSON.
        let data = input.isEmpty ? Data(preview.utf8) : input
        let fields =
            data.count <= 16_384
            ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] : nil
        if let description = fields?["description"] as? String, !compact(description).isEmpty {
            return compact(description)
        }
        let leaf = normalized(name).components(separatedBy: "__").last ?? normalized(name)
        let kind = leaf.split(whereSeparator: { $0 == "." || $0 == "/" }).last.map(String.init) ?? leaf
        let keys: [String]
        let action: String
        switch kind {
        case "read", "read_file", "readfile":
            action = "Reading"; keys = ["path", "file_path", "filePath"]
        case "edit", "write", "write_file", "edit_file", "multiedit", "multi_edit", "apply_patch", "patch":
            action = "Editing"; keys = ["path", "file_path", "filePath"]
        case "bash", "shell", "command", "exec", "exec_command", "terminal":
            action = "Running"; keys = ["command", "cmd", "argv"]
        case "grep", "glob", "search", "websearch", "web_search":
            action = "Searching"; keys = ["query", "pattern"]
        case "webfetch", "web_fetch", "fetch":
            action = "Fetching"; keys = ["url"]
        case "write_stdin", "wait":
            return "Waiting for command…"
        default:
            return "Using \(toolTitle(name))…"
        }
        var target = ""
        for key in keys {
            if let value = fields?[key] as? String { target = value; break }
            if let values = fields?[key] as? [String] { target = values.joined(separator: " "); break }
        }
        if fields == nil, !preview.hasPrefix("{"), !preview.hasPrefix("["), !preview.hasPrefix("*** Begin Patch") {
            target = preview
        }
        if action == "Reading" || action == "Editing", !target.isEmpty {
            target = (target as NSString).lastPathComponent
        }
        let detail = compact(target)
        if !detail.isEmpty { return compact("\(action) \(detail)") }
        switch action {
        case "Reading": return "Reading file…"
        case "Editing": return "Editing files…"
        case "Running": return "Running command…"
        case "Fetching": return "Fetching page…"
        default: return "Searching…"
        }
    }

    private static func toolTitle(_ name: String) -> String {
        let leaf = name.components(separatedBy: "__").last ?? name
        let title = compact(leaf.replacingOccurrences(of: "_", with: " "))
        return title.isEmpty ? "tool" : title
    }

    private static func reasoningSummary(_ text: String) -> String? {
        // Codex includes its short activity headings in the reasoning stream.
        // Adjacent chunks can be coalesced, so use the last complete heading.
        // Bound the work even for long reasoning; never show an unfinished **.
        let lines = text.suffix(4_096).split(whereSeparator: \.isNewline)
        for line in lines.reversed() {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("**"), let end = value.dropFirst(2).range(of: "**") {
                let heading = compact(String(value[value.index(value.startIndex, offsetBy: 2)..<end.lowerBound]))
                if !heading.isEmpty { return heading }
            }
            let hashes = value.prefix(while: { $0 == "#" }).count
            if (1...6).contains(hashes), value.dropFirst(hashes).first == " " {
                let heading = compact(
                    String(value.dropFirst(hashes)).trimmingCharacters(in: CharacterSet(charactersIn: " #")))
                if !heading.isEmpty { return heading }
            }
        }
        // Some providers emit a plain, short activity summary without Markdown.
        // Long paragraphs stay in the transcript instead of filling the badge.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120, !trimmed.contains("\n"), !trimmed.hasPrefix("*") else {
            return nil
        }
        return compact(trimmed)
    }

    private static func compact(_ value: String) -> String {
        let text = value.prefix(1_024).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.count > 120 ? String(text.prefix(119)) + "…" : text
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isUser(_ message: Dieter_V1_UiMessage) -> Bool {
        ["user", "human"].contains(normalized(message.role))
    }
}
