import DieterAPI
import Foundation

/// Device-local defaults shared by the new-card and new-chat composers.
struct ConversationCreationPreferences: Equatable {
    static let providerKey = "DieterConversationCreationProvider"
    static let modelKey = "DieterConversationCreationModel"
    static let effortKey = "DieterConversationCreationEffort"
    static let workspaceModeKey = "DieterConversationCreationWorkspaceMode"

    var provider: String
    var model: String
    var effort: String
    var workspaceMode: ConversationWorkspaceMode

    init(
        provider: String = "",
        model: String = "",
        effort: String = "",
        workspaceMode: ConversationWorkspaceMode = .worktree
    ) {
        self.provider = provider
        self.model = model
        self.effort = effort
        self.workspaceMode = workspaceMode
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(
            provider: defaults.string(forKey: providerKey) ?? "",
            model: defaults.string(forKey: modelKey) ?? "",
            effort: defaults.string(forKey: effortKey) ?? "",
            workspaceMode: defaults.string(forKey: workspaceModeKey)
                .flatMap(ConversationWorkspaceMode.init(rawValue:)) ?? .worktree
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(provider, forKey: Self.providerKey)
        defaults.set(model, forKey: Self.modelKey)
        defaults.set(effort, forKey: Self.effortKey)
        defaults.set(workspaceMode.rawValue, forKey: Self.workspaceModeKey)
    }

    func resolved(in harnesses: [Dieter_V1_Harness]) -> ConversationCreationSelection? {
        guard let selection = HarnessSelection(provider: provider, model: model, effort: effort).resolved(in: harnesses)
        else { return nil }
        return ConversationCreationSelection(
            provider: selection.provider, model: selection.model,
            effort: selection.effort, workspaceMode: workspaceMode)
    }
}

struct ConversationCreationSelection: Equatable {
    var provider: String
    var model: String
    var effort: String
    var workspaceMode: ConversationWorkspaceMode
}

enum ConversationHarnessCatalogDirectory {
    static func endpointID(
        projectID: String,
        activeEndpointID: String,
        projectEndpointIDs: [String: String]
    ) -> String {
        projectEndpointIDs[projectID] ?? activeEndpointID
    }

    static func catalog(
        endpointID: String,
        activeEndpointID: String,
        activeCatalog: Dieter_V1_HarnessCatalog,
        catalogsByEndpoint: [String: Dieter_V1_HarnessCatalog]
    ) -> Dieter_V1_HarnessCatalog? {
        if let catalog = catalogsByEndpoint[endpointID], !catalog.harnesses.isEmpty {
            return catalog
        }
        return endpointID == activeEndpointID && !activeCatalog.harnesses.isEmpty ? activeCatalog : nil
    }
}
