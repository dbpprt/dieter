import DieterAPI

/// Provider option values against a harness's advertised options.
package enum ProviderOptionValues {
    package static func options(for harness: Dieter_V1_Harness?, model: String) -> [Dieter_V1_ProviderOption] {
        guard let harness else { return [] }
        let selectedModel = model.isEmpty ? harness.defaultModel : model
        return harness.options.filter { $0.models.isEmpty || $0.models.contains(selectedModel) }
    }

    package static func normalized(
        for harness: Dieter_V1_Harness?,
        model: String,
        saved: [String: String]
    ) -> [String: String] {
        resolved(for: harness, existing: saved).filter { key, _ in
            options(for: harness, model: model).contains { $0.id == key }
        }
    }

    package static func isEnabled(_ option: Dieter_V1_ProviderOption, conversationLocked: Bool) -> Bool {
        !conversationLocked || option.mutable
    }

    package static func resolved(for harness: Dieter_V1_Harness?, existing: [String: String]) -> [String: String] {
        Dictionary(
            (harness?.options ?? []).map { option in
                var value = existing[option.id] ?? option.defaultValue
                switch option.type.lowercased() {
                case "bool", "boolean":
                    value = ["true", "false"].contains(value.lowercased()) ? value.lowercased() : option.defaultValue
                case "enum", "select":
                    if !option.choices.contains(where: { $0.value == value }) { value = option.defaultValue }
                default: break
                }
                return (option.id, value)
            }, uniquingKeysWith: { first, _ in first })
    }
}
