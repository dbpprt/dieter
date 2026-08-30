import Foundation

@MainActor
enum ConversationRenderCache {
    private final class AttributedStringBox: NSObject {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let markdownCache: NSCache<NSString, AttributedStringBox> = {
        let cache = NSCache<NSString, AttributedStringBox>()
        cache.countLimit = 512
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    static func markdown(_ source: String) -> AttributedString {
        let key = source as NSString
        if let cached = markdownCache.object(forKey: key) { return cached.value }
        let value = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
        markdownCache.setObject(AttributedStringBox(value), forKey: key, cost: source.utf8.count)
        return value
    }
}
