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
            let toolOnly =
                message.role.lowercased() != "user"
                && message.parts.contains(where: ConversationMessagePartGroup.isToolCall)
                && message.parts.allSatisfy { part in
                    ConversationMessagePartGroup.isToolCall(part)
                        || ConversationMessagePartGroup.isHidden(part, showReasoning: showReasoning)
                        || (part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && part.data.isEmpty
                            && part.url.isEmpty && part.filename.isEmpty)
                }
            if toolOnly, result.last?.isToolCallGroup == true {
                result[result.count - 1].messages.append(message)
            } else {
                let prefix = toolOnly ? "tools" : "message"
                let sourceID = message.id.isEmpty ? "position:\(position)" : message.id
                result.append(
                    .init(
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
    let displayGroups: [ConversationTimelineDisplayGroup]
    let unattachedPlans: [Dieter_V1_TaskPlan]

    static let empty = ConversationTimelineProjection(items: [], rows: [], displayGroups: [], unattachedPlans: [])

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
                ["user", "human"].contains(message.role.lowercased()) || structuredMessageIDs.contains(message.id)
                    || message.parts.contains {
                        ConversationActivityGrouping.isVisible($0, showReasoning: showReasoning)
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
                displayGroups: ConversationTimelineDisplayGroup.group(rows, showReasoning: showReasoning),
                unattachedPlans: plans.filter {
                    !$0.messageID.isEmpty && !allMessageIDs.contains($0.messageID)
                }
            )
        }
    }
}

struct ConversationPresentationKey: Hashable {
    let conversationID: String
    let revision: Int
    let showReasoning: Bool
    let renderStart: Int
    let renderCount: Int
}

enum ConversationRenderWindow {
    static let maximumMessages = 60
    static let maximumTextBytes = 16_000
    static let maximumParts = 160

    enum Position: Equatable {
        case latest
        case startingAt(Int, minimumMessages: Int = 1)
        case pagingEarlier(from: Int)
        case pagingLater(from: Int)

        func afterUserScroll(isAtLatest: Bool, renderedRange: Range<Int>) -> Self {
            if isAtLatest { return .latest }
            // Freeze the chosen start so appends cannot evict the text being
            // read. Paging retains its two-message overlap even for large rows.
            switch self {
            case .latest:
                return .startingAt(renderedRange.lowerBound)
            case .pagingEarlier, .pagingLater:
                return .startingAt(renderedRange.lowerBound, minimumMessages: 2)
            case .startingAt:
                return self
            }
        }
    }

    static func range(messages: [Dieter_V1_UiMessage], position: Position) -> Range<Int> {
        guard !messages.isEmpty else { return 0..<0 }
        switch position {
        case .pagingEarlier(let requestedAnchor):
            let anchor = min(max(0, requestedAnchor), messages.count - 1)
            return centeredRange(messages: messages, anchor: anchor, requiredIndex: max(0, anchor - 1))
        case .pagingLater(let requestedAnchor):
            let anchor = min(max(0, requestedAnchor), messages.count - 1)
            return centeredRange(
                messages: messages,
                anchor: anchor,
                requiredIndex: min(messages.count - 1, anchor + 1)
            )
        case .latest, .startingAt:
            break
        }
        let anchor: Int
        switch position {
        case .latest:
            anchor = messages.count - 1
        case .startingAt(let index, let minimumMessages):
            return forwardRange(
                messages: messages, start: min(max(0, index), messages.count - 1),
                minimumMessages: minimumMessages)
        case .pagingEarlier, .pagingLater:
            preconditionFailure("paging windows return before directional layout")
        }
        var lower = anchor, upper = anchor, bytes = 0, parts = 0
        let candidates = Array(max(0, anchor - maximumMessages + 1)...anchor).reversed().map { $0 }
        for index in candidates {
            let message = messages[index]
            let cost = message.parts.reduce(0) {
                $0 + min($1.text.utf8.count, ConversationRenderCache.maximumPreviewCharacters)
            }
            if upper > lower && (bytes + cost > maximumTextBytes || parts + message.parts.count > maximumParts) {
                break
            }
            bytes += cost
            parts += message.parts.count
            lower = min(lower, index)
            upper = max(upper, index + 1)
        }
        return lower..<upper
    }

    private static func centeredRange(
        messages: [Dieter_V1_UiMessage],
        anchor: Int,
        requiredIndex: Int
    ) -> Range<Int> {
        let idealStart = max(
            0,
            min(anchor - maximumMessages / 2, messages.count - maximumMessages)
        )
        let ideal = forwardRange(messages: messages, start: idealStart, minimumMessages: 2)
        if ideal.contains(anchor), ideal.contains(requiredIndex) { return ideal }
        return forwardRange(messages: messages, start: min(anchor, requiredIndex), minimumMessages: 2)
    }

    private static func forwardRange(
        messages: [Dieter_V1_UiMessage],
        start: Int,
        minimumMessages: Int = 1
    ) -> Range<Int> {
        var upper = start, bytes = 0, parts = 0
        for index in start..<min(messages.count, start + maximumMessages) {
            let message = messages[index]
            let cost = message.parts.reduce(0) {
                $0 + min($1.text.utf8.count, ConversationRenderCache.maximumPreviewCharacters)
            }
            if upper - start >= minimumMessages,
                bytes + cost > maximumTextBytes || parts + message.parts.count > maximumParts
            {
                break
            }
            bytes += cost
            parts += message.parts.count
            upper = index + 1
        }
        return start..<upper
    }

    static func range(messages: [Dieter_V1_UiMessage], requestedStart: Int?) -> Range<Int> {
        range(messages: messages, position: requestedStart.map { Position.startingAt($0) } ?? .latest)
    }

    static func range(messageCount: Int, position: Position) -> Range<Int> {
        guard messageCount > 0 else { return 0..<0 }
        switch position {
        case .latest:
            return max(0, messageCount - maximumMessages)..<messageCount
        case .startingAt(let requestedStart, _):
            let start = min(max(0, requestedStart), max(0, messageCount - maximumMessages))
            return start..<min(messageCount, start + maximumMessages)
        case .pagingEarlier(let requestedAnchor), .pagingLater(let requestedAnchor):
            let anchor = min(max(0, requestedAnchor), messageCount - 1)
            let start = max(0, min(anchor - maximumMessages / 2, messageCount - maximumMessages))
            return start..<min(messageCount, start + maximumMessages)
        }
    }

    static func range(messageCount: Int, requestedStart: Int?) -> Range<Int> {
        range(messageCount: messageCount, position: requestedStart.map { Position.startingAt($0) } ?? .latest)
    }
}
