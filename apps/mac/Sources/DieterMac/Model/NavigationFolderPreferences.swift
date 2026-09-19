import Foundation

struct NavigationFolder: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var itemIDs: [String]
    var isExpanded: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        itemIDs: [String] = [],
        isExpanded: Bool = true
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.itemIDs = Self.unique(itemIDs)
        self.isExpanded = isExpanded
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Mac-only navigation organization. Folders intentionally live in local
/// preferences: they arrange daemon-owned projects and chats without changing
/// the underlying resources or their behavior on other clients.
struct NavigationFolderPreferences: Equatable {
    enum Scope {
        case projects
        case chats

        var storageKey: String {
            switch self {
            case .projects: "DieterSidebarProjectFolders"
            case .chats: "DieterAllChatsFolders"
            }
        }
    }

    private(set) var folders: [NavigationFolder]

    init(folders: [NavigationFolder] = []) {
        var seenFolderIDs: Set<String> = []
        var assignedItemIDs: Set<String> = []
        self.folders = folders.compactMap { folder in
            let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !folder.id.isEmpty, !name.isEmpty, seenFolderIDs.insert(folder.id).inserted else { return nil }
            let itemIDs = folder.itemIDs.filter { assignedItemIDs.insert($0).inserted }
            return NavigationFolder(
                id: folder.id,
                name: name,
                itemIDs: itemIDs,
                isExpanded: folder.isExpanded
            )
        }
    }

    static func load(scope: Scope, from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: scope.storageKey),
            let folders = try? JSONDecoder().decode([NavigationFolder].self, from: data)
        else { return Self() }
        return Self(folders: folders)
    }

    func save(scope: Scope, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        defaults.set(data, forKey: scope.storageKey)
    }

    func folder(containing itemID: String) -> NavigationFolder? {
        folders.first { $0.itemIDs.contains(itemID) }
    }

    func unfiledIDs(from availableIDs: [String]) -> [String] {
        let assigned = Set(folders.flatMap(\.itemIDs))
        return availableIDs.filter { !assigned.contains($0) }
    }

    @discardableResult
    mutating func createFolder(named proposedName: String) -> String? {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !containsFolder(named: name) else { return nil }
        let folder = NavigationFolder(name: name)
        folders.append(folder)
        return folder.id
    }

    @discardableResult
    mutating func renameFolder(_ folderID: String, to proposedName: String) -> Bool {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
            !containsFolder(named: name, excluding: folderID),
            let index = folders.firstIndex(where: { $0.id == folderID }),
            folders[index].name != name
        else { return false }
        folders[index].name = name
        return true
    }

    @discardableResult
    mutating func deleteFolder(_ folderID: String) -> Bool {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return false }
        folders.remove(at: index)
        return true
    }

    @discardableResult
    mutating func toggleExpanded(_ folderID: String) -> Bool {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return false }
        folders[index].isExpanded.toggle()
        return true
    }

    /// Passing `nil` removes the item from its folder. Moving to a folder also
    /// removes any stale duplicate membership before appending it there.
    @discardableResult
    mutating func moveItem(_ itemID: String, to folderID: String?) -> Bool {
        guard !itemID.isEmpty else { return false }
        if let folderID, !folders.contains(where: { $0.id == folderID }) { return false }

        let previous = folders
        for index in folders.indices {
            folders[index].itemIDs.removeAll { $0 == itemID }
        }
        if let folderID, let index = folders.firstIndex(where: { $0.id == folderID }) {
            folders[index].itemIDs.append(itemID)
        }
        return folders != previous
    }

    private func containsFolder(named name: String, excluding folderID: String? = nil) -> Bool {
        folders.contains {
            $0.id != folderID
                && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }
}
