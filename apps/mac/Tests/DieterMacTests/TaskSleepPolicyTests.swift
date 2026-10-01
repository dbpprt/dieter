import Foundation
import Testing

/// Swift #81771: a duration-based `Task.sleep` that is cancelled mid-sleep can
/// abort the process in `swift_task_dealloc`. Release 0.4.349 crashed this way
/// from a SwiftUI `.task` that a fast conversation load cancelled. App code
/// sleeps through `DieterTaskSleep`, which uses the nanosecond overload.
@Test func appCodeSleepsOnlyThroughTheNanosecondOverload() throws {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Sources")
    var offenders: [String] = []
    for module in ["DieterMac", "DieterIOS", "SharedCore"] {
        let files = FileManager.default.enumerator(at: sources.appending(path: module), includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let lines = try String(contentsOf: file, encoding: .utf8).split(
                separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated()
            where line.contains("Task.sleep(for:") || line.contains("Task.sleep(until:") {
                offenders.append("\(module)/\(file.lastPathComponent):\(index + 1)")
            }
        }
    }
    #expect(offenders.isEmpty, "Sleep with DieterTaskSleep instead: \(offenders)")
}
