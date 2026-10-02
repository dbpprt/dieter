import DieterAPI
import Foundation
import Testing
@testable import DieterCore

@Test func providerOptionsValidateEnumsAndBooleansWithoutDroppingUnknownOptionTypes() {
    var harness = Dieter_V1_Harness(); harness.id = "provider"
    var choice = Dieter_V1_ProviderOption(); choice.id = "mode"; choice.type = "enum"; choice.defaultValue = "safe"
    var safe = Dieter_V1_ProviderOptionChoice(); safe.value = "safe"; choice.choices = [safe]
    var boolean = Dieter_V1_ProviderOption(); boolean.id = "enabled"; boolean.type = "boolean";
    boolean.defaultValue = "false"
    var text = Dieter_V1_ProviderOption(); text.id = "future"; text.type = "future-type"
    harness.options = [choice, boolean, text]
    #expect(
        ProviderOptionValues.resolved(
            for: harness, existing: ["mode": "invalid", "enabled": "TRUE", "future": "retained", "obsolete": "drop"])
            == ["mode": "safe", "enabled": "true", "future": "retained"])
}

@Test func controlRouteLabelsDistinguishTURNFromDirect() {
    #expect(MachineConnectionRoute.webrtcTURN.rawValue == "WebRTC · TURN")
    #expect(MachineConnectionRoute.webrtcDirect.rawValue == "WebRTC · Direct")
    #expect(MachineConnectionRoute.webrtc.rawValue == "WebRTC")
}
