import Foundation

enum FileSyntaxHighlightStyle: Equatable, Sendable {
    case number
    case type
    case function
    case keyword
    case keywordBold
    case property
    case string
    case comment
}

struct FileSyntaxHighlightRun: Sendable {
    let location: Int
    let length: Int
    let style: FileSyntaxHighlightStyle
}

struct FileSyntaxHighlightPlan: Sendable {
    let location: Int
    let length: Int
    let runs: [FileSyntaxHighlightRun]
}

/// Produces only value-typed ranges and styles, so whole-document regex work
/// can run in a detached task without touching AppKit or NSTextStorage.
enum FileSyntaxHighlightPlanner {
    static func build(
        source: String,
        language: ProjectFileLanguage,
        requestedRange: NSRange? = nil
    ) -> FileSyntaxHighlightPlan {
        MacPerformanceSignposts.measure("Syntax highlight plan", log: MacPerformanceSignposts.editor) {
        let fullRange = NSRange(location: 0, length: (source as NSString).length)
        let range = requestedRange.map { NSIntersectionRange($0, fullRange) } ?? fullRange
        guard range.length > 0 else {
            return FileSyntaxHighlightPlan(location: range.location, length: range.length, runs: [])
        }
        var runs: [FileSyntaxHighlightRun] = []

        append(#"(?<![\w.])(?:0x[\da-fA-F]+|\d+(?:\.\d+)?)(?![\w.])"#, style: .number, source: source, range: range, to: &runs)
        append(#"\b[A-Z][A-Za-z0-9_]*\b"#, style: .type, source: source, range: range, to: &runs)
        append(#"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"#, style: .function, source: source, range: range, to: &runs)

        if !language.keywords.isEmpty {
            let escaped = language.keywords.map(NSRegularExpression.escapedPattern).joined(separator: "|")
            append(
                "\\b(?:\(escaped))\\b",
                style: .keywordBold,
                options: language == .sql ? [.caseInsensitive] : [],
                source: source,
                range: range,
                to: &runs
            )
        }

        switch language {
        case .json:
            append(#""(?:\\.|[^"\\])*"(?=\s*:)"#, style: .property, source: source, range: range, to: &runs)
        case .yaml, .toml:
            append(#"(?m)^[\t ]*(?:-\s*)?[A-Za-z_][\w.-]*(?=\s*[=:])"#, style: .property, source: source, range: range, to: &runs)
        case .html, .xml:
            append(#"</?[A-Za-z][^>]*>"#, style: .keyword, source: source, range: range, to: &runs)
            append(#"\b[A-Za-z_:][-A-Za-z0-9_:.]*(?=\s*=)"#, style: .property, source: source, range: range, to: &runs)
        case .css:
            append(#"(?m)(?:^|[;{])\s*[-A-Za-z]+(?=\s*:)"#, style: .property, source: source, range: range, to: &runs)
            append(#"(?:#[\da-fA-F]{3,8})\b"#, style: .number, source: source, range: range, to: &runs)
        case .markdown:
            append(#"(?m)^#{1,6}\s+.*$"#, style: .keywordBold, source: source, range: range, to: &runs)
            append(#"(?m)^\s*(?:[-*+] |\d+\. )"#, style: .number, source: source, range: range, to: &runs)
            append(#"\[[^\]]+\]\([^\)]+\)"#, style: .function, source: source, range: range, to: &runs)
            append(#"(?s)```.*?```"#, style: .string, source: source, range: range, to: &runs)
        default:
            break
        }

        let basicStrings = "\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'|`(?:\\\\.|[^`\\\\])*`"
        let stringPattern = language == .python || language == .ruby
            ? "\"\"\"[\\s\\S]*?\"\"\"|'''[\\s\\S]*?'''|\(basicStrings)"
            : basicStrings
        if let commentPattern = language.commentPattern,
           let expression = try? NSRegularExpression(pattern: "(\(stringPattern))|(\(commentPattern))") {
            expression.enumerateMatches(in: source, range: range) { result, _, _ in
                guard let result else { return }
                Self.append(result.range(at: 1), style: .string, to: &runs)
                Self.append(result.range(at: 2), style: .comment, to: &runs)
            }
        } else {
            append(stringPattern, style: .string, source: source, range: range, to: &runs)
        }
        return FileSyntaxHighlightPlan(location: range.location, length: range.length, runs: runs)
        }
    }

    private static func append(
        _ pattern: String,
        style: FileSyntaxHighlightStyle,
        options: NSRegularExpression.Options = [],
        source: String,
        range: NSRange,
        to runs: inout [FileSyntaxHighlightRun]
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        expression.enumerateMatches(in: source, range: range) { result, _, _ in
            guard let result else { return }
            append(result.range, style: style, to: &runs)
        }
    }

    private static func append(
        _ range: NSRange,
        style: FileSyntaxHighlightStyle,
        to runs: inout [FileSyntaxHighlightRun]
    ) {
        guard range.location != NSNotFound, range.length > 0 else { return }
        runs.append(.init(location: range.location, length: range.length, style: style))
    }
}
