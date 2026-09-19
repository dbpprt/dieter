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
            if summary.hasRemainingPercent {
                Text("\(summary.remainingPercent)%")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                ProgressView(value: Double(summary.remainingPercent), total: 100)
                    .progressViewStyle(.linear)
                    .tint(ProviderQuotaPresentation.tint(summary.remainingPercent))
                    .frame(width: 34)
            } else {
                Text("—").font(.caption2)
            }
            if summary.totalAccountCount > 1 {
                Text("\(summary.totalAccountCount)")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Provider quotas").font(.headline)
                    Text("Each account stays separate; the bar shows the lowest remaining window.")
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
                        .tint(ProviderQuotaPresentation.tint(group.summary.remainingPercent))
                    Text("\(group.summary.remainingPercent)% remaining")
                        .font(.caption.monospacedDigit())
                }
            }
            ForEach(group.accounts, id: \.accountKey) { account in
                accountView(account)
            }
        }
    }

    private func accountView(_ account: Dieter_Gateway_V1_ProviderQuotaSnapshot) -> some View {
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
            ForEach(account.windows, id: \.id) { window in
                HStack(spacing: 8) {
                    Text(window.label.isEmpty ? ProviderQuotaPresentation.windowName(window.kind) : window.label)
                        .font(.caption).frame(width: 92, alignment: .leading)
                    if window.hasRemainingPercent {
                        ProgressView(value: Double(window.remainingPercent), total: 100)
                            .progressViewStyle(.linear)
                            .tint(ProviderQuotaPresentation.tint(window.remainingPercent))
                        Text("\(window.remainingPercent)%")
                            .font(.caption.monospacedDigit()).frame(width: 34, alignment: .trailing)
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

    static func tint(_ remaining: UInt32) -> Color {
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
