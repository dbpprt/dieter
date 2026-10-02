import DieterCore
import Foundation
import Testing

@Test func parsesDieterEndpointWithDefaultPort() {
    let endpoint = DieterEndpoint.parse("board.local", name: "Office")
    #expect(endpoint?.name == "Office")
    #expect(endpoint?.host == "board.local")
    #expect(endpoint?.port == 4242)
}

@Test func parsesDieterEndpointWithExplicitPort() {
    let endpoint = DieterEndpoint.parse("127.0.0.1:50051")
    #expect(endpoint?.address == "http://127.0.0.1:50051")
    #expect(DieterEndpoint.parse("127.0.0.1:70000") == nil)
}

@Test func parsesSecureDieterEndpointWithHTTPSDefaultPort() {
    let endpoint = DieterEndpoint.parse("https://dieter.example", name: "Public")
    #expect(endpoint?.host == "dieter.example")
    #expect(endpoint?.port == 443)
    #expect(endpoint?.secure == true)
    #expect(endpoint?.address == "https://dieter.example:443")
}

@Test func offlineMachineLastSeenTextIsCompact() throws {
    let now = try #require(ISO8601DateFormatter().date(from: "2026-08-18T15:00:00Z"))
    #expect(MachinePresenceText.lastSeen("2026-08-18T14:59:40Z", relativeTo: now) == "Last seen just now")
    #expect(MachinePresenceText.lastSeen("2026-08-18T14:52:00Z", relativeTo: now) == "Last seen 8m ago")
    #expect(MachinePresenceText.lastSeen("2026-08-18T12:00:00Z", relativeTo: now) == "Last seen 3h ago")
    #expect(MachinePresenceText.lastSeen("", relativeTo: now) == "Last seen unknown")
    #expect(MachinePresenceText.isFresh("2026-08-18T14:59:31Z", relativeTo: now))
    #expect(!MachinePresenceText.isFresh("2026-08-18T14:59:30Z", relativeTo: now))
    #expect(MachinePresenceText.online(serverOnline: true, lastSeenAt: "", relativeTo: now))
    #expect(!MachinePresenceText.online(serverOnline: false, lastSeenAt: "2026-08-18T14:59:59Z", relativeTo: now))
}
