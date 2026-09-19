import DieterAPI
import DieterCore
import Foundation

struct IOSConversationDraft {
    var text = ""
    var attachments: [Dieter_V1_MessagePart] = []
    var selection: Dieter_V1_HarnessSelection?

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }
}

struct IOSConversationActivityStep: Identifiable, Sendable {
    let id: String
    let messageID: String
    let part: Dieter_V1_MessagePart
}

struct IOSConversationPartGroup: Identifiable, Sendable {
    var steps: [IOSConversationActivityStep]
    let isActivity: Bool
    var id: String { steps[0].id }
}

struct IOSConversationTimelineItem: Identifiable, Sendable {
    var messages: [Dieter_V1_UiMessage]
    let isActivity: Bool
    let id: String

    var steps: [IOSConversationActivityStep] {
        messages.enumerated().flatMap { messageIndex, message in
            IOSConversationPresentation.steps(
                in: message,
                fallbackMessageID: "position:\(messageIndex)"
            )
        }
    }
}

struct IOSConversationActivitySummary: Equatable {
    let reasoning: Int
    let edits: Int
    let commands: Int
    let otherTools: Int

    init(steps: [IOSConversationActivityStep]) {
        var reasoning = 0
        var edits = 0
        var commands = 0
        var otherTools = 0
        for step in steps {
            if IOSConversationPresentation.isReasoning(step.part) {
                reasoning += 1
                continue
            }
            guard IOSConversationPresentation.isToolCall(step.part) else { continue }
            switch IOSConversationPresentation.toolCategory(step.part) {
            case .edit: edits += 1
            case .command: commands += 1
            case .other: otherTools += 1
            }
        }
        self.reasoning = reasoning
        self.edits = edits
        self.commands = commands
        self.otherTools = otherTools
    }

    var title: String {
        var labels: [String] = []
        if reasoning > 0 { labels.append("Reasoning") }
        if edits > 0 { labels.append("\(edits) edit\(edits == 1 ? "" : "s")") }
        if commands > 0 { labels.append("\(commands) command\(commands == 1 ? "" : "s")") }
        if otherTools > 0 { labels.append("\(otherTools) tool call\(otherTools == 1 ? "" : "s")") }
        return labels.isEmpty ? "Activity" : labels.joined(separator: " · ")
    }
}

enum IOSConversationPresentation {
    enum ToolCategory { case edit, command, other }

    private static let activeStatuses = Set(["starting", "running", "working", "streaming", "cancelling"])

    static func isAgentWorking(conversationStatus: String, cardRuntime: String) -> Bool {
        [conversationStatus, cardRuntime].contains {
            activeStatuses.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }

    static func turnStart(messages: [Dieter_V1_UiMessage], runtimeUpdatedAt: String) -> Date? {
        if let user = messages.last(where: { isUser($0) }),
            let metadata = try? JSONSerialization.jsonObject(with: user.metadataJson) as? [String: Any],
            let createdAt = metadata["createdAt"] as? String,
            let date = DieterTimestamp.date(from: createdAt)
        {
            return date
        }
        return DieterTimestamp.date(from: runtimeUpdatedAt)
    }

    static func timelineItems(_ messages: [Dieter_V1_UiMessage]) -> [IOSConversationTimelineItem] {
        var result: [IOSConversationTimelineItem] = []
        for (position, message) in messages.enumerated() {
            let steps = steps(in: message, fallbackMessageID: "position:\(position)")
            let activity =
                !isUser(message)
                && !steps.isEmpty
                && steps.allSatisfy { isRoutineActivity($0.part) }
            if activity, result.last?.isActivity == true {
                result[result.count - 1].messages.append(message)
            } else {
                let sourceID = message.id.isEmpty ? "position:\(position)" : message.id
                result.append(
                    IOSConversationTimelineItem(
                        messages: [message], isActivity: activity,
                        id: "\(activity ? "activity" : "message"):\(sourceID)"
                    ))
            }
        }
        return result
    }

    static func anchorItem(
        containing messageID: String,
        in items: [IOSConversationTimelineItem]
    ) -> String? {
        guard !messageID.isEmpty else { return nil }
        return items.first { item in item.messages.contains { $0.id == messageID } }?.id
    }

    static func partGroups(in message: Dieter_V1_UiMessage) -> [IOSConversationPartGroup] {
        var groups: [IOSConversationPartGroup] = []
        for step in steps(in: message, fallbackMessageID: "message") {
            let activity = isRoutineActivity(step.part)
            if activity, groups.last?.isActivity == true {
                groups[groups.count - 1].steps.append(step)
            } else {
                groups.append(IOSConversationPartGroup(steps: [step], isActivity: activity))
            }
        }
        return groups
    }

    static func steps(in message: Dieter_V1_UiMessage, fallbackMessageID: String) -> [IOSConversationActivityStep] {
        let sourceID = message.id.isEmpty ? fallbackMessageID : message.id
        return message.parts.enumerated().compactMap { index, part in
            guard isVisible(part) else { return nil }
            return IOSConversationActivityStep(
                id: "\(sourceID):part:\(index)", messageID: message.id, part: part)
        }
    }

    static func queuedDraft(for message: Dieter_V1_QueuedMessage) -> IOSConversationDraft {
        let textParts = message.parts.filter { $0.type.lowercased() == "text" }.map(\.text)
        let text = textParts.isEmpty ? message.text : textParts.joined()
        return IOSConversationDraft(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: message.parts.filter { $0.type.lowercased() != "text" },
            selection: message.hasSelection ? message.selection : nil
        )
    }

    static func attachmentIdentity(_ attachments: [Dieter_V1_MessagePart]) -> [String] {
        attachments.map {
            [$0.type, $0.mediaType, $0.filename, $0.url, $0.data.base64EncodedString()].joined(separator: "\u{0}")
        }
    }

    static func isReasoning(_ part: Dieter_V1_MessagePart) -> Bool {
        ["reasoning", "thinking"].contains(part.type.lowercased())
    }

    static func isToolCall(_ part: Dieter_V1_MessagePart) -> Bool {
        let type = part.type.lowercased()
        return ["tool", "tool_call", "dynamic-tool"].contains(type) || type.hasPrefix("tool-")
    }

    static func effectiveToolName(_ part: Dieter_V1_MessagePart) -> String {
        if !part.toolName.isEmpty { return part.toolName }
        if part.type.lowercased().hasPrefix("tool-") {
            return String(part.type.dropFirst("tool-".count))
        }
        return ""
    }

    static func needsAttention(_ part: Dieter_V1_MessagePart) -> Bool {
        let state = part.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let type = part.type.lowercased()
        return !part.errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || ["error", "failed", "failure", "denied", "rejected", "cancelled", "canceled"].contains(state)
            || ["error", "approval", "permission", "confirmation"].contains {
                state.contains($0) || type.contains($0)
            }
    }

    static func isRoutineActivity(_ part: Dieter_V1_MessagePart) -> Bool {
        !needsAttention(part) && (isReasoning(part) || isToolCall(part))
    }

    static func toolCategory(_ part: Dieter_V1_MessagePart) -> ToolCategory {
        let normalized =
            effectiveToolName(part)
            .lowercased()
            .split(whereSeparator: { $0 == "." || $0 == "/" })
            .last
            .map(String.init) ?? ""
        if ["edit", "apply_patch", "patch", "write_file", "multi_edit", "str_replace_editor"].contains(
            normalized)
        {
            return .edit
        }
        if ["bash", "shell", "command", "exec", "exec_command", "write_stdin", "terminal"].contains(
            normalized)
        {
            return .command
        }
        return .other
    }

    private static func isVisible(_ part: Dieter_V1_MessagePart) -> Bool {
        if isRoutineActivity(part) || needsAttention(part) { return true }
        switch part.type.lowercased() {
        case "step-start": return false
        case "image": return !part.url.isEmpty || !part.data.isEmpty
        case "file", "attachment": return true
        default:
            return !part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !part.filename.isEmpty
        }
    }

    private static func isUser(_ message: Dieter_V1_UiMessage) -> Bool {
        ["user", "human"].contains(message.role.lowercased())
    }
}

enum IOSConversationScrollBehavior {
    static let bottomID = "ios.conversation.bottom"
    private static let latestTolerance: CGFloat = 2
    static let jumpToLatestThreshold: CGFloat = 96

    static func isAtLatest(
        visibleMaxY: CGFloat,
        contentHeight: CGFloat,
        bottomInset: CGFloat = 0
    ) -> Bool {
        visibleMaxY - bottomInset >= contentHeight - latestTolerance
    }

    static func distanceFromLatest(
        visibleMaxY: CGFloat,
        contentHeight: CGFloat,
        bottomInset: CGFloat = 0
    ) -> CGFloat {
        max(0, contentHeight - (visibleMaxY - bottomInset))
    }

    static func shouldShowJumpToLatest(
        visibleMaxY: CGFloat,
        contentHeight: CGFloat,
        bottomInset: CGFloat = 0
    ) -> Bool {
        distanceFromLatest(
            visibleMaxY: visibleMaxY,
            contentHeight: contentHeight,
            bottomInset: bottomInset
        ) >= jumpToLatestThreshold
    }
}
