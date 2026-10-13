import DieterClientAPI
import Testing

@testable import DieterMacKit

/// The Devices view model over a scripted core: the slice is observed only
/// while shown, the code field formats as the core's rule says, and commands
/// carry exactly what the user typed or chose.
@MainActor
struct DevicesModelTests {
    @Test func theDevicesSliceIsObservedOnlyWhileAViewShowsIt() {
        let core = ScriptedCoreClient()
        let model = DevicesModel()
        model.core = core
        model.observe()
        model.observe()
        #expect(core.isObserved(.devices))
        core.emit(.devices) {
            $0.devices = .with {
                $0.trust = .trusted
                $0.title = "This device is trusted"
                $0.devices = [
                    .with {
                        $0.name = "Studio"; $0.revocable = true
                    }
                ]
            }
        }
        #expect(model.slice.title == "This device is trusted" && model.slice.devices.map(\.name) == ["Studio"])
        model.release()
        #expect(core.isObserved(.devices), "another view still shows it")
        model.release()
        #expect(!core.isObserved(.devices))
    }

    @Test func theCodeFieldFormatsAndApprovesTheTypedCode() async {
        let core = ScriptedCoreClient()
        let model = DevicesModel()
        model.core = core
        model.type("abcdefgh")
        #expect(model.code == "ABCD-EFGH")
        #expect(!model.canApprove)
        model.type("abcd efgh jkmn pqrs tuvw")
        #expect(model.code == "ABCD-EFGH-JKMN-PQRS")
        #expect(model.canApprove)
        await model.approve()
        #expect(core.commands.last?.devices.approve.code == "ABCD-EFGH-JKMN-PQRS")
        #expect(model.code.isEmpty && model.failure == nil)

        core.handler = { _ in throw CoreFailure(kind: .invalid, message: "No device is waiting with this code.") }
        model.type("ABCD-EFGH-JKMN-PQRS")
        await model.approve()
        #expect(model.failure == "No device is waiting with this code.")
        #expect(model.code == "ABCD-EFGH-JKMN-PQRS", "a failed approval keeps the code to correct it")
    }

    @Test func removalAndResetReachTheCore() async {
        let core = ScriptedCoreClient()
        let model = DevicesModel()
        model.core = core
        await model.revoke("dv_pixel")
        #expect(core.commands.last?.devices.revoke.deviceID == "dv_pixel")
        await model.reset()
        if case .reset = core.commands.last?.devices.action {} else { Issue.record("expected a reset") }
    }

    @Test func pairingTakesTheWindowOnlyWhileTrustIsMissing() {
        #expect(ClientDeviceTrust.pending.needsPairing && ClientDeviceTrust.noRoster.needsPairing)
        #expect(ClientDeviceTrust.revoked.needsPairing && ClientDeviceTrust.conflict.needsPairing)
        #expect(!ClientDeviceTrust.unknown.needsPairing && !ClientDeviceTrust.trusted.needsPairing)
        #expect(ClientDeviceTrust.revoked.needsReset && ClientDeviceTrust.conflict.needsReset)
        #expect(!ClientDeviceTrust.pending.needsReset)
    }
}
