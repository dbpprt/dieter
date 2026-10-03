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
                "Use one OpenAI reset credit?",
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
                Text("This consumes one credit and resets the eligible quota windows for this exact account.")
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

    #if DEBUG
        /// The quota sheet over fixture accounts, for UI tests and screenshots
        /// (`DIETER_IOS_QUOTA_PREVIEW`; `details` opens the sheet at launch).
        struct IOSProviderQuotaPreviewScreen: View {
            @State private var quotas: CoreProviderQuotas
            @State private var detailsPresented: Bool

            init(showDetails: Bool) {
                let quotas = CoreProviderQuotas(core: ScriptedCoreClient())
                quotas.install(groups: IOSProviderQuotaPreviewFixture.groups)
                _quotas = State(initialValue: quotas)
                _detailsPresented = State(initialValue: showDetails)
            }

            var body: some View {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            Label("Running", systemImage: "circle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                            Text("Add multi-account provider quotas")
                                .font(.title2.bold())
                            Text(
                                "The toolbar shows the conversation's account. Tap it for account details and controls."
                            )
                            .foregroundStyle(.secondary)
                            Spacer(minLength: 360)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                    }
                    .navigationTitle("Quota-aware conversation")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            if let group = quotas.providerQuotaRows.first, let account = group.accounts.first {
                                Button {
                                    detailsPresented = true
                                } label: {
                                    IOSProviderQuotaAccountPill(provider: group.provider, account: account)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("ios.provider-quotas")
                            }
                        }
                    }
                    .sheet(isPresented: $detailsPresented) {
                        IOSProviderQuotaDetailsView(quotas: quotas)
                            .presentationDetents([.large])
                            .presentationDragIndicator(.visible)
                    }
                }
                .tint(.blue)
            }
        }

        /// OpenAI accounts the core's quota rows describe: one low, one excluded, one signed out.
        private enum IOSProviderQuotaPreviewFixture {
            static var groups: [Dieter_Gateway_V1_ProviderQuotaGroup] { [openAIGroup] }

            private static func date(hoursFromNow: TimeInterval) -> String {
                ISO8601DateFormatter().string(from: Date().addingTimeInterval(hoursFromNow * 3_600))
            }

            private static func window(
                id: String, label: String, kind: Dieter_Gateway_V1_ProviderQuotaWindowKind, remaining: UInt32,
                resetsInHours: TimeInterval
            ) -> Dieter_Gateway_V1_ProviderQuotaWindow {
                .with {
                    $0.id = id
                    $0.label = label
                    $0.kind = kind
                    $0.usedPercent = 100 - remaining
                    $0.remainingPercent = remaining
                    $0.resetsAt = date(hoursFromNow: resetsInHours)
                }
            }

            private static func account(
                key: String, email: String, plan: String, fiveHourRemaining: UInt32, weeklyRemaining: UInt32
            ) -> Dieter_Gateway_V1_ProviderQuotaSnapshot {
                var value = Dieter_Gateway_V1_ProviderQuotaSnapshot()
                value.provider = .openaiCodex
                value.accountKey = key
                value.displayEmail = email
                value.includedInSummary = true
                value.accountKind = .subscription
                value.plan = plan
                value.availability = .available
                value.windows = [
                    window(
                        id: "\(key)-five-hour", label: "5 hour", kind: .fiveHour, remaining: fiveHourRemaining,
                        resetsInHours: 2.3),
                    window(
                        id: "\(key)-weekly", label: "Weekly", kind: .weekly, remaining: weeklyRemaining,
                        resetsInHours: 72),
                ]
                value.nextResetAt = value.windows[0].resetsAt
                value.nextResetWindowID = value.windows[0].id
                value.ordinaryUsageAllowed = true
                value.refreshedAt = date(hoursFromNow: -0.01)
                value.freshUntil = date(hoursFromNow: 0.02)
                value.refreshState = .idle
                value.onlineSourceCount = 1
                value.statusCode = "available"
                return value
            }

            private static var openAIGroup: Dieter_Gateway_V1_ProviderQuotaGroup {
                var plus = account(
                    key: "acct_preview_plus", email: "michael@example.com", plan: "plus", fiveHourRemaining: 18,
                    weeklyRemaining: 64)
                plus.credits = .with {
                    $0.hasCredits_p = true
                    $0.balance = "$120.00"
                }
                plus.resetCredits = .with { $0.availableCount = 2 }

                var team = account(
                    key: "acct_preview_team", email: "team@example.com", plan: "team", fiveHourRemaining: 72,
                    weeklyRemaining: 91)
                team.includedInSummary = false

                var signedOut = Dieter_Gateway_V1_ProviderQuotaSnapshot()
                signedOut.provider = .openaiCodex
                signedOut.accountKey = "acct_preview_archive"
                signedOut.displayEmail = "archive@example.com"
                signedOut.accountKind = .subscription
                signedOut.plan = "free"
                signedOut.availability = .signedOut
                signedOut.statusCode = "signed_out"
                signedOut.includedInSummary = true

                var group = Dieter_Gateway_V1_ProviderQuotaGroup()
                group.provider = .openaiCodex
                group.accounts = [plus, team, signedOut]
                group.summary = .with {
                    $0.totalAccountCount = 3
                    $0.numericAccountCount = 2
                    $0.unavailableAccountCount = 1
                    $0.remainingPercent = 18
                    $0.summaryAccountKey = plus.accountKey
                    $0.summaryWindowID = plus.windows[0].id
                    $0.summaryWindowKind = .fiveHour
                    $0.summaryWindowLabel = "5 hour"
                    $0.resetsAt = plus.windows[0].resetsAt
                    $0.freshness = .fresh
                    $0.includedAccountCount = 2
                    $0.excludedAccountCount = 1
                }
                return group
            }
        }
    #endif
#endif
