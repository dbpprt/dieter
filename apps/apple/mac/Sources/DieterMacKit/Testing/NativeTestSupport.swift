#if DIETER_E2E
    import AppKit
    import Foundation

    /// The E2E launch contract. The pipeline starts the app with
    /// `--e2e-activation-ready PIDFILE --e2e-flow PLAN.json --e2e-output DIR`
    /// besides the isolated state root, defaults suite, endpoint and token file.
    @MainActor enum NativeTestSupport {
        /// Whether this launch runs a flow; normal startup is skipped then.
        nonisolated static let isE2E = ProcessInfo.processInfo.arguments.contains("--e2e-flow")

        nonisolated static func argument(_ flag: String) -> String? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }

        static var outputDirectory: URL {
            if let path = argument("--e2e-output") { return URL(fileURLWithPath: path, isDirectory: true) }
            return FileManager.default.temporaryDirectory.appending(path: "dieter-e2e", directoryHint: .isDirectory)
        }

        /// Advertises this exact PID once the app scene is ready, then waits
        /// until the runner's Launch Services `open` foregrounds this process.
        static func awaitForeground() async throws {
            guard let path = argument("--e2e-activation-ready") else { return }
            try String(ProcessInfo.processInfo.processIdentifier).write(
                toFile: path, atomically: true, encoding: .utf8)
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while !NSApp.isActive && ContinuousClock.now < deadline {
                try await DieterTaskSleep.milliseconds(50)
            }
            guard NSApp.isActive else { throw ActivationError() }
        }

        /// Writes the report atomically, then quits; the runner waits for both.
        static func finish(_ results: [String: String], to output: URL) {
            do {
                let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output.appending(path: "report.json"), options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("E2E report failed: \(error)\n".utf8))
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
            // Termination can be deferred, e.g. by a modal session; the report is final.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
        }

        /// The window's own rendering, independent of screen recording permission.
        static func capture(_ window: NSWindow, to url: URL) throws {
            if ProcessInfo.processInfo.arguments.contains("--e2e-compositor-capture") {
                // Layer-backed SwiftUI and embedded native surfaces are not all
                // included by cacheDisplay. Visual qualification needs the
                // window's composed pixels, with Screen Recording permission.
                window.displayIfNeeded()
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
                try capture.run()
                capture.waitUntilExit()
                guard capture.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
                    throw CaptureError()
                }
                return
            }
            guard let view = window.contentView,
                let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { throw CaptureError() }
            view.cacheDisplay(in: view.bounds, to: representation)
            guard let data = representation.representation(using: .png, properties: [:]) else { throw CaptureError() }
            try data.write(to: url, options: .atomic)
        }

        private struct ActivationError: Error, CustomStringConvertible {
            var description: String { "The app was not activated within 20 s" }
        }
        private struct CaptureError: Error, CustomStringConvertible {
            var description: String { "Screenshot unavailable" }
        }
    }
#endif
