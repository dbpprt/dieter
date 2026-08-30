import Foundation

struct SubagentUsagePresentation: Equatable, Sendable {
    let metrics: [String]

    static func resolve(tokens: Int64, contextTokens: Int64, contextWindow: Int64) -> Self {
        var metrics: [String] = []
        if tokens > 0 {
            metrics.append("\(compact(tokens)) processed")
        }
        if contextTokens > 0, contextWindow > 0 {
            let percent = min(100, max(0, Int((Double(contextTokens) / Double(contextWindow) * 100).rounded())))
            metrics.append("\(compact(contextTokens)) / \(compact(contextWindow)) context (\(percent)%)")
        }
        return Self(metrics: metrics)
    }

    private static func compact(_ tokens: Int64) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 100_000 { return String(format: "%.0fk", Double(tokens) / 1_000) }
        if tokens >= 1_000 { return String(format: "%.1fk", Double(tokens) / 1_000) }
        return String(tokens)
    }
}
