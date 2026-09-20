import Foundation

struct ChatProjectDisclosurePreferences: Equatable {

    private(set) var collapsedProjectIDs: Set<String>
    private(set) var expandedProjectIDs: Set<String>

    init(
        collapsedProjectIDs: Set<String> = [],
        expandedProjectIDs: Set<String> = []
    ) {
        self.collapsedProjectIDs = collapsedProjectIDs
        self.expandedProjectIDs = expandedProjectIDs
    }

    func isCollapsed(_ projectID: String) -> Bool {
        collapsedProjectIDs.contains(projectID)
    }

    func isExpanded(_ projectID: String) -> Bool {
        expandedProjectIDs.contains(projectID)
    }

    mutating func toggleCollapsed(_ projectID: String) {
        toggle(projectID, in: &collapsedProjectIDs)
    }

    mutating func toggleExpanded(_ projectID: String) {
        toggle(projectID, in: &expandedProjectIDs)
    }

    private func toggle(_ projectID: String, in projectIDs: inout Set<String>) {
        if !projectIDs.insert(projectID).inserted {
            projectIDs.remove(projectID)
        }
    }
}
