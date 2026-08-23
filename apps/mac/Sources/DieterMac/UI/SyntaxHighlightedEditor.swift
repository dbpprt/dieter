import AppKit
import SwiftUI

enum ProjectFileLanguage: String, CaseIterable, Sendable {
    case plain
    case swift
    case go
    case kotlin
    case java
    case javascript
    case typescript
    case python
    case ruby
    case rust
    case c
    case cpp
    case objectiveC
    case shell
    case json
    case yaml
    case html
    case xml
    case css
    case sql
    case markdown
    case toml

    static func detect(filename: String) -> ProjectFileLanguage {
        let lowercased = filename.lowercased()
        let extensionName = (lowercased as NSString).pathExtension

        switch lowercased {
        case "dockerfile", "makefile", "justfile": return .shell
        default: break
        }

        switch extensionName {
        case "swift": return .swift
        case "go": return .go
        case "kt", "kts": return .kotlin
        case "java": return .java
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx", "mts", "cts": return .typescript
        case "py", "pyw": return .python
        case "rb": return .ruby
        case "rs": return .rust
        case "c", "h": return .c
        case "cc", "cpp", "cxx", "hpp", "hh": return .cpp
        case "m", "mm": return .objectiveC
        case "sh", "bash", "zsh", "fish": return .shell
        case "json", "jsonc": return .json
        case "yaml", "yml": return .yaml
        case "html", "htm": return .html
        case "xml", "svg": return .xml
        case "css", "scss", "sass", "less": return .css
        case "sql": return .sql
        case "md", "markdown", "mdx": return .markdown
        case "toml": return .toml
        default: return .plain
        }
    }

    var displayName: String {
        switch self {
        case .plain: "Plain text"
        case .swift: "Swift"
        case .go: "Go"
        case .kotlin: "Kotlin"
        case .java: "Java"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .python: "Python"
        case .ruby: "Ruby"
        case .rust: "Rust"
        case .c: "C"
        case .cpp: "C++"
        case .objectiveC: "Objective-C"
        case .shell: "Shell"
        case .json: "JSON"
        case .yaml: "YAML"
        case .html: "HTML"
        case .xml: "XML"
        case .css: "CSS"
        case .sql: "SQL"
        case .markdown: "Markdown"
        case .toml: "TOML"
        }
    }

    fileprivate var keywords: [String] {
        switch self {
        case .swift:
            ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "isolated", "let", "nil", "nonisolated", "open", "private", "protocol", "public", "repeat", "rethrows", "return", "self", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where", "while"]
        case .go:
            ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var"]
        case .kotlin:
            ["as", "break", "by", "catch", "class", "companion", "const", "continue", "data", "do", "else", "enum", "false", "finally", "for", "fun", "if", "import", "in", "interface", "internal", "is", "lateinit", "null", "object", "open", "operator", "override", "package", "private", "protected", "public", "return", "sealed", "suspend", "this", "throw", "true", "try", "typealias", "val", "var", "when", "where", "while"]
        case .java:
            ["abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "false", "final", "finally", "float", "for", "if", "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "null", "package", "private", "protected", "public", "return", "short", "static", "strictfp", "super", "switch", "synchronized", "this", "throw", "throws", "transient", "true", "try", "void", "volatile", "while"]
        case .javascript, .typescript:
            ["as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "declare", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from", "function", "if", "implements", "import", "in", "instanceof", "interface", "keyof", "let", "new", "null", "of", "package", "private", "protected", "public", "readonly", "return", "static", "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "with", "yield"]
        case .python:
            ["and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del", "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with", "yield"]
        case .ruby:
            ["alias", "and", "begin", "break", "case", "class", "def", "defined", "do", "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield"]
        case .rust:
            ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"]
        case .c, .cpp, .objectiveC:
            ["auto", "bool", "break", "case", "catch", "char", "class", "const", "constexpr", "continue", "default", "delete", "do", "double", "else", "enum", "explicit", "extern", "false", "float", "for", "friend", "if", "inline", "int", "long", "namespace", "new", "nullptr", "operator", "private", "protected", "public", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this", "throw", "true", "try", "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "while"]
        case .shell:
            ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local", "readonly", "return", "select", "then", "until", "while"]
        case .sql:
            ["ADD", "ALTER", "AND", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASE", "COMMIT", "CREATE", "DELETE", "DESC", "DISTINCT", "DROP", "ELSE", "END", "EXISTS", "FROM", "FULL", "GROUP", "HAVING", "IN", "INDEX", "INNER", "INSERT", "INTO", "IS", "JOIN", "LEFT", "LIKE", "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "OUTER", "PRIMARY", "REFERENCES", "RETURNING", "RIGHT", "ROLLBACK", "SELECT", "SET", "TABLE", "THEN", "UNION", "UNIQUE", "UPDATE", "VALUES", "WHEN", "WHERE", "WITH"]
        default: []
        }
    }

    fileprivate var commentPattern: String? {
        switch self {
        case .python, .ruby, .shell, .yaml, .toml: "#[^\\n]*"
        case .sql: "--[^\\n]*|/\\*[\\s\\S]*?\\*/"
        case .html, .xml, .markdown: "<!--[\\s\\S]*?-->"
        case .css: "/\\*[\\s\\S]*?\\*/"
        case .plain, .json: nil
        default: "//[^\\n]*|/\\*[\\s\\S]*?\\*/"
        }
    }
}

enum ProjectFilePresentation {
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico", "svg"]

    static func isImage(filename: String, mimeType: String) -> Bool {
        if mimeType.lowercased().hasPrefix("image/") { return true }
        return imageExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    static func bytes(binary: Bool, content: String, data: Data) -> Data {
        binary ? data : Data(content.utf8)
    }
}

struct SyntaxHighlightedEditor: NSViewRepresentable {
    @Binding var text: String
    let filename: String

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> SyntaxEditorContainer {
        let container = SyntaxEditorContainer()
        let textView = container.textView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.string = text
        context.coordinator.textView = textView
        context.coordinator.container = container
        context.coordinator.highlight(force: true)
        return container
    }

    func updateNSView(_ container: SyntaxEditorContainer, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            context.coordinator.isApplyingUpdate = true
            textView.string = text
            context.coordinator.isApplyingUpdate = false
            context.coordinator.highlight(force: true)
        } else {
            context.coordinator.highlight(force: false)
        }
        container.needsLayout = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyntaxHighlightedEditor
        weak var textView: NSTextView?
        weak var container: SyntaxEditorContainer?
        var isApplyingUpdate = false
        private var highlightedLanguage: ProjectFileLanguage?

        init(parent: SyntaxHighlightedEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingUpdate, let textView else { return }
            parent.text = textView.string
            highlight(force: true)
            container?.needsLayout = true
        }

        func highlight(force: Bool) {
            guard let textView, let storage = textView.textStorage else { return }
            let language = ProjectFileLanguage.detect(filename: parent.filename)
            guard force || highlightedLanguage != language else { return }
            highlightedLanguage = language
            let selectedRanges = textView.selectedRanges
            FileSyntaxHighlighter.apply(to: storage, language: language)
            textView.typingAttributes = FileSyntaxHighlighter.baseAttributes
            textView.selectedRanges = selectedRanges
        }
    }
}

@MainActor
final class SyntaxEditorContainer: NSView {
    let scrollView = NSScrollView()
    let textView = SyntaxEditorTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let pointInScrollView = scrollView.convert(point, from: self)
        if let scroller = scrollView.verticalScroller,
           !scroller.isHidden,
           scroller.frame.contains(pointInScrollView) {
            return scroller
        }
        return textView
    }

    override func layout() {
        super.layout()
        let viewport = scrollView.contentSize
        guard viewport.width > 0, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        textContainer.containerSize = NSSize(width: viewport.width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height
        textView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: viewport.width, height: max(viewport.height, ceil(usedHeight) + 24))
        )
    }
}

@MainActor
final class SyntaxEditorTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

@MainActor
private enum FileSyntaxHighlighter {
    static let baseFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
    static let foreground = NSColor(calibratedWhite: 0.87, alpha: 1)
    static let keyword = NSColor(calibratedRed: 0.77, green: 0.57, blue: 1, alpha: 1)
    static let string = NSColor(calibratedRed: 0.63, green: 0.83, blue: 0.56, alpha: 1)
    static let comment = NSColor(calibratedRed: 0.49, green: 0.52, blue: 0.57, alpha: 1)
    static let number = NSColor(calibratedRed: 0.93, green: 0.68, blue: 0.42, alpha: 1)
    static let function = NSColor(calibratedRed: 0.43, green: 0.76, blue: 0.98, alpha: 1)
    static let type = NSColor(calibratedRed: 0.48, green: 0.83, blue: 0.80, alpha: 1)
    static let property = NSColor(calibratedRed: 0.90, green: 0.58, blue: 0.76, alpha: 1)
    static let regexCache = NSCache<NSString, NSRegularExpression>()

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 28
        return [.font: baseFont, .foregroundColor: foreground, .paragraphStyle: paragraph]
    }

    static func apply(to storage: NSTextStorage, language: ProjectFileLanguage) {
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: fullRange)
        guard storage.length > 0 else { storage.endEditing(); return }

        apply(#"(?<![\w.])(?:0x[\da-fA-F]+|\d+(?:\.\d+)?)(?![\w.])"#, color: number, to: storage)
        apply(#"\b[A-Z][A-Za-z0-9_]*\b"#, color: type, to: storage)
        apply(#"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"#, color: function, to: storage)

        if !language.keywords.isEmpty {
            let escaped = language.keywords.map(NSRegularExpression.escapedPattern).joined(separator: "|")
            let options: NSRegularExpression.Options = language == .sql ? [.caseInsensitive] : []
            apply("\\b(?:\(escaped))\\b", color: keyword, font: boldFont, options: options, to: storage)
        }

        switch language {
        case .json:
            apply(#""(?:\\.|[^"\\])*"(?=\s*:)"#, color: property, to: storage)
        case .yaml, .toml:
            apply(#"(?m)^[\t ]*(?:-\s*)?[A-Za-z_][\w.-]*(?=\s*[=:])"#, color: property, to: storage)
        case .html, .xml:
            apply(#"</?[A-Za-z][^>]*>"#, color: keyword, to: storage)
            apply(#"\b[A-Za-z_:][-A-Za-z0-9_:.]*(?=\s*=)"#, color: property, to: storage)
        case .css:
            apply(#"(?m)(?:^|[;{])\s*[-A-Za-z]+(?=\s*:)"#, color: property, to: storage)
            apply(#"(?:#[\da-fA-F]{3,8})\b"#, color: number, to: storage)
        case .markdown:
            apply(#"(?m)^#{1,6}\s+.*$"#, color: keyword, font: boldFont, to: storage)
            apply(#"(?m)^\s*(?:[-*+] |\d+\. )"#, color: number, to: storage)
            apply(#"\[[^\]]+\]\([^\)]+\)"#, color: function, to: storage)
            apply(#"(?s)```.*?```"#, color: string, to: storage)
        default: break
        }

        let basicStrings = "\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'|`(?:\\\\.|[^`\\\\])*`"
        let stringPattern = language == .python || language == .ruby
            ? "\"\"\"[\\s\\S]*?\"\"\"|'''[\\s\\S]*?'''|\(basicStrings)"
            : basicStrings
        if let commentPattern = language.commentPattern {
            applyLexical("(\(stringPattern))|(\(commentPattern))", to: storage)
        } else {
            apply(stringPattern, color: string, to: storage)
        }
        storage.endEditing()
    }

    private static func applyLexical(_ pattern: String, to storage: NSTextStorage) {
        guard let expression = expression(pattern) else { return }
        let range = NSRange(location: 0, length: storage.length)
        expression.enumerateMatches(in: storage.string, range: range) { result, _, _ in
            guard let result else { return }
            let stringRange = result.range(at: 1)
            let commentRange = result.range(at: 2)
            if stringRange.location != NSNotFound { storage.addAttribute(.foregroundColor, value: string, range: stringRange) }
            if commentRange.location != NSNotFound { storage.addAttribute(.foregroundColor, value: comment, range: commentRange) }
        }
    }

    private static func apply(
        _ pattern: String,
        color: NSColor,
        font: NSFont? = nil,
        options: NSRegularExpression.Options = [],
        to storage: NSTextStorage
    ) {
        guard let expression = expression(pattern, options: options) else { return }
        let range = NSRange(location: 0, length: storage.length)
        expression.enumerateMatches(in: storage.string, range: range) { result, _, _ in
            guard let matchRange = result?.range, matchRange.location != NSNotFound else { return }
            storage.addAttribute(.foregroundColor, value: color, range: matchRange)
            if let font { storage.addAttribute(.font, value: font, range: matchRange) }
        }
    }

    private static func expression(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(options.rawValue):\(pattern)" as NSString
        if let cached = regexCache.object(forKey: key) { return cached }
        guard let created = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        regexCache.setObject(created, forKey: key)
        return created
    }
}
