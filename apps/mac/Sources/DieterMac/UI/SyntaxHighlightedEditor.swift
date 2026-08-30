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

    var keywords: [String] {
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

    var commentPattern: String? {
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
    let session: FileEditorSession
    let documentKey: String
    let text: String
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
        textView.font = FileSyntaxHighlighter.baseFont
        textView.textColor = FileSyntaxHighlighter.foreground
        context.coordinator.textView = textView
        context.coordinator.container = container
        session.attach(textView, documentKey: documentKey, initialText: text)
        context.coordinator.highlight(force: true)
        return container
    }

    func updateNSView(_ container: SyntaxEditorContainer, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.textView != nil else { return }
        if session.documentKey != documentKey {
            context.coordinator.isApplyingUpdate = true
            session.prepare(documentKey: documentKey, text: text)
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
        private var pendingEditedRange: NSRange?
        private var pendingLineDelta = 0
        private var fullHighlightTask: Task<Void, Never>?

        init(parent: SyntaxHighlightedEditor) { self.parent = parent }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            let current = textView.string as NSString
            let removed = current.substring(with: affectedCharRange)
            let replacement = replacementString ?? ""
            pendingLineDelta = replacement.utf8.filter { $0 == 0x0A }.count - removed.utf8.filter { $0 == 0x0A }.count
            pendingEditedRange = NSRange(
                location: affectedCharRange.location,
                length: (replacement as NSString).length
            )
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingUpdate, textView != nil else { return }
            parent.session.didEdit(lineDelta: pendingLineDelta)
            highlightEditedRange(pendingEditedRange)
            pendingEditedRange = nil
            pendingLineDelta = 0
            container?.needsLayout = true
        }

        func highlight(force: Bool) {
            guard let textView, let storage = textView.textStorage else { return }
            let language = ProjectFileLanguage.detect(filename: parent.filename)
            guard force || highlightedLanguage != language else { return }
            highlightedLanguage = language
            textView.typingAttributes = FileSyntaxHighlighter.baseAttributes
            guard storage.length <= FileSyntaxHighlighter.backgroundFullHighlightLimit else { return }
            scheduleFullHighlight(language: language, delayNanoseconds: 0)
        }

        private func highlightEditedRange(_ editedRange: NSRange?) {
            guard let textView, let storage = textView.textStorage, let editedRange else { return }
            let source = storage.string as NSString
            let safeLocation = min(editedRange.location, source.length)
            let safeLength = min(editedRange.length, source.length - safeLocation)
            let lineRange = source.lineRange(for: NSRange(location: safeLocation, length: safeLength))
            let language = ProjectFileLanguage.detect(filename: parent.filename)
            FileSyntaxHighlighter.apply(
                FileSyntaxHighlightPlanner.build(source: storage.string, language: language, requestedRange: lineRange),
                to: storage
            )
            guard storage.length <= FileSyntaxHighlighter.backgroundFullHighlightLimit else { return }
            scheduleFullHighlight(language: language, delayNanoseconds: 550_000_000)
        }

        private func scheduleFullHighlight(language: ProjectFileLanguage, delayNanoseconds: UInt64) {
            guard let storage = textView?.textStorage else { return }
            fullHighlightTask?.cancel()
            let source = storage.string
            let revision = parent.session.revision
            fullHighlightTask = Task { @MainActor [weak self] in
                if delayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                }
                guard !Task.isCancelled else { return }
                let plan = await Task.detached(priority: .userInitiated) {
                    FileSyntaxHighlightPlanner.build(source: source, language: language)
                }.value
                guard !Task.isCancelled,
                      let self,
                      self.parent.session.revision == revision,
                      let textView = self.textView,
                      let storage = textView.textStorage else { return }
                let selectedRanges = textView.selectedRanges
                FileSyntaxHighlighter.apply(plan, to: storage)
                textView.selectedRanges = selectedRanges
            }
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
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.minSize = scrollView.contentSize
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
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
        guard viewport.width > 0, let textContainer = textView.textContainer else { return }
        textContainer.containerSize = NSSize(width: viewport.width, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = viewport
        if textView.frame.width != viewport.width {
            textView.frame.size.width = viewport.width
        }
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
    static let backgroundFullHighlightLimit = 180_000
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

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 28
        return [.font: baseFont, .foregroundColor: foreground, .paragraphStyle: paragraph]
    }

    static func apply(_ plan: FileSyntaxHighlightPlan, to storage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let range = NSIntersectionRange(NSRange(location: plan.location, length: plan.length), fullRange)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: range)
        guard range.length > 0 else { storage.endEditing(); return }
        for run in plan.runs {
            let runRange = NSIntersectionRange(NSRange(location: run.location, length: run.length), fullRange)
            guard runRange.length > 0 else { continue }
            storage.addAttribute(.foregroundColor, value: color(for: run.style), range: runRange)
            if run.style == .keywordBold {
                storage.addAttribute(.font, value: boldFont, range: runRange)
            }
        }
        storage.endEditing()
    }

    private static func color(for style: FileSyntaxHighlightStyle) -> NSColor {
        switch style {
        case .number: number
        case .type: type
        case .function: function
        case .keyword, .keywordBold: keyword
        case .property: property
        case .string: string
        case .comment: comment
        }
    }
}
