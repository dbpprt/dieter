import Foundation

enum PrivacyHelperPackage {
    static func bundle(for executable: URL) -> URL {
        let directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        let adjacent = directory.appendingPathComponent("DieterPrivacyHelper.app")
        let homebrew = directory.deletingLastPathComponent()
            .appendingPathComponent("libexec/DieterPrivacyHelper.app")
        for candidate in [adjacent, homebrew] {
            if FileManager.default.isExecutableFile(
                atPath: candidate.appendingPathComponent("Contents/MacOS/dieter-privacy").path)
            {
                return candidate
            }
        }
        return adjacent
    }
}
