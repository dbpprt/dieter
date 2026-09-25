import DieterAPI

/// Joins the daemon's causal frontiers, independently for placement and runtime.
/// A transport arrival and a wall clock are neither a revision nor an acknowledgement.
package enum CardStateProjection {
    private static func covers(_ a: [String: UInt64], _ b: [String: UInt64]) -> Bool {
        b.allSatisfy { a[$0.key, default: 0] >= $0.value }
    }

    package static func hasOlderRuntime(_ incoming: Dieter_V1_Card, than previous: Dieter_V1_Card) -> Bool {
        guard let old = previous.stateFields.first(where: { $0.name == "summary" }),
            let new = incoming.stateFields.first(where: { $0.name == "summary" })
        else { return false }
        return new.versions.allSatisfy { candidate in old.versions.contains { covers($0.clock, candidate.clock) } }
            && !old.versions.allSatisfy { candidate in new.versions.contains { covers($0.clock, candidate.clock) } }
    }

    package static func merge(_ incoming: Dieter_V1_Card, with previous: Dieter_V1_Card?) -> Dieter_V1_Card {
        guard let previous, previous.id == incoming.id else { return incoming }
        var result = incoming
        let oldFields = Dictionary(previous.stateFields.map { ($0.name, $0) }, uniquingKeysWith: { _, b in b })
        let newFields = Dictionary(incoming.stateFields.map { ($0.name, $0) }, uniquingKeysWith: { _, b in b })
        result.stateFields = Set(oldFields.keys).union(newFields.keys).sorted().map { name in
            guard let old = oldFields[name] else { return newFields[name]! }
            guard let new = newFields[name] else { return old }
            let all = old.versions + new.versions
            var field = new
            field.versions = all.enumerated().filter { i, version in
                !all.enumerated().contains { j, other in
                    guard i != j, covers(other.clock, version.clock) else { return false }
                    return !covers(version.clock, other.clock)
                        || other.rank > version.rank || (other.rank == version.rank && j < i)
                }
            }.map(\.element).sorted { $0.rank < $1.rank }
            // Match the peer-store frontier bound. Keep the last complete view
            // until a daemon supplies a resolved register, rather than dropping
            // causal siblings or letting a disconnected client grow without bound.
            guard field.versions.count <= 16 else { return old }
            // A client-side join is not a daemon CAS receipt. A move must wait
            // for a replica which has observed that complete frontier.
            if field.versions == new.versions {
                field.revision = new.revision
            } else if field.versions == old.versions {
                field.revision = old.revision
            } else {
                field.revision = "unobserved-join"
            }
            return field
        }
        for field in result.stateFields {
            guard let selected = field.versions.max(by: { $0.rank < $1.rank }),
                !field.versions.contains(where: \.deleted)
            else { continue }
            let value = selected.value
            switch field.name {
            case "placement":
                result.boardID = value.boardID
                result.lane = value.lane
                result.orderKey = value.orderKey
                result.phaseChangedAt = value.phaseChangedAt
                result.placementRevision = field.revision
            case "summary":
                result.runtime = value.runtime
                result.runtimeUpdatedAt = value.runtimeUpdatedAt
                result.lastActivityAt = value.lastActivityAt
                result.provider = value.provider
                result.model = value.model
                result.effort = value.effort
                result.initialPromptSentAt = value.initialPromptSentAt
                result.responseSeq = value.responseSeq
                result.responseMessageID = value.responseMessageID
                result.seenResponseSeq = value.seenResponseSeq
                result.mergedIntoCardID = value.mergedIntoCardID
            default: break
            }
        }
        return result
    }
}
