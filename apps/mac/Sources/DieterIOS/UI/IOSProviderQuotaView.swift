#if os(iOS)
    import DieterAPI
    import Foundation
    import SwiftUI

    struct IOSProviderQuotaCompactView: View {
        @Bindable var store: IOSStore
        @State private var presented = false

        private var groups: [Dieter_Gateway_V1_ProviderQuotaGroup] {
            store.providerQuotaGroups.filter { !$0.accounts.isEmpty }
        }

        var body: some View {
            if !groups.isEmpty || store.providerQuotasLoading {
                Button {
                    presented = true
                } label: {
                    if groups.isEmpty {
                        ProgressView().controlSize(.mini)
                    } else {
                        HStack(spacing: 7) {
                            ForEach(groups, id: \.provider.rawValue) { group in
                                IOSProviderQuotaCompactLabel(group: group)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Provider quotas")
                .accessibilityIdentifier("ios.provider-quotas")
                .sheet(isPresented: $presented) {
                    IOSProviderQuotaDetailsView(store: store)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
        }
    }

    struct IOSProviderQuotaCompactLabel: View {
        let group: Dieter_Gateway_V1_ProviderQuotaGroup

        var body: some View {
            let summary = group.summary
            HStack(spacing: 4) {
                Image(systemName: IOSProviderQuotaPresentation.symbol(group.provider))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(IOSProviderQuotaPresentation.tint(group.provider))
                if summary.hasRemainingPercent {
                    Text("\(summary.remainingPercent)%")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(IOSProviderQuotaPresentation.tint(group.provider))
                    ProgressView(value: Double(summary.remainingPercent), total: 100)
                        .progressViewStyle(.linear)
                        .tint(IOSProviderQuotaPresentation.tint(group.provider))
                        .frame(width: 28)
                } else {
                    Text("—").font(.caption2)
                }
                if summary.totalAccountCount > 1 {
                    Text(
                        summary.excludedAccountCount > 0
                            ? "\(summary.includedAccountCount)/\(summary.totalAccountCount)"
                            : "\(summary.totalAccountCount)"
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                if summary.unavailableAccountCount > 0 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.thinMaterial, in: Capsule())
        }
    }

    struct IOSConversationProviderQuotaView: View {
        @Bindable var store: IOSStore
        let card: Dieter_V1_Card
        @State private var presented = false

        private var selection: IOSProviderQuotaAccountSelection? {
            IOSProviderQuotaSelection.account(for: card, in: store.providerQuotaGroups)
        }

        var body: some View {
            if let selection {
                Button {
                    presented = true
                } label: {
                    IOSProviderQuotaAccountCompactLabel(
                        provider: selection.provider,
                        account: selection.account
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "Quota for this conversation's \(IOSProviderQuotaPresentation.accountLabel(selection.account)) account"
                )
                .accessibilityIdentifier("ios.conversation.provider-account-quota")
                .sheet(isPresented: $presented) {
                    IOSProviderQuotaDetailsView(
                        store: store,
                        accountKey: selection.account.accountKey
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            }
        }
    }

    private struct IOSProviderQuotaAccountCompactLabel: View {
        let provider: Dieter_Gateway_V1_ProviderQuotaProvider
        let account: Dieter_Gateway_V1_ProviderQuotaSnapshot

        private var remaining: UInt32? {
            IOSProviderQuotaPresentation.remainingPercent(account)
        }

        var body: some View {
            HStack(spacing: 5) {
                Image(systemName: IOSProviderQuotaPresentation.symbol(provider))
                    .font(.system(size: 10, weight: .semibold))
                if let remaining {
                    Text("\(remaining)%")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    ProgressView(value: Double(remaining), total: 100)
                        .progressViewStyle(.linear)
                        .frame(width: 28)
                } else {
                    Text("—").font(.caption2)
                }
                if account.availability != .available {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }
            .foregroundStyle(IOSProviderQuotaPresentation.tint(provider))
            .tint(IOSProviderQuotaPresentation.tint(provider))
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(.thinMaterial, in: Capsule())
        }
    }

    struct IOSProviderQuotaDetailsView: View {
        @Environment(\.dismiss) private var dismiss
        @Bindable var store: IOSStore
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
            NavigationStack {
                IOSProviderQuotaDetailsContent(
                    groups: groups,
                    showsProviderSummary: accountKey == nil,
                    loading: store.providerQuotasLoading,
                    error: store.providerQuotaError,
                    mutatingAccounts: store.providerQuotaMutatingAccounts,
                    refresh: { Task { await store.loadProviderQuotas(requestRefresh: true) } },
                    setInclusion: { provider, accountKey, included in
                        Task {
                            await store.setProviderQuotaSummaryInclusion(
                                provider: provider, accountKey: accountKey, included: included)
                        }
                    },
                    useReset: { resetConfirmationAccountKey = $0 }
                )
                .navigationTitle(accountKey == nil ? "Provider quotas" : "Conversation quota")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
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
                ),
                titleVisibility: .visible
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
    }

    private struct IOSProviderQuotaDetailsContent: View {
        let groups: [Dieter_Gateway_V1_ProviderQuotaGroup]
        let showsProviderSummary: Bool
        let loading: Bool
        let error: String?
        let mutatingAccounts: Set<String>
        let refresh: () -> Void
        let setInclusion: (Dieter_Gateway_V1_ProviderQuotaProvider, String, Bool) -> Void
        let useReset: (String) -> Void

        var body: some View {
            List {
                Section {
                    Text(
                        showsProviderSummary
                            ? "The header summarizes included accounts. Every account and quota window stays separate here."
                            : "Usage for the exact provider account assigned to this conversation."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    if let error, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if groups.isEmpty {
                    ContentUnavailableView(
                        "No provider accounts",
                        systemImage: "gauge.with.dots.needle.0percent",
                        description: Text("Sign in to a supported provider on an online Dieter machine."))
                } else {
                    ForEach(groups, id: \.provider.rawValue) { group in
                        providerSection(group)
                    }
                }
            }
            .refreshable { refresh() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                        .disabled(loading)
                }
            }
            .overlay {
                if loading, groups.isEmpty { ProgressView("Loading quotas…") }
            }
        }

        private func providerSection(_ group: Dieter_Gateway_V1_ProviderQuotaGroup) -> some View {
            Section {
                if showsProviderSummary, group.hasSummary, group.summary.hasRemainingPercent {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("Included-account summary")
                            Spacer()
                            Text("\(group.summary.remainingPercent)% remaining")
                                .monospacedDigit()
                                .foregroundStyle(IOSProviderQuotaPresentation.tint(group.provider))
                        }
                        .font(.subheadline.weight(.semibold))
                        ProgressView(value: Double(group.summary.remainingPercent), total: 100)
                            .tint(IOSProviderQuotaPresentation.tint(group.provider))
                        if group.summary.excludedAccountCount > 0 {
                            Text(
                                "\(group.summary.includedAccountCount) included · \(group.summary.excludedAccountCount) excluded"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(group.accounts, id: \.accountKey) { account in
                    accountView(account, provider: group.provider)
                }
            } header: {
                HStack {
                    Label(
                        IOSProviderQuotaPresentation.name(group.provider),
                        systemImage: IOSProviderQuotaPresentation.symbol(group.provider))
                    Spacer()
                    Text("\(group.accounts.count) account\(group.accounts.count == 1 ? "" : "s")")
                }
                .foregroundStyle(IOSProviderQuotaPresentation.tint(group.provider))
            }
        }

        private func accountView(
            _ account: Dieter_Gateway_V1_ProviderQuotaSnapshot,
            provider: Dieter_Gateway_V1_ProviderQuotaProvider
        ) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.plan.isEmpty ? "Account" : account.plan.capitalized)
                            .font(.headline)
                        if !account.displayEmail.isEmpty {
                            Text(account.displayEmail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else {
                            Text("••\(account.accountKey.suffix(6))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(IOSProviderQuotaPresentation.availability(account.availability))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(account.availability == .available ? Color.secondary : Color.orange)
                }

                ForEach(account.windows, id: \.id) { window in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(
                                window.label.isEmpty
                                    ? IOSProviderQuotaPresentation.windowName(window.kind) : window.label)
                            Spacer()
                            if window.hasRemainingPercent {
                                Text("\(window.remainingPercent)%")
                                    .monospacedDigit()
                                    .foregroundStyle(IOSProviderQuotaPresentation.tint(provider))
                            } else {
                                Text("Not reported").foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline)
                        if window.hasRemainingPercent {
                            ProgressView(value: Double(window.remainingPercent), total: 100)
                                .tint(IOSProviderQuotaPresentation.tint(provider))
                        }
                        if !window.resetsAt.isEmpty {
                            Text(IOSProviderQuotaPresentation.resetText(window.resetsAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if account.hasCredits {
                    quotaMetadata(
                        "Credits",
                        account.credits.unlimited
                            ? "Unlimited" : (account.credits.balance.isEmpty ? "Available" : account.credits.balance))
                }
                if account.hasSpendAllowance {
                    quotaMetadata(
                        "Spend",
                        [account.spendAllowance.used, account.spendAllowance.limit]
                            .filter { !$0.isEmpty }.joined(separator: " / "))
                }
                if account.hasResetCredits {
                    quotaMetadata("Reset credits", "\(account.resetCredits.availableCount) available")
                }

                Toggle(
                    "Include in header summary",
                    isOn: Binding(
                        get: { !account.hasIncludedInSummary || account.includedInSummary },
                        set: { setInclusion(provider, account.accountKey, $0) }
                    )
                )
                .disabled(mutatingAccounts.contains(account.accountKey))
                .accessibilityIdentifier("ios.provider-quotas.include.\(account.accountKey)")

                if provider == .openaiCodex, account.hasResetCredits,
                    account.resetCredits.availableCount > 0
                {
                    Button("Use reset credit…", systemImage: "arrow.counterclockwise") {
                        useReset(account.accountKey)
                    }
                    .disabled(mutatingAccounts.contains(account.accountKey))
                    .accessibilityIdentifier("ios.provider-quotas.reset.\(account.accountKey)")
                }
            }
            .padding(.vertical, 4)
        }

        private func quotaMetadata(_ label: String, _ value: String) -> some View {
            LabeledContent(label, value: value.isEmpty ? "Reported" : value)
                .font(.subheadline)
        }
    }

    @MainActor
    private enum IOSProviderQuotaPresentation {
        static let openAI = Color(red: 37 / 255, green: 136 / 255, blue: 245 / 255)

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

        static func tint(_ provider: Dieter_Gateway_V1_ProviderQuotaProvider) -> Color {
            provider == .openaiCodex ? openAI : .orange
        }

        static func remainingPercent(
            _ account: Dieter_Gateway_V1_ProviderQuotaSnapshot
        ) -> UInt32? {
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
            return "Resets " + date.formatted(.relative(presentation: .named))
        }
    }

    #if DEBUG
        struct IOSProviderQuotaPreviewScreen: View {
            let showDetails: Bool
            @State private var detailsPresented: Bool
            private let groups = IOSProviderQuotaPreviewFixture.groups

            init(showDetails: Bool) {
                self.showDetails = showDetails
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
                                "The header shows the conservative summary across included OpenAI accounts. Tap it for account details and controls."
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
                            Button {
                                detailsPresented = true
                            } label: {
                                IOSProviderQuotaCompactLabel(group: groups[0])
                            }
                            .buttonStyle(.plain)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Task actions", systemImage: "ellipsis.circle") {}
                                .labelStyle(.iconOnly)
                        }
                    }
                    .sheet(isPresented: $detailsPresented) {
                        NavigationStack {
                            IOSProviderQuotaDetailsContent(
                                groups: groups,
                                showsProviderSummary: true,
                                loading: false,
                                error: nil,
                                mutatingAccounts: [],
                                refresh: {},
                                setInclusion: { _, _, _ in },
                                useReset: { _ in }
                            )
                            .navigationTitle("Provider quotas")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Done") { detailsPresented = false }
                                }
                            }
                        }
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                    }
                }
                .tint(.blue)
            }
        }

        private enum IOSProviderQuotaPreviewFixture {
            static var groups: [Dieter_Gateway_V1_ProviderQuotaGroup] { [openAIGroup] }

            private static func date(hoursFromNow: TimeInterval) -> String {
                ISO8601DateFormatter().string(from: Date().addingTimeInterval(hoursFromNow * 3_600))
            }

            private static func window(
                id: String,
                label: String,
                kind: Dieter_Gateway_V1_ProviderQuotaWindowKind,
                remaining: UInt32,
                resetsInHours: TimeInterval
            ) -> Dieter_Gateway_V1_ProviderQuotaWindow {
                var value = Dieter_Gateway_V1_ProviderQuotaWindow()
                value.id = id
                value.label = label
                value.kind = kind
                value.usedPercent = 100 - remaining
                value.remainingPercent = remaining
                value.resetsAt = date(hoursFromNow: resetsInHours)
                return value
            }

            private static func account(
                key: String,
                email: String,
                plan: String,
                fiveHourRemaining: UInt32,
                weeklyRemaining: UInt32
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
                        id: "\(key)-five-hour", label: "5 hour", kind: .fiveHour,
                        remaining: fiveHourRemaining, resetsInHours: 2.3),
                    window(
                        id: "\(key)-weekly", label: "Weekly", kind: .weekly,
                        remaining: weeklyRemaining, resetsInHours: 72),
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
                    key: "acct_8d9c1a2b3c4d", email: "michael@example.com", plan: "plus",
                    fiveHourRemaining: 18, weeklyRemaining: 64)
                var credits = Dieter_Gateway_V1_ProviderCreditBalance()
                credits.hasCredits_p = true
                credits.balance = "$120.00"
                plus.credits = credits
                var resetCredits = Dieter_Gateway_V1_ProviderResetCredits()
                resetCredits.availableCount = 2
                plus.resetCredits = resetCredits

                var team = account(
                    key: "acct_1f2e3d4c5b6a", email: "team@example.com", plan: "team",
                    fiveHourRemaining: 72, weeklyRemaining: 91)
                team.includedInSummary = false

                var signedOut = Dieter_Gateway_V1_ProviderQuotaSnapshot()
                signedOut.provider = .openaiCodex
                signedOut.accountKey = "acct_ffeeddccbbaa"
                signedOut.displayEmail = "archive@example.com"
                signedOut.accountKind = .subscription
                signedOut.plan = "free"
                signedOut.availability = .signedOut
                signedOut.statusCode = "signed_out"
                signedOut.includedInSummary = true

                var summary = Dieter_Gateway_V1_ProviderQuotaSummary()
                summary.totalAccountCount = 3
                summary.numericAccountCount = 2
                summary.unavailableAccountCount = 1
                summary.remainingPercent = 18
                summary.summaryAccountKey = plus.accountKey
                summary.summaryWindowID = plus.windows[0].id
                summary.summaryWindowKind = .fiveHour
                summary.summaryWindowLabel = "5 hour"
                summary.resetsAt = plus.windows[0].resetsAt
                summary.freshness = .fresh
                summary.includedAccountCount = 2
                summary.excludedAccountCount = 1

                var group = Dieter_Gateway_V1_ProviderQuotaGroup()
                group.provider = .openaiCodex
                group.accounts = [plus, team, signedOut]
                group.summary = summary
                return group
            }
        }
    #endif
#endif
