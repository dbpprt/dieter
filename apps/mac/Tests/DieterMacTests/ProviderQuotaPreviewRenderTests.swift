import AppKit
import DieterAPI
import SwiftUI
import Testing
@testable import DieterMac

private func quotaPreviewDate(hoursFromNow: TimeInterval) -> String {
    ISO8601DateFormatter().string(from: Date().addingTimeInterval(hoursFromNow * 3_600))
}

private struct QuotaPopoverPointer: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

private func quotaPreviewWindow(
    id: String,
    label: String,
    kind: Dieter_Gateway_V1_ProviderQuotaWindowKind,
    remaining: UInt32,
    resetsInHours: TimeInterval
) -> Dieter_Gateway_V1_ProviderQuotaWindow {
    var window = Dieter_Gateway_V1_ProviderQuotaWindow()
    window.id = id
    window.label = label
    window.kind = kind
    window.usedPercent = 100 - remaining
    window.remainingPercent = remaining
    window.resetsAt = quotaPreviewDate(hoursFromNow: resetsInHours)
    return window
}

private func availableQuotaPreviewAccount(
    provider: Dieter_Gateway_V1_ProviderQuotaProvider = .openaiCodex,
    key: String,
    email: String,
    plan: String,
    fiveHourRemaining: UInt32,
    weeklyRemaining: UInt32
) -> Dieter_Gateway_V1_ProviderQuotaSnapshot {
    var account = Dieter_Gateway_V1_ProviderQuotaSnapshot()
    account.provider = provider
    account.accountKey = key
    account.displayEmail = email
    account.includedInSummary = true
    account.accountKind = .subscription
    account.plan = plan
    account.availability = .available
    account.windows = [
        quotaPreviewWindow(
            id: "\(key)-five-hour",
            label: "5 hour",
            kind: .fiveHour,
            remaining: fiveHourRemaining,
            resetsInHours: 2.3
        ),
        quotaPreviewWindow(
            id: "\(key)-weekly",
            label: "Weekly",
            kind: .weekly,
            remaining: weeklyRemaining,
            resetsInHours: 72
        ),
    ]
    account.nextResetAt = account.windows[0].resetsAt
    account.nextResetWindowID = account.windows[0].id
    account.ordinaryUsageAllowed = true
    account.refreshedAt = quotaPreviewDate(hoursFromNow: -0.01)
    account.freshUntil = quotaPreviewDate(hoursFromNow: 0.02)
    account.refreshState = .idle
    account.onlineSourceCount = 1
    account.statusCode = "available"
    var laptop = Dieter_Gateway_V1_ProviderQuotaMachine()
    laptop.daemonID = "d_local_mac"
    laptop.name = "Michael’s MacBook Pro"
    laptop.online = true
    laptop.availability = .available
    laptop.lastSeenAt = quotaPreviewDate(hoursFromNow: -0.01)
    var buildMachine = Dieter_Gateway_V1_ProviderQuotaMachine()
    buildMachine.daemonID = "d_build_mac"
    buildMachine.name = "Build Mac"
    buildMachine.online = false
    buildMachine.availability = .temporarilyUnavailable
    buildMachine.lastSeenAt = quotaPreviewDate(hoursFromNow: -1)
    account.machines = [laptop, buildMachine]
    return account
}

private func quotaPreviewGroup() -> Dieter_Gateway_V1_ProviderQuotaGroup {
    var plus = availableQuotaPreviewAccount(
        key: "acct_8d9c1a2b3c4d",
        email: "michael@example.com",
        plan: "plus",
        fiveHourRemaining: 18,
        weeklyRemaining: 64
    )
    var plusCredits = Dieter_Gateway_V1_ProviderCreditBalance()
    plusCredits.hasCredits_p = true
    plusCredits.balance = "$120.00"
    plus.credits = plusCredits
    var resetCredits = Dieter_Gateway_V1_ProviderResetCredits()
    resetCredits.availableCount = 2
    plus.resetCredits = resetCredits

    var team = availableQuotaPreviewAccount(
        key: "acct_1f2e3d4c5b6a",
        email: "team@example.com",
        plan: "team",
        fiveHourRemaining: 72,
        weeklyRemaining: 91
    )
    var spend = Dieter_Gateway_V1_ProviderSpendAllowance()
    spend.used = "$18.40"
    spend.limit = "$100.00"
    spend.currency = "USD"
    spend.remainingPercent = 82
    team.spendAllowance = spend
    team.includedInSummary = false

    var signedOut = Dieter_Gateway_V1_ProviderQuotaSnapshot()
    signedOut.provider = .openaiCodex
    signedOut.accountKey = "acct_ffeeddccbbaa"
    signedOut.accountKind = .subscription
    signedOut.plan = "free"
    signedOut.availability = .signedOut
    signedOut.statusCode = "signed_out"
    signedOut.displayEmail = "archive@example.com"
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

private func claudeQuotaPreviewGroup() -> Dieter_Gateway_V1_ProviderQuotaGroup {
    let account = availableQuotaPreviewAccount(
        provider: .anthropicClaude,
        key: "claude_acct_617f9a8e",
        email: "claude@example.com",
        plan: "max",
        fiveHourRemaining: 83,
        weeklyRemaining: 74
    )

    var summary = Dieter_Gateway_V1_ProviderQuotaSummary()
    summary.totalAccountCount = 1
    summary.numericAccountCount = 1
    summary.remainingPercent = 74
    summary.summaryAccountKey = account.accountKey
    summary.summaryWindowID = account.windows[1].id
    summary.summaryWindowKind = .weekly
    summary.summaryWindowLabel = "Weekly"
    summary.resetsAt = account.windows[1].resetsAt
    summary.freshness = .fresh
    summary.includedAccountCount = 1

    var group = Dieter_Gateway_V1_ProviderQuotaGroup()
    group.provider = .anthropicClaude
    group.accounts = [account]
    group.summary = summary
    return group
}

@MainActor private func renderQuotaPreview<Content: View>(_ content: Content, to url: URL) throws {
    let hostingView = NSHostingView(rootView: content)
    hostingView.appearance = NSAppearance(named: .darkAqua)
    hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
    hostingView.layoutSubtreeIfNeeded()
    hostingView.needsDisplay = true
    guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
        Issue.record("Could not create quota preview bitmap")
        return
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        Issue.record("Could not encode quota preview PNG")
        return
    }
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

@Test @MainActor func providerQuotaMultiAccountViewsRender() throws {
    let outputDirectory =
        ProcessInfo.processInfo.environment["DIETER_QUOTA_SCREENSHOT_DIR"]
        .map(URL.init(fileURLWithPath:))
        ?? URL(fileURLWithPath: "/tmp/dieter-provider-quota")
    let selection = DieterThemeSelection(
        appearance: .dark,
        palette: .electricBlue,
        transparencyEnabled: false
    )
    DieterTheme.install(selection: selection, systemColorScheme: .dark, reduceTransparency: true)
    defer { DieterTheme.install(palette: .monochrome, colorScheme: .light) }

    let store = DieterStore(restoreSync: false)
    store.providerQuotaGroups = [quotaPreviewGroup(), claudeQuotaPreviewGroup()]

    var card = Dieter_V1_Card()
    card.provider = "codex"
    card.providerAccountKey = "acct_8d9c1a2b3c4d"

    let compact = HStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 2) {
            Text("Global")
                .font(.caption).foregroundStyle(DieterTheme.tertiary)
            ProviderQuotaCompactView().environment(store)
        }
        Spacer()
        VStack(alignment: .leading, spacing: 2) {
            Text("This chat")
                .font(.caption).foregroundStyle(DieterTheme.tertiary)
            ConversationProviderQuotaView(card: card).environment(store)
        }
    }
    .padding(.horizontal, 16)
    .frame(width: 760, height: 62)
    .background(DieterTheme.background)
    .foregroundStyle(DieterTheme.text)
    .environment(\.colorScheme, .dark)

    let details = VStack(spacing: -1) {
        ProviderQuotaDetailsView()
            .environment(store)
            .padding(16)
            .frame(width: 422)
            .background(
                DieterTheme.background,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DieterTheme.border)
            )
            .shadow(color: .black.opacity(0.42), radius: 20, y: 10)
        QuotaPopoverPointer()
            .fill(DieterTheme.background)
            .frame(width: 26, height: 13)
    }
    .padding(30)
    .background(Color(red: 0.055, green: 0.061, blue: 0.075))
    .foregroundStyle(DieterTheme.text)
    .environment(\.colorScheme, .dark)

    let claudeDetails = VStack(spacing: -1) {
        ProviderQuotaDetailsView(accountKey: "claude_acct_617f9a8e")
            .environment(store)
            .padding(16)
            .frame(width: 422)
            .background(
                DieterTheme.background,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DieterTheme.border)
            )
            .shadow(color: .black.opacity(0.42), radius: 20, y: 10)
        QuotaPopoverPointer()
            .fill(DieterTheme.background)
            .frame(width: 26, height: 13)
    }
    .padding(30)
    .background(Color(red: 0.055, green: 0.061, blue: 0.075))
    .foregroundStyle(DieterTheme.text)
    .environment(\.colorScheme, .dark)

    try renderQuotaPreview(compact, to: outputDirectory.appending(path: "macos-compact.png"))
    try renderQuotaPreview(details, to: outputDirectory.appending(path: "macos-details.png"))
    try renderQuotaPreview(claudeDetails, to: outputDirectory.appending(path: "macos-claude-details.png"))
}
