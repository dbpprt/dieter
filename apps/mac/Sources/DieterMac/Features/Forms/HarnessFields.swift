import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct HarnessFields: View {
    let catalog: Dieter_V1_HarnessCatalog
    @Binding var provider: String
    @Binding var model: String
    @Binding var effort: String
    @Binding var providerOptions: [String: String]

    private var harness: Dieter_V1_Harness? { catalog.harnesses.first { $0.id == provider } }
    private var selectedModel: Dieter_V1_HarnessModel? { harness?.models.first { $0.id == model } }

    var body: some View {
        Picker("Agent", selection: $provider) {
            Text("Server default").tag("")
            ForEach(catalog.harnesses, id: \.id) { Text($0.name).tag($0.id) }
        }.onChange(of: provider) { _, _ in
            let selection = HarnessSelection(provider: provider).resolved(
                in: catalog.harnesses, allowServerDefault: true)
            model = selection?.model ?? ""
            effort = selection?.effort ?? ""
            providerOptions = selection?.providerOptions ?? [:]
        }
        Picker("Model", selection: $model) {
            Text("Agent default").tag("")
            ForEach(harness?.models ?? [], id: \.id) { Text($0.name).tag($0.id) }
        }.onChange(of: model) { _, _ in
            effort = selectedModel?.defaultEffort ?? ""
            providerOptions = ProviderOptionValues.normalized(
                for: harness, model: model, saved: providerOptions)
        }
        if let efforts = selectedModel?.efforts, !efforts.isEmpty {
            Picker("Reasoning effort", selection: $effort) {
                Text("Agent default").tag("")
                ForEach(efforts, id: \.self) { Text($0.capitalized).tag($0) }
            }
        }
        ProviderOptionFields(
            options: ProviderOptionValues.options(for: harness, model: model), values: $providerOptions)
    }
}
struct ProviderOptionFields: View {
    let options: [Dieter_V1_ProviderOption]
    @Binding var values: [String: String]

    var body: some View {
        ForEach(options, id: \Dieter_V1_ProviderOption.id) { option in
            ProviderOptionField(option: option, values: $values)
        }
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
            Toggle(option.name, isOn: booleanValue).help(option.description_p)
        } else if ["enum", "select"].contains(option.type.lowercased()) {
            Picker(option.name, selection: value) {
                ForEach(option.choices, id: \Dieter_V1_ProviderOptionChoice.value) { choice in
                    Text(choice.name.isEmpty ? choice.value : choice.name).tag(choice.value)
                }
            }.help(option.description_p)
        } else {
            TextField(option.name, text: value).help(option.description_p)
        }
    }
}

struct ProviderOptionChips: View {
    let options: [Dieter_V1_ProviderOption]
    @Binding var values: [String: String]
    var conversationLocked = false

    var body: some View {
        ForEach(options, id: \Dieter_V1_ProviderOption.id) { option in
            ProviderOptionChip(
                option: option,
                values: $values,
                isEnabled: ProviderOptionValues.isEnabled(option, conversationLocked: conversationLocked)
            )
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
            .nativeHelp(
                option.id == "fast_mode"
                    ? "Fast mode: \(enabled ? "On" : "Off"). Requests faster processing for your next message when supported by the model; usage may cost more. The current turn keeps its settings."
                    : option.description_p)
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
            }.menuStyle(.borderlessButton).fixedSize().disabled(!isEnabled).nativeHelp(option.description_p)
        } else {
            TextField(option.name, text: Binding(get: { currentValue }, set: { values[option.id] = $0 }))
                .textFieldStyle(.roundedBorder).frame(width: 130).disabled(!isEnabled).nativeHelp(
                    option.description_p)
        }
    }
}
