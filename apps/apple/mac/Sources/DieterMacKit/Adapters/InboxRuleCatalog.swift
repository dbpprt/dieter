import DieterAPI
import Foundation

/// The projects and labels an Inbox rule can name, as plain values for the rules sheet.
struct InboxRuleCatalog {
    struct Project: Identifiable {
        let id: String
        let name: String
    }

    struct Label: Identifiable {
        let id: String
        let name: String
        let color: String
    }

    /// A board's labels under the project they belong to.
    struct LabelGroup: Identifiable {
        let id: String
        let title: String
        let labels: [Label]
    }

    let projects: [Project]
    let labelGroups: [LabelGroup]

    var projectNames: [String: String] {
        Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    var labelNames: [String: String] {
        Dictionary(
            labelGroups.flatMap(\.labels).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}

extension DieterStore {
    var inboxRuleCatalog: InboxRuleCatalog {
        let listed = projects
        return InboxRuleCatalog(
            projects: listed.filter { !$0.archived }.map { .init(id: $0.id, name: $0.name) },
            labelGroups: listed.flatMap { project in
                boards(for: project.id).filter { !$0.labels.isEmpty }.map { board in
                    InboxRuleCatalog.LabelGroup(
                        id: board.id, title: "\(project.name) · \(board.name)",
                        labels: board.labels.map { .init(id: $0.id, name: $0.name, color: $0.color) })
                }
            })
    }
}
