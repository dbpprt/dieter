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
        guard let harness = harnesses.first(where: { $0.id == provider }) ?? harnesses.first else {
            return nil
        }
        guard let selectedModel = harness.models.first(where: { $0.id == model })
            ?? harness.models.first(where: { $0.id == harness.defaultModel })
            ?? harness.models.first else {
            return ConversationCreationSelection(
                provider: harness.id,
                model: "",
                effort: "",
                workspaceMode: workspaceMode
            )
        }

        let allowedEfforts = harness.effort.options.filter {
            selectedModel.efforts.isEmpty || selectedModel.efforts.contains($0.id)
        }
        let resolvedEffort: String
        if harness.id == provider,
           selectedModel.id == model,
           (effort.isEmpty || allowedEfforts.contains(where: { $0.id == effort })) {
            resolvedEffort = effort
        } else if !selectedModel.defaultEffort.isEmpty,
                  allowedEfforts.isEmpty || allowedEfforts.contains(where: { $0.id == selectedModel.defaultEffort }) {
            resolvedEffort = selectedModel.defaultEffort
        } else {
            resolvedEffort = allowedEfforts.first?.id ?? ""
        }

        return ConversationCreationSelection(
            provider: harness.id,
            model: selectedModel.id,
            effort: resolvedEffort,
            workspaceMode: workspaceMode
        )
    }
}

struct ConversationCreationSelection: Equatable {
    var provider: String
    var model: String
    var effort: String
    var workspaceMode: ConversationWorkspaceMode
}
