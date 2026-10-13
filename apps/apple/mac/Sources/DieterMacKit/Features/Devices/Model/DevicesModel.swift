import DieterClientAPI
import DieterCore
import Foundation
import Observation

/// This device's trust and the account's devices, as the core's devices slice
/// presents them, and the commands that change them. The core rereads waiting
/// devices only while the slice is observed, so a view holds it with
/// `observe()` while shown and lets go with `release()`.
@MainActor @Observable package final class DevicesModel {
    package private(set) var slice = ClientDevicesSlice()
    /// The "Add a device" field: the code shown on the new device, as typed.
    package private(set) var code = ""
    /// A command is on its way to the core.
    package private(set) var working = false
    /// Why the last command failed, as the core words it.
    package var failure: String?

    @ObservationIgnored package var core: CoreClient?
    @ObservationIgnored private var subscription: SliceSubscription?
    @ObservationIgnored private var observers = 0

    package init() {}

    /// Formats what was typed into the code field as a pairing code.
    package func type(_ typed: String) {
        let formatted = SharedRules.shared.pairingCodeInput(typed: typed)
        if code != formatted { code = formatted }
    }

    package var canApprove: Bool { !working && SharedRules.shared.pairingCodeComplete(typed: code) }

    package func observe() {
        observers += 1
        guard subscription == nil, let core else { return }
        subscription = SliceSubscription(
            client: core, slice: .devices, onReset: { [weak self] in self?.slice = ClientDevicesSlice() }
        ) { [weak self] update in
            guard let self, case .devices(let value) = update.value, value != slice else { return }
            slice = value
        }
    }

    package func release() {
        observers = max(0, observers - 1)
        guard observers == 0 else { return }
        subscription?.close()
        subscription = nil
    }

    /// Adds the device that shows the typed code to the account.
    package func approve() async {
        guard canApprove else { return }
        let typed = code
        if await run({ $0.devices = .with { $0.approve = .with { $0.code = typed } } }) { code = "" }
    }

    /// Removes a device from the account.
    package func revoke(_ deviceID: String) async {
        await run { $0.devices = .with { $0.revoke = .with { $0.deviceID = deviceID } } }
    }

    /// Forgets the trusted devices and this device's key; it then asks to join again.
    package func reset() async {
        await run { $0.devices = .with { $0.reset = ClientStep() } }
    }

    package func refresh() async {
        await run { $0.devices = .with { $0.refresh = ClientStep() } }
    }

    @discardableResult
    private func run(_ build: (inout ClientCommand) -> Void) async -> Bool {
        guard let core else { return false }
        var command = ClientCommand()
        build(&command)
        working = true
        failure = nil
        defer { working = false }
        do {
            try await core.dispatch(command)
            return true
        } catch {
            failure = error.localizedDescription
            return false
        }
    }
}

extension ClientDeviceTrust {
    /// The window shows pairing instead of machines: the account has no
    /// roster yet, this device waits for approval, or it lost its trust.
    /// Unknown (still reading the roster) keeps the window as it is.
    package var needsPairing: Bool {
        switch self {
        case .noRoster, .pending, .revoked, .conflict: true
        case .unknown, .trusted, .UNRECOGNIZED: false
        }
    }

    /// Trust is lost until this device resets and pairs again.
    package var needsReset: Bool { self == .revoked || self == .conflict }
}
