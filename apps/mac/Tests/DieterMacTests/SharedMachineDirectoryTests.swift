import DieterAPI
import DieterCore
import Testing
@testable import DieterMac

@Test func sharedCardRefreshRetainsOwnerDetailsInEitherArrivalOrder() {
    let owner = DieterEndpoint(name: "Owner", host: "test", port: 443, daemonID: "owner")
    let peer = DieterEndpoint(name: "Peer", host: "test", port: 443, daemonID: "peer")
    var project = Dieter_V1_Project(); project.id = "project"
    var full = Dieter_V1_Card()
    full.id = "card"; full.projectID = project.id; full.ownerDaemonID = "owner"
    full.boardID = "board"; full.lane = "running"; full.title = "Original"
    full.summary = "A three-line summary whose disappearance changes the height of the card"
    full.initialPrompt = "The full request"; full.updatedAt = "2026-09-23T09:00:00Z"
    full.workspaceMode = "worktree"; full.workspaceBranch = "feature"
    full.providerOptions = ["fast_mode": "true"]; full.tokenUsage.totalTokens = 123
    full.activeSubagents = [Dieter_V1_Subagent()]
    var replicated = full
    replicated.summary = ""; replicated.initialPrompt = ""; replicated.updatedAt = ""
    replicated.workspaceMode = ""; replicated.workspaceBranch = ""; replicated.providerOptions = [:]
    replicated.clearTokenUsage(); replicated.activeSubagents = []
    let status = MachineConnectionStatus(route: .gateway, latencyMilliseconds: 1)
    func snapshot(_ endpoint: DieterEndpoint, _ card: Dieter_V1_Card) -> MachineSnapshot {
        MachineSnapshot(
            endpoint: endpoint, connection: status, projects: [project], boards: [], cards: [card], chats: [])
    }
    let empty = MachineDirectoryProjection(
        projects: [:], projectReplicaEndpointIDs: [:], boards: [:], cards: [:], chats: [])
    for snapshots in [
        [snapshot(owner, full), snapshot(peer, replicated)], [snapshot(peer, replicated), snapshot(owner, full)],
    ] {
        var current = MachineDirectoryReducer.merging(empty, snapshots: snapshots)
        #expect(current.cards[project.id] == [full])
        for _ in 0..<3 {
            current = MachineDirectoryReducer.merging(current, snapshots: [snapshot(peer, replicated)])
            #expect(current.cards[project.id] == [full])
            current = MachineDirectoryReducer.merging(current, snapshots: [snapshot(owner, full)])
            #expect(current.cards[project.id] == [full])
        }
        // Shared edits from another machine still win, without deleting the
        // execution owner's details or relying on incomparable client clocks.
        var edited = replicated
        edited.title = "Renamed remotely"; edited.lane = "review"; edited.labelIds = ["label"]
        edited.responseSeq = 30; edited.responseMessageID = "reply"; edited.seenResponseSeq = 30
        current = MachineDirectoryReducer.merging(current, snapshots: [snapshot(peer, edited)])
        #expect(current.cards[project.id]?.first?.summary == full.summary)
        #expect(current.cards[project.id]?.first?.title == edited.title)
        #expect(current.cards[project.id]?.first?.lane == edited.lane)
        #expect(current.cards[project.id]?.first?.labelIds == edited.labelIds)
        #expect(current.cards[project.id]?.first?.responseSeq == 30)
        #expect(current.cards[project.id]?.first?.responseMessageID == "reply")
        #expect(current.cards[project.id]?.first?.seenResponseSeq == 30)
        // Empty fields from the owner are authoritative, not missing data.
        current = MachineDirectoryReducer.merging(current, snapshots: [snapshot(owner, edited)])
        #expect(current.cards[project.id] == [edited])
    }
}

@Test func sharedProjectCatalogUnionsOwnersAndPreservesCheckoutPaths() {
    let a = DieterEndpoint(name: "A", host: "test", port: 443, daemonID: "a")
    let b = DieterEndpoint(name: "B", host: "test", port: 443, daemonID: "b")
    var ca = Dieter_V1_Checkout(); ca.id = "ca"; ca.daemonID = "a"; ca.path = "/a/repo"
    var cb = Dieter_V1_Checkout(); cb.id = "cb"; cb.daemonID = "b"; cb.path = "/b/repo"
    var pa = Dieter_V1_Project(); pa.id = "project"; pa.checkouts = [ca]
    var pb = pa; pb.checkouts = [cb]
    var ia = Dieter_V1_Card(); ia.id = "ia"; ia.projectID = pa.id; ia.ownerDaemonID = "a"
    var ib = ia; ib.id = "ib"; ib.ownerDaemonID = "b"
    let initial = MachineDirectoryProjection(
        projects: [:], projectReplicaEndpointIDs: [:], boards: [:], cards: [:], chats: [])
    let status = MachineConnectionStatus(route: .gateway, latencyMilliseconds: 1)
    let next = MachineDirectoryReducer.merging(
        initial,
        snapshots: [
            MachineSnapshot(endpoint: a, connection: status, projects: [pa], boards: [], cards: [ia], chats: []),
            MachineSnapshot(endpoint: b, connection: status, projects: [pb], boards: [], cards: [ib], chats: []),
        ])
    #expect(next.projects.count == 1)
    #expect(Set(next.projects[pa.id]?.checkouts.map(\.id) ?? []) == ["ca", "cb"])
    #expect(Set(next.cards[pa.id]?.map(\.id) ?? []) == ["ia", "ib"])
    // B may retire its own item, while A is offline and still represented.
    let archived = MachineDirectoryReducer.merging(
        next,
        snapshots: [MachineSnapshot(endpoint: b, connection: status, projects: [pb], boards: [], cards: [], chats: [])])
    #expect(archived.cards[pa.id]?.map(\.id) == ["ia"])
    #expect(archived.projects[pa.id]?.checkouts.first { $0.id == "ca" }?.path == "/a/repo")
}

@Test func sharedArchiveFromReplicaRemovesOfflineOwnersCachedItem() {
    let a = DieterEndpoint(name: "A", host: "test", port: 443, daemonID: "a")
    let b = DieterEndpoint(name: "B", host: "test", port: 443, daemonID: "b")
    var project = Dieter_V1_Project(); project.id = "project"; project.updatedAt = "2099"
    var item = Dieter_V1_Card(); item.id = "item"; item.projectID = project.id; item.ownerDaemonID = "a"
    let initial = MachineDirectoryProjection(
        projects: [project.id: project], projectReplicaEndpointIDs: [project.id: a.id], boards: [:],
        cards: [project.id: [item]], chats: [])
    var archives = Dieter_V1_SharedArchives(); archives.itemIds = [item.id]
    var resolved = project; resolved.name = "Resolved"; resolved.updatedAt = "2026"
    let next = MachineDirectoryReducer.merging(
        initial,
        snapshots: [
            MachineSnapshot(
                endpoint: b, connection: .init(route: .gateway, latencyMilliseconds: 0), projects: [resolved],
                boards: [], cards: [], chats: [], archives: archives)
        ])
    #expect(next.cards[project.id]?.isEmpty != false)
    #expect(next.projects[project.id]?.name == "Resolved")
    archives.projectIds = [project.id]
    let archived = MachineDirectoryReducer.merging(
        next,
        snapshots: [
            MachineSnapshot(
                endpoint: b, connection: .init(route: .gateway, latencyMilliseconds: 0), projects: [], boards: [],
                cards: [], chats: [], archives: archives)
        ])
    #expect(archived.projects.isEmpty)
}
