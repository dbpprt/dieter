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
    /// A detached reader keeps several pages mounted. Scrolling back therefore
    /// grows the transcript like an ordinary document; rows are released only
    /// far outside the viewport, never underneath the text being read.
    static let retainedPages = 4

    /// Windows are keyed by message identity. History pages and retention
    /// trimming shift array indices underneath a reader; identities do not.
    enum Position: Equatable {
        case latest
        /// Pinned start; extends toward newer messages up to the retained budget.
        case from(messageID: String)
        /// Pinned end; extends toward older messages up to the retained budget.
        case through(messageID: String)
    }

    static func range(messages: [Dieter_V1_UiMessage], position: Position) -> Range<Int> {
        guard !messages.isEmpty else { return 0..<0 }
        switch position {
        case .latest:
            break
        case .from(let messageID):
            if let start = index(of: messageID, in: messages) {
                return forwardRange(messages: messages, start: start, pages: retainedPages)
            }
        case .through(let messageID):
            if let last = index(of: messageID, in: messages) {
                return backwardRange(messages: messages, end: last + 1, pages: retainedPages)
            }
        }
        return backwardRange(messages: messages, end: messages.count, pages: 1)
    }

    /// Freezes the rendered start when the reader leaves the live tail, so
    /// appends cannot evict the text being read.
    static func detached(
        from position: Position, messages: [Dieter_V1_UiMessage], renderedRange: Range<Int>
    ) -> Position {
        guard position == .latest, messages.indices.contains(renderedRange.lowerBound),
            !messages[renderedRange.lowerBound].id.isEmpty
        else { return position }
        return .from(messageID: messages[renderedRange.lowerBound].id)
    }

    /// One more page of older messages above the rendered range, or nil when
    /// the loaded transcript has none.
    static func extendingEarlier(messages: [Dieter_V1_UiMessage], renderedRange: Range<Int>) -> Position? {
        guard renderedRange.lowerBound > 0, renderedRange.lowerBound <= messages.count else { return nil }
        let start = backwardRange(messages: messages, end: renderedRange.lowerBound, pages: 1).lowerBound
        guard !messages[start].id.isEmpty else { return nil }
        return .from(messageID: messages[start].id)
    }

    /// One more page of newer messages below the rendered range, or nil when
    /// the range already reaches the newest loaded message.
    static func extendingLater(messages: [Dieter_V1_UiMessage], renderedRange: Range<Int>) -> Position? {
        guard renderedRange.upperBound < messages.count else { return nil }
        let end = forwardRange(messages: messages, start: renderedRange.upperBound, pages: 1).upperBound
        guard !messages[end - 1].id.isEmpty else { return .latest }
        return .through(messageID: messages[end - 1].id)
    }

    private static func index(of messageID: String, in messages: [Dieter_V1_UiMessage]) -> Int? {
        messageID.isEmpty ? nil : messages.firstIndex { $0.id == messageID }
    }

    private static func messageTextCost(_ message: Dieter_V1_UiMessage) -> Int {
        message.parts.reduce(0) {
            $0 + min($1.text.utf8.count, ConversationRenderCache.maximumPreviewCharacters)
        }
    }

    private static func backwardRange(messages: [Dieter_V1_UiMessage], end: Int, pages: Int) -> Range<Int> {
        var lower = end, bytes = 0, parts = 0
        for index in stride(from: end - 1, through: max(0, end - maximumMessages * pages), by: -1) {
            let cost = messageTextCost(messages[index])
            let partCount = messages[index].parts.count
            if lower < end, bytes + cost > maximumTextBytes * pages || parts + partCount > maximumParts * pages {
                break
            }
            bytes += cost
            parts += partCount
            lower = index
        }
        return lower..<end
    }

    private static func forwardRange(messages: [Dieter_V1_UiMessage], start: Int, pages: Int) -> Range<Int> {
        var upper = start, bytes = 0, parts = 0
        for index in start..<min(messages.count, start + maximumMessages * pages) {
            let cost = messageTextCost(messages[index])
            let partCount = messages[index].parts.count
            if upper > start, bytes + cost > maximumTextBytes * pages || parts + partCount > maximumParts * pages {
                break
            }
            bytes += cost
            parts += partCount
            upper = index + 1
        }
        return start..<upper
    }
}
