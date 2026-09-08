import DieterAPI
import Testing
@testable import DieterMac

@Test func boardStatusTracksRuntimeRatherThanLane() {
    var card = Dieter_V1_Card()
    card.lane = "running"
    card.runtime = "idle"
    #expect(BoardAgentStatus.resolve(card) == .idle)
    for status in ["running", "starting", "streaming", "working", "cancelling"] {
        card.lane = "done"
        card.runtime = status
        #expect(BoardAgentStatus.resolve(card) == .running)
    }
    for status in ["failed", "error"] {
        card.runtime = status
        #expect(BoardAgentStatus.resolve(card) == .failed)
    }
    for status in ["idle", "completed", "done", "cancelled", ""] {
        card.runtime = status
        #expect(BoardAgentStatus.resolve(card) == .idle)
    }
}

@Test func boardStatusRemainsActiveWhileSubagentRuns() {
    var card = Dieter_V1_Card()
    card.runtime = "failed"
    var worker = Dieter_V1_Subagent()
    worker.status = "running"
    card.activeSubagents = [worker]
    #expect(BoardAgentStatus.resolve(card) == .running)
    card.activeSubagents[0].status = "completed"
    #expect(BoardAgentStatus.resolve(card) == .failed)
}
