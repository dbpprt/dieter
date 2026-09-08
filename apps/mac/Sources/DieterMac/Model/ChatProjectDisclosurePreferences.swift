import Foundation

struct ChatProjectDisclosurePreferences: Equatable {
    static let collapsedKey = "DieterChatsCollapsedProjects"
    static let expandedKey = "DieterChatsExpandedProjects"

    private(set) var collapsedProjectIDs: Set<String>
    private(set) var expandedProjectIDs: Set<String>

    init(
        collapsedProjectIDs: Set<String> = [],
        expandedProjectIDs: Set<String> = []
    ) {
        self.collapsedProjectIDs = collapsedProjectIDs
        self.expandedProjectIDs = expandedProjectIDs
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(
            collapsedProjectIDs: Set(defaults.stringArray(forKey: collapsedKey) ?? []),
            expandedProjectIDs: Set(defaults.stringArray(forKey: expandedKey) ?? [])
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(collapsedProjectIDs.sorted(), forKey: Self.collapsedKey)
        defaults.set(expandedProjectIDs.sorted(), forKey: Self.expandedKey)
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
