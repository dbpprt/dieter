import DieterAPI
import Foundation

struct ConversationMessagePartGroup {
    var parts: [Dieter_V1_MessagePart]
    let isToolCallGroup: Bool

    static func group(_ parts: [Dieter_V1_MessagePart], showReasoning: Bool = true) -> [ConversationMessagePartGroup] {
        var groups: [ConversationMessagePartGroup] = []
        for part in parts {
            if isHidden(part, showReasoning: showReasoning) { continue }
            let isToolCall = isToolCall(part)
            if isToolCall, groups.last?.isToolCallGroup == true {
                groups[groups.count - 1].parts.append(part)
            } else {
                groups.append(.init(parts: [part], isToolCallGroup: isToolCall))
            }
        }
        return groups
    }

    static func isToolCall(_ part: Dieter_V1_MessagePart) -> Bool {
        let type = part.type.lowercased()
        return toolTypes.contains(type) || type.hasPrefix("tool-")
    }

    // Hidden parts must not split adjacent tool calls into separate groups,
    // matching the Android timeline behavior.
    static func isHidden(_ part: Dieter_V1_MessagePart, showReasoning: Bool) -> Bool {
        if isToolCall(part) { return false }
        if ConversationTurnFailure.isFailurePart(part) { return true }
        switch part.type.lowercased() {
        case "reasoning", "thinking":
            return !showReasoning || part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case "step-start":
            return true
        case "image":
            return part.url.isEmpty && part.data.isEmpty
        case "file", "attachment":
            return false
        default:
            return part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static let toolTypes: Set<String> = ["tool", "tool_call", "dynamic-tool"]
}

extension Dieter_V1_MessagePart {
    // AI SDK static tool parts are typed "tool-<Name>" and may omit toolName.
    var effectiveToolName: String {
        if !toolName.isEmpty { return toolName }
        if type.lowercased().hasPrefix("tool-") { return String(type.dropFirst("tool-".count)) }
        return ""
    }
}
