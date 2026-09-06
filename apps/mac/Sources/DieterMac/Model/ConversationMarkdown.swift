import Foundation

enum ConversationMarkdownAlignment: Equatable {
    case leading
    case center
    case trailing
}

struct ConversationMarkdownTable: Equatable {
    let headers: [String]
    let alignments: [ConversationMarkdownAlignment]
    let rows: [[String]]
}

enum ConversationMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(String)
    case code(String)
    case table(ConversationMarkdownTable)
}

enum ConversationMarkdownParser {
    static func parse(_ source: String) -> [ConversationMarkdownBlock] {
        let lines = source.components(separatedBy: .newlines)
        var blocks: [ConversationMarkdownBlock] = []
        var pending: [String] = []
        var inCode = false
        var index = 0

        func flush() {
            guard !pending.isEmpty else { return }
            let text = pending.joined(separator: "\n").trimmingCharacters(in: .newlines)
            pending.removeAll(keepingCapacity: true)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            blocks.append(inCode ? .code(text) : .paragraph(text))
        }

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush()
                inCode.toggle()
                index += 1
                continue
            }

            if !inCode,
               index + 1 < lines.count,
               let headers = tableCells(lines[index]),
               let alignments = tableDelimiter(lines[index + 1]),
               headers.count == alignments.count
            {
                flush()
                index += 2
                var rows: [[String]] = []
                while index < lines.count, let cells = tableCells(lines[index]) {
                    rows.append(headers.indices.map { $0 < cells.count ? cells[$0] : "" })
                    index += 1
                }
                blocks.append(.table(.init(headers: headers, alignments: alignments, rows: rows)))
                continue
            }

            if !inCode, line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else if !inCode, let heading = heading(line) {
                flush()
                blocks.append(.heading(level: heading.level, text: heading.text))
            } else if !inCode, let bullet = bullet(line) {
                flush()
                blocks.append(.bullet(bullet))
            } else {
                pending.append(line)
            }
            index += 1
        }
        flush()
        return blocks
    }

    static func tableCells(_ source: String) -> [String]? {
        var content = source.trimmingCharacters(in: .whitespaces)
        guard content.contains("|") else { return nil }
        if content.first == "|" { content.removeFirst() }
        if content.last == "|", !content.hasSuffix("\\|") { content.removeLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for character in content {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                current.append(character)
            } else if character == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func tableDelimiter(_ source: String) -> [ConversationMarkdownAlignment]? {
        guard let cells = tableCells(source) else { return nil }
        var alignments: [ConversationMarkdownAlignment] = []
        for cell in cells {
            let marker = cell.trimmingCharacters(in: .whitespaces)
            let dashes = marker.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            if marker.hasPrefix(":"), marker.hasSuffix(":") {
                alignments.append(.center)
            } else if marker.hasSuffix(":") {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }
        return alignments
    }

    private static func heading(_ source: String) -> (level: Int, text: String)? {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        let level = trimmed.prefix { $0 == "#" }.count
        guard (1...4).contains(level), trimmed.dropFirst(level).first == " " else { return nil }
        return (level, String(trimmed.dropFirst(level + 1)))
    }

    private static func bullet(_ source: String) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return nil }
        return String(trimmed.dropFirst(2))
    }
}
