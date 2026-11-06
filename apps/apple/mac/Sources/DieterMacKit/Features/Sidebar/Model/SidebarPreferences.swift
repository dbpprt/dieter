import Foundation

/// Where the sidebar keeps its widths on this Mac.
enum SidebarPreferences {
    /// The `--sidebar-preferences-suite` defaults, else the standard ones.
    static func applicationDefaults(arguments: [String] = ProcessInfo.processInfo.arguments) -> UserDefaults {
        guard let flag = arguments.firstIndex(of: "--sidebar-preferences-suite"),
            arguments.indices.contains(flag + 1),
            let defaults = UserDefaults(suiteName: arguments[flag + 1])
        else { return .standard }
        return defaults
    }
}
