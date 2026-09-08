import Foundation

enum ConversationRenderCache {
    private final class AttributedStringBox: NSObject {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private final class MarkdownBlockBox: NSObject {
        let value: [ConversationMarkdownBlock]
        init(_ value: [ConversationMarkdownBlock]) { self.value = value }
    }

    // NSCache synchronizes lookup/insert/eviction. Boxes are immutable once
    // inserted; no mutable formatter or parser is shared across workers.
    private final class Storage: @unchecked Sendable {
        let markdownCache: NSCache<NSString, AttributedStringBox> = {
            let cache = NSCache<NSString, AttributedStringBox>()
            cache.countLimit = 512
            cache.totalCostLimit = 8 * 1_024 * 1_024
            return cache
        }()

        let blockCache: NSCache<NSString, MarkdownBlockBox> = {
            let cache = NSCache<NSString, MarkdownBlockBox>()
            cache.countLimit = 512
            cache.totalCostLimit = 8 * 1_024 * 1_024
            return cache
        }()
    }
    private static let storage = Storage()

    static func markdown(_ source: String) -> AttributedString {
        let key = source as NSString
        if let cached = storage.markdownCache.object(forKey: key) { return cached.value }
        let value = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
        storage.markdownCache.setObject(AttributedStringBox(value), forKey: key, cost: source.utf8.count)
        return value
    }

    static let maximumPreviewCharacters = 12_000

    static func preview(_ source: String) -> String {
        String(source.prefix(maximumPreviewCharacters))
    }

    static func cachedBlocks(_ source: String) -> [ConversationMarkdownBlock]? {
        storage.blockCache.object(forKey: source as NSString)?.value
    }

    /// Populate immutable render data before SwiftUI constructs text views.
    /// Check cancellation between blocks/cells so streaming supersession is bounded.
    static func prepare(_ source: String) throws -> [ConversationMarkdownBlock] {
        if let cached = cachedBlocks(source) { return cached }
        let value = ConversationMarkdownParser.parse(source)
        for block in value {
            try Task.checkCancellation()
            switch block {
            case .paragraph(let text), .heading(_, let text), .bullet(let text):
                _ = markdown(text)
            case .table(let table):
                for row in [table.headers] + Array(table.rows.prefix(20)) {
                    for cell in row {
                        try Task.checkCancellation()
                        _ = markdown(cell)
                    }
                }
            case .code: break
            }
        }
        storage.blockCache.setObject(MarkdownBlockBox(value), forKey: source as NSString, cost: source.utf8.count)
        return value
    }

    static func blocks(_ source: String) -> [ConversationMarkdownBlock] {
        let key = source as NSString
        if let cached = storage.blockCache.object(forKey: key) { return cached.value }
        let value = ConversationMarkdownParser.parse(source)
        storage.blockCache.setObject(MarkdownBlockBox(value), forKey: key, cost: source.utf8.count)
        return value
    }
}
