import AppKit
import DieterAPI
import DieterClientAPI
import DieterCore
import SwiftUI
import UniformTypeIdentifiers

/// Agent pickers as the shared core shows them; each pick is a choice the
/// caller applies.
struct AgentPickerFields: View {
    let controls: ClientAgentControlsState
    /// The account picker offers "Default account" (an empty choice) even
    /// after an account was chosen, for forms that keep following the
    /// provider default, e.g. schedules.
    var offersDefaultAccount = false
    let choose: (ClientAgentChoice.OneOf_Choice) -> Void

    var body: some View {
        Picker("Agent", selection: Binding(get: { controls.selection.provider }, set: { choose(.provider($0)) })) {
            ForEach(controls.providers, id: \.id) { Text($0.name).tag($0.id) }
        }
        .disabled(!controls.providerEnabled)
        if !controls.accounts.isEmpty {
            Picker(
                "Account",
                selection: Binding(
                    get: { controls.selection.accountID },
                    set: { id in if id != controls.selection.accountID { choose(.account(id)) } })
            ) {
                if offersDefaultAccount || controls.selection.accountID.isEmpty {
                    Text("Default account").tag("")
                }
                ForEach(controls.accounts, id: \.id) { account in
                    Text(AccountOptionText.title(account)).tag(account.id).disabled(!account.ready)
                }
            }
            .disabled(!controls.accountEnabled)
            .accessibilityIdentifier("agent-fields.account")
        }
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
/// the pickers do not allow changes nothing. The account picker judges the
/// account's provider accounts on `daemonID`, the machine that runs the agent.
struct AgentControlFields: View {
    /// Absent outside the workspace window (e.g. in isolated tests); the
    /// fields then offer no accounts.
    @Environment(ProvidersModel.self) private var providers: ProvidersModel?
    let catalog: Dieter_V1_HarnessCatalog
    @Binding var selection: Dieter_V1_HarnessSelection
    var daemonID = ""
    /// Sees each choice before the selection changes, e.g. to note that the
    /// user picked an account.
    var onChoose: (ClientAgentChoice.OneOf_Choice) -> Void = { _ in }
    @State private var resolved = AgentControlsMemo()

    var body: some View {
        let slice = providers?.slice ?? ClientProvidersSlice()
        AgentPickerFields(
            controls: resolved.controls(selection, catalog: catalog, providers: slice, daemonID: daemonID),
            offersDefaultAccount: true
        ) { choice in
            onChoose(choice)
            // The core offers no empty account; the form itself goes back to
            // the provider default.
            if case .account(let id) = choice, id.isEmpty {
                selection.accountID = ""
                return
            }
            selection =
                Self.controls(selection, catalog: catalog, providers: slice, daemonID: daemonID, choice: choice)
                .selection
        }
        .onAppear { providers?.observe() }
        .onDisappear { providers?.release() }
    }

    /// The pickers for `selection`, after `choice` when there is one.
    static func controls(
        _ selection: Dieter_V1_HarnessSelection, catalog: Dieter_V1_HarnessCatalog,
        providers: ClientProvidersSlice = ClientProvidersSlice(), daemonID: String = "",
        choice: ClientAgentChoice.OneOf_Choice? = nil
    ) -> ClientAgentControlsState {
        let choiceData = choice.map { value in ClientAgentChoice.with { $0.choice = value }.rulesData } ?? Data()
        return ClientAgentControlsState(
            rules: SharedRules.shared.agentControls(
                selection: selection.rulesData, catalog: catalog.rulesData, locked: false, choice: choiceData,
                providers: providers == ClientProvidersSlice() ? Data() : providers.rulesData, daemonId: daemonID))
    }
}

/// The pickers last resolved for a selection, catalog, accounts and machine.
/// A form redraws its agent fields as other fields change; only a change of
/// these asks the core again, rather than serializing the whole catalog on
/// every keystroke.
@MainActor
private final class AgentControlsMemo {
    private var selection: Dieter_V1_HarnessSelection?
    private var catalog: Dieter_V1_HarnessCatalog?
    private var providers: ClientProvidersSlice?
    private var daemonID: String?
    private var value = ClientAgentControlsState()

    func controls(
        _ selection: Dieter_V1_HarnessSelection, catalog: Dieter_V1_HarnessCatalog,
        providers: ClientProvidersSlice, daemonID: String
    ) -> ClientAgentControlsState {
        if selection == self.selection, catalog == self.catalog, providers == self.providers,
            daemonID == self.daemonID
        {
            return value
        }
        value = AgentControlFields.controls(selection, catalog: catalog, providers: providers, daemonID: daemonID)
        self.selection = selection
        self.catalog = catalog
        self.providers = providers
        self.daemonID = daemonID
        return value
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
