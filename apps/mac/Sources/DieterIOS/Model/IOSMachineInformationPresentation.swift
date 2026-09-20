import Foundation

enum IOSMachineInformationPresentation {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(min(value, UInt64(Int64.max))),
            countStyle: .memory
        )
    }

    static func rate(_ value: Double) -> String {
        guard value > 0 else { return "0 B/s" }
        return bytes(UInt64(value.rounded())) + "/s"
    }

    static func uptime(_ seconds: UInt64) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static func percentage(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    static func fraction(_ value: UInt64, of total: UInt64) -> Double {
        guard total > 0 else { return 0 }
        return min(max(Double(value) / Double(total), 0), 1)
    }

    static func shortRevision(_ value: String) -> String? {
        guard !value.isEmpty, value != "unknown" else { return nil }
        return String(value.prefix(10))
    }
}
