import DieterAPI
import Foundation

/// The rows mounted for the rendered message range: the core's rows whose
/// messages meet it, each whole.
struct ConversationTimelineProjection: Sendable {
    let rows: [ClientTimelineItem]

    static let empty = ConversationTimelineProjection(rows: [])
}

struct ConversationPresentationKey: Hashable {
    let conversationID: String
    let revision: Int
    let renderStart: Int
    let renderCount: Int
}

enum ConversationRenderWindow {
    // Start near the visible tail. Short rows expand this window after native
    // layout until it fills the viewport; scrollback retains the larger budget.
    static let initialMessages = 8
    static let maximumMessages = 60
    static let maximumTextBytes = 32_000
    static let maximumParts = 240
    static let latestPages = 3
    /// Crossing an edge reveals a useful overlapping stretch. A single
    /// budget page can be visually tiny when collapsed command groups carry
    /// many hidden parts, so scrollback advances by two pages at a time.
    static let scrollbackPages = 2
    /// A detached reader keeps several pages mounted. Scrolling back therefore
    /// grows the transcript like an ordinary document; rows are released only
    /// far outside the viewport, never underneath the text being read.
    static let retainedPages = 6

    /// Windows are keyed by message identity. History pages and retention
    /// trimming shift array indices underneath a reader; identities do not.
    enum Position: Equatable {
        case latest
        /// Pinned start; extends toward newer messages up to the retained budget.
        case from(messageID: String)
        /// Pinned end; extends toward older messages up to the retained budget.
        case through(messageID: String)
    }

    static func range(
        messages: [Dieter_V1_UiMessage], position: Position, latestMessageLimit: Int? = nil
    ) -> Range<Int> {
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
        if let latestMessageLimit {
            return backwardRange(
                messages: messages, end: messages.count, pages: 1, messageLimit: latestMessageLimit)
        }
        return backwardRange(messages: messages, end: messages.count, pages: latestPages)
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

    /// Another overlapping batch of older messages above the rendered range, or nil when
    /// the loaded transcript has none.
    static func extendingEarlier(messages: [Dieter_V1_UiMessage], renderedRange: Range<Int>) -> Position? {
        guard renderedRange.lowerBound > 0, renderedRange.lowerBound <= messages.count else { return nil }
        let start = backwardRange(
            messages: messages, end: renderedRange.lowerBound, pages: scrollbackPages
        ).lowerBound
        guard !messages[start].id.isEmpty else { return nil }
        return .from(messageID: messages[start].id)
    }

    /// Another overlapping batch of newer messages below the rendered range, or nil when
    /// the range already reaches the newest loaded message.
    static func extendingLater(messages: [Dieter_V1_UiMessage], renderedRange: Range<Int>) -> Position? {
        guard renderedRange.upperBound < messages.count else { return nil }
        let end = forwardRange(
            messages: messages, start: renderedRange.upperBound, pages: scrollbackPages
        ).upperBound
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

    private static func backwardRange(
        messages: [Dieter_V1_UiMessage], end: Int, pages: Int, messageLimit: Int = maximumMessages
    ) -> Range<Int> {
        var lower = end, bytes = 0, parts = 0
        let count = min(maximumMessages, max(1, messageLimit)) * pages
        for index in stride(from: end - 1, through: max(0, end - count), by: -1) {
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
