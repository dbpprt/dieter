import Foundation
import SwiftProtobuf

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
