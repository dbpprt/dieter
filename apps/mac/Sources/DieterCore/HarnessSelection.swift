import DieterAPI

/// Shared fallback and option validation; each surface chooses whether an empty
/// provider means a server default or the first advertised harness.
package struct HarnessSelection: Equatable, Sendable {
    package var provider: String
    package var model: String
    package var effort: String
    package var providerOptions: [String: String]

    package init(
        provider: String = "", model: String = "", effort: String = "", providerOptions: [String: String] = [:]
    ) {
        self.provider = provider; self.model = model; self.effort = effort; self.providerOptions = providerOptions
    }

    package func resolved(in harnesses: [Dieter_V1_Harness], allowServerDefault: Bool = false) -> Self? {
        if allowServerDefault && provider.isEmpty { return Self() }
        guard let harness = harnesses.first(where: { $0.id == provider }) ?? harnesses.first else { return nil }
        let selected =
            harness.models.first(where: { $0.id == model })
            ?? harness.models.first(where: { $0.id == harness.defaultModel }) ?? harness.models.first
        let allowed = harness.effort.options.filter {
            selected?.efforts.isEmpty != false || selected!.efforts.contains($0.id)
        }.map(\.id)
        let effort: String
        if harness.id == provider, selected?.id == model,
            self.effort.isEmpty || allowed.contains(self.effort)
        {
            effort = self.effort
        } else if let value = selected?.defaultEffort, !value.isEmpty, allowed.isEmpty || allowed.contains(value) {
            effort = value
        } else {
            effort = allowed.first ?? ""
        }
        return Self(
            provider: harness.id, model: selected?.id ?? "", effort: selected == nil ? "" : effort,
            providerOptions: ProviderOptionValues.normalized(
                for: harness, model: selected?.id ?? "", saved: harness.id == provider ? providerOptions : [:]))
    }
}

package enum ProviderOptionValues {
    package static func options(for harness: Dieter_V1_Harness?, model: String) -> [Dieter_V1_ProviderOption] {
        guard let harness else { return [] }
        let selectedModel = model.isEmpty ? harness.defaultModel : model
        return harness.options.filter { $0.models.isEmpty || $0.models.contains(selectedModel) }
    }

    package static func defaults(for harness: Dieter_V1_Harness?, model: String?) -> [String: String] {
        normalized(for: harness, model: model ?? harness?.defaultModel ?? "", saved: [:])
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

    package static func defaults(for harness: Dieter_V1_Harness?) -> [String: String] {
        resolved(for: harness, existing: [:])
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
