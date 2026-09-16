import DieterAPI
import DieterCore
import Testing
@testable import DieterIOS

@Suite("iOS reconnect continuity")
struct IOSContinuityTests {
    @Test func reconnectRetainsSameNodeDespitePresenceAndDisplayChanges() {
        let previous = origin()
        var refreshed = previous
        refreshed.name = "Renamed gateway"
        refreshed.online = false
        #expect(
            IOSWorkspaceContinuity.canRetainSnapshot(
                currentOrigin: previous, currentDaemonID: "daemon-a",
                requestedOrigin: refreshed, requestedDaemonID: "daemon-a"))
    }

    @Test func nodeFallbackAndGatewayChangesCannotDisplayAnotherScopeSnapshot() {
        let previous = origin()
        #expect(
            !IOSWorkspaceContinuity.canRetainSnapshot(
                currentOrigin: previous, currentDaemonID: "daemon-a",
                requestedOrigin: previous, requestedDaemonID: "daemon-b"))
        #expect(
            !IOSWorkspaceContinuity.canRetainSnapshot(
                currentOrigin: previous, currentDaemonID: "daemon-a",
                requestedOrigin: origin(host: "other.example"), requestedDaemonID: "daemon-a"))
        #expect(
            !IOSWorkspaceContinuity.canRetainSnapshot(
                currentOrigin: previous, currentDaemonID: "daemon-a",
                requestedOrigin: origin(port: 8443), requestedDaemonID: "daemon-a"))
        #expect(
            !IOSWorkspaceContinuity.canRetainSnapshot(
                currentOrigin: previous, currentDaemonID: "daemon-a",
                requestedOrigin: nil, requestedDaemonID: "daemon-a"))
        #expect(
            !IOSWorkspaceContinuity.canRetainSnapshot(
                currentOrigin: nil, currentDaemonID: nil,
                requestedOrigin: previous, requestedDaemonID: "daemon-a"))
    }

    @Test func offlineDirectoryKeepsSelectedNodeButRemovalAndIncompatibilityRetireIt() {
        var offline = origin()
        offline.daemonID = "daemon-a"
        offline.online = false
        offline.apiVersion = IOSMachinePolicy.apiVersion
        var other = offline
        other.daemonID = "daemon-b"
        #expect(
            IOSWorkspaceContinuity.retainedOfflineSelection(in: [other, offline], previousDaemonID: "daemon-a")
                == "daemon-a")
        #expect(IOSWorkspaceContinuity.retainedOfflineSelection(in: [other], previousDaemonID: "daemon-a") == nil)
        offline.apiVersion = "2"
        #expect(IOSWorkspaceContinuity.retainedOfflineSelection(in: [offline], previousDaemonID: "daemon-a") == nil)
        #expect(IOSWorkspaceContinuity.retainedOfflineSelection(in: [other], previousDaemonID: nil) == nil)
    }

    @Test func creationReplyAfterWatchStateKeepsNewerCardAndUniqueIdentity() {
        var reply = Dieter_V1_Card()
        reply.id = "created-card"
        reply.title = "Initial title"
        reply.runtime = "starting"
        var streamed = reply
        streamed.title = "Generated short title"
        streamed.runtime = "idle"
        var other = Dieter_V1_Card()
        other.id = "other-card"
        let current = [other, streamed]
        let reconciled = IOSWorkspaceContinuity.admittingCreatedCard(reply, into: current)
        #expect(reconciled == current)
        #expect(reconciled.filter { $0.id == reply.id }.count == 1)
        #expect(reconciled.last?.title == "Generated short title")

        let aheadOfStream = IOSWorkspaceContinuity.admittingCreatedCard(reply, into: [other])
        #expect(aheadOfStream.map(\.id) == ["created-card", "other-card"])
    }

    private func origin(host: String = "gateway.example", port: Int = 443) -> DieterEndpoint {
        .init(name: "Gateway", host: host, port: port, secure: true)
    }
}
