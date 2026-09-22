import DieterCore
import Foundation
import Testing
@testable import DieterMac

@Test @MainActor func gatewayEndpointMigrationPersistsSelectionAndPreservesCustomOrigins() throws {
    let suite = "dieter-gateway-relocation-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let old = DieterEndpoint(name: "Dieter Gateway", host: "board.dbpprt.com", port: 443, secure: true)
    let custom = DieterEndpoint(name: "Custom", host: "private.example", port: 443, secure: true)
    var machine = old
    machine.daemonID = "enrolled-machine"
    defaults.set(try JSONEncoder().encode([old, DieterEndpoint.defaults[0], custom]), forKey: "DieterEndpoints")
    defaults.set(try JSONEncoder().encode(machine), forKey: "DieterActiveEndpoint")
    let environment = DieterAppEnvironment.testing(defaults: defaults)
    defer { if let root = environment.storageRoot { try? FileManager.default.removeItem(at: root) } }
    let store = DieterStore(environment: environment, restoreSync: false)
    #expect(store.gatewayOrigins == [DieterEndpoint.defaults[0], custom])
    #expect(store.endpoint.daemonID == machine.daemonID)
    #expect(store.endpoint.credentialID != old.credentialID)
    #expect(store.endpoint.host == "gateway.getdieter.com")
    let restored = DieterStore(environment: environment, restoreSync: false)
    #expect(restored.endpoint == store.endpoint)
    #expect(restored.gatewayOrigins == store.gatewayOrigins)
    var differentPort = old
    differentPort.port = 8443
    #expect(differentPort.currentPublicGateway == differentPort)
    var insecure = old
    insecure.secure = false
    #expect(insecure.currentPublicGateway == insecure)
}
