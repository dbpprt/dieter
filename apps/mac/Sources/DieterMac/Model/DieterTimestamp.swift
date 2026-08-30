import Foundation

/// Shared ISO-8601 parsing for daemon timestamps. The daemon's timestamp
/// strings are immutable, so retaining a bounded cache avoids rebuilding
/// formatters and reparsing the same values throughout SwiftUI projections.
enum DieterTimestamp {
    private static let parser = Parser()

    static func date(from value: String) -> Date? {
        parser.date(from: value)
    }

    static func string(from date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }

    private final class Parser: @unchecked Sendable {
        private let cache = NSCache<NSString, NSDate>()
        private let precise = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        private let standard = Date.ISO8601FormatStyle()

        init() {
            cache.countLimit = 4_096
        }

        func date(from value: String) -> Date? {
            guard !value.isEmpty else { return nil }
            let key = value as NSString
            if let cached = cache.object(forKey: key) { return cached as Date }
            let parsed = (try? precise.parse(value)) ?? (try? standard.parse(value))
            if let parsed { cache.setObject(parsed as NSDate, forKey: key) }
            return parsed
        }
    }
}
