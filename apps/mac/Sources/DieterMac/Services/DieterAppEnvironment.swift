import Foundation

/// Composition inputs. Feature models receive narrower capabilities from here.
@MainActor
struct DieterAppEnvironment {
    let arguments: [String]
    let defaults: UserDefaults
    /// `--dieter-state-root` of an isolated run; Application Support otherwise.
    let storageRoot: URL?

    init(arguments: [String], defaults: UserDefaults, storageRoot: URL?) {
        self.arguments = arguments; self.defaults = defaults; self.storageRoot = storageRoot
    }

    /// Gateway session tokens, keyed by gateway origin. An isolated run keeps
    /// its own file under its state root.
    var credentialsFile: URL {
        storageRoot?.appending(path: "gateway-sessions.json") ?? Self.defaultCredentialsFile()
    }

    static func live(arguments: [String] = ProcessInfo.processInfo.arguments) -> Self {
        .init(
            arguments: arguments, defaults: DieterAppearance.applicationDefaults(arguments: arguments),
            storageRoot: stateRoot(arguments: arguments))
    }

    static func testing(defaults: UserDefaults? = nil) -> Self {
        .init(
            arguments: [], defaults: defaults ?? UserDefaults(suiteName: "DieterTests.\(UUID().uuidString)")!,
            storageRoot: FileManager.default.temporaryDirectory.appending(path: "dieter-client-\(UUID().uuidString)"))
    }

    /// Smoke runs point the app's state at a throwaway directory so isolated
    /// fixtures neither read nor write the real state.
    static func stateRoot(arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--dieter-state-root"), arguments.indices.contains(index + 1)
        else { return nil }
        return URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
    }

    static func defaultCredentialsFile() -> URL {
        let applicationSupport =
            (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
        return
            applicationSupport
            .appending(path: "com.dbpprt.dieter.mac", directoryHint: .isDirectory)
            .appending(path: "gateway-sessions.json", directoryHint: .notDirectory)
    }
}
