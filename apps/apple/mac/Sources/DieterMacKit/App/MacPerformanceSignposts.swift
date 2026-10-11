import DieterIdentity
import OSLog

enum MacPerformanceSignposts {
    static let projection = OSLog(subsystem: DistributionIdentity.macBundleID, category: "Projection")
    static let editor = OSLog(subsystem: DistributionIdentity.macBundleID, category: "Editor")
    static let attachment = OSLog(subsystem: DistributionIdentity.macBundleID, category: "Attachment")
    static let conversation = OSLog(subsystem: DistributionIdentity.macBundleID, category: "Conversation")

    static func measure<T>(
        _ name: StaticString,
        log: OSLog,
        operation: () throws -> T
    ) rethrows -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return try operation()
    }
}
