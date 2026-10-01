import DieterCore
import Foundation
import Testing
@testable import DieterMac

/// The shared core relocates the old public gateway when it imports the Mac's
/// saved endpoints (`Gateway.currentPublicGateway`, covered by its legacy
/// import tests). The Swift rule the iOS app still uses must agree.
@Test func onlyTheOldPublicGatewayIsRelocated() {
    let old = DieterEndpoint(name: "Dieter Gateway", host: "board.dbpprt.com", port: 443, secure: true)
    #expect(old.currentPublicGateway.host == "gateway.getdieter.com")
    #expect(old.currentPublicGateway.credentialID == DieterEndpoint.defaults[0].credentialID)
    let custom = DieterEndpoint(name: "Custom", host: "private.example", port: 443, secure: true)
    #expect(custom.currentPublicGateway == custom)
    var differentPort = old
    differentPort.port = 8443
    #expect(differentPort.currentPublicGateway == differentPort)
    var insecure = old
    insecure.secure = false
    #expect(insecure.currentPublicGateway == insecure)
}
