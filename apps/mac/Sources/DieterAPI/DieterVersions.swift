import Foundation

public enum DieterRelease {
    /// Marketing release embedded in every Apple artifact. Development and
    /// test bundles use a valid SemVer fallback rather than a contract number.
    public static var current: String {
        (Bundle.main.object(forInfoDictionaryKey: "DieterReleaseVersion") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "0.0.0-dev.0"
    }
}

public enum DieterRemoteDesktopProtocol {
    public static let version = "3"
    public static let number: UInt32 = 3
}
