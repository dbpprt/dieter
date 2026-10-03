import Foundation
import Testing

/// The iOS app is a presentation-only client of the shared core: it reaches
/// gateways and daemons only through SharedCore, never through its own gRPC
/// clients, and the share extension stays small enough for its memory budget
/// by not linking the core.
@Suite("iOS shared-core architecture")
struct IOSArchitectureTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every line in `directory`'s Swift files containing one of `forbidden`.
    static func offenders(in directory: URL, forbidden: [String]) -> [String] {
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift",
                let source = try? String(contentsOf: file, encoding: .utf8)
            else { continue }
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                for term in forbidden where line.contains(term) {
                    offenders.append("\(file.lastPathComponent):\(index + 1): \(term)")
                }
            }
        }
        return offenders
    }

    @Test func appSourcesUseOnlyTheSharedCore() throws {
        let sources = Self.root.appending(path: "Sources/DieterIOS", directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: sources.path))
        let offenders = Self.offenders(
            in: sources,
            forbidden: [
                "import DieterCore", "import DieterClient", "import GRPCCore",
                "DieterRPC(", "ConnectionManager(", "DataPlaneConnection(", "RemoteDesktopSignalingConnection(",
                "#if DIETER_IOS_PENDING",
            ])
        #expect(offenders.isEmpty, "Go through SharedCore instead: \(offenders)")
    }

    @Test func shareExtensionDoesNotLinkTheCore() throws {
        let sources = Self.root.appending(path: "../ios/DieterIOSShare", directoryHint: .isDirectory)
        #expect(FileManager.default.fileExists(atPath: sources.path))
        let offenders = Self.offenders(
            in: sources,
            forbidden: ["import DieterShared", "import SharedCore", "import DieterIOS", "import DieterAPI"])
        #expect(offenders.isEmpty, "The extension hands off through the app group: \(offenders)")
    }
}
