import Foundation

struct SidebarProjectNavigationPreferences: Equatable {
    static let orderKey = "NauclioSidebarProjectOrder"
    static let collapsedKey = "NauclioSidebarCollapsedProjects"

    static func applicationDefaults(arguments: [String] = ProcessInfo.processInfo.arguments) -> UserDefaults {
        guard let flag = arguments.firstIndex(of: "--sidebar-preferences-suite"),
              arguments.indices.contains(flag + 1),
              let defaults = UserDefaults(suiteName: arguments[flag + 1]) else { return .standard }
        return defaults
    }

    private(set) var projectOrder: [String]
    private(set) var collapsedProjectIDs: Set<String>

    init(projectOrder: [String] = [], collapsedProjectIDs: Set<String> = []) {
        self.projectOrder = Self.unique(projectOrder)
        self.collapsedProjectIDs = collapsedProjectIDs
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(
            projectOrder: defaults.stringArray(forKey: orderKey) ?? [],
            collapsedProjectIDs: Set(defaults.stringArray(forKey: collapsedKey) ?? [])
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(projectOrder, forKey: Self.orderKey)
        defaults.set(collapsedProjectIDs.sorted(), forKey: Self.collapsedKey)
    }

    func orderedIDs(from availableIDs: [String]) -> [String] {
        let available = Self.unique(availableIDs)
        let availableSet = Set(available)
        let preferred = projectOrder.filter(availableSet.contains)
        let preferredSet = Set(preferred)
        return preferred + available.filter { !preferredSet.contains($0) }
    }

    func isCollapsed(_ projectID: String) -> Bool {
        collapsedProjectIDs.contains(projectID)
    }

    mutating func toggleCollapsed(_ projectID: String) {
        if !collapsedProjectIDs.insert(projectID).inserted {
            collapsedProjectIDs.remove(projectID)
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
