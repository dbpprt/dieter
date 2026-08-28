import DieterAPI
import Foundation

enum ProjectSetupMode: String, CaseIterable, Identifiable, Sendable {
    case existing = "open"
    case newRepository = "create"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .existing: "Existing Git repo"
        case .newRepository: "New Git project"
        }
    }

    var pathLabel: String {
        switch self {
        case .existing: "Git working tree"
        case .newRepository: "New project path"
        }
    }

    var submitTitle: String {
        switch self {
        case .existing: "Add project"
        case .newRepository: "Create project"
        }
    }
}

struct ProjectSetupDraft: Equatable, Sendable {
    var mode: ProjectSetupMode = .existing
    var path = ""
    var name = ""
    var summary = ""
    var prompt = ""
    var boardName = "Main"
    var workflow = "review"
    var defaultWorkspaceMode = "worktree"
    var baseRemote = "origin"
    var baseBranch = "main"
    var validationCommands: [Dieter_V1_ValidationCommand] = []

    var canSubmit: Bool {
        !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !boardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !baseBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func request() -> Dieter_V1_CreateProjectRequest {
        var request = Dieter_V1_CreateProjectRequest()
        request.mode = mode.rawValue
        request.path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        request.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        request.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        request.prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        request.boardName = boardName.trimmingCharacters(in: .whitespacesAndNewlines)
        request.workflow = workflow
        request.defaultWorkspaceMode = defaultWorkspaceMode
        request.baseRemote = baseRemote.trimmingCharacters(in: .whitespacesAndNewlines)
        request.baseBranch = baseBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        request.validationCommands = validationCommands
        return request
    }
}

enum RemoteProjectPath {
    static func parentAndName(_ path: String) -> (parent: String, name: String) {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.count > 1 && (trimmed.hasSuffix("/") || trimmed.hasSuffix("\\")) {
            trimmed.removeLast()
        }
        guard let index = trimmed.lastIndex(where: { $0 == "/" || $0 == "\\" }) else {
            return ("", trimmed)
        }
        let parent = String(trimmed[..<index])
        let name = String(trimmed[trimmed.index(after: index)...])
        return (parent.isEmpty ? String(trimmed[index]) : parent, name)
    }

    static func lastComponent(_ path: String) -> String {
        path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
            .components(separatedBy: CharacterSet(charactersIn: "/\\"))
            .filter { !$0.isEmpty }
            .last ?? ""
    }

    static func joining(_ parent: String, _ child: String, separator: String) -> String {
        let separator = separator.isEmpty ? "/" : separator
        let cleanChild = child.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        guard !cleanChild.isEmpty else { return parent }
        guard !parent.isEmpty else { return cleanChild }
        if parent.hasSuffix(separator) { return parent + cleanChild }
        return parent + separator + cleanChild
    }

    static func validDirectoryName(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\\")
    }

    static func updatingSuggestedName(
        currentName: String,
        previousSuggestion: String,
        path: String
    ) -> (name: String, suggestion: String) {
        let suggestion = lastComponent(path)
        let name = currentName.isEmpty || currentName == previousSuggestion ? suggestion : currentName
        return (name, suggestion)
    }
}
