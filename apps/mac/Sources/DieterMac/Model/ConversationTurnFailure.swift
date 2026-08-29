import DieterAPI
import Foundation

struct ConversationTurnFailure {
    let summary: String
    let log: String
    let retryParts: [Dieter_V1_MessagePart]

    static func resolve(
        messages: [Dieter_V1_UiMessage],
        conversationStatus: String,
        cardRuntime: String
    ) -> ConversationTurnFailure? {
        let statuses = [conversationStatus, cardRuntime].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard statuses.contains("failed") else { return nil }

        let failedMessageIndex = messages.lastIndex { message in
            !["user", "human"].contains(message.role.lowercased()) && message.parts.contains(where: isFailurePart)
        }
        let failureParts = failedMessageIndex.map { index in
            messages[index].parts.filter(isFailurePart)
        } ?? []
        let diagnostic = failureParts.compactMap { part -> String? in
            let value = part.errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? part.text
                : part.errorText
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.joined(separator: "\n\n")
        let log = diagnostic.isEmpty
            ? "The harness turn failed without producing diagnostic output."
            : diagnostic

        let retrySearchEnd = failedMessageIndex ?? messages.endIndex
        let retryParts = messages[..<retrySearchEnd].reversed().first { message in
            ["user", "human"].contains(message.role.lowercased()) && message.parts.contains(where: isRetryablePart)
        }?.parts ?? []

        return ConversationTurnFailure(
            summary: conciseSummary(log),
            log: log,
            retryParts: retryParts
        )
    }

    static func isFailurePart(_ part: Dieter_V1_MessagePart) -> Bool {
        part.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "error"
            || (!part.errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !ConversationMessagePartGroup.isToolCall(part))
    }

    private static func isRetryablePart(_ part: Dieter_V1_MessagePart) -> Bool {
        switch part.type.lowercased() {
        case "text":
            return !part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case "file", "attachment", "image":
            return !part.url.isEmpty || !part.data.isEmpty
        default:
            return false
        }
    }

    private static func conciseSummary(_ log: String) -> String {
        var line = log.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? "The harness exited unexpectedly."
        for prefix in ["Turn failed — ", "Turn failed: ", "Turn failed - "] where line.lowercased().hasPrefix(prefix.lowercased()) {
            line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        let limit = 180
        if line.count > limit {
            line = String(line.prefix(limit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return line.isEmpty ? "The harness exited unexpectedly." : line
    }
}
