#if os(iOS)
    import DieterAPI
    import DieterShared
    import Foundation
    import SharedCore
    import SwiftUI

    /// Provider symbols and tints; the wording and severity come from the core.
    @MainActor
    enum IOSProviderQuotaPresentation {
        static func symbol(_ provider: Dieter_Gateway_V1_ProviderQuotaProvider) -> String {
            switch provider {
            case .openaiCodex: "sparkles"
            case .anthropicClaude: "brain.head.profile"
            default: "gauge.with.dots.needle.50percent"
            }
        }

        /// A low or critical severity wins over the provider's brand color.
        static func tint(_ provider: Dieter_Gateway_V1_ProviderQuotaProvider, _ severity: ClientQuotaSeverity) -> Color
        {
            switch severity {
            case .critical: return .red
            case .low: return .orange
            default:
                switch provider {
                case .openaiCodex: return Color(red: 37 / 255, green: 136 / 255, blue: 245 / 255)
                case .anthropicClaude: return .orange
                default: return .green
                }
            }
        }
    }

    /// The provider account a conversation runs on, as a compact bar in its
    /// toolbar; tapping it shows that account's quota.
    struct IOSConversationProviderQuotaView: View {
        @Environment(IOSAppModel.self) private var app
        let accountKey: String
        @State private var presented = false

        private var match: (provider: Dieter_Gateway_V1_ProviderQuotaProvider, account: ClientQuotaAccountRow)? {
            guard !accountKey.isEmpty else { return nil }
            for group in app.quotas.providerQuotaRows {
                if let account = group.accounts.first(where: { $0.accountKey == accountKey }) {
                    return (group.provider, account)
                }
            }
            return nil
        }

        var body: some View {
            if let match {
                Button {
                    presented = true
                } label: {
                    IOSProviderQuotaAccountPill(provider: match.provider, account: match.account)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(match.account.summaryLine)
                .accessibilityHint("Shows this account's quota")
                .accessibilityIdentifier("ios.conversation.provider-account-quota")
                .sheet(isPresented: $presented) {
                    IOSProviderQuotaDetailsView(quotas: app.quotas, accountKey: accountKey)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
        }
    }

    /// One account's lowest remaining allowance, with a warning when it is
    /// unavailable or stale.
    struct IOSProviderQuotaAccountPill: View {
        let provider: Dieter_Gateway_V1_ProviderQuotaProvider
        let account: ClientQuotaAccountRow

        var body: some View {
            let tint = IOSProviderQuotaPresentation.tint(provider, account.severity)
            let warning = SharedRules.shared.quotaWarning(
                unavailable: account.unavailable, freshUntilMillis: account.freshUntilMillis,
                nowMillis: Date.now.epochMillis)
            HStack(spacing: 5) {
                Image(systemName: IOSProviderQuotaPresentation.symbol(provider))
                    .font(.system(size: 10, weight: .semibold))
                if account.remaining >= 0 {
                    Text("\(account.remaining)%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    ProgressView(value: Double(account.remaining), total: 100)
                        .progressViewStyle(.linear)
                        .frame(width: 28)
                } else {
                    Text("—").font(.caption2)
                }
                if !warning.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.orange)
                        .accessibilityLabel(warning)
                }
            }
            .foregroundStyle(tint)
            .tint(tint)
            .padding(.horizontal, 7)
            .frame(height: 28)
        }
    }

    /// Every provider account and its quota windows, or only the account
    /// `accountKey` names, with the summary and reset controls.
    struct IOSProviderQuotaDetailsView: View {
        @Environment(\.dismiss) private var dismiss
        let quotas: CoreProviderQuotas
        var accountKey: String?
        @State private var resetConfirmationAccountKey: String?

        private var groups: [ClientQuotaGroupRow] {
            guard let accountKey else { return quotas.providerQuotaRows }
            return quotas.providerQuotaRows.compactMap { group in
                var filtered = group
                filtered.accounts = group.accounts.filter { $0.accountKey == accountKey }
                return filtered.accounts.isEmpty ? nil : filtered
            }
        }

        var body: some View {
            NavigationStack {
                TimelineView(.periodic(from: .now, by: 30)) { clock in
                    list(now: clock.date.epochMillis)
                }
                .navigationTitle(accountKey == nil ? "Provider quotas" : "Conversation quota")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("ios.provider-quotas.done")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if quotas.providerQuotasLoading {
                            ProgressView()
                        } else {
                            Button("Refresh", systemImage: "arrow.clockwise") {
                                Task { await quotas.load(requestRefresh: true) }
                            }
                            .accessibilityIdentifier("ios.provider-quotas.refresh")
                        }
                    }
                }
            }
            .accessibilityIdentifier("ios.provider-quotas.details")
            .task {
                if quotas.providerQuotaRows.isEmpty { await quotas.load() }
            }
            .confirmationDialog(
                SharedRules.shared.quotaResetTitle(),
                isPresented: Binding(
                    get: { resetConfirmationAccountKey != nil },
                    set: { if !$0 { resetConfirmationAccountKey = nil } }),
                titleVisibility: .visible
            ) {
                Button("Use reset credit", role: .destructive) {
                    guard let accountKey = resetConfirmationAccountKey else { return }
                    resetConfirmationAccountKey = nil
                    Task { await quotas.consumeReset(accountKey: accountKey) }
                }
                Button("Cancel", role: .cancel) { resetConfirmationAccountKey = nil }
            } message: {
                Text(SharedRules.shared.quotaResetMessage())
            }
        }

        private func list(now: Int64) -> some View {
            List {
                Section {
                    Text(
                        accountKey == nil
                            ? "Every account and quota window stays separate here. The summary counts included accounts."
                            : "Usage for the exact provider account assigned to this conversation."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    if let error = quotas.providerQuotaError, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("ios.provider-quotas.error")
                    }
                }
                if groups.isEmpty {
                    if quotas.providerQuotasLoading {
                        ProgressView("Loading quotas…").frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        ContentUnavailableView(
                            "No provider accounts", systemImage: "gauge.with.dots.needle.0percent",
                            description: Text("Sign in to a supported provider on an online Dieter machine."))
                    }
                } else {
                    ForEach(groups, id: \.provider.rawValue) { group in
                        Section {
                            ForEach(group.accounts, id: \.accountKey) { account in
                                accountView(account, provider: group.provider, now: now)
                            }
                        } header: {
                            HStack {
                                Label(
                                    group.providerName, systemImage: IOSProviderQuotaPresentation.symbol(group.provider)
                                )
                                Spacer()
                                Text(group.summary)
                            }
                        }
                    }
                }
            }
            .refreshable { await quotas.load(requestRefresh: true) }
        }

        private func accountView(
            _ account: ClientQuotaAccountRow, provider: Dieter_Gateway_V1_ProviderQuotaProvider, now: Int64
        ) -> some View {
            let warning = SharedRules.shared.quotaWarning(
                unavailable: account.unavailable, freshUntilMillis: account.freshUntilMillis, nowMillis: now)
            let mutating = quotas.providerQuotaMutatingAccounts.contains(account.accountKey)
            return VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.identity)
                            .font(.headline)
                            .lineLimit(1)
                            .textSelection(.enabled)
                        Text(account.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !warning.isEmpty {
                        Text(warning)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
                .accessibilityElement(children: .combine)

                if account.windows.isEmpty, !account.status.isEmpty {
                    Text(account.status).font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(account.windows, id: \.id) { window in
                    windowView(window, provider: provider, now: now)
                }
                ForEach(Array(account.details.enumerated()), id: \.offset) { _, detail in
                    LabeledContent(detail.label, value: detail.text).font(.subheadline)
                }
                if !account.machines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Available on").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(account.machines, id: \.daemonID) { machine in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(machine.online ? Color.green : Color.secondary)
                                    .frame(width: 6, height: 6)
                                Text(machine.name).lineLimit(1)
                                Spacer()
                                Text(machine.state).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                Toggle(
                    "Include in summary",
                    isOn: Binding(
                        get: { account.included },
                        set: { included in
                            Task {
                                await quotas.setInclusion(
                                    provider: provider, accountKey: account.accountKey, included: included)
                            }
                        })
                )
                .disabled(mutating)
                .accessibilityIdentifier("ios.provider-quotas.include.\(account.accountKey)")

                if account.canReset {
                    Button("Use reset credit…", systemImage: "arrow.counterclockwise") {
                        resetConfirmationAccountKey = account.accountKey
                    }
                    .disabled(mutating)
                    .accessibilityIdentifier("ios.provider-quotas.reset.\(account.accountKey)")
                }
                if account.refreshing {
                    Text("Refreshing…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }

        private func windowView(
            _ window: ClientQuotaWindowRow, provider: Dieter_Gateway_V1_ProviderQuotaProvider, now: Int64
        ) -> some View {
            let tint = IOSProviderQuotaPresentation.tint(provider, window.severity)
            return VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(window.name)
                    Spacer()
                    if window.remaining >= 0 {
                        Text("\(window.remaining)%").monospacedDigit().foregroundStyle(tint)
                    } else {
                        Text("Not reported").foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
                if window.remaining >= 0 {
                    ProgressView(value: Double(window.remaining), total: 100).tint(tint)
                }
                if !window.resetsAt.isEmpty {
                    Text(SharedRules.shared.quotaResetText(resetsAt: window.resetsAt, nowMillis: now, fine: false))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

#endif
