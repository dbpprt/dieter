import OSLog

enum MacPerformanceSignposts {
    static let projection = OSLog(subsystem: "com.dbpprt.dieter.mac", category: "Projection")
    static let editor = OSLog(subsystem: "com.dbpprt.dieter.mac", category: "Editor")
    static let attachment = OSLog(subsystem: "com.dbpprt.dieter.mac", category: "Attachment")

    static func measure<T>(
        _ name: StaticString,
        log: OSLog,
        operation: () throws -> T
    ) rethrows -> T {
        os_signpost(.begin, log: log, name: name)
        defer { os_signpost(.end, log: log, name: name) }
        return try operation()
    }
}
