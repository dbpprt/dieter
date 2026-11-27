import AppKit
import DieterClientAPI
import DieterCore
import SwiftUI

/// One provider account in Settings › Providers: who it is, its usage, how
/// it counts in summaries, and its sign-in on each machine. Every line comes
/// from the core's row; the panel only lays it out and sends commands.
struct ProviderAccountPanel: View {
    @Environment(DieterStore.self) private var store
    let account: ClientProviderAccountRow
    let provider: String
    @State private var renaming = false
    @State private var confirmingRemoval = false
    @State private var confirmingReset = false
    @State private var confirmingOmpAccess = false
    /// The last reset's outcome, as the core words it.
    @State private var resetOutcome: String?

    private var providers: ProvidersModel { store.providersModel }
    private var busy: Bool { providers.isMutating(account.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            usage
            if !account.dieterTokens.isEmpty {
                Label(account.dieterTokens, systemImage: "number")
                    .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    .accessibilityLabel("Dieter turns: \(account.dieterTokens)")
            }
            controls
            machines
        }
        .padding(12)
        .dieterInset(radius: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("providers.account.\(account.id)")
        .e2eTarget("providers.account.\(account.id)", text: account.label)
        .sheet(isPresented: $renaming) {
            RenameProviderAccountSheet(account: account).environment(store)
        }
        .confirmationDialog("Remove \(account.label)?", isPresented: $confirmingRemoval) {
            Button("Remove account", role: .destructive) {
                Task { await providers.remove(accountID: account.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                account.managed
                    ? "\(account.label) follows a machine's own login. Removing it hides it until Dieter finds that login again."
                    : "Every machine signs \(account.label) out and deletes its sign-in. Conversations that used it switch to the default account."
            )
        }
        .confirmationDialog(SharedRules.shared.providerResetTitle(), isPresented: $confirmingReset) {
            Button("Use reset credit", role: .destructive) {
                Task {
                    let outcome = await providers.consumeReset(accountID: account.id)
                    resetOutcome = outcome.map(\.message).flatMap { $0.isEmpty ? nil : $0 }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SharedRules.shared.providerResetMessage())
        }
        .confirmationDialog(SharedRules.shared.providerOmpAccessTitle(), isPresented: $confirmingOmpAccess) {
            Button(SharedRules.shared.providerOmpAccessConfirm()) {
                Task { await providers.setOmpAccess(accountID: account.id, allowed: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(SharedRules.shared.providerOmpAccessMessage())
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ProviderPresentation.symbol(provider))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ProviderPresentation.tint(provider, account.severity))
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(account.label).font(.system(size: 13, weight: .semibold))
                    if account.isDefault {
                        Text("DEFAULT").font(.system(size: 8, weight: .bold)).foregroundStyle(DieterTheme.eyes)
                    }
                    if busy { ProgressView().controlSize(.mini) }
                }
                Text(account.identity)
                    .font(.caption).foregroundStyle(DieterTheme.subtle)
                    .textSelection(.enabled)
                if !account.subtitle.isEmpty {
                    Text(account.subtitle).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                }
            }
            Spacer(minLength: 8)
            if let url = URL(string: account.manageUsageURL), !account.manageUsageURL.isEmpty {
                Button("Manage usage", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) }
                    .buttonStyle(DieterBarButtonStyle(size: 24))
                    .help(account.manageUsageURL)
                    .accessibilityIdentifier("providers.account.\(account.id).manage-usage")
            }
            Button("Rename", systemImage: "pencil") { renaming = true }
                .labelStyle(.iconOnly)
                .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 24))
                .disabled(busy)
                .quickHelp("Rename")
                .accessibilityIdentifier("providers.account.\(account.id).rename")
            Button("Remove", systemImage: "trash", role: .destructive) { confirmingRemoval = true }
                .labelStyle(.iconOnly)
                .buttonStyle(DieterBarButtonStyle(shape: .circle, destructive: true, size: 24))
                .disabled(busy)
                .quickHelp("Remove account")
                .accessibilityIdentifier("providers.account.\(account.id).remove")
                .e2eTarget("providers.account.\(account.id).remove", text: account.label)
        }
    }

    private var usage: some View {
        VStack(alignment: .leading, spacing: 6) {
            if account.windows.isEmpty {
                Text(account.status.isEmpty ? "Usage not reported" : account.status)
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
            } else {
                ProviderUsageMeters(
                    provider: provider, windows: account.windows, identifierPrefix: "providers.account.\(account.id)")
            }
            HStack(spacing: 6) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let now = context.date.epochMillis
                    let stale = SharedRules.shared.providerUsageStale(
                        observedAt: account.usageObservedAt, nowMillis: now)
                    Label(
                        SharedRules.shared.providerUsageUpdated(observedAt: account.usageObservedAt, nowMillis: now),
                        systemImage: stale ? "clock.badge.exclamationmark" : "clock"
                    )
                    .font(.caption2)
                    .foregroundStyle(stale ? DieterTheme.amber : DieterTheme.tertiary)
                }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await providers.refreshUsage(accountID: account.id) }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(DieterTheme.tertiary)
                .disabled(busy)
                .quickHelp("Refresh usage")
                .accessibilityIdentifier("providers.account.\(account.id).refresh")
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Toggle(
                "Include in summary",
                isOn: Binding(
                    get: { account.included },
                    set: { included in Task { await providers.setIncluded(accountID: account.id, included: included) } }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(busy)
            .help("The sidebar and the Inbox show the tightest limit of included accounts.")
            .accessibilityIdentifier("providers.account.\(account.id).include")
            if account.offersOmpAccess {
                Toggle(
                    SharedRules.shared.providerOmpAccessLabel(),
                    isOn: Binding(
                        get: { account.ompAccess },
                        set: { allowed in
                            if allowed {
                                confirmingOmpAccess = true
                            } else {
                                Task { await providers.setOmpAccess(accountID: account.id, allowed: false) }
                            }
                        }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(busy)
                .help(SharedRules.shared.providerOmpAccessDetail())
                .accessibilityIdentifier("providers.account.\(account.id).omp-access")
            }
            Spacer(minLength: 8)
            if let resetOutcome {
                Text(resetOutcome).font(.caption2).foregroundStyle(DieterTheme.subtle)
            }
            if account.canReset {
                Button(account.resetLabel.isEmpty ? "Reset usage limits" : account.resetLabel) {
                    confirmingReset = true
                }
                .buttonStyle(DieterBarButtonStyle(size: 24))
                .disabled(busy)
                .accessibilityIdentifier("providers.account.\(account.id).reset")
                .e2eTarget("providers.account.\(account.id).reset", text: account.label)
            }
        }
    }

    private var machines: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !account.machines.isEmpty {
                Divider().overlay(DieterTheme.border)
            }
            ForEach(account.machines, id: \.daemonID) { machine in
                ProviderMachineLine(account: account, machine: machine, busy: busy)
            }
            if account.canSignInAll {
                Button("Sign in on all machines", systemImage: "person.badge.key") {
                    Task { await providers.presentSignInAll(accountID: account.id) }
                }
                .buttonStyle(DieterBarButtonStyle(size: 24))
                .disabled(busy)
                .accessibilityIdentifier("providers.account.\(account.id).signin-all")
                .e2eTarget("providers.account.\(account.id).signin-all", text: account.label)
            }
        }
    }
}

/// An account's sign-in on one machine, with what can be done there.
private struct ProviderMachineLine: View {
    @Environment(DieterStore.self) private var store
    let account: ClientProviderAccountRow
    let machine: ClientProviderMachineRow
    let busy: Bool

    private var providers: ProvidersModel { store.providersModel }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(machine.online ? DieterTheme.running : DieterTheme.tertiary)
                .frame(width: 6, height: 6)
                .accessibilityLabel(machine.online ? "Online" : "Offline")
            Text(machine.name).font(.caption.weight(.semibold)).lineLimit(1)
            Text(machine.stateLabel)
                .font(.caption)
                .foregroundStyle(ProviderPresentation.stateTint(machine.state))
                .e2eTarget(
                    "providers.account.\(account.id).machine.\(machine.daemonID)",
                    text: "\(account.label) · \(machine.stateLabel)")
            if !machine.detail.isEmpty {
                Text(machine.detail)
                    .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(machine.detail)
            }
            Spacer(minLength: 6)
            if machine.canCheck {
                Button("Check") { Task { await providers.check(accountID: account.id, daemonID: machine.daemonID) } }
                    .buttonStyle(DieterBarButtonStyle(size: 22))
                    .disabled(busy)
                    .accessibilityIdentifier("providers.account.\(account.id).check.\(machine.daemonID)")
            }
            if machine.canSignOut {
                Button("Sign out") {
                    Task { await providers.signOut(accountID: account.id, daemonID: machine.daemonID) }
                }
                .buttonStyle(DieterBarButtonStyle(size: 22))
                .disabled(busy)
                .accessibilityIdentifier("providers.account.\(account.id).signout.\(machine.daemonID)")
            }
            if machine.canSignIn {
                Button("Sign in") {
                    Task { await providers.presentSignIn(accountID: account.id, daemonID: machine.daemonID) }
                }
                .buttonStyle(DieterBarButtonStyle(prominent: true, size: 22))
                .disabled(busy)
                .accessibilityLabel("Sign in \(account.label) on \(machine.name)")
                .accessibilityIdentifier("providers.account.\(account.id).signin.\(machine.daemonID)")
                .e2eTarget(
                    "providers.account.\(account.id).signin.\(machine.daemonID)", text: account.label)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Renames an account; the label is shared by every client of the account.
private struct RenameProviderAccountSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let account: ClientProviderAccountRow
    @State private var label = ""
    @State private var saving = false

    private var normalized: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename account").font(.title2.weight(.bold))
            Text("Every device and machine of your account shows this name, e.g. in the composer's account menu.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Account name", text: $label)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
                .accessibilityIdentifier("providers.rename.label")
            if let failure = store.providersModel.failure {
                Text(failure).font(.caption).foregroundStyle(DieterTheme.coral)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DieterBarButtonStyle())
                Button("Rename") { save() }.buttonStyle(DieterBarButtonStyle(prominent: true))
                    .disabled(saving || normalized.isEmpty || normalized == account.label)
            }
        }
        .padding(24).frame(width: 460)
        .onAppear { label = account.label }
    }

    private func save() {
        guard !normalized.isEmpty, normalized != account.label else { return }
        saving = true
        Task {
            let renamed = await store.providersModel.rename(accountID: account.id, label: normalized)
            saving = false
            if renamed { dismiss() }
        }
    }
}
