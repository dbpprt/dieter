import DieterAPI
import Foundation

struct ConversationToolCall: Identifiable, Sendable {
    let messageID: String
    let part: Dieter_V1_MessagePart

    var id: String {
        if !part.toolCallID.isEmpty { return "\(messageID):\(part.toolCallID)" }
        return "\(messageID):\(part.toolName):\(part.payloadRevision)"
    }
}

struct ConversationTimelineItem: Identifiable, Sendable {
    var messages: [Dieter_V1_UiMessage]
    let isToolCallGroup: Bool
    let id: String

    var toolCalls: [ConversationToolCall] {
        messages.flatMap { message in
            message.parts.filter(ConversationMessagePartGroup.isToolCall).map {
                ConversationToolCall(messageID: message.id, part: $0)
            }
        }
    }

    static func group(_ messages: [Dieter_V1_UiMessage], showReasoning: Bool = true) -> [ConversationTimelineItem] {
        var result: [ConversationTimelineItem] = []
        for (position, message) in messages.enumerated() {
            let toolOnly = message.role.lowercased() != "user" &&
                message.parts.contains(where: ConversationMessagePartGroup.isToolCall) &&
                message.parts.allSatisfy { part in
                    ConversationMessagePartGroup.isToolCall(part) ||
                        ConversationMessagePartGroup.isHidden(part, showReasoning: showReasoning) ||
                        (part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                            part.data.isEmpty && part.url.isEmpty && part.filename.isEmpty)
                }
            if toolOnly, result.last?.isToolCallGroup == true {
                result[result.count - 1].messages.append(message)
            } else {
                let prefix = toolOnly ? "tools" : "message"
                let sourceID = message.id.isEmpty ? "position:\(position)" : message.id
                result.append(.init(
                    messages: [message],
                    isToolCallGroup: toolOnly,
                    id: "\(prefix):\(sourceID)"
                ))
            }
        }
        return result
    }
}

struct ConversationTimelineMessageDetails: Identifiable, Sendable {
    let id: String
    let plans: [Dieter_V1_TaskPlan]
    let subagents: [Dieter_V1_Subagent]
}

struct ConversationTimelineRowContent: Identifiable, Sendable {
    let item: ConversationTimelineItem
    let details: [ConversationTimelineMessageDetails]

    var id: String { item.id }
}

struct ConversationTimelineProjection: Sendable {
    let items: [ConversationTimelineItem]
    let rows: [ConversationTimelineRowContent]
    let unattachedPlans: [Dieter_V1_TaskPlan]

    static let empty = ConversationTimelineProjection(items: [], rows: [], unattachedPlans: [])

    static func build(
        messages: [Dieter_V1_UiMessage],
        allMessageIDs: Set<String>,
        plans: [Dieter_V1_TaskPlan],
        subagents: [Dieter_V1_Subagent],
        queue: [Dieter_V1_QueuedMessage],
        showReasoning: Bool
    ) -> ConversationTimelineProjection {
        MacPerformanceSignposts.measure("Conversation projection", log: MacPerformanceSignposts.projection) {
        let structuredMessageIDs = Set(plans.map(\.messageID) + subagents.map(\.messageID))
        let visibleMessages = ConversationQueuePresentation.deliveredMessages(
            messages,
            whileQueued: queue
        ).filter { message in
            ["user", "human"].contains(message.role.lowercased()) ||
                structuredMessageIDs.contains(message.id) ||
                message.parts.contains {
                    !ConversationMessagePartGroup.isHidden($0, showReasoning: showReasoning)
                }
        }
        let items = ConversationTimelineItem.group(visibleMessages, showReasoning: showReasoning)
        let plansByMessage = Dictionary(grouping: plans, by: \.messageID)
        let subagentsByMessage = Dictionary(grouping: subagents, by: \.messageID)
        let rows = items.map { item in
            ConversationTimelineRowContent(
                item: item,
                details: item.messages.enumerated().map { index, message in
                    ConversationTimelineMessageDetails(
                        id: message.id.isEmpty ? "\(item.id):\(index)" : message.id,
                        plans: plansByMessage[message.id] ?? [],
                        subagents: subagentsByMessage[message.id] ?? []
                    )
                }
            )
        }
        return ConversationTimelineProjection(
            items: items,
            rows: rows,
            unattachedPlans: plans.filter {
                !$0.messageID.isEmpty && !allMessageIDs.contains($0.messageID)
            }
        )
        }
    }
}

struct ConversationPresentationKey: Hashable {
    let revision: Int
    let showReasoning: Bool
    let renderStart: Int
    let renderCount: Int
}

enum ConversationRenderWindow {
    static let maximumMessages = 180

    static func range(messageCount: Int, requestedStart: Int?) -> Range<Int> {
        guard messageCount > maximumMessages else { return 0..<messageCount }
        if let requestedStart {
            let start = min(max(0, requestedStart), messageCount - maximumMessages)
            return start..<(start + maximumMessages)
        }
        return (messageCount - maximumMessages)..<messageCount
    }
}
