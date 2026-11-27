import DieterClientAPI
import DieterCore
import DieterPlatform
import Foundation
import Observation

/// The account's Claude and ChatGPT accounts, their sign-ins on each machine
/// and their usage, as the core's providers slice presents them, and the
/// commands that change them. The slice is account-wide and works from the
/// account replica; views hold it with `observe()` while shown and let go
/// with `release()`.
@MainActor @Observable package final class ProvidersModel {
    package private(set) var slice = ClientProvidersSlice()
    /// Commands on their way to the core.
    package private(set) var pending = 0
    /// Why the last command failed, as the core words it.
    package var failure: String?
    /// The sign-in session the app-wide sign-in sheet shows; nil while none.
    package var presentedSessionID: String?

    @ObservationIgnored package var core: CoreClient?
    @ObservationIgnored private var subscription: SliceSubscription?
    @ObservationIgnored private var observers = 0
    /// A rendering fixture installed the slice; the core's does not replace it.
    @ObservationIgnored private var installed = false
    /// How long a new account may take to reach this device's replica before
    /// its first sign-in starts.
    @ObservationIgnored package var arrivalTimeout: Duration = .seconds(30)

    package init() {}

    package var working: Bool { pending > 0 }
    package var groups: [ClientProviderGroupRow] { slice.groups }
    package var summary: ClientProviderSummary { slice.summary }
    package var sessions: [ClientProviderSignInSession] { slice.sessions }
    /// The last command's failure, else the slice's.
    package var problem: String? { failure ?? (slice.error.isEmpty ? nil : slice.error) }
    package var hasAccounts: Bool { slice.groups.contains { !$0.accounts.isEmpty } }

    package func account(_ id: String) -> ClientProviderAccountRow? {
        for group in slice.groups {
            if let row = group.accounts.first(where: { $0.id == id }) { return row }
        }
        return nil
    }

    package func session(_ id: String?) -> ClientProviderSignInSession? {
        guard let id, !id.isEmpty else { return nil }
        return slice.sessions.first { $0.id == id }
    }

    /// The account allows one change at a time; its controls wait meanwhile.
    package func isMutating(_ accountID: String) -> Bool { slice.mutating.contains(accountID) }

    package func observe() {
        observers += 1
        guard subscription == nil, !installed, let core else { return }
        subscription = SliceSubscription(
            client: core, slice: .providers, onReset: { [weak self] in self?.slice = ClientProvidersSlice() }
        ) { [weak self] update in
            guard let self, !installed, case .providers(let value) = update.value, value != slice else { return }
            slice = value
        }
    }

    package func release() {
        observers = max(0, observers - 1)
        guard observers == 0 else { return }
        subscription?.close()
        subscription = nil
    }

    /// Shows a fixed slice the core does not provide, e.g. in rendering tests.
    package func install(_ value: ClientProvidersSlice) {
        installed = true
        subscription?.close()
        subscription = nil
        slice = value
    }

    // MARK: Account-wide changes

    /// Adds an account; returns its ID, which the core generates.
    @discardableResult
    package func create(provider: String, label: String, method: String = "") async -> String? {
        let result = await run {
            $0.create = .with {
                $0.provider = provider
                $0.label = label
                $0.method = method
            }
        }
        guard let id = result?.providerAccount.accountID, !id.isEmpty else { return nil }
        return id
    }

    /// Adds an account and starts its first sign-in on `daemonID` once the
    /// account reached this device's replica, which a sign-in needs. The
    /// account stays when the sign-in cannot start; its row offers it again.
    package func add(provider: String, label: String, method: String, daemonID: String) async -> AddedAccount? {
        guard let accountID = await create(provider: provider, label: label, method: method) else { return nil }
        guard !daemonID.isEmpty else { return AddedAccount(accountID: accountID, sessionID: nil) }
        guard await arrival(of: accountID) else {
            failure = "\(label) was added. Sign it in from its row once it appears."
            return AddedAccount(accountID: accountID, sessionID: nil)
        }
        return AddedAccount(accountID: accountID, sessionID: await signIn(accountID: accountID, daemonID: daemonID))
    }

    package struct AddedAccount: Equatable {
        package let accountID: String
        package let sessionID: String?
    }

    /// Waits while the slice lacks `accountID`, up to `arrivalTimeout`.
    private func arrival(of accountID: String) async -> Bool {
        observe()
        defer { release() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: arrivalTimeout)
        while account(accountID) == nil {
            guard clock.now < deadline else { return false }
            do { try await DieterTaskSleep.milliseconds(100) } catch { return false }
        }
        return true
    }

    @discardableResult
    package func rename(accountID: String, label: String) async -> Bool {
        await run {
            $0.rename = .with {
                $0.accountID = accountID
                $0.label = label
            }
        } != nil
    }

    /// Every machine signs the account out and deletes its files.
    @discardableResult
    package func remove(accountID: String) async -> Bool {
        await run { $0.remove = .with { $0.accountID = accountID } } != nil
    }

    package func setDefault(accountID: String) async {
        await run { $0.setDefault = .with { $0.accountID = accountID } }
    }

    package func setIncluded(accountID: String, included: Bool) async {
        await run {
            $0.setIncluded = .with {
                $0.accountID = accountID
                $0.included = included
            }
        }
    }

    /// Lets Oh My Pi use a Claude login, once the user confirmed the core's
    /// warning; or stops it.
    package func setOmpAccess(accountID: String, allowed: Bool) async {
        await run {
            $0.setOmpAccess = .with {
                $0.accountID = accountID
                $0.allowed = allowed
            }
        }
    }

    package func refreshUsage(accountID: String) async {
        await run { $0.refreshUsage = .with { $0.accountID = accountID } }
    }

    /// Spends a ChatGPT reset credit; returns the outcome as the core words it.
    package func consumeReset(accountID: String) async -> ClientProviderResetOutcome? {
        await run { $0.consumeReset = .with { $0.accountID = accountID } }?.providerReset
    }

    // MARK: Machine actions

    package func signOut(accountID: String, daemonID: String) async {
        await run {
            $0.signOut = .with {
                $0.accountID = accountID
                $0.daemonID = daemonID
            }
        }
    }

    package func check(accountID: String, daemonID: String) async {
        await run {
            $0.check = .with {
                $0.accountID = accountID
                $0.daemonID = daemonID
            }
        }
    }

    // MARK: Sign-in sessions

    /// Starts signing the account in on a machine; returns the session ID.
    package func signIn(accountID: String, daemonID: String, flow: String = "") async -> String? {
        let result = await run {
            $0.signIn = .with {
                $0.accountID = accountID
                $0.daemonID = daemonID
                $0.flow = flow
            }
        }
        guard let id = result?.providerSignIn.sessionID, !id.isEmpty else { return nil }
        return id
    }

    /// Starts one session that signs the account in on every online machine
    /// that lacks a sign-in; returns its ID.
    package func signInAll(accountID: String) async -> String? {
        let result = await run { $0.signInAll = .with { $0.accountID = accountID } }
        guard let id = result?.providerSignIn.sessionID, !id.isEmpty else { return nil }
        return id
    }

    /// Signs in and shows the session in the app-wide sign-in sheet.
    package func presentSignIn(accountID: String, daemonID: String) async {
        if let id = await signIn(accountID: accountID, daemonID: daemonID) { present(id) }
    }

    package func presentSignInAll(accountID: String) async {
        if let id = await signInAll(accountID: accountID) { present(id) }
    }

    /// Shows `sessionID` in the sign-in sheet, dropping the one it showed.
    package func present(_ sessionID: String) {
        if let shown = presentedSessionID, shown != sessionID { Task { await dismiss(sessionID: shown) } }
        presentedSessionID = sessionID
    }

    package func submit(sessionID: String, code: String) async {
        await run {
            $0.submit = .with {
                $0.sessionID = sessionID
                $0.code = code
            }
        }
    }

    package func submit(sessionID: String, callbackURL: String) async {
        await run {
            $0.submit = .with {
                $0.sessionID = sessionID
                $0.callbackURL = callbackURL
            }
        }
    }

    package func cancel(sessionID: String) async {
        await run { $0.cancel = .with { $0.sessionID = sessionID } }
    }

    /// Drops a session from the slice; the core cancels a live one first.
    /// A sheet closes this way, so a session it already dropped is no failure.
    package func dismiss(sessionID: String) async {
        guard let core else { return }
        let command = ClientProvidersCommand.with { $0.dismiss = .with { $0.sessionID = sessionID } }
        _ = try? await core.dispatch { $0.providers = command }
    }

    /// The app-wide sheet showing `sessionID` closed.
    package func close(sessionID: String) async {
        if presentedSessionID == sessionID { presentedSessionID = nil }
        await dismiss(sessionID: sessionID)
    }

    @discardableResult
    private func run(_ build: (inout ClientProvidersCommand) -> Void) async -> ClientResult? {
        guard let core else { return nil }
        var command = ClientProvidersCommand()
        build(&command)
        let sent = command
        pending += 1
        failure = nil
        defer { pending -= 1 }
        do {
            return try await core.dispatch { $0.providers = sent }
        } catch {
            failure = error.localizedDescription
            return nil
        }
    }
}

extension ClientProviderSignInSession {
    /// The session still waits on the machine or the user.
    package var isLive: Bool { !["succeeded", "failed", "canceled"].contains(phase) }

    /// The page to open on this device: the loopback variant when this device
    /// is the signing machine, since it completes the sign-in by itself.
    package var pageURL: URL? {
        let address = sameHost && !localURL.isEmpty ? localURL : openURL
        guard !address.isEmpty else { return nil }
        return URL(string: address)
    }

    /// The sheet asks for a pasted code or browser address only while the
    /// machine waits for it.
    package var acceptsInput: Bool { phase == "waiting" }
}
