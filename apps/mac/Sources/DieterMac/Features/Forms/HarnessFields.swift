import AppKit
import DieterAPI
import DieterShared
import SwiftUI
import UniformTypeIdentifiers

/// Agent pickers as the shared core shows them; each pick is a choice the
/// caller applies.
struct AgentPickerFields: View {
    let controls: ClientAgentControlsState
    let choose: (ClientAgentChoice.OneOf_Choice) -> Void

    var body: some View {
        Picker("Agent", selection: Binding(get: { controls.selection.provider }, set: { choose(.provider($0)) })) {
            ForEach(controls.providers, id: \.id) { Text($0.name).tag($0.id) }
        }
        .disabled(!controls.providerEnabled)
        Picker("Model", selection: Binding(get: { controls.selection.model }, set: { choose(.model($0)) })) {
            ForEach(controls.models, id: \.id) { Text($0.name).tag($0.id) }
        }
        .disabled(!controls.modelEnabled)
        if !controls.efforts.isEmpty {
            Picker(
                "Reasoning effort",
                selection: Binding(
                    get: { controls.selection.effort.isEmpty ? "default" : controls.selection.effort },
                    set: { choose(.effort($0)) })
            ) {
                Text("Default").tag("default")
                ForEach(controls.efforts, id: \.id) { Text($0.name).tag($0.id) }
            }
            .disabled(!controls.effortEnabled)
        }
        ForEach(controls.options, id: \Dieter_V1_ProviderOption.id) { option in
            ProviderOptionField(
                option: option,
                values: Binding(
                    get: { controls.optionValues },
                    set: { values in
                        guard let value = values[option.id], value != controls.optionValues[option.id] else { return }
                        choose(
                            .option(
                                .with {
                                    $0.id = option.id
                                    $0.optionValue = value
                                }))
                    })
            )
            .disabled(controls.optionEnabled[option.id] == false)
        }
    }
}

/// Agent pickers for a form outside a conversation, e.g. a schedule or a
/// card's draft, as the shared core resolves them against the destination
/// machine's catalog: a blank agent becomes the catalog's first, and a choice
/// the pickers do not allow changes nothing.
struct AgentControlFields: View {
    let catalog: Dieter_V1_HarnessCatalog
    @Binding var selection: Dieter_V1_HarnessSelection

    var body: some View {
        AgentPickerFields(controls: Self.controls(selection, catalog: catalog)) { choice in
            selection = Self.controls(selection, catalog: catalog, choice: choice).selection
        }
    }

    /// The pickers for `selection`, after `choice` when there is one.
    static func controls(
        _ selection: Dieter_V1_HarnessSelection, catalog: Dieter_V1_HarnessCatalog,
        choice: ClientAgentChoice.OneOf_Choice? = nil
    ) -> ClientAgentControlsState {
        let choiceData = choice.map { value in ClientAgentChoice.with { $0.choice = value }.rulesData } ?? Data()
        return ClientAgentControlsState(
            rules: SharedRules.shared.agentControls(
                selection: selection.rulesData, catalog: catalog.rulesData, locked: false, choice: choiceData))
    }
}

struct ProviderOptionField: View {
    let option: Dieter_V1_ProviderOption
    @Binding var values: [String: String]

    private var value: Binding<String> {
        Binding(get: { values[option.id, default: option.defaultValue] }, set: { values[option.id] = $0 })
    }

    private var booleanValue: Binding<Bool> {
        Binding(get: { value.wrappedValue.lowercased() == "true" }, set: { value.wrappedValue = $0 ? "true" : "false" })
    }

    @ViewBuilder var body: some View {
        if ["boolean", "bool"].contains(option.type.lowercased()) {
            Toggle(option.name, isOn: booleanValue).quickHelp(option.name)
        } else if ["enum", "select"].contains(option.type.lowercased()) {
            Picker(option.name, selection: value) {
                ForEach(option.choices, id: \Dieter_V1_ProviderOptionChoice.value) { choice in
                    Text(choice.name.isEmpty ? choice.value : choice.name).tag(choice.value)
                }
            }.quickHelp(option.name)
        } else {
            TextField(option.name, text: value).quickHelp(option.name)
        }
    }
}

struct ProviderOptionChip: View {
    let option: Dieter_V1_ProviderOption
    @Binding var values: [String: String]
    let isEnabled: Bool

    private var currentValue: String { values[option.id, default: option.defaultValue] }

    @ViewBuilder var body: some View {
        if ["boolean", "bool"].contains(option.type.lowercased()) {
            let enabled = currentValue.lowercased() == "true"
            Button {
                values[option.id] = enabled ? "false" : "true"
            } label: {
                if option.id == "fast_mode" {
                    Image(systemName: enabled ? "bolt.fill" : "bolt")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(enabled ? Color.yellow : DieterTheme.subtle)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                } else {
                    DieterChipLabel(
                        title: option.name,
                        symbol: enabled ? "checkmark.circle.fill" : "circle",
                        showsDisclosure: false
                    )
                }
            }
            .buttonStyle(.plain).disabled(!isEnabled)
            .accessibilityLabel(option.id == "fast_mode" ? "Fast mode" : option.name)
            .accessibilityValue(enabled ? "On" : "Off")
            .quickHelp(option.id == "fast_mode" ? "Fast mode" : option.name)
        } else if ["enum", "select"].contains(option.type.lowercased()) {
            Menu {
                ForEach(option.choices, id: \Dieter_V1_ProviderOptionChoice.value) { choice in
                    Button(choice.name.isEmpty ? choice.value : choice.name) {
                        values[option.id] = choice.value
                    }
                }
            } label: {
                DieterChipLabel(
                    title: option.choices.first(where: { $0.value == currentValue })?.name ?? option.name,
                    symbol: "slider.horizontal.3")
            }.menuStyle(.borderlessButton).fixedSize().disabled(!isEnabled).quickHelp(option.name)
        } else {
            TextField(option.name, text: Binding(get: { currentValue }, set: { values[option.id] = $0 }))
                .textFieldStyle(.roundedBorder).frame(width: 130).disabled(!isEnabled).quickHelp(option.name)
        }
    }
}
