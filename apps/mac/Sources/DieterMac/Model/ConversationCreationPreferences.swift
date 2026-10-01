import DieterAPI
import Foundation

/// Device-local defaults shared by the new-card and new-chat composers.
/// Device-local defaults shared by the new-card and new-chat composers; the
/// shared core remembers them (`AppSession.creationPreferences`).
struct ConversationCreationPreferences: Equatable {
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
        projectReplicaEndpointIDs: [String: String]
    ) -> String {
        projectReplicaEndpointIDs[projectID] ?? activeEndpointID
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
