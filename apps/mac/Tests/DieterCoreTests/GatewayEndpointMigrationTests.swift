import DieterCore
import Foundation
import Testing

/// iOS relocates a saved gateway only when it is the old public one.
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
