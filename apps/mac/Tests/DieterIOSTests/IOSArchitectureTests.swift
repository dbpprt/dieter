import Foundation
import Testing

@Suite("iOS shared-core architecture")
struct IOSArchitectureTests {
    @Test func productionUIHasNoLegacyBusinessLogicClients() throws {
        let macRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = macRoot.appending(path: "Sources/DieterIOS", directoryHint: .isDirectory)
        let forbidden = [
            "DieterRPC(",
            "ConnectionManager(",
            "DataPlaneConnection(",
            "RemoteDesktopSignalingConnection(",
        ]
        let files = try #require(
            FileManager.default.enumerator(
                at: sourceRoot, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects
                as? [URL])
        let violations =
            try files
            .filter { $0.pathExtension == "swift" }
            .flatMap { url -> [String] in
                let source = try String(contentsOf: url, encoding: .utf8)
                return forbidden.filter(source.contains).map { "\(url.lastPathComponent): \($0)" }
            }
        #expect(violations.isEmpty, "Legacy iOS clients found: \(violations.joined(separator: ", "))")
    }
}
