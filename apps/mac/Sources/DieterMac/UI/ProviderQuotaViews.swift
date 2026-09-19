import DieterAPI
import SwiftUI

struct ProviderQuotaCompactView: View {
    @Environment(DieterStore.self) private var store
    @State private var presented = false

    private var groups: [Dieter_Gateway_V1_ProviderQuotaGroup] {
        store.providerQuotaGroups.filter { !$0.accounts.isEmpty }
    }

    var body: some View {
        if !groups.isEmpty || store.providerQuotasLoading {
            Button {
                presented.toggle()
            } label: {
                HStack(spacing: 8) {
                    if groups.isEmpty {
                        ProgressView().controlSize(.mini)
                    } else {
                        ForEach(groups, id: \.provider.rawValue) { group in
                            compactGroup(group)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(DieterTheme.raised, in: Capsule())
                .overlay(Capsule().stroke(DieterTheme.border))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Provider quotas")
            .accessibilityIdentifier("conversation.provider-quotas")
            .popover(isPresented: $presented, arrowEdge: .bottom) {
                ProviderQuotaDetailsView()
                    .environment(store)
                    .frame(width: 390)
                    .padding(16)
            }
        }
    }

    @ViewBuilder private func compactGroup(_ group: Dieter_Gateway_V1_ProviderQuotaGroup) -> some View {
        let summary = group.summary
        HStack(spacing: 5) {
            Image(systemName: ProviderQuotaPresentation.symbol(group.provider))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ProviderQuotaPresentation.tint(group.provider, 100))
            if summary.hasRemainingPercent {
                Text("\(summary.remainingPercent)%")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(ProviderQuotaPresentation.tint(group.provider, summary.remainingPercent))
                ProgressView(value: Double(summary.remainingPercent), total: 100)
                    .progressViewStyle(.linear)
                    .tint(ProviderQuotaPresentation.tint(group.provider, summary.remainingPercent))
                    .frame(width: 34)
            } else {
                Text("—").font(.caption2)
            }
            if summary.totalAccountCount > 1 {
                Text(
                    summary.excludedAccountCount > 0
                        ? "\(summary.includedAccountCount)/\(summary.totalAccountCount)"
                        : "\(summary.totalAccountCount)"
                )
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(DieterTheme.tertiary)
            }
            if summary.unavailableAccountCount > 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DieterTheme.amber)
                    .accessibilityLabel(
                        "\(summary.unavailableAccountCount) account\(summary.unavailableAccountCount == 1 ? "" : "s") unavailable"
                    )
            }
            if summary.freshness == .stale {
                Circle().fill(DieterTheme.amber).frame(width: 5, height: 5)
                    .accessibilityLabel("Stale")
            }
        }
        .foregroundStyle(DieterTheme.subtle)
    }
}

struct ProviderQuotaDetailsView: View {
    @Environment(DieterStore.self) private var store
    @State private var resetConfirmationAccountKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Provider quotas").font(.headline)
                    Text("The bar summarizes included accounts; every account stays separate below.")
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
            }

            if let error = store.providerQuotaError, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(DieterTheme.coral)
            }

            if store.providerQuotaGroups.isEmpty {
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
                        ForEach(store.providerQuotaGroups, id: \.provider.rawValue) { group in
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
            if group.hasSummary, group.summary.hasRemainingPercent {
                HStack(spacing: 8) {
                    ProgressView(value: Double(group.summary.remainingPercent), total: 100)
                        .progressViewStyle(.linear)
                        .tint(ProviderQuotaPresentation.tint(group.provider, group.summary.remainingPercent))
                    Text("\(group.summary.remainingPercent)% remaining")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(
                            ProviderQuotaPresentation.tint(group.provider, group.summary.remainingPercent))
                }
            }
            if group.summary.excludedAccountCount > 0 {
                Text(
                    "\(group.summary.includedAccountCount) included · \(group.summary.excludedAccountCount) excluded"
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
                "Include in header summary",
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
