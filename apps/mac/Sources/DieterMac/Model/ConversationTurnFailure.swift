import DieterAPI
import Foundation
import SharedCore

/// The last turn's failure, as the shared core reads it from the transcript.
struct ConversationTurnFailure {
    let summary: String
    let log: String
    /// The failed request can be sent again.
    let retryable: Bool

    init(summary: String, log: String, retryable: Bool) {
        self.summary = summary
        self.log = log
        self.retryable = retryable
    }

    init(_ failure: ClientTurnFailure) {
        self.init(summary: failure.summary, log: failure.log, retryable: failure.retryable)
    }

    /// A part the transcript renders as a failure.
    static func isFailurePart(_ part: Dieter_V1_MessagePart) -> Bool {
        part.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "error"
            || (!part.errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !ConversationMessagePartGroup.isToolCall(part))
    }
}
