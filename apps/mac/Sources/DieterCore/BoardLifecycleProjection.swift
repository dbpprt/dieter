import DieterAPI

/// Retirement is a causal intent. References and unresolved intents keep a
/// board visible; arrival order and unrelated replica cursors cannot retire it.
package enum BoardLifecycleProjection {
    private static func covers(_ a: [String: UInt64], _ b: [String: UInt64]) -> Bool {
        b.allSatisfy { a[$0.key, default: 0] >= $0.value }
    }

    package static func merge(_ incoming: Dieter_V1_Board, with previous: Dieter_V1_Board?) -> Dieter_V1_Board {
        guard let previous, previous.id == incoming.id else { return incoming }
        var result = incoming
        let all = previous.retirementVersions + incoming.retirementVersions
        let frontier = all.enumerated().filter { i, version in
            !all.enumerated().contains { j, other in
                guard i != j, covers(other.clock, version.clock) else { return false }
                return !covers(version.clock, other.clock) || other.rank > version.rank
                    || (other.rank == version.rank && j < i)
            }
        }.map(\.element).sorted { $0.rank < $1.rank }
        guard frontier.count <= 16, previous.retirementRevision != "overflow" else {
            result.retirementVersions = previous.retirementVersions
            result.retirementRevision = "overflow"
            result.retired = false; result.retirementBlocked = true
            return result
        }
        result.retirementVersions = frontier
        let same: (Dieter_V1_Board) -> Bool = { $0.retirementVersions.sorted { $0.rank < $1.rank } == frontier }
        result.retirementRevision =
            same(incoming)
            ? incoming.retirementRevision
            : same(previous) ? previous.retirementRevision : "unobserved-join"
        let requested = frontier.contains { $0.retired && !$0.deleted }
        let references = Array(Set(previous.retirementReferences + incoming.retirementReferences).sorted().prefix(64))
        result.retirementBlocked =
            requested
            && (frontier.count != 1 || !references.isEmpty
                || same(incoming) && incoming.retirementBlocked || same(previous) && previous.retirementBlocked)
        result.retirementReferences = requested ? references : []
        result.retired = requested && !result.retirementBlocked
        return result
    }
}
