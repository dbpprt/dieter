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
                selection: Binding(get: { controls.effortValue }, set: { choose(.effort($0)) })
            ) {
                ForEach(controls.effortChoices, id: \.id) { Text($0.name).tag($0.id) }
            }
            .disabled(!controls.effortEnabled)
        }
        ForEach(controls.options, id: \Dieter_V1_ProviderOption.id) { option in
            ProviderOptionField(option: option, controls: controls, choose: choose)
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

/// One provider option, edited as the core says it is edited: a switch, a
/// choice, or text. Each change is a choice the caller applies.
struct ProviderOptionField: View {
    let option: Dieter_V1_ProviderOption
    let controls: ClientAgentControlsState
    let choose: (ClientAgentChoice.OneOf_Choice) -> Void

    private var value: Binding<String> {
        Binding(
            get: { controls.optionValues[option.id] ?? option.defaultValue },
            set: { next in ProviderOptionChoices.set(option, to: next, controls: controls, choose: choose) })
    }

    private var on: Binding<Bool> {
        Binding(
            get: { controls.optionOn[option.id] ?? false },
            set: { value.wrappedValue = SharedRules.shared.toggleOptionValue(on: $0) })
    }

    @ViewBuilder var body: some View {
        switch controls.optionKinds[option.id] ?? .text {
        case .toggle:
            Toggle(option.name, isOn: on).quickHelp(option.name)
        case .choice:
            Picker(option.name, selection: value) {
                ForEach(option.choices, id: \Dieter_V1_ProviderOptionChoice.value) { choice in
                    Text(choice.name).tag(choice.value)
                }
            }.quickHelp(option.name)
        default:
            TextField(option.name, text: value).quickHelp(option.name)
        }
    }
}

enum ProviderOptionChoices {
    /// Chooses `value` for `option` unless it already has it.
    static func set(
        _ option: Dieter_V1_ProviderOption, to value: String, controls: ClientAgentControlsState,
        choose: (ClientAgentChoice.OneOf_Choice) -> Void
    ) {
        guard value != (controls.optionValues[option.id] ?? option.defaultValue) else { return }
        choose(
            .option(
                .with {
                    $0.id = option.id
                    $0.optionValue = value
                }))
    }
}

struct ProviderOptionChip: View {
    let option: Dieter_V1_ProviderOption
    let controls: ClientAgentControlsState
    let choose: (ClientAgentChoice.OneOf_Choice) -> Void
    let isEnabled: Bool

    private var currentValue: String { controls.optionValues[option.id] ?? option.defaultValue }
    private var fast: Bool { option.id == controls.fastOptionID }

    @ViewBuilder var body: some View {
        switch controls.optionKinds[option.id] ?? .text {
        case .toggle:
            let enabled = controls.optionOn[option.id] ?? false
            Button {
                ProviderOptionChoices.set(
                    option, to: SharedRules.shared.toggleOptionValue(on: !enabled), controls: controls, choose: choose)
            } label: {
                if fast {
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
            .accessibilityLabel(option.name)
            .accessibilityValue(enabled ? "On" : "Off")
            .quickHelp(option.name)
        case .choice:
            Menu {
                ForEach(option.choices, id: \Dieter_V1_ProviderOptionChoice.value) { choice in
                    Button(choice.name) {
                        ProviderOptionChoices.set(option, to: choice.value, controls: controls, choose: choose)
                    }
                }
            } label: {
                DieterChipLabel(
                    title: option.choices.first(where: { $0.value == currentValue })?.name ?? option.name,
                    symbol: "slider.horizontal.3")
            }.menuStyle(.borderlessButton).fixedSize().disabled(!isEnabled).quickHelp(option.name)
        default:
            TextField(
                option.name,
                text: Binding(
                    get: { currentValue },
                    set: { ProviderOptionChoices.set(option, to: $0, controls: controls, choose: choose) })
            )
            .textFieldStyle(.roundedBorder).frame(width: 130).disabled(!isEnabled).quickHelp(option.name)
        }
    }
}
