import DieterClientAPI
import SwiftUI

/// Settings › Providers: one panel per provider with its accounts, the
/// provider's default account and adding one. Everything shown comes from
/// the providers slice, so the page works offline from the account replica.
struct ProvidersSettings: View {
    @Environment(DieterStore.self) private var store
    @State private var adding: AddProviderAccountRequest?

    private var providers: ProvidersModel { store.providersModel }

    var body: some View {
        SettingsPage {
            VStack(spacing: 14) {
                if let problem = providers.problem {
                    Text(problem)
                        .font(.caption).foregroundStyle(DieterTheme.coral)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("providers.error")
                }
                if providers.groups.isEmpty {
                    SettingsPanel(title: "Accounts", subtitle: "Reading the account's providers…") {
                        HStack {
                            ProgressView().controlSize(.small)
                            Spacer()
                            addButton(provider: "claude", name: "Claude")
                        }
                    }
                }
                ForEach(providers.groups, id: \.provider) { group in
                    groupPanel(group)
                }
            }
        }
        .onAppear { providers.observe() }
        .onDisappear { providers.release() }
        .sheet(item: $adding) { request in
            AddProviderAccountSheet(provider: request.provider).environment(store)
        }
    }

    private func groupPanel(_ group: ClientProviderGroupRow) -> some View {
        SettingsPanel(title: group.providerName, subtitle: group.summary) {
            HStack(spacing: 10) {
                if group.accounts.count > 1 {
                    Picker(
                        "Default account",
                        selection: Binding(
                            get: { group.defaultAccountID },
                            set: { id in Task { await providers.setDefault(accountID: id) } })
                    ) {
                        if group.defaultAccountID.isEmpty { Text("None").tag("") }
                        ForEach(group.accounts, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .frame(maxWidth: 280)
                    .disabled(providers.isMutating(group.defaultAccountID))
                    .accessibilityIdentifier("providers.default.\(group.provider)")
                }
                Spacer()
                addButton(provider: group.provider, name: group.providerName)
            }
            if group.accounts.isEmpty {
                Text("No \(group.providerName) accounts yet. Add one, then sign it in on your machines.")
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
            }
            ForEach(group.accounts, id: \.id) { account in
                ProviderAccountPanel(account: account, provider: group.provider)
            }
        }
        .e2eTarget("providers.group.\(group.provider)", text: group.providerName)
    }

    private func addButton(provider: String, name: String) -> some View {
        Button("Add account", systemImage: "plus") { adding = AddProviderAccountRequest(provider: provider) }
            .buttonStyle(DieterBarButtonStyle(size: 26))
            .accessibilityLabel("Add \(name) account")
            .accessibilityIdentifier("providers.add")
            .e2eTarget("providers.add", text: name)
    }
}

/// The add-account sheet for a provider, chosen up front.
struct AddProviderAccountRequest: Identifiable {
    let provider: String
    var id: String { provider }
}
