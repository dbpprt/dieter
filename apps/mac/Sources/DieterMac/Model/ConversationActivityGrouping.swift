import DieterAPI
import Foundation

/// Only routine agent activity belongs behind the compact disclosure. Prose,
/// attachments, diagnostics, and requests for a decision remain in the timeline.
enum ConversationActivityGrouping {
    static func needsAttention(_ part: Dieter_V1_MessagePart) -> Bool {
        let state = part.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let type = part.type.lowercased()
        return !part.errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || ["error", "failed", "failure", "denied", "rejected", "cancelled", "canceled"].contains(state)
            || ["error", "approval", "permission", "confirmation"].contains { state.contains($0) || type.contains($0) }
    }

    static func isReasoning(_ part: Dieter_V1_MessagePart) -> Bool {
        ["reasoning", "thinking"].contains(part.type.lowercased())
    }

    static func isActivity(_ part: Dieter_V1_MessagePart) -> Bool {
        !needsAttention(part) && (isReasoning(part) || ConversationMessagePartGroup.isToolCall(part))
    }

    static func isVisible(_ part: Dieter_V1_MessagePart, showReasoning: Bool) -> Bool {
        needsAttention(part) || !ConversationMessagePartGroup.isHidden(part, showReasoning: showReasoning)
    }
}

struct ConversationActivityStep: Identifiable, Sendable {
    let id: String
    let messageID: String
    var part: Dieter_V1_MessagePart

    static func steps(messages: [Dieter_V1_UiMessage], showReasoning: Bool) -> [Self] {
        messages.enumerated().flatMap { messageIndex, message in
            let sourceID = message.id.isEmpty ? "position:\(messageIndex)" : message.id
            // Keep original part positions in IDs: toggling reasoning or a tool's
            // live state must not attach disclosure state to a different step.
            var result: [Self] = []
            for (partIndex, part) in message.parts.enumerated() {
                guard ConversationActivityGrouping.isVisible(part, showReasoning: showReasoning) else { continue }
                if part.type.lowercased() == "text", result.last?.part.type.lowercased() == "text",
                    !ConversationActivityGrouping.needsAttention(part),
                    !ConversationActivityGrouping.needsAttention(result[result.count - 1].part)
                {
                    result[result.count - 1].part.text += "\n\n" + part.text
                } else {
                    result.append(Self(id: "\(sourceID):part:\(partIndex)", messageID: message.id, part: part))
                }
            }
            return result
        }
    }
}

struct ConversationActivityPartGroup: Identifiable, Sendable {
    var steps: [ConversationActivityStep]
    let isActivity: Bool
    var id: String { steps[0].id }

    static func group(_ steps: [ConversationActivityStep]) -> [Self] {
        var groups: [Self] = []
        for step in steps {
            let activity = ConversationActivityGrouping.isActivity(step.part)
            if activity, groups.last?.isActivity == true {
                groups[groups.count - 1].steps.append(step)
            } else {
                groups.append(Self(steps: [step], isActivity: activity))
            }
        }
        return groups
    }
}

struct ConversationActivitySummary: Equatable {
    let reasoningCount: Int
    let tools: ToolCallGroupSummary

    init(steps: [ConversationActivityStep]) {
        reasoningCount = steps.filter { ConversationActivityGrouping.isReasoning($0.part) }.count
        tools = ToolCallGroupSummary(
            toolNames: steps.filter {
                ConversationMessagePartGroup.isToolCall($0.part)
            }.map(\.part.effectiveToolName))
    }

    var title: String {
        var labels: [String] = []
        if reasoningCount > 0 { labels.append("Reasoning") }
        if tools.edits + tools.commands + tools.otherTools > 0 {
            labels.append(tools.title.replacingOccurrences(of: ", ", with: " · "))
        }
        return labels.isEmpty ? "Activity" : labels.joined(separator: " · ")
    }
}

struct ConversationTimelineDisplayGroup: Identifiable, Sendable {
    var rows: [ConversationTimelineRowContent]
    let isActivity: Bool
    var id: String { rows[0].id }

    static func group(_ rows: [ConversationTimelineRowContent], showReasoning: Bool) -> [Self] {
        var groups: [Self] = []
        for row in rows {
            let steps = ConversationActivityStep.steps(messages: row.item.messages, showReasoning: showReasoning)
            let activity =
                !steps.isEmpty
                && row.item.messages.allSatisfy { !["user", "human"].contains($0.role.lowercased()) }
                && row.details.allSatisfy { $0.plans.isEmpty && $0.subagents.isEmpty }
                && steps.allSatisfy { ConversationActivityGrouping.isActivity($0.part) }
            if activity, groups.last?.isActivity == true {
                groups[groups.count - 1].rows.append(row)
            } else {
                groups.append(Self(rows: [row], isActivity: activity))
            }
        }
        return groups
    }
}
