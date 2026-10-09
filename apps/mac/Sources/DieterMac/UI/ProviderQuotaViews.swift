import DieterAPI
import DieterShared
import SwiftUI

private struct ProviderQuotaCompactAccount: Identifiable {
    let provider: Dieter_Gateway_V1_ProviderQuotaProvider
    let account: ClientQuotaAccountRow

    var id: String { "\(provider.rawValue):\(account.accountKey)" }
}

/// The sidebar's quota meters, one row per included account.
struct ProviderQuotaCompactView: View {
    @Environment(DieterStore.self) private var store
    @State private var presented = false

    private var groups: [ClientQuotaGroupRow] {
        store.quotas.providerQuotaRows.filter { !$0.accounts.isEmpty }
    }

    private var accounts: [ProviderQuotaCompactAccount] {
        groups.flatMap { group in
            group.accounts.filter(\.included).map {
                ProviderQuotaCompactAccount(provider: group.provider, account: $0)
            }
        }
    }

    var body: some View {
        if !groups.isEmpty || store.quotas.providerQuotasLoading {
            Button {
                presented.toggle()
            } label: {
                Group {
                    if groups.isEmpty {
                        ProgressView().controlSize(.mini)
                    } else if accounts.isEmpty {
                        Label("Quotas", systemImage: "gauge.with.dots.needle.0percent")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DieterTheme.tertiary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(accounts) { item in
                                ProviderQuotaAccountCompactLabel(
                                    provider: item.provider,
                                    account: item.account
                                )
                                .fixedSize(horizontal: false, vertical: true)
                                .smokeTarget("sidebar.quota.\(item.id)")
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Global provider quotas by account")
            .accessibilityIdentifier("global.provider-quotas")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                ProviderQuotaDetailsView()
                    .environment(store)
                    .frame(width: 390)
                    .padding(16)
            }
        }
    }
}

/// The quota panel below the machines. It keeps its place while quotas load
/// or when no provider account is signed in, so the sidebar never jumps.
struct ProviderQuotaSidebarBlock: View {
    @Environment(DieterStore.self) private var store
    @State private var presented = false

    private var hasAccounts: Bool { store.quotas.providerQuotaRows.contains { !$0.accounts.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Quotas")
                    .smokeTarget("sidebar.quotas-title")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DieterTheme.tertiary)
                Spacer(minLength: 4)
                if store.quotas.providerQuotasLoading {
                    ProgressView().controlSize(.mini).accessibilityLabel("Loading quotas")
                }
            }
            .padding(.horizontal, 8).frame(height: 22)
            if hasAccounts {
                ProviderQuotaCompactView()
                    .padding(.horizontal, 8)
            } else {
                Button {
                    presented = true
                } label: {
                    Text(
                        store.quotas.providerQuotasLoading
                            ? "Loading provider accounts…"
                            : (store.quotas.providerQuotaError ?? "No provider accounts")
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(DieterTheme.tertiary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8).padding(.bottom, 2)
                .accessibilityIdentifier("global.provider-quotas")
                .popover(isPresented: $presented, arrowEdge: .trailing) {
                    ProviderQuotaDetailsView()
                        .environment(store)
                        .frame(width: 390)
                        .padding(16)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar.provider-quotas")
    }
}

private struct ProviderQuotaAccountCompactLabel: View {
    let provider: Dieter_Gateway_V1_ProviderQuotaProvider
    let account: ClientQuotaAccountRow

    var body: some View {
        let tint = ProviderQuotaPresentation.tint(provider, account.severity)
        let warning = SharedRules.shared.quotaWarning(
            unavailable: account.unavailable, freshUntilMillis: account.freshUntilMillis,
            nowMillis: Date.now.epochMillis)
        HStack(spacing: 6) {
            Image(systemName: ProviderQuotaPresentation.symbol(provider))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(account.label)
                .font(.system(size: 11.5))
                .foregroundStyle(DieterTheme.text.opacity(0.88))
                .lineLimit(1)
                .frame(minWidth: 42, maxWidth: .infinity, alignment: .leading)
            if account.remaining >= 0 {
                ProviderQuotaMeter(fraction: Double(account.remaining) / 100, tint: tint)
                    .frame(width: 44, height: 4)
                Text("\(account.remaining)%")
                    .font(DieterFont.monoSmall)
                    .foregroundStyle(DieterTheme.subtle)
                    .monospacedDigit()
                    .frame(minWidth: 30, alignment: .trailing)
            } else {
                Text("—").font(.caption2)
            }
            if !warning.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DieterTheme.amber)
                    .accessibilityLabel(warning)
            }
        }
        .foregroundStyle(DieterTheme.subtle)
        .help(account.summaryLine)
    }
}

struct ProviderQuotaDetailsView: View {
    @Environment(DieterStore.self) private var store
    var accountKey: String? = nil
    @State private var resetConfirmationAccountKey: String?

    private var groups: [ClientQuotaGroupRow] {
        guard let accountKey else { return store.quotas.providerQuotaRows }
        return store.quotas.providerQuotaRows.compactMap { group in
            var filtered = group
            filtered.accounts = group.accounts.filter { $0.accountKey == accountKey }
            return filtered.accounts.isEmpty ? nil : filtered
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(accountKey == nil ? "Provider quotas" : "Conversation account quota").font(.headline)
                    Text(
                        accountKey == nil
                            ? "The app header shows one small bar for each enabled account."
                            : "Usage for the exact provider account assigned to this conversation."
                    )
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
                Button {
                    Task { await store.loadProviderQuotas(requestRefresh: true) }
                } label: {
                    if store.quotas.providerQuotasLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(DieterBarButtonStyle(size: 28))
                .disabled(store.quotas.providerQuotasLoading)
                .accessibilityIdentifier("provider-quotas.refresh")
                .smokeTarget("provider-quotas.refresh")
            }

            if let error = store.quotas.providerQuotaError, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(DieterTheme.coral)
            }

            if groups.isEmpty {
                ContentUnavailableView(
                    "No provider accounts",
                    systemImage: "gauge.with.dots.needle.0percent",
                    description: Text(
                        store.quotas.providerQuotaError
                            ?? "Sign in to a supported provider on an online Dieter machine.")
                )
                .frame(minHeight: 150)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(groups, id: \.provider.rawValue) { group in
                            providerGroup(group)
                        }
                    }
                }
                .frame(maxHeight: 480)
            }
        }
        .task {
            if store.quotas.providerQuotaRows.isEmpty { await store.loadProviderQuotas() }
        }
        .confirmationDialog(
            SharedRules.shared.quotaResetTitle(),
            isPresented: Binding(
                get: { resetConfirmationAccountKey != nil },
                set: { if !$0 { resetConfirmationAccountKey = nil } }
            )
        ) {
            Button("Use reset credit", role: .destructive) {
                guard let accountKey = resetConfirmationAccountKey else { return }
                resetConfirmationAccountKey = nil
                Task { await store.consumeProviderQuotaReset(accountKey: accountKey) }
            }
            Button("Cancel", role: .cancel) { resetConfirmationAccountKey = nil }
        } message: {
            Text(SharedRules.shared.quotaResetMessage())
        }
    }

    private func providerGroup(_ group: ClientQuotaGroupRow) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(group.providerName, systemImage: ProviderQuotaPresentation.symbol(group.provider))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(group.summary)
                    .font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
            ForEach(group.accounts, id: \.accountKey) { account in
                accountView(account, provider: group.provider)
            }
        }
    }

    private func accountView(
        _ account: ClientQuotaAccountRow,
        provider: Dieter_Gateway_V1_ProviderQuotaProvider
    ) -> some View {
        let now = Date.now.epochMillis
        let warning = SharedRules.shared.quotaWarning(
            unavailable: account.unavailable, freshUntilMillis: account.freshUntilMillis, nowMillis: now)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(account.identity)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer()
                if !warning.isEmpty {
                    Text(warning).font(.caption2).foregroundStyle(DieterTheme.amber)
                }
            }
            Text(account.subtitle)
                .font(.caption).foregroundStyle(DieterTheme.tertiary)
            if !account.machines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Available on")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DieterTheme.tertiary)
                    ForEach(account.machines, id: \.daemonID) { machine in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(machine.online ? DieterTheme.running : DieterTheme.tertiary)
                                .frame(width: 6, height: 6)
                            Image(systemName: "server.rack")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(DieterTheme.tertiary)
                            Text(machine.name)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(machine.state)
                                .font(.caption2)
                                .foregroundStyle(machine.online ? DieterTheme.running : DieterTheme.tertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.vertical, 2)
            }
            if account.windows.isEmpty {
                Text(account.status).font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
            ForEach(account.windows, id: \.id) { window in
                HStack(spacing: 8) {
                    Text(window.name)
                        .font(.caption).frame(width: 92, alignment: .leading)
                    if window.remaining >= 0 {
                        let tint = ProviderQuotaPresentation.tint(provider, window.severity)
                        ProgressView(value: Double(window.remaining), total: 100)
                            .progressViewStyle(.linear)
                            .tint(tint)
                        Text("\(window.remaining)%")
                            .font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
                            .foregroundStyle(tint)
                    } else {
                        Text("Not reported").font(.caption).foregroundStyle(DieterTheme.tertiary)
                        Spacer()
                    }
                    if !window.resetsAt.isEmpty {
                        Text(SharedRules.shared.quotaResetText(resetsAt: window.resetsAt, nowMillis: now, fine: true))
                            .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    }
                }
            }
            ForEach(Array(account.details.enumerated()), id: \.offset) { _, detail in
                HStack {
                    Text(detail.label).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    Spacer()
                    Text(detail.text).font(.caption2.monospacedDigit())
                }
            }
            Toggle(
                "Show in app header",
                isOn: Binding(
                    get: { account.included },
                    set: { included in
                        Task {
                            await store.setProviderQuotaSummaryInclusion(
                                provider: provider, accountKey: account.accountKey, included: included)
                        }
                    }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(store.quotas.providerQuotaMutatingAccounts.contains(account.accountKey))
            .accessibilityIdentifier("provider-quotas.include.\(account.accountKey)")
            if account.canReset {
                Button("Use reset credit…") { resetConfirmationAccountKey = account.accountKey }
                    .buttonStyle(DieterBarButtonStyle(size: 26))
                    .disabled(store.quotas.providerQuotaMutatingAccounts.contains(account.accountKey))
                    .accessibilityIdentifier("provider-quotas.reset.\(account.accountKey)")
            }
            if account.refreshing {
                Text("Refreshing…").font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
        }
        .padding(10)
        .dieterTile(radius: 10)
    }
}

/// A thin capsule meter for the remaining share of a quota window.
private struct ProviderQuotaMeter: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(DieterTheme.hairline)
                Capsule().fill(tint).frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .accessibilityHidden(true)
    }
}

/// SF Symbols and colours for quota rows; the wording and severity come from the shared core.
@MainActor
enum ProviderQuotaPresentation {
    static func symbol(_ provider: Dieter_Gateway_V1_ProviderQuotaProvider) -> String {
        switch provider {
        case .openaiCodex: "sparkles"
        case .anthropicClaude: "brain.head.profile"
        default: "gauge.with.dots.needle.50percent"
        }
    }

    /// A low or critical severity wins over the provider's brand colour.
    static func tint(_ provider: Dieter_Gateway_V1_ProviderQuotaProvider, _ severity: ClientQuotaSeverity) -> Color {
        switch severity {
        case .critical: return DieterTheme.coral
        case .low: return DieterTheme.amber
        default:
            switch provider {
            case .openaiCodex: return DieterTheme.openAIQuota
            case .anthropicClaude: return DieterTheme.amber
            default: return DieterTheme.eyes
            }
        }
    }
}
