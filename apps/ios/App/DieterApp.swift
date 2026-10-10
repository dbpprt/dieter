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
                        let environment = ProcessInfo.processInfo.environment
                        if let url = environment["DIETER_IOS_TEST_GATEWAY"],
                            let token = environment["DIETER_IOS_TEST_TOKEN"]
                        {
                            host.adoptFixture(url: url, token: token)
                        }
                        if let script = environment["DIETER_IOS_TEST_SCRIPT"] { host.runDebugScript(script) }
                    #endif
                }
                .onOpenURL { host.completeSignIn(url: $0.absoluteString) }
                .onChange(of: scenePhase) { _, phase in host.setForeground(phase == .active) }
        }
    }
}

/// The native tab bar, navigation stacks and sheets live in UIKit; Compose draws each screen.
private struct ShellView: UIViewControllerRepresentable {
    let host: ComposeHost
    func makeUIViewController(context: Context) -> UIViewController { host.rootController }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
