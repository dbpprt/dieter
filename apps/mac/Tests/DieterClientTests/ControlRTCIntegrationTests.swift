import DieterClient
import DieterCore
import DieterAPI
import Foundation
import Testing

/// Opt-in fixture; no saved credentials, operator daemon, or screen capture.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["DIETER_CONTROL_FIXTURE"] != nil))
func controlWebRTCRoutesNativeRPCAndReportsSelectedMode() async throws {
    guard let path = ProcessInfo.processInfo.environment["DIETER_CONTROL_FIXTURE"] else { return }
    let values = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").reduce(
        into: [String: String]()
    ) { result, line in
        let parts = line.split(separator: "=", maxSplits: 1)
        if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
    }
    let address = try #require(values["DIETER_ISOLATED_ADDR"])
    let port = try #require(Int(address.split(separator: ":").last.map(String.init) ?? ""))
    let token = try #require(values["DIETER_ISOLATED_TOKEN"])
    let id = try #require(values["DIETER_ISOLATED_DAEMON"])
    let origin = DieterEndpoint(name: "RTC fixture", host: "127.0.0.1", port: port)
    let target = DieterEndpoint(name: "RTC fixture", host: "127.0.0.1", port: port, daemonID: id)
    let gateway = try DieterRPC(endpoint: origin, accessToken: token)
    let gatewayTask = Task { try await gateway.run() }
    defer { gatewayTask.cancel(); gateway.shutdown() }
    let manager = ConnectionManager()
    let plane = try await manager.selectDataPlane(gateway: gateway, target: target, gatewayAccessToken: token)
    defer { plane.shutdown() }
    #expect(plane.connection.route == .webrtcDirect)
    #expect(!plane.rpc.isLoopbackDataPlane)
    #expect(plane.connection.route.rawValue == "WebRTC · Direct")
    let health = try await plane.rpc.health(timeout: .seconds(5))
    #expect(health.status == "ok")
    var request = Dieter_V1_GetStateRequest(); request.allProjects = true
    let state = try await plane.rpc.service.getState(request: .init(message: request))
    #expect(!state.projects.isEmpty)
    var watch = Dieter_V1_WatchStateRequest(); watch.filter = request
    let observed = try await plane.rpc.service.watchState(request: .init(message: watch)) { response in
        for try await item in response.messages { return !item.projects.isEmpty }
        return false
    }
    #expect(observed)
    var kvList = Dieter_V1_KVListRequest(); kvList.namespace = "navigation"
    let kvInfo = try await plane.rpc.listKV(kvList)
    var kvRef = Dieter_V1_KVRef(); kvRef.namespace = "navigation"; kvRef.key = "projects-folder.native-swift.name";
    kvRef.account = kvInfo.account
    var kvPut = Dieter_V1_KVPutRequest(); kvPut.ref = kvRef; kvPut.valueJson = Data("\"Swift RTC folder\"".utf8)
    kvPut.operationID = UUID().uuidString; kvPut.daemonID = kvInfo.daemonID
    let kvWritten = try await plane.rpc.putKV(kvPut)
    #expect(try await plane.rpc.putKV(kvPut).revision == kvWritten.revision)
    var kvWatch = Dieter_V1_KVWatchRequest(); kvWatch.namespace = "navigation"; kvWatch.account = kvInfo.account
    let kvObserved = try await plane.rpc.service.watchKV(request: .init(message: kvWatch)) { response in
        for try await frame in response.messages {
            if frame.entries.contains(where: { $0.key == "projects-folder.native-swift.name" }) { return true }
        }
        return false
    }
    #expect(kvObserved)
    let suiteA = "native-kv-a-" + UUID().uuidString, suiteB = "native-kv-b-" + UUID().uuidString
    let defaultsA = try #require(UserDefaults(suiteName: suiteA)),
        defaultsB = try #require(UserDefaults(suiteName: suiteB))
    let sharedA = SharedKV(defaults: defaultsA), sharedB = SharedKV(defaults: defaultsB)
    defer {
        sharedA.bind(nil); sharedB.bind(nil); defaultsA.removePersistentDomain(forName: suiteA);
        defaultsB.removePersistentDomain(forName: suiteB)
    }
    sharedA.bind(plane.rpc); sharedB.bind(plane.rpc)
    for _ in 0..<250 {
        if sharedA.account == kvInfo.account && sharedB.account == kvInfo.account { break };
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(sharedA.account == kvInfo.account)
    sharedA.put("projects-folder.native-shared.name", "Native shared navigation")
    sharedA.put("projects-folder.native-shared.expanded", false)
    for _ in 0..<250 {
        if sharedA.pendingCount == 0 && sharedB.values["projects-folder.native-shared.expanded"] == Data("false".utf8) {
            break
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(sharedA.pendingCount == 0)
    #expect(sharedB.values["projects-folder.native-shared.name"] == Data("\"Native shared navigation\"".utf8))
    #expect(sharedB.values["projects-folder.native-shared.expanded"] == Data("false".utf8))
    #expect(try await plane.rpc.health(timeout: .seconds(5)).status == "ok")
    plane.shutdown()
    // Directory reads restrict advertised direct candidates to loopback, but
    // still negotiate WebRTC for remote machines.
    let reconnected = try await manager.selectDataPlane(
        gateway: gateway, target: target, gatewayAccessToken: token, directCandidateScope: .loopbackOnly)
    defer { reconnected.shutdown() }
    #expect(reconnected.connection.route == .webrtcDirect)
    #expect(try await reconnected.rpc.health(timeout: .seconds(5)).status == "ok")
}

@Test func controlRouteLabelsDistinguishTURNFromDirect() {
    #expect(MachineConnectionRoute.webrtcTURN.rawValue == "WebRTC · TURN")
    #expect(MachineConnectionRoute.webrtcDirect.rawValue == "WebRTC · Direct")
    #expect(MachineConnectionRoute.webrtc.rawValue == "WebRTC")
}
