import DieterComposeHost
import SwiftUI

@main
struct DieterComposeSpikeApp: App {
    @State private var host = ComposeHost(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-dev.0")
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            SpikeRoot(host: host)
                .preferredColorScheme(host.appearance == "dark" ? .dark : host.appearance == "light" ? .light : nil)
                .task {
                    #if DEBUG
                        let environment = ProcessInfo.processInfo.environment
                        if let url = environment["DIETER_IOS_TEST_GATEWAY"],
                            let token = environment["DIETER_IOS_TEST_TOKEN"]
                        {
                            host.adoptFixture(url: url, token: token)
                        }
                    #endif
                }
                .onOpenURL { host.completeSignIn(url: $0.absoluteString) }
                .onChange(of: scenePhase) { _, phase in host.setForeground(phase == .active) }
        }
    }
}
private struct ComposeContent: UIViewControllerRepresentable {
    let host: ComposeHost
    func makeUIViewController(context: Context) -> UIViewController { host.controller }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
private struct SpikeRoot: View {
    let host: ComposeHost
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ComposeContent(host: host)
            .background(Color(uiColor: .systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if host.chromeVisible {
                    HStack(spacing: 8) {
                        HStack(spacing: 2) {
                            tabButton(0, "Inbox", "tray")
                            tabButton(1, "Projects", "square.split.2x2")
                            tabButton(2, "Chats", "bubble.left.and.bubble.right")
                            tabButton(3, "Tools", "square.grid.2x2")
                        }
                        .padding(6).modifier(GlassBar(reduceTransparency: reduceTransparency))
                        Button(action: host.newTask) {
                            Image(systemName: "plus").font(.title3.weight(.semibold)).frame(width: 52, height: 52)
                        }
                        .accessibilityLabel("New task").accessibilityIdentifier("native-new-task")
                        .modifier(GlassControl(reduceTransparency: reduceTransparency))
                    }
                    .frame(maxWidth: 560).padding(.horizontal, 16).padding(.bottom, 8).padding(.top, 8)
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .tint(.primary)
    }
    private func tabButton(_ index: Int, _ title: String, _ icon: String) -> some View {
        Button {
            host.selectTab(index)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 20))
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .frame(maxWidth: .infinity).frame(height: 46)
            .foregroundStyle(host.selectedTab == index ? .primary : .secondary)
            .background(host.selectedTab == index ? Color.primary.opacity(0.08) : .clear, in: Capsule())
        }.accessibilityLabel(title).accessibilityAddTraits(host.selectedTab == index ? [.isSelected] : [])
    }
}
private struct GlassControl: ViewModifier {
    let reduceTransparency: Bool
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(.background, in: Circle())
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}
private struct GlassBar: ViewModifier {
    let reduceTransparency: Bool
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(.background, in: Capsule())
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}
