import DieterAPI
import SwiftUI

private struct ProviderQuotaCompactAccount: Identifiable {
    let provider: Dieter_Gateway_V1_ProviderQuotaProvider
    let account: Dieter_Gateway_V1_ProviderQuotaSnapshot

    var id: String { "\(provider.rawValue):\(account.accountKey)" }
}

struct ProviderQuotaCompactView: View {
    @Environment(DieterStore.self) private var store
    @State private var presented = false
    var embeddedInToolbar = false
    var embeddedInSidebar = false

    private var groups: [Dieter_Gateway_V1_ProviderQuotaGroup] {
        store.providerQuotaGroups.filter { !$0.accounts.isEmpty }
    }

    private var accounts: [ProviderQuotaCompactAccount] {
        groups.flatMap { group in
            group.accounts.compactMap { account in
                guard !account.hasIncludedInSummary || account.includedInSummary else { return nil }
                return ProviderQuotaCompactAccount(provider: group.provider, account: account)
            }
        }
    }

    var body: some View {
        if !groups.isEmpty || store.providerQuotasLoading {
            Button {
                presented.toggle()
            } label: {
                Group {
                    if groups.isEmpty {
                        ProgressView()
                            .controlSize(.mini)
                            .providerQuotaCompactChrome(
                                embeddedInToolbar: embeddedInToolbar,
                                embeddedInSidebar: embeddedInSidebar)
                    } else if accounts.isEmpty {
                        Label("Quotas", systemImage: "gauge.with.dots.needle.0percent")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DieterTheme.tertiary)
                            .providerQuotaCompactChrome(
                                embeddedInToolbar: embeddedInToolbar,
                                embeddedInSidebar: embeddedInSidebar)
                    } else if embeddedInSidebar {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(accounts) { item in
                                ProviderQuotaAccountCompactLabel(
                                    provider: item.provider,
                                    account: item.account
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(alignment: .center, spacing: embeddedInToolbar ? 10 : 6) {
                            ForEach(accounts) { item in
                                ProviderQuotaAccountCompactLabel(
                                    provider: item.provider,
                                    account: item.account
                                )
                                .providerQuotaCompactChrome(
                                    embeddedInToolbar: embeddedInToolbar,
                                    embeddedInSidebar: false)
                            }
                        }
                    }
                }
                .frame(
                    maxWidth: embeddedInSidebar ? .infinity : nil,
                    minHeight: 30,
                    alignment: embeddedInSidebar ? .leading : .center)
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

struct ProviderQuotaSidebarBlock: View {
    @Environment(DieterStore.self) private var store

    private var visible: Bool {
        store.providerQuotasLoading || store.providerQuotaGroups.contains { !$0.accounts.isEmpty }
    }

    var body: some View {
        if visible {
            VStack(alignment: .leading, spacing: 4) {
                Text("QUOTAS")
                    .font(DieterFont.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(DieterTheme.tertiary)
                ProviderQuotaCompactView(embeddedInSidebar: true)
            }
            .padding(8)
            .background(
                DieterTheme.surface.opacity(0.72),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DieterTheme.border))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sidebar.provider-quotas")
        }
    }
}

private struct ProviderQuotaCompactChrome: ViewModifier {
    let embeddedInToolbar: Bool
    let embeddedInSidebar: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, embeddedInSidebar ? 0 : embeddedInToolbar ? 4 : 8)
            .frame(
                maxWidth: embeddedInSidebar ? .infinity : nil,
                minHeight: 24,
                alignment: embeddedInSidebar ? .leading : .center
            )
            .background {
                if !embeddedInToolbar && !embeddedInSidebar {
                    RoundedRectangle(cornerRadius: embeddedInSidebar ? 7 : 12, style: .continuous)
                        .fill(DieterTheme.raised)
                }
            }
            .overlay {
                if !embeddedInToolbar && !embeddedInSidebar {
                    RoundedRectangle(cornerRadius: embeddedInSidebar ? 7 : 12, style: .continuous)
                        .stroke(DieterTheme.border)
                }
            }
    }
}

private extension View {
    func providerQuotaCompactChrome(embeddedInToolbar: Bool, embeddedInSidebar: Bool = false) -> some View {
        modifier(
            ProviderQuotaCompactChrome(
                embeddedInToolbar: embeddedInToolbar,
                embeddedInSidebar: embeddedInSidebar))
    }
}

private struct ProviderQuotaAccountCompactLabel: View {
    let provider: Dieter_Gateway_V1_ProviderQuotaProvider
    let account: Dieter_Gateway_V1_ProviderQuotaSnapshot

    private var remaining: UInt32? { ProviderQuotaPresentation.remainingPercent(account) }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: ProviderQuotaPresentation.symbol(provider))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ProviderQuotaPresentation.tint(provider, remaining ?? 100))
            Text(ProviderQuotaPresentation.accountLabel(account))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(DieterTheme.subtle)
                .lineLimit(1)
                .frame(minWidth: 42, maxWidth: .infinity, alignment: .leading)
            if let remaining {
                Text("\(remaining)%")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(ProviderQuotaPresentation.tint(provider, remaining))
                    .monospacedDigit()
                ProgressView(value: Double(remaining), total: 100)
                    .progressViewStyle(.linear)
                    .tint(ProviderQuotaPresentation.tint(provider, remaining))
                    .frame(minWidth: 36, maxWidth: 84)
                    .layoutPriority(1)
            } else {
                Text("—").font(.caption2)
            }
            if account.availability != .available {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DieterTheme.amber)
                    .accessibilityLabel(ProviderQuotaPresentation.availability(account.availability))
            }
        }
        .foregroundStyle(DieterTheme.subtle)
        .help(ProviderQuotaPresentation.accountDescription(account, provider: provider))
    }
}

struct ConversationProviderQuotaView: View {
    @Environment(DieterStore.self) private var store
    let card: Dieter_V1_Card
    @State private var presented = false

    private var selected: ProviderQuotaCompactAccount? {
        guard !card.providerAccountKey.isEmpty else { return nil }
        for group in store.providerQuotaGroups {
            if let account = group.accounts.first(where: { $0.accountKey == card.providerAccountKey }) {
                return ProviderQuotaCompactAccount(provider: group.provider, account: account)
            }
        }
        return nil
    }

    var body: some View {
        if let selected {
            Button {
                presented.toggle()
            } label: {
                ProviderQuotaAccountCompactLabel(
                    provider: selected.provider,
                    account: selected.account
                )
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(DieterTheme.raised, in: Capsule())
                .overlay(Capsule().stroke(DieterTheme.border))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "Quota for this conversation's \(ProviderQuotaPresentation.accountLabel(selected.account)) account"
            )
            .accessibilityIdentifier("conversation.provider-account-quota")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                ProviderQuotaDetailsView(accountKey: selected.account.accountKey)
                    .environment(store)
                    .frame(width: 390)
                    .padding(16)
            }
        }
    }
}

struct ProviderQuotaDetailsView: View {
    @Environment(DieterStore.self) private var store
    var accountKey: String? = nil
    @State private var resetConfirmationAccountKey: String?

    private var groups: [Dieter_Gateway_V1_ProviderQuotaGroup] {
        guard let accountKey else { return store.providerQuotaGroups }
        return store.providerQuotaGroups.compactMap { group in
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
                    if store.providerQuotasLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.providerQuotasLoading)
                .accessibilityIdentifier("provider-quotas.refresh")
                .smokeTarget("provider-quotas.refresh")
            }

            if let error = store.providerQuotaError, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(DieterTheme.coral)
            }

            if groups.isEmpty {
                ContentUnavailableView(
                    "No provider accounts",
                    systemImage: "gauge.with.dots.needle.0percent",
                    description: Text(
                        store.providerQuotaError ?? "Sign in to a supported provider on an online Dieter machine.")
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
            if store.providerQuotaGroups.isEmpty { await store.loadProviderQuotas() }
        }
        .confirmationDialog(
            "Use one OpenAI reset credit?",
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
            Text("This consumes one credit and resets the eligible quota windows for this exact account.")
        }
    }

    private func providerGroup(_ group: Dieter_Gateway_V1_ProviderQuotaGroup) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(
                    ProviderQuotaPresentation.name(group.provider),
                    systemImage: ProviderQuotaPresentation.symbol(group.provider)
                )
                .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(group.accounts.count) account\(group.accounts.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
            if accountKey == nil, group.summary.excludedAccountCount > 0 {
                Text(
                    "\(group.summary.includedAccountCount) shown in header · \(group.summary.excludedAccountCount) hidden"
                )
                .font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
            ForEach(group.accounts, id: \.accountKey) { account in
                accountView(account, provider: group.provider)
            }
        }
    }

    private func accountView(
        _ account: Dieter_Gateway_V1_ProviderQuotaSnapshot,
        provider: Dieter_Gateway_V1_ProviderQuotaProvider
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(account.plan.isEmpty ? "Account" : account.plan.capitalized)
                    .font(.system(size: 12, weight: .semibold))
                Text("••\(account.accountKey.suffix(6))")
                    .font(.caption2.monospaced()).foregroundStyle(DieterTheme.tertiary)
                Spacer()
                Text(ProviderQuotaPresentation.availability(account.availability))
                    .font(.caption2).foregroundStyle(
                        account.availability == .available ? DieterTheme.eyes : DieterTheme.amber)
            }
            if !account.displayEmail.isEmpty {
                Text(account.displayEmail)
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
                    .textSelection(.enabled)
            }
            if !account.machines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Available on")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(DieterTheme.tertiary)
                    ForEach(account.machines, id: \.daemonID) { machine in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(machine.online ? DieterTheme.eyes : DieterTheme.tertiary)
                                .frame(width: 6, height: 6)
                            Image(systemName: "server.rack")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(DieterTheme.tertiary)
                            Text(machine.name.isEmpty ? String(machine.daemonID.prefix(8)) : machine.name)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(
                                machine.online
                                    ? "Online"
                                    : ProviderQuotaPresentation.availability(machine.availability)
                            )
                            .font(.caption2)
                            .foregroundStyle(machine.online ? DieterTheme.eyes : DieterTheme.tertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.vertical, 2)
            }
            ForEach(account.windows, id: \.id) { window in
                HStack(spacing: 8) {
                    Text(window.label.isEmpty ? ProviderQuotaPresentation.windowName(window.kind) : window.label)
                        .font(.caption).frame(width: 92, alignment: .leading)
                    if window.hasRemainingPercent {
                        ProgressView(value: Double(window.remainingPercent), total: 100)
                            .progressViewStyle(.linear)
                            .tint(ProviderQuotaPresentation.tint(provider, window.remainingPercent))
                        Text("\(window.remainingPercent)%")
                            .font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
                            .foregroundStyle(ProviderQuotaPresentation.tint(provider, window.remainingPercent))
                    } else {
                        Text("Not reported").font(.caption).foregroundStyle(DieterTheme.tertiary)
                        Spacer()
                    }
                    if !window.resetsAt.isEmpty {
                        Text(ProviderQuotaPresentation.resetText(window.resetsAt))
                            .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    }
                }
            }
            if account.hasCredits {
                quotaMetadata(
                    "Credits",
                    account.credits.unlimited
                        ? "Unlimited" : (account.credits.balance.isEmpty ? "Available" : account.credits.balance)
                )
            }
            if account.hasSpendAllowance {
                let allowance = account.spendAllowance
                quotaMetadata(
                    "Spend",
                    [allowance.used, allowance.limit].filter { !$0.isEmpty }.joined(separator: " / ")
                )
            }
            if account.hasResetCredits {
                quotaMetadata("Reset credits", "\(account.resetCredits.availableCount) available")
            }
            Toggle(
                "Show in app header",
                isOn: Binding(
                    get: { !account.hasIncludedInSummary || account.includedInSummary },
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
            .disabled(store.providerQuotaMutatingAccounts.contains(account.accountKey))
            .accessibilityIdentifier("provider-quotas.include.\(account.accountKey)")
            if provider == .openaiCodex, account.hasResetCredits,
                account.resetCredits.availableCount > 0
            {
                Button("Use reset credit…") { resetConfirmationAccountKey = account.accountKey }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.providerQuotaMutatingAccounts.contains(account.accountKey))
                    .accessibilityIdentifier("provider-quotas.reset.\(account.accountKey)")
            }
            if account.refreshState == .refreshing {
                Text("Refreshing…").font(.caption2).foregroundStyle(DieterTheme.tertiary)
            } else if !account.statusCode.isEmpty, account.availability != .available {
                Text(account.statusCode.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
        }
        .padding(10)
        .background(DieterTheme.raised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(DieterTheme.border))
    }

    private func quotaMetadata(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(DieterTheme.tertiary)
            Spacer()
            Text(value.isEmpty ? "Reported" : value).font(.caption2.monospacedDigit())
        }
    }
}

@MainActor
enum ProviderQuotaPresentation {
    static func remainingPercent(_ account: Dieter_Gateway_V1_ProviderQuotaSnapshot) -> UInt32? {
        account.windows.compactMap { $0.hasRemainingPercent ? $0.remainingPercent : nil }.min()
    }

    static func accountLabel(_ account: Dieter_Gateway_V1_ProviderQuotaSnapshot) -> String {
        if !account.displayEmail.isEmpty {
            let local = account.displayEmail.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
            if !local.isEmpty { return local }
        }
        if !account.plan.isEmpty { return account.plan.capitalized }
        return "••\(account.accountKey.suffix(4))"
    }

    static func accountDescription(
        _ account: Dieter_Gateway_V1_ProviderQuotaSnapshot,
        provider: Dieter_Gateway_V1_ProviderQuotaProvider
    ) -> String {
        let identity = account.displayEmail.isEmpty ? accountLabel(account) : account.displayEmail
        if let remaining = remainingPercent(account) {
            return "\(name(provider)) · \(identity) · \(remaining)% remaining"
        }
        return "\(name(provider)) · \(identity) · \(availability(account.availability))"
    }

    static func name(_ provider: Dieter_Gateway_V1_ProviderQuotaProvider) -> String {
        switch provider {
        case .openaiCodex: "OpenAI"
        case .anthropicClaude: "Claude"
        default: "Provider"
        }
    }

    static func symbol(_ provider: Dieter_Gateway_V1_ProviderQuotaProvider) -> String {
        switch provider {
        case .openaiCodex: "sparkles"
        case .anthropicClaude: "brain.head.profile"
        default: "gauge.with.dots.needle.50percent"
        }
    }

    static func tint(
        _ provider: Dieter_Gateway_V1_ProviderQuotaProvider,
        _ remaining: UInt32
    ) -> Color {
        if provider == .openaiCodex { return DieterTheme.openAIQuota }
        if provider == .anthropicClaude { return DieterTheme.amber }
        if remaining <= 10 { return DieterTheme.coral }
        if remaining <= 30 { return DieterTheme.amber }
        return DieterTheme.eyes
    }

    static func availability(_ value: Dieter_Gateway_V1_ProviderQuotaAvailability) -> String {
        switch value {
        case .available: "Available"
        case .signedOut: "Signed out"
        case .unsupported: "Unsupported"
        case .temporarilyUnavailable: "Unavailable"
        case .permissionDenied: "Permission denied"
        default: "Unknown"
        }
    }

    static func windowName(_ kind: Dieter_Gateway_V1_ProviderQuotaWindowKind) -> String {
        switch kind {
        case .fiveHour: "5 hour"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .model: "Model"
        default: "Quota"
        }
    }

    static func resetText(_ value: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: value) else { return value }
        return "resets " + date.formatted(.relative(presentation: .named))
    }
}
