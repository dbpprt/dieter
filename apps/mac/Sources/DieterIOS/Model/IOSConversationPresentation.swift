import DieterAPI
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
    enum Kind: Equatable, Sendable {
        case reasoning
        case tool
        case attention
        case content
    }

    let id: String
    let messageID: String
    let part: Dieter_V1_MessagePart
    let kind: Kind
    let toolName: String
    let needsAttention: Bool
}

struct IOSConversationPartGroup: Identifiable, Sendable {
    let id: String
    let steps: [IOSConversationActivityStep]
    let isActivity: Bool
    let summary: String
}

struct IOSConversationTimelineItem: Identifiable, Sendable {
    let messages: [Dieter_V1_UiMessage]
    let isActivity: Bool
    let id: String
    let groups: [IOSConversationPartGroup]
    let summary: String

    var steps: [IOSConversationActivityStep] { groups.flatMap(\.steps) }
}

/// Projects the canonical core messages into the compact native timeline.
/// The core owns transcript state; this is deliberately presentation-only.
enum IOSConversationPresentation {
    static func timelineItems(_ messages: [Dieter_V1_UiMessage]) -> [IOSConversationTimelineItem] {
        var result: [IOSConversationTimelineItem] = []
        for (messageIndex, message) in messages.enumerated() {
            let groups = partGroups(message, messageIndex: messageIndex)
            guard !groups.isEmpty || ["user", "human"].contains(message.role.lowercased()) else { continue }
            let activity =
                !groups.isEmpty && groups.allSatisfy(\.isActivity)
                && !["user", "human"].contains(message.role.lowercased())
            if activity, result.last?.isActivity == true {
                let previous = result.removeLast()
                let combinedGroups = previous.groups + groups
                result.append(
                    IOSConversationTimelineItem(
                        messages: previous.messages + [message], isActivity: true,
                        id: previous.id, groups: combinedGroups,
                        summary: summary(combinedGroups.flatMap(\.steps))))
            } else {
                let sourceID = message.id.isEmpty ? "position:\(messageIndex)" : message.id
                result.append(
                    IOSConversationTimelineItem(
                        messages: [message], isActivity: activity,
                        id: "\(activity ? "activity" : "message"):\(sourceID)", groups: groups,
                        summary: summary(groups.flatMap(\.steps))))
            }
        }
        return result
    }

    private static func partGroups(
        _ message: Dieter_V1_UiMessage, messageIndex: Int
    ) -> [IOSConversationPartGroup] {
        let sourceID = message.id.isEmpty ? "position:\(messageIndex)" : message.id
        var steps: [IOSConversationActivityStep] = []
        for (partIndex, part) in message.parts.enumerated() {
            guard isVisible(part) else { continue }
            let attention = needsAttention(part)
            let tool = isTool(part)
            let reasoning = ["reasoning", "thinking"].contains(part.type.lowercased())
            let kind: IOSConversationActivityStep.Kind =
                attention ? .attention : tool ? .tool : reasoning ? .reasoning : .content
            steps.append(
                IOSConversationActivityStep(
                    id: "\(sourceID):part:\(partIndex)", messageID: message.id, part: part,
                    kind: kind, toolName: effectiveToolName(part), needsAttention: attention))
        }
        var groups: [IOSConversationPartGroup] = []
        for step in steps {
            let activity = [.reasoning, .tool].contains(step.kind) && !step.needsAttention
            if activity, groups.last?.isActivity == true {
                let previous = groups.removeLast()
                let combined = previous.steps + [step]
                groups.append(
                    IOSConversationPartGroup(
                        id: previous.id, steps: combined, isActivity: true,
                        summary: summary(combined)))
            } else {
                groups.append(
                    IOSConversationPartGroup(
                        id: step.id, steps: [step], isActivity: activity,
                        summary: summary([step])))
            }
        }
        return groups
    }

    private static func isVisible(_ part: Dieter_V1_MessagePart) -> Bool {
        let type = part.type.lowercased()
        if type == "step-start" { return false }
        if isTool(part) || needsAttention(part) { return true }
        if ["file", "attachment"].contains(type) { return true }
        if type == "image" { return !part.url.isEmpty || !part.data.isEmpty }
        return !part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isTool(_ part: Dieter_V1_MessagePart) -> Bool {
        let type = part.type.lowercased()
        return ["tool", "tool_call", "tool-call", "dynamic-tool"].contains(type) || type.hasPrefix("tool-")
    }

    private static func effectiveToolName(_ part: Dieter_V1_MessagePart) -> String {
        if !part.toolName.isEmpty { return part.toolName }
        let type = part.type.lowercased()
        return type.hasPrefix("tool-") ? String(part.type.dropFirst("tool-".count)) : ""
    }

    private static func needsAttention(_ part: Dieter_V1_MessagePart) -> Bool {
        let state = part.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let type = part.type.lowercased()
        return !part.errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || ["error", "failed", "failure", "denied", "rejected", "cancelled", "canceled"].contains(state)
            || ["error", "approval", "permission", "confirmation"].contains {
                state.contains($0) || type.contains($0)
            }
    }

    private static func summary(_ steps: [IOSConversationActivityStep]) -> String {
        let reasoning = steps.filter { $0.kind == .reasoning }.count
        let tools = steps.filter { $0.kind == .tool }.map(\.toolName)
        var labels: [String] = []
        if reasoning > 0 { labels.append("Reasoning") }
        if !tools.isEmpty {
            let commands = tools.filter { ["exec_command", "bash", "shell"].contains($0.lowercased()) }.count
            let edits = tools.filter { $0.lowercased().contains("patch") || $0.lowercased().contains("edit") }.count
            let other = tools.count - commands - edits
            if commands > 0 { labels.append("\(commands) command\(commands == 1 ? "" : "s")") }
            if edits > 0 { labels.append("\(edits) edit\(edits == 1 ? "" : "s")") }
            if other > 0 { labels.append("\(other) tool\(other == 1 ? "" : "s")") }
        }
        return labels.isEmpty ? "Activity" : labels.joined(separator: " · ")
    }

    static func anchorItem(
        containing messageID: String,
        in items: [IOSConversationTimelineItem]
    ) -> String? {
        guard !messageID.isEmpty else { return nil }
        return items.first { item in item.messages.contains { $0.id == messageID } }?.id
    }

    static func queuedDraft(for message: Dieter_V1_QueuedMessage) -> IOSConversationDraft {
        let textParts = message.parts.filter { $0.type.lowercased() == "text" }.map(\.text)
        let text = textParts.isEmpty ? message.text : textParts.joined()
        return IOSConversationDraft(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: message.parts.filter { $0.type.lowercased() != "text" },
            selection: message.hasSelection ? message.selection : nil)
    }

    static func attachmentIdentity(_ attachments: [Dieter_V1_MessagePart]) -> [String] {
        attachments.map {
            [$0.type, $0.mediaType, $0.filename, $0.url, $0.data.base64EncodedString()]
                .joined(separator: "\u{0}")
        }
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
            bottomInset: bottomInset) >= jumpToLatestThreshold
    }
}
