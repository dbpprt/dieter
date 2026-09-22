import DieterAPI
import DieterClient
import Foundation

extension AppSession {
    func bindSharedNavigation() {
        sharedNavigation.changed = { [weak self] in self?.applySharedNavigation() }
        sharedNavigation.bind(rpc)
    }
    func applySharedNavigation() {
        guard !applyingSharedNavigation else { return }
        applyingSharedNavigation = true
        defer { applyingSharedNavigation = false }
        let values = sharedNavigation.values
        func value<T: Decodable>(_ key: String, as: T.Type) -> T? {
            values[key].flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
        func ids(_ prefix: String, field: String) -> [String] {
            values.keys.filter { $0.hasPrefix(prefix + ".") && $0.hasSuffix("." + field) }
                .map { String($0.dropFirst(prefix.count + 1).dropLast(field.count + 1)) }.sorted()
        }
        func ordered(_ prefix: String, parent: String = "") -> [String] {
            ids(prefix, field: "position").filter {
                value("\(prefix).\($0).position", as: SharedPosition.self)?.parent == parent
            }
            .sorted {
                let a = value("\(prefix).\($0).position", as: SharedPosition.self)?.rank ?? ""
                let b = value("\(prefix).\($1).position", as: SharedPosition.self)?.rank ?? ""
                return a == b ? $0 < $1 : a < b
            }
        }
        func folders(_ scope: String) -> NavigationFolderPreferences {
            let prefix = scope + "-folder"
            let names = ids(prefix, field: "name")
            let order = ordered(prefix)
            return NavigationFolderPreferences(
                folders: (order.filter(names.contains) + names.filter { !order.contains($0) }).compactMap { id in
                    guard let name = value("\(prefix).\(id).name", as: String.self) else { return nil }
                    return NavigationFolder(
                        id: id, name: name, itemIDs: ordered(scope + "-item", parent: id),
                        isExpanded: value("\(prefix).\(id).expanded", as: Bool.self) ?? true)
                })
        }
        func enabled(_ prefix: String, inverted: Bool = false) -> Set<String> {
            Set(ids(prefix, field: "expanded").filter { value("\(prefix).\($0).expanded", as: Bool.self) == !inverted })
        }
        sidebarProjectFolders = folders("projects")
        allChatsFolders = folders("chats")
        sidebarProjectNavigation = .init(
            projectOrder: ordered("projects-order"), expandedProjectIDs: enabled("projects-disclosure"))
        pinnedProjectNavigation = .init(projectOrder: ordered("projects-pinned"))
        pinnedChatNavigation = .init(chatOrder: ordered("pinned-order"))
        chatProjectDisclosure = .init(
            collapsedProjectIDs: enabled("chats-section", inverted: true),
            expandedProjectIDs: enabled("chats-disclosure"))
        sharedLaneSortDirections = values.filter { $0.key.hasPrefix("lane.") }.compactMapValues {
            try? JSONDecoder().decode(String.self, from: $0)
        }
        navigationPendingCount = sharedNavigation.pendingCount
        navigationSyncError = sharedNavigation.error
    }
    func syncNavigationFolders(_ old: NavigationFolderPreferences, _ next: NavigationFolderPreferences, scope: String) {
        guard !applyingSharedNavigation else { return }
        let prefix = scope + "-folder"
        for folder in old.folders where !next.folders.contains(where: { $0.id == folder.id }) {
            sharedNavigation.delete("\(prefix).\(folder.id).name")
        }
        for folder in next.folders {
            let previous = old.folders.first { $0.id == folder.id }
            if previous?.name != folder.name {
                sharedNavigation.put("\(prefix).\(folder.id).name", folder.name, requiresExisting: previous != nil)
            }
            if previous?.isExpanded != folder.isExpanded {
                sharedNavigation.put("\(prefix).\(folder.id).expanded", folder.isExpanded)
            }
            syncNavigationOrder(previous?.itemIDs ?? [], folder.itemIDs, prefix: scope + "-item", parent: folder.id)
        }
        let newMembers = Set(next.folders.flatMap(\.itemIDs))
        for id in old.folders.flatMap(\.itemIDs) where !newMembers.contains(id) {
            // A deleted folder projects its retained memberships as unfiled.
            if let oldFolder = old.folder(containing: id), next.folders.contains(where: { $0.id == oldFolder.id }) {
                sharedNavigation.move("\(scope)-item.\(id).position")
            }
        }
        syncNavigationOrder(old.folders.map(\.id), next.folders.map(\.id), prefix: prefix)
    }
    func syncNavigationOrder(_ old: [String], _ next: [String], prefix: String, parent: String = "") {
        guard !applyingSharedNavigation else { return }
        let changed = Set(
            next.difference(from: old).compactMap { change -> String? in
                if case .insert(_, let id, _) = change { return id }; return nil
            })
        for (index, id) in next.enumerated() where changed.contains(id) {
            let after = index > 0 ? "\(prefix).\(next[index - 1]).position" : ""
            let before =
                next.dropFirst(index + 1).first { !changed.contains($0) }.map { "\(prefix).\($0).position" } ?? ""
            sharedNavigation.move("\(prefix).\(id).position", parent: parent, after: after, before: before)
        }
    }
    func syncNavigationMembership(_ old: [String], _ next: [String], prefix: String) {
        guard !applyingSharedNavigation else { return }
        let nextIDs = Set(next)
        for id in old where !nextIDs.contains(id) {
            sharedNavigation.delete("\(prefix).\(id).position")
        }
        syncNavigationOrder(old.filter(nextIDs.contains), next, prefix: prefix)
    }
    func syncNavigationFlags(_ old: Set<String>, _ next: Set<String>, prefix: String, inverted: Bool = false) {
        guard !applyingSharedNavigation else { return }
        for id in old.symmetricDifference(next) {
            sharedNavigation.put("\(prefix).\(id).expanded", next.contains(id) != inverted)
        }
    }
    func laneSortDirection(board: String, lane: String) -> BoardCardSortDirection {
        sharedLaneSortDirections["lane.\(board).\(lane).sort"] == "ascending" ? .ascending : .descending
    }
    func toggleLaneSort(board: String, lane: String) {
        let next = laneSortDirection(board: board, lane: lane) == .ascending ? "descending" : "ascending"
        sharedNavigation.put("lane.\(board).\(lane).sort", next)
    }
}
