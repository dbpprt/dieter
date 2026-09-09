import DieterCore
import Testing

@Test func documentIdentityIncludesEveryScopeWithoutSeparatorCollisions() {
    let first = WorkspaceTarget(endpointID: "a:b", projectID: "c", conversationID: "d")
    let second = WorkspaceTarget(endpointID: "a", projectID: "b:c", conversationID: "d")
    #expect(first.documentKey(path: "same.swift") != second.documentKey(path: "same.swift"))
    #expect(first.documentKey(path: "same.swift") == first.documentKey(path: "same.swift"))
}
