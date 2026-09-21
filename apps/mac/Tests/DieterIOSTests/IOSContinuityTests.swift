import DieterAPI
import Testing
@testable import DieterIOS

@Suite("iOS directory continuity")
struct IOSContinuityTests {
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
}
