import DieterAPI
import Foundation

package enum TranscriptRetention {
    package static let messageLimit = 2_000
    package static let byteLimit = 32 * 1_024 * 1_024

    package struct Window {
        package let messages: [Dieter_V1_UiMessage]
        package let removed: Int
    }

    /// Keep an earlier page while browsing backwards, or the latest contiguous
    /// history during streaming. The daemon remains the complete transcript.
    package static func window(
        _ messages: [Dieter_V1_UiMessage], keepingEarlier: Bool,
        countLimit: Int = messageLimit, byteLimit: Int = byteLimit
    ) -> Window {
        var count = 0, bytes = 0
        for offset in 0..<min(messages.count, max(1, countLimit)) {
            let index = keepingEarlier ? offset : messages.count - 1 - offset
            let size = (try? messages[index].serializedData().count) ?? byteLimit
            if count > 0, bytes + size > byteLimit { break }
            bytes += size; count += 1
        }
        return Window(
            messages: Array(keepingEarlier ? messages.prefix(count) : messages.suffix(count)),
            removed: messages.count - count)
    }
}
