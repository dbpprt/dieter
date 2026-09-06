import Foundation

@MainActor
enum ConversationRenderCache {
    private final class AttributedStringBox: NSObject {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private final class MarkdownBlockBox: NSObject {
        let value: [ConversationMarkdownBlock]
        init(_ value: [ConversationMarkdownBlock]) { self.value = value }
    }

    private static let markdownCache: NSCache<NSString, AttributedStringBox> = {
        let cache = NSCache<NSString, AttributedStringBox>()
        cache.countLimit = 512
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    private static let blockCache: NSCache<NSString, MarkdownBlockBox> = {
        let cache = NSCache<NSString, MarkdownBlockBox>()
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

    static func blocks(_ source: String) -> [ConversationMarkdownBlock] {
        let key = source as NSString
        if let cached = blockCache.object(forKey: key) { return cached.value }
        let value = ConversationMarkdownParser.parse(source)
        blockCache.setObject(MarkdownBlockBox(value), forKey: key, cost: source.utf8.count)
        return value
    }
}
