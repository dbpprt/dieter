import DieterClientAPI
import SwiftUI

/// The account-wide switch on Settings › Experimental. It applies at once on
/// every machine (the setting replicates); project and board settings can
/// override it.
struct ChannelsGlobalSetting: View {
    let model: ChannelsModel

    var body: some View {
        let settings = model.settings
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agent channels").font(.system(size: 12, weight: .semibold))
                if settings.saving { ProgressView().controlSize(.mini) }
                Spacer()
                Toggle(
                    "Agent channels",
                    isOn: Binding(get: { settings.global }, set: { on in Task { await model.setGlobal(on) } })
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Agent channels")
                .accessibilityIdentifier("settings.experimental.channels")
                .e2eTarget("settings.experimental.channels")
            }
            Text(
                "Off by default. Agents working in the same project on one machine get a channel: they can message each other, claim the files they change, and pin decisions. Messages reach running agents in their turn. Override it per project in Project context and per board in Board settings."
            )
            .font(.caption).foregroundStyle(DieterTheme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            if let error = model.errorMessage ?? (settings.error.isEmpty ? nil : settings.error) {
                Text(error).font(.caption).foregroundStyle(DieterTheme.coral)
            }
        }
    }
}

/// A project's or board's Inherit/On/Off override, labelled with what it
/// resolves to, e.g. "Inherit (On)". It applies at once.
struct ChannelSettingPicker: View {
    let model: ChannelsModel
    let scope: ClientChannelSettingScope
    let row: ClientChannelSettingRow?
    let identifier: String

    var body: some View {
        if let row {
            VStack(alignment: .leading, spacing: 4) {
                Picker(
                    "Agent channels",
                    selection: Binding(
                        get: { row.mode },
                        set: { mode in Task { await model.setSetting(scope: scope, id: row.id, mode: mode) } })
                ) {
                    ForEach(row.options, id: \.mode) { option in
                        Text(option.label).tag(option.mode)
                    }
                }
                .disabled(model.settings.saving)
                .accessibilityIdentifier(identifier)
                .e2eTarget(identifier, text: row.label)
                Text(row.detail + " Experimental; applies at once on every machine.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("Agent channels settings load with the workspace.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
