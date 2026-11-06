import Foundation
import SwiftProtobuf
import Synchronization

extension Date {
    /// Epoch milliseconds, the unit the shared core's rules take times in.
    package var epochMillis: Int64 { Int64((timeIntervalSince1970 * 1_000).rounded()) }

    /// The date of epoch milliseconds the core sent; nil for 0 (unknown).
    package init?(epochMillis: Int64) {
        guard epochMillis > 0 else { return nil }
        self.init(timeIntervalSince1970: Double(epochMillis) / 1_000)
    }
}

extension SwiftProtobuf.Message {
    /// Decodes a message a shared rule returned encoded; the default value when it cannot.
    package init(rules data: Data) {
        self = (try? Self(serializedBytes: data)) ?? Self()
    }

    /// The encoded message, as shared rules take message inputs.
    package var rulesData: Data { (try? serializedData()) ?? Data() }
}

/// A bounded memo of a pure shared rule's answers by their whole input. Rows
/// ask the same rule the same question on every render, and each answer is a
/// call into the core and a decode, so a list of a few hundred rows would
/// otherwise pay for both per frame.
package final class SharedRuleMemo<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private let entries = Mutex<[Key: Value]>([:])
    private let limit: Int

    package init(limit: Int = 4_096) { self.limit = limit }

    package func value(_ key: Key, _ compute: () -> Value) -> Value {
        if let known = entries.withLock({ $0[key] }) { return known }
        let value = compute()
        entries.withLock { entries in
            if entries.count >= limit { entries.removeAll(keepingCapacity: true) }
            entries[key] = value
        }
        return value
    }
}

/// The latest answer of a pure shared rule per entity (a card, a project),
/// kept while the input it was computed from is unchanged. Rules over an
/// encoded message take it whole, so an entity that changes in place replaces
/// its answer instead of adding one.
package final class SharedRuleEntityMemo<Input: Equatable & Sendable, Value: Sendable>: Sendable {
    private let entries = Mutex<[String: (input: Input, value: Value)]>([:])
    private let limit: Int

    package init(limit: Int = 4_096) { self.limit = limit }

    package func value(_ id: String, input: Input, _ compute: () -> Value) -> Value {
        if let known = entries.withLock({ $0[id] }), known.input == input { return known.value }
        let value = compute()
        entries.withLock { entries in
            if entries.count >= limit, entries[id] == nil { entries.removeAll(keepingCapacity: true) }
            entries[id] = (input, value)
        }
        return value
    }
}
