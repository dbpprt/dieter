import DieterAPI
import Foundation

/// Protobuf decoding runs on this actor, never on the UI actor. Serialized
/// identity prevents a cached endpoint from returning an older projection.
actor DieterSnapshotDecoder {
    private struct Entry {
        let data: Data
        let snapshot: Dieter_V1_GlobalSnapshot
        let conversations: [String: Dieter_V1_ConversationSnapshot]
    }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let maximumBytes = 16 * 1_024 * 1_024

    func snapshot(endpointID: String, data: Data?) -> Dieter_V1_GlobalSnapshot? {
        entry(endpointID: endpointID, data: data)?.snapshot
    }

    func conversation(cardID: String, endpointID: String, data: Data?) -> Dieter_V1_ConversationSnapshot? {
        entry(endpointID: endpointID, data: data)?.conversations[cardID]
    }

    private func entry(endpointID: String, data: Data?) -> Entry? {
        guard !Task.isCancelled, let data else { return nil }
        if let cached = entries[endpointID], cached.data == data { return cached }
        guard let snapshot = try? Dieter_V1_GlobalSnapshot(serializedBytes: data), !Task.isCancelled else { return nil }
        let value = Entry(
            data: data, snapshot: snapshot,
            conversations: snapshot.conversations.reduce(into: [:]) {
                $0[$1.detail.card.id] = $1
            })
        order.removeAll { $0 == endpointID }
        entries.removeValue(forKey: endpointID)
        if data.count <= maximumBytes {
            while order.count >= 4 || entries.values.reduce(data.count, { $0 + $1.data.count }) > maximumBytes {
                guard !order.isEmpty else { break }
                entries.removeValue(forKey: order.removeFirst())
            }
            entries[endpointID] = value
            order.append(endpointID)
        }
        return value
    }
}
