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
