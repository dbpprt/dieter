import DieterIOS
import SwiftUI

@main
struct DieterApp: App {
    @State private var host = ComposeHost(
        version: Bundle.main.object(forInfoDictionaryKey: "DieterReleaseVersion") as? String ?? "0.0.0-dev.0")
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            ShellView(host: host)
                .ignoresSafeArea()
                .task {
                    #if DEBUG
                        // Maestro flows sign in to the isolated E2E gateway fixture and may run a debug script.
                        if let url = launchArgument("fixture_url"), let token = launchArgument("fixture_token") {
                            host.adoptFixture(url: url, token: token)
                        }
                        if let script = launchArgument("script") { host.runDebugScript(script) }
                    #endif
                }
                .onOpenURL { host.completeSignIn(url: $0.absoluteString) }
                .onChange(of: scenePhase) { _, phase in host.setForeground(phase == .active) }
        }
    }
}

#if DEBUG
    /// Maestro's launchApp arguments arrive as `-key value` launch arguments.
    private func launchArgument(_ key: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(where: { $0 == "-" + key || $0 == key }),
            arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }
#endif

/// The native tab bar, navigation stacks and sheets live in UIKit; Compose draws each screen.
private struct ShellView: UIViewControllerRepresentable {
    let host: ComposeHost
    func makeUIViewController(context: Context) -> UIViewController { host.rootController }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
