import Foundation

struct SidebarProjectNavigationPreferences: Equatable {
    static let orderKey = "DieterSidebarProjectOrder"
    // Projects are compressed (title + initials only) by default. This set records
    // the projects the person has explicitly expanded to reveal boards inline.
    static let expandedKey = "DieterSidebarExpandedProjects"

    static func applicationDefaults(arguments: [String] = ProcessInfo.processInfo.arguments) -> UserDefaults {
        guard let flag = arguments.firstIndex(of: "--sidebar-preferences-suite"),
              arguments.indices.contains(flag + 1),
              let defaults = UserDefaults(suiteName: arguments[flag + 1]) else { return .standard }
        return defaults
    }

    private(set) var projectOrder: [String]
    private(set) var expandedProjectIDs: Set<String>

    init(projectOrder: [String] = [], expandedProjectIDs: Set<String> = []) {
        self.projectOrder = Self.unique(projectOrder)
        self.expandedProjectIDs = expandedProjectIDs
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(
            projectOrder: defaults.stringArray(forKey: orderKey) ?? [],
            expandedProjectIDs: Set(defaults.stringArray(forKey: expandedKey) ?? [])
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(projectOrder, forKey: Self.orderKey)
        defaults.set(expandedProjectIDs.sorted(), forKey: Self.expandedKey)
    }

    func orderedIDs(from availableIDs: [String]) -> [String] {
        let available = Self.unique(availableIDs)
        let availableSet = Set(available)
        let preferred = projectOrder.filter(availableSet.contains)
        let preferredSet = Set(preferred)
        return preferred + available.filter { !preferredSet.contains($0) }
    }

    func isExpanded(_ projectID: String) -> Bool {
        expandedProjectIDs.contains(projectID)
    }

    mutating func toggleExpanded(_ projectID: String) {
        if !expandedProjectIDs.insert(projectID).inserted {
            expandedProjectIDs.remove(projectID)
        }
    }

    @discardableResult
    mutating func move(_ projectID: String, before targetProjectID: String?, availableIDs: [String]) -> Bool {
        guard projectID != targetProjectID else { return false }
        var visibleOrder = orderedIDs(from: availableIDs)
        guard let sourceIndex = visibleOrder.firstIndex(of: projectID) else { return false }
        let previousOrder = visibleOrder
        visibleOrder.remove(at: sourceIndex)

        let insertionIndex: Int
        if let targetProjectID, let targetIndex = visibleOrder.firstIndex(of: targetProjectID) {
            insertionIndex = targetIndex
        } else {
            insertionIndex = visibleOrder.endIndex
        }
        visibleOrder.insert(projectID, at: insertionIndex)

        guard visibleOrder != previousOrder else { return false }
        let visibleIDs = Set(availableIDs)
        projectOrder = visibleOrder + projectOrder.filter { !visibleIDs.contains($0) }
        return true
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
