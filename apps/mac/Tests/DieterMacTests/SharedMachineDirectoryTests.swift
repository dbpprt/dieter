import DieterAPI
import DieterCore
import Testing
@testable import DieterMac

@Test func sharedProjectCatalogUnionsOwnersAndPreservesCheckoutPaths() {
    let a = DieterEndpoint(name: "A", host: "test", port: 443, daemonID: "a")
    let b = DieterEndpoint(name: "B", host: "test", port: 443, daemonID: "b")
    var ca = Dieter_V1_Checkout(); ca.id = "ca"; ca.daemonID = "a"; ca.path = "/a/repo"
    var cb = Dieter_V1_Checkout(); cb.id = "cb"; cb.daemonID = "b"; cb.path = "/b/repo"
    var pa = Dieter_V1_Project(); pa.id = "project"; pa.checkouts = [ca]
    var pb = pa; pb.checkouts = [cb]
    var ia = Dieter_V1_Card(); ia.id = "ia"; ia.projectID = pa.id; ia.ownerDaemonID = "a"
    var ib = ia; ib.id = "ib"; ib.ownerDaemonID = "b"
    let initial = MachineDirectoryProjection(projects: [:], projectReplicaEndpointIDs: [:], boards: [:], cards: [:], chats: [])
    let status = MachineConnectionStatus(route: .gateway, latencyMilliseconds: 1)
    let next = MachineDirectoryReducer.merging(initial, snapshots: [
        MachineSnapshot(endpoint: a, connection: status, projects: [pa], boards: [], cards: [ia], chats: []),
        MachineSnapshot(endpoint: b, connection: status, projects: [pb], boards: [], cards: [ib], chats: [])])
    #expect(next.projects.count == 1)
    #expect(Set(next.projects[pa.id]?.checkouts.map(\.id) ?? []) == ["ca", "cb"])
    #expect(Set(next.cards[pa.id]?.map(\.id) ?? []) == ["ia", "ib"])
    // B may retire its own item, while A is offline and still represented.
    let archived = MachineDirectoryReducer.merging(next, snapshots: [MachineSnapshot(endpoint: b, connection: status, projects: [pb], boards: [], cards: [], chats: [])])
    #expect(archived.cards[pa.id]?.map(\.id) == ["ia"])
    #expect(archived.projects[pa.id]?.checkouts.first { $0.id == "ca" }?.path == "/a/repo")
}

@Test func sharedArchiveFromReplicaRemovesOfflineOwnersCachedItem() {
    let a = DieterEndpoint(name: "A", host: "test", port: 443, daemonID: "a")
    let b = DieterEndpoint(name: "B", host: "test", port: 443, daemonID: "b")
    var project = Dieter_V1_Project(); project.id = "project"; project.updatedAt = "2099"
    var item = Dieter_V1_Card(); item.id = "item"; item.projectID = project.id; item.ownerDaemonID = "a"
    let initial = MachineDirectoryProjection(projects: [project.id: project], projectReplicaEndpointIDs: [project.id: a.id], boards: [:], cards: [project.id: [item]], chats: [])
    var archives = Dieter_V1_SharedArchives(); archives.itemIds = [item.id]
    var resolved = project; resolved.name = "Resolved"; resolved.updatedAt = "2026"
    let next = MachineDirectoryReducer.merging(initial, snapshots: [MachineSnapshot(endpoint: b, connection: .init(route: .gateway, latencyMilliseconds: 0), projects: [resolved], boards: [], cards: [], chats: [], archives: archives)])
    #expect(next.cards[project.id]?.isEmpty != false)
    #expect(next.projects[project.id]?.name == "Resolved")
    archives.projectIds = [project.id]
    let archived = MachineDirectoryReducer.merging(next, snapshots: [MachineSnapshot(endpoint: b, connection: .init(route: .gateway, latencyMilliseconds: 0), projects: [], boards: [], cards: [], chats: [], archives: archives)])
    #expect(archived.projects.isEmpty)
}
