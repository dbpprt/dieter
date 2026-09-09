import DieterAPI
import SwiftUI

struct TaskTokenUsageBadge: View {
    let usage: Dieter_V1_TokenUsage

    var body: some View {
        if usage.reportedMessages > 0 || usage.missingMessages > 0 || usage.partial {
            Label(TaskTokenUsagePresentation.label(usage), systemImage: "number")
                .font(.system(size: 10))
                .foregroundStyle(DieterTheme.tertiary)
                .help(TaskTokenUsagePresentation.detail(usage))
                .accessibilityLabel(TaskTokenUsagePresentation.detail(usage))
        }
    }
}

enum TaskTokenUsagePresentation {
    static func label(_ usage: Dieter_V1_TokenUsage) -> String {
        guard usage.reportedMessages > 0 else { return "Tokens unavailable" }
        let count = usage.totalTokens
        let compact =
            count >= 1_000_000
            ? String(format: "%.1fM", Double(count) / 1_000_000)
            : count >= 1_000 ? String(format: "%.1fK", Double(count) / 1_000) : String(count)
        return "\(compact) tokens" + (usage.partial ? " · partial" : "")
    }

    static func detail(_ usage: Dieter_V1_TokenUsage) -> String {
        guard usage.reportedMessages > 0 else { return "Token usage was not reported by the provider." }
        return
            "\(usage.totalTokens.formatted()) total tokens · \(usage.inputTokens.formatted()) input · \(usage.outputTokens.formatted()) output."
            + (usage.partial ? " Partial provider data; input/output counts may be incomplete." : "")
            + " Cumulative conversation usage. Copied fork history is excluded; separate subagent counters are not added."
    }
}
