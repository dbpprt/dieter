import DieterAPI
import DieterCore
import Testing
@testable import DieterMac

private func stateCard(lane: String, runtime: String, placement: UInt64, summary: UInt64) -> Dieter_V1_Card {
    var card = Dieter_V1_Card()
    card.id = "card"; card.ownerDaemonID = "owner"; card.projectID = "project"
    card.boardID = "board"; card.lane = lane; card.runtime = runtime; card.orderKey = "key-\(placement)"
    card.placementRevision = "placement-\(placement)"
    card.runtimeUpdatedAt = "time-\(summary)"
    for (name, count) in [("placement", placement), ("summary", summary)] {
        var value = Dieter_V1_Card()
        if name == "placement" {
            value.boardID = card.boardID; value.lane = lane; value.orderKey = card.orderKey
        } else {
            value.runtime = runtime; value.runtimeUpdatedAt = card.runtimeUpdatedAt; value.responseSeq = Int64(summary);
            value.seenResponseSeq = Int64(summary)
        }
        var version = Dieter_V1_CardStateVersion()
        version.clock = ["owner": count]; version.rank = "\(count)"; version.value = value
        var field = Dieter_V1_CardStateField()
        field.name = name; field.revision = "\(name)-\(count)"; field.versions = [version]
        card.stateFields.append(field)
    }
    return card
}

@Test func delayedReplicasCannotReopenFinishedCardsOrRestoreOldRuntime() {
    let running = stateCard(lane: "running", runtime: "running", placement: 1, summary: 1)
    let review = stateCard(lane: "review", runtime: "idle", placement: 2, summary: 2)
    let done = stateCard(lane: "done", runtime: "idle", placement: 3, summary: 3)
    for sequence in [
        [running, review, done, running, review], [done, review, running, done], [review, running, done],
    ] {
        let final = sequence.dropFirst().reduce(sequence[0]) { CardStateProjection.merge($1, with: $0) }
        #expect(final.lane == "done")
        #expect(final.runtime == "idle")
        #expect(final.seenResponseSeq == 3)
        #expect(final.placementRevision == done.placementRevision)
    }
    // A new placement must not carry an old runtime back into the UI.
    let mixed = stateCard(lane: "done", runtime: "running", placement: 3, summary: 1)
    let merged = CardStateProjection.merge(mixed, with: review)
    #expect(merged.lane == "done" && merged.runtime == "idle")
}

@Test func concurrentPlacementsJoinWithoutLosingAnUnselectedBranch() {
    let original = stateCard(lane: "todo", runtime: "idle", placement: 1, summary: 1)
    var a = stateCard(lane: "review", runtime: "idle", placement: 2, summary: 1)
    var b = stateCard(lane: "done", runtime: "idle", placement: 2, summary: 1)
    a.stateFields[0].versions[0].clock = ["owner": 1, "a": 1]
    a.stateFields[0].versions[0].rank = "a"
    b.stateFields[0].versions[0].clock = ["owner": 1, "b": 1]
    b.stateFields[0].versions[0].rank = "b"
    let ab = CardStateProjection.merge(b, with: a)
    let ba = CardStateProjection.merge(a, with: b)
    #expect(ab.stateFields == ba.stateFields)
    #expect(ab.lane == "done" && ab.placementRevision == "unobserved-join")
    #expect(CardStateProjection.merge(original, with: ab).lane == "done")
    var joinedReceipt = ab
    joinedReceipt.stateFields[0].revision = "daemon-join"
    #expect(CardStateProjection.merge(joinedReceipt, with: ab).placementRevision == "daemon-join")
    var resolved = a
    resolved.stateFields[0].versions[0].clock = ["owner": 1, "a": 2, "b": 1]
    resolved.stateFields[0].revision = "resolved"
    var current = CardStateProjection.merge(resolved, with: ab)
    for stale in [b, a, original, ab] { current = CardStateProjection.merge(stale, with: current) }
    #expect(current.lane == "review" && current.placementRevision == "resolved")
}

@Test @MainActor func finishReceiptSurvivesBackgroundAndActiveReplicaSnapshots() {
    let store = DieterStore(restoreSync: false)
    var project = Dieter_V1_Project(); project.id = "project"
    var board = Dieter_V1_Board(); board.id = "board"; board.projectID = project.id
    var state = Dieter_V1_State(); state.projects = [project]; state.project = project; state.boards = [board]
    let running = stateCard(lane: "running", runtime: "running", placement: 1, summary: 1)
    let done = stateCard(lane: "done", runtime: "idle", placement: 2, summary: 2)
    state.cards = [running]
    store.endpoint = DieterEndpoint(name: "Owner", host: "test", port: 443, daemonID: "owner")
    store.acceptState(state)
    store.acceptWorkspaceCard(done)
    // RPC replies and rollback paths can also arrive late from the owner.
    store.acceptWorkspaceCard(running, sourceDaemonID: "owner")
    #expect(store.boardCards.first?.lane == "done")
    #expect(store.boardCards.first?.runtime == "idle")
    for _ in 0..<3 {
        var snapshot = Dieter_V1_GlobalSnapshot(); snapshot.state = state
        store.applyGlobalSnapshot(snapshot, endpointID: "account#peer")
        store.acceptState(state)
        #expect(store.boardCards.first?.lane == "done")
        #expect(store.boardCards.first?.runtime == "idle")
    }
}

@Test func newerPeerCompletionDoesNotRetainOldSubagentRunningBadge() {
    var running = stateCard(lane: "running", runtime: "running", placement: 1, summary: 1)
    var worker = Dieter_V1_Subagent(); worker.status = "running"; running.activeSubagents = [worker]
    let done = stateCard(lane: "done", runtime: "idle", placement: 2, summary: 2)
    let merged = MachineDirectoryReducer.retainingOwnerDetails(done, from: running, sourceDaemonID: "peer")
    #expect(merged.runtime == "idle")
    #expect(merged.activeSubagents.isEmpty)
    #expect(BoardAgentStatus.resolve(merged) == .idle)
}

@Test @MainActor func causalMetadataDoesNotEraseAnOptimisticStart() {
    let store = DieterStore(restoreSync: false)
    let original = stateCard(lane: "todo", runtime: "idle", placement: 1, summary: 1)
    store.state.cards = [original]
    store.navigationCards = [original.projectID: [original]]
    let start = OptimisticCardStart(operationID: .init(), runningLaneID: "running")
    store.pendingCardStarts[original.id] = start
    store.applyBoardCardMutation(start.applying(to: original))
    #expect(store.state.cards.first?.lane == "running")
    #expect(store.state.cards.first?.runtime == "starting")
    #expect(store.pendingCardStarts[original.id] == start)
}

@Test func transcriptMetadataCannotUndoAPlacementReceipt() {
    var current = Dieter_V1_ConversationSnapshot()
    current.detail.card = stateCard(lane: "done", runtime: "idle", placement: 2, summary: 2)
    current.conversation.lastSeq = 20
    var incoming = current
    incoming.detail.card = stateCard(lane: "review", runtime: "running", placement: 1, summary: 1)
    incoming.conversation.lastSeq = 21
    let next = TranscriptFreshness.merging(incoming, with: current)
    #expect(next.detail.card.lane == "done" && next.detail.card.runtime == "idle")
    #expect(next.conversation.lastSeq == 21)
}
