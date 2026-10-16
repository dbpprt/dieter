import DieterAPI
import DieterClientAPI
import Foundation

/// A conversation's loaded messages, keyed as the core's timeline steps name
/// them: by ID, else "position:<index>".
package struct ConversationMessages: Equatable, Sendable {
    package private(set) var byKey: [String: Dieter_V1_UiMessage] = [:]

    package init(_ messages: [Dieter_V1_UiMessage] = []) {
        for (index, message) in messages.enumerated() {
            byKey[message.id.isEmpty ? "position:\(index)" : message.id] = message
        }
    }

    /// The message a timeline step renders.
    package func message(for step: ClientTimelineStep) -> Dieter_V1_UiMessage? {
        if !step.messageID.isEmpty, let message = byKey[step.messageID] { return message }
        return byKey[Self.positionKey(step)]
    }

    /// The messages `row` renders: those it names and those its steps come
    /// from, keyed as here. A row given only these does not change when
    /// another message streams.
    package func scoped(to row: ClientTimelineItem) -> ConversationMessages {
        var scoped = ConversationMessages()
        for id in row.messageIds {
            if let message = byKey[id] { scoped.byKey[id] = message }
        }
        for group in row.groups {
            for step in group.steps {
                if !step.messageID.isEmpty, let message = byKey[step.messageID] {
                    scoped.byKey[step.messageID] = message
                    continue
                }
                let key = Self.positionKey(step)
                if let message = byKey[key] { scoped.byKey[key] = message }
            }
        }
        return scoped
    }

    private static func positionKey(_ step: ClientTimelineStep) -> String {
        step.id.components(separatedBy: ":part:").first ?? ""
    }

    /// The part a timeline step renders: its message's part, with coalesced prose as its text.
    package func part(for step: ClientTimelineStep) -> Dieter_V1_MessagePart? {
        guard let message = message(for: step), message.parts.indices.contains(Int(step.partIndex)) else {
            return nil
        }
        var part = message.parts[Int(step.partIndex)]
        if !step.text.isEmpty { part.text = step.text }
        return part
    }

    /// A row's loaded messages, as the core's copy rule takes them.
    package func timelineMessages(_ row: ClientTimelineItem) -> ClientTimelineMessages {
        .with { $0.messages = row.messageIds.compactMap { byKey[$0] } }
    }
}

extension Dieter_V1_Conversation {
    /// The task plans a row shows, at their latest revision.
    package func taskPlans(ids: [String]) -> [Dieter_V1_TaskPlan] {
        guard !ids.isEmpty else { return [] }
        return ids.compactMap { id in taskPlans.filter { $0.id == id }.max { $0.revision < $1.revision } }
    }

    /// The delegated agents a row shows, in the row's order.
    package func subagents(ids: [String]) -> [Dieter_V1_Subagent] {
        guard !ids.isEmpty else { return [] }
        return ids.compactMap { id in subagents.first { $0.id == id } }
    }
}
