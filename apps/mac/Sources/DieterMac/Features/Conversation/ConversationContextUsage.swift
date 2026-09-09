import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct ConversationContextUsage: Equatable {
    let used: Int64
    let window: Int64

    var fraction: Double { window > 0 ? min(1, max(0, Double(used) / Double(window))) : 0 }
    var percentage: Int { Int((fraction * 100).rounded()) }

    static func latest(messages: [Dieter_V1_UiMessage], fallbackWindow: Int64) -> ConversationContextUsage? {
        guard let metadata = messages.reversed().lazy.map(\.metadataJson).first(where: { !$0.isEmpty }) else {
            return nil
        }
        return ConversationContextUsageCache.value(metadata: metadata, fallbackWindow: fallbackWindow)
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }
}

enum ConversationContextUsageCache {
    private final class Box: NSObject {
        let value: ConversationContextUsage?
        init(_ value: ConversationContextUsage?) { self.value = value }
    }

    private final class Cache: @unchecked Sendable {
        let values: NSCache<NSString, Box> = {
            let cache = NSCache<NSString, Box>()
            cache.countLimit = 128
            return cache
        }()
    }

    private static let cache = Cache()

    static func value(metadata: Data, fallbackWindow: Int64) -> ConversationContextUsage? {
        let key = "\(fallbackWindow):\(metadata.base64EncodedString())" as NSString
        if let cached = cache.values.object(forKey: key) { return cached.value }
        guard let root = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any] else {
            cache.values.setObject(Box(nil), forKey: key)
            return nil
        }
        let usage = root["usage"] as? [String: Any]
        let used = integer(usage?["totalTokens"]) ?? integer(usage?["inputTokens"])
        let window = integer(root["contextWindowTokens"]) ?? (fallbackWindow > 0 ? fallbackWindow : nil)
        let result = used.flatMap { used in
            window.flatMap { $0 > 0 ? ConversationContextUsage(used: used, window: $0) : nil }
        }
        cache.values.setObject(Box(result), forKey: key)
        return result
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }
}

struct ContextUsageIndicator: View {
    let usage: ConversationContextUsage

    var body: some View {
        ZStack {
            Circle().stroke(DieterTheme.raised, lineWidth: 3)
            Circle().trim(from: 0, to: usage.fraction)
                .stroke(
                    usage.fraction > 0.85 ? DieterTheme.amber : DieterTheme.shell,
                    style: .init(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(usage.percentage)").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(
                DieterTheme.subtle)
        }
        .frame(width: 28, height: 28)
        .help("Context used: \(compact(usage.used)) of \(compact(usage.window)) tokens (\(usage.percentage)%)")
        .accessibilityLabel("Context used \(usage.percentage) percent")
    }

    private func compact(_ value: Int64) -> String {
        value >= 1_000_000
            ? String(format: "%.1fM", Double(value) / 1_000_000) : value >= 1_000 ? "\(value / 1_000)k" : "\(value)"
    }
}
