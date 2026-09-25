#if DIETER_UI_SMOKE
    import AppKit
    import Foundation

    @MainActor enum NativeTestSupport {
        static func argument(_ flag: String) -> String? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        static func outputDirectory(flag: String = "--ui-smoke-output") -> URL {
            if let path = argument(flag) { return URL(fileURLWithPath: path, isDirectory: true) }
            return FileManager.default.temporaryDirectory.appending(
                path: "dieter-native-test", directoryHint: .isDirectory)
        }
        static func writeReport(
            _ results: [String: String], to output: URL, name: String = "report.json", terminate: Bool = true
        ) {
            do {
                let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output.appending(path: name), options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("Native test report failed: \(error)\n".utf8))
            }
            if terminate { DispatchQueue.main.async { NSApp.terminate(nil) } }
        }
    }
#endif
