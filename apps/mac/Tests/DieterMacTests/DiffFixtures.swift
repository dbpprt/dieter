import Foundation
@testable import DieterMac

/// Numbers a unified diff the way the core's `UnifiedDiff` does, so layout
/// tests can describe diffs as patches. The app shows the core's rows.
enum DiffFixtures {
    /// Git metadata emitted between a `diff --git` line and its first hunk.
    private static let metadataPrefixes = [
        "+++", "---", "index ",
        "new file mode", "deleted file mode", "old mode", "new mode",
        "similarity index", "dissimilarity index",
        "rename from", "rename to", "copy from", "copy to", "Binary files",
    ]

    static func parse(_ patch: String) -> [UnifiedDiffLine] {
        var result: [UnifiedDiffLine] = []
        var oldLine: Int?
        var newLine: Int?
        for (index, raw) in patch.split(separator: "\n", omittingEmptySubsequences: false).map(
            String.init
        ).enumerated() {
            // Every hunk line has a prefix, including a blank context line
            // (" "). A bare empty string is a separator or final newline.
            guard !raw.isEmpty else { continue }
            if raw.hasPrefix("@@"), let ranges = hunkRanges(raw) {
                oldLine = ranges.old
                newLine = ranges.new
                result.append(.init(id: index, kind: .hunk, text: raw, oldLine: nil, newLine: nil))
            } else if raw.hasPrefix("diff ") {
                // A new file section: whole-commit patches concatenate several.
                oldLine = nil
                newLine = nil
                result.append(.init(id: index, kind: .header, text: raw, oldLine: nil, newLine: nil))
            } else if raw.hasPrefix("\\ No newline") {
                result.append(.init(id: index, kind: .header, text: raw, oldLine: nil, newLine: nil))
            } else if oldLine == nil, newLine == nil, metadataPrefixes.contains(where: raw.hasPrefix) {
                result.append(.init(id: index, kind: .header, text: raw, oldLine: nil, newLine: nil))
            } else if raw.hasPrefix("+") {
                result.append(.init(id: index, kind: .addition, text: raw, oldLine: nil, newLine: newLine))
                newLine = newLine.map { $0 + 1 }
            } else if raw.hasPrefix("-") {
                result.append(.init(id: index, kind: .deletion, text: raw, oldLine: oldLine, newLine: nil))
                oldLine = oldLine.map { $0 + 1 }
            } else {
                result.append(
                    .init(id: index, kind: .context, text: raw, oldLine: oldLine, newLine: newLine))
                oldLine = oldLine.map { $0 + 1 }
                newLine = newLine.map { $0 + 1 }
            }
        }
        return result
    }

    private static func hunkRanges(_ value: String) -> (old: Int, new: Int)? {
        let pieces = value.split(separator: " ")
        guard pieces.count >= 3 else { return nil }
        func start(_ piece: Substring) -> Int? {
            Int(piece.dropFirst().split(separator: ",", maxSplits: 1).first ?? "")
        }
        guard let old = start(pieces[1]), let new = start(pieces[2]) else { return nil }
        return (old, new)
    }
}

