import AppKit
import Foundation

/// Focused packaged-app verification for the authenticated machine path. It
/// deliberately never invokes restart or shutdown.
@MainActor
enum MachineUISmokeRunner {
    static func run(store: DieterStore) async {
        let output = outputDirectory()
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        guard await waitUntil(timeout: 25, condition: {
            store.workspaceIsLive && store.machines.contains(where: \.online)
        }) else {
            writeReport(["connection": "failed: no live enrolled machine (\(store.phase.label))"], to: output)
            return
        }
        guard let machine = store.machines.first(where: \.online) else {
            writeReport(["connection": "failed: machine directory was empty"], to: output)
            return
        }

        await store.openMachine(machine)
        guard await waitUntil(timeout: 15, condition: {
            store.section == .machines && store.machineInformation[machine.id] != nil
        }), let information = store.machineInformation[machine.id] else {
            writeReport([
                "connection": "passed",
                "machine-rpc": "failed: \(store.machineInformationError ?? "telemetry unavailable")",
            ], to: output)
            return
        }

        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title == "Dieter" })
            ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else {
            writeReport(["window": "failed: Dieter window not found"], to: output)
            return
        }
        window.setContentSize(NSSize(width: 1_380, height: 780))
        window.center()
        window.makeKeyAndOrderFront(nil)
        try? await DieterTaskSleep.seconds(3)

        var results: [String: String] = [
            "connection": "passed",
            "machine-rpc": information.hostname.isEmpty || information.osName.isEmpty
                ? "failed: host identity was incomplete" : "passed",
            "telemetry": information.logicalCpuCount == 0 || information.cpuCoreUsagePercent.isEmpty
                || information.memoryTotalBytes == 0 || information.diskTotalBytes == 0
                ? "failed: telemetry was incomplete" : "passed",
            "dieter-processes": information.processes.contains(where: { $0.kind == "daemon" })
                ? "passed" : "failed: daemon process was absent",
            "host-controls": information.supportsRestart && information.supportsShutdown
                ? "passed" : "failed: restart/shutdown were unavailable",
            "route": store.connectionStatus(for: machine) == nil
                ? "failed: no authenticated route measurement" : "passed",
        ]
        results["render"] = capture(window: window, to: output.appendingPathComponent("machine-information.png"))
            ? "passed" : "failed: could not capture machine dashboard"
        writeReport(results, to: output)
    }

    private static func outputDirectory() -> URL {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--machine-ui-smoke-output"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dieter-machine-ui-smoke", isDirectory: true)
    }

    private static func waitUntil(timeout: TimeInterval, condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await DieterTaskSleep.milliseconds(100)
        }
        return condition()
    }

    private static func capture(window: NSWindow, to destination: URL) -> Bool {
        guard let view = window.contentView,
              let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let data = representation.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: destination, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func writeReport(_ results: [String: String], to output: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: output.appendingPathComponent("report.json"), options: .atomic)
    }
}
