import DieterAPI

/// Compare daemon revisions, never client receive times: independent streams
/// can deliver an older projection after a newer conversation read.
package enum TranscriptFreshness {
    package static func isOlder(sequence: Int64, updatedAt: String, than current: Dieter_V1_Conversation) -> Bool {
        if sequence != current.lastSeq { return sequence < current.lastSeq }
        guard let incomingDate = DieterTimestamp.date(from: updatedAt),
            let currentDate = DieterTimestamp.date(from: current.updatedAt)
        else { return false }
        return incomingDate < currentDate
    }

    package static func merging(
        _ incoming: Dieter_V1_ConversationSnapshot, with current: Dieter_V1_ConversationSnapshot?
    ) -> Dieter_V1_ConversationSnapshot {
        guard let current, current.detail.card.id == incoming.detail.card.id,
            isOlder(
                sequence: incoming.conversation.lastSeq, updatedAt: incoming.conversation.updatedAt,
                than: current.conversation)
        else { return incoming }
        // Card metadata has its own lifecycle; only retain the transcript and
        // its matching pagination window when that projection is older.
        var result = incoming
        result.conversation = current.conversation
        result.page = current.page
        return result
    }
}
