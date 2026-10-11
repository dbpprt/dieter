import Foundation

/// One visible row of a changed-file tree: a folder or a file, indented by depth.
struct ChangeTreeRow: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case folder
        case file
    }

    let kind: Kind
    /// The checkout-relative folder or file path.
    let path: String
    /// The file name, or a folder chain with single children joined ("cms/packages/dist").
    let name: String
    let depth: Int
    /// Changed files below a folder; 1 for a file.
    let fileCount: Int
}

/// Lays checkout-relative paths out as a VS Code-style tree: folders first,
/// then files, each in Git's byte order, with single-child folder chains compacted.
enum ChangeTree {
    private final class Node {
        var folders: [String: Node] = [:]
        var files: [String] = []
        var count = 0
    }

    /// The visible rows; folders in `collapsed` show without their contents.
    static func rows(paths: [String], collapsed: Set<String> = []) -> [ChangeTreeRow] {
        let root = Node()
        for path in paths {
            var node = root
            node.count += 1
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            for part in parts.dropLast() {
                let next = node.folders[part] ?? Node()
                node.folders[part] = next
                node = next
                node.count += 1
            }
            node.files.append(path)
        }
        var rows: [ChangeTreeRow] = []
        append(root, prefix: "", depth: 0, collapsed: collapsed, into: &rows)
        return rows
    }

    /// Every folder path in the tree, for collapsing or expanding all at once.
    static func folders(paths: [String]) -> Set<String> {
        Set(rows(paths: paths).filter { $0.kind == .folder }.map(\.path))
    }

    private static func append(
        _ node: Node, prefix: String, depth: Int, collapsed: Set<String>, into rows: inout [ChangeTreeRow]
    ) {
        for name in node.folders.keys.sorted(by: ordered) {
            var child = node.folders[name]!
            var label = name
            var path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            while child.files.isEmpty, child.folders.count == 1, let only = child.folders.first {
                label += "/\(only.key)"
                path += "/\(only.key)"
                child = only.value
            }
            rows.append(.init(kind: .folder, path: path, name: label, depth: depth, fileCount: child.count))
            if !collapsed.contains(path) {
                append(child, prefix: path, depth: depth + 1, collapsed: collapsed, into: &rows)
            }
        }
        for path in node.files.sorted(by: { ordered(filename($0), filename($1)) }) {
            rows.append(.init(kind: .file, path: path, name: filename(path), depth: depth, fileCount: 1))
        }
    }

    private static func filename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Git's byte order, so the tree walks files in the order the core steps through them.
    private static func ordered(_ left: String, _ right: String) -> Bool { left < right }
}
