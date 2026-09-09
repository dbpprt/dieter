import Foundation

package enum ProjectFileLanguage: String, CaseIterable, Sendable {
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

    package static func detect(filename: String) -> ProjectFileLanguage {
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

    package var displayName: String {
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

    package var keywords: [String] {
        switch self {
        case .swift:
            [
                "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
                "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
                "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "isolated", "let",
                "nil", "nonisolated", "open", "private", "protocol", "public", "repeat", "rethrows", "return", "self",
                "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try",
                "typealias", "var", "where", "while",
            ]
        case .go:
            [
                "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func",
                "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct",
                "switch", "type", "var",
            ]
        case .kotlin:
            [
                "as", "break", "by", "catch", "class", "companion", "const", "continue", "data", "do", "else", "enum",
                "false", "finally", "for", "fun", "if", "import", "in", "interface", "internal", "is", "lateinit",
                "null", "object", "open", "operator", "override", "package", "private", "protected", "public", "return",
                "sealed", "suspend", "this", "throw", "true", "try", "typealias", "val", "var", "when", "where",
                "while",
            ]
        case .java:
            [
                "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue",
                "default", "do", "double", "else", "enum", "extends", "false", "final", "finally", "float", "for", "if",
                "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "null", "package",
                "private", "protected", "public", "return", "short", "static", "strictfp", "super", "switch",
                "synchronized", "this", "throw", "throws", "transient", "true", "try", "void", "volatile", "while",
            ]
        case .javascript, .typescript:
            [
                "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "declare",
                "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "from",
                "function", "if", "implements", "import", "in", "instanceof", "interface", "keyof", "let", "new",
                "null", "of", "package", "private", "protected", "public", "readonly", "return", "static", "super",
                "switch", "this", "throw", "true", "try", "type", "typeof", "undefined", "var", "void", "while", "with",
                "yield",
            ]
        case .python:
            [
                "and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del", "elif",
                "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda",
                "match", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True", "try", "while", "with",
                "yield",
            ]
        case .ruby:
            [
                "alias", "and", "begin", "break", "case", "class", "def", "defined", "do", "else", "elsif", "end",
                "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "rescue", "retry",
                "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield",
            ]
        case .rust:
            [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false",
                "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
                "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while",
            ]
        case .c, .cpp, .objectiveC:
            [
                "auto", "bool", "break", "case", "catch", "char", "class", "const", "constexpr", "continue", "default",
                "delete", "do", "double", "else", "enum", "explicit", "extern", "false", "float", "for", "friend", "if",
                "inline", "int", "long", "namespace", "new", "nullptr", "operator", "private", "protected", "public",
                "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this",
                "throw", "true", "try", "typedef", "typename", "union", "unsigned", "using", "virtual", "void",
                "volatile", "while",
            ]
        case .shell:
            [
                "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local",
                "readonly", "return", "select", "then", "until", "while",
            ]
        case .sql:
            [
                "ADD", "ALTER", "AND", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASE", "COMMIT", "CREATE", "DELETE",
                "DESC", "DISTINCT", "DROP", "ELSE", "END", "EXISTS", "FROM", "FULL", "GROUP", "HAVING", "IN", "INDEX",
                "INNER", "INSERT", "INTO", "IS", "JOIN", "LEFT", "LIKE", "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER",
                "OUTER", "PRIMARY", "REFERENCES", "RETURNING", "RIGHT", "ROLLBACK", "SELECT", "SET", "TABLE", "THEN",
                "UNION", "UNIQUE", "UPDATE", "VALUES", "WHEN", "WHERE", "WITH",
            ]
        default: []
        }
    }

    package var commentPattern: String? {
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

package enum ProjectFilePresentation {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico", "svg",
    ]

    package static func isImage(filename: String, mimeType: String) -> Bool {
        if mimeType.lowercased().hasPrefix("image/") { return true }
        return imageExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    package static func bytes(binary: Bool, content: String, data: Data) -> Data {
        binary ? data : Data(content.utf8)
    }
}
