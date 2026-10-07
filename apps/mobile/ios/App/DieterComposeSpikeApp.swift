import DieterComposeHost
import SwiftUI

@main
struct DieterComposeSpikeApp: App {
    @State private var host = ComposeHost(
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-dev.0")
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            SpikeRoot(host: host).tint(Color(red: 0.94, green: 0.40, blue: 0.29))
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
    @State private var tab = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let paper = Color(red: 0.969, green: 0.973, blue: 0.953)
    var body: some View {
        ComposeContent(host: host)
            .background(paper)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Text("dieter").font(.system(size: 25, weight: .bold, design: .rounded))
                    Spacer()
                    Button(action: host.reconnect) { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                        .accessibilityLabel("Reconnect").modifier(GlassControl(reduceTransparency: reduceTransparency))
                    Button(action: host.newTask) {
                        Image(systemName: "plus").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("New task").modifier(GlassControl(reduceTransparency: reduceTransparency))
                }
                .padding(.horizontal, 22).padding(.vertical, 10).background(paper)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 4) {
                    tabButton(0, "Board", "square.grid.2x2")
                    tabButton(1, "Chats", "bubble.left.and.bubble.right")
                    tabButton(2, "Machines", "desktopcomputer")
                }
                .frame(maxWidth: 440)
                .padding(7).modifier(GlassBar(reduceTransparency: reduceTransparency))
                .padding(.horizontal, 28).padding(.bottom, 10).padding(.top, 8)
            }
            // Compose applies imePadding to its form and composer. Keeping the
            // host's frame stable prevents SwiftUI from avoiding the keyboard a
            // second time and leaves native chrome beneath the keyboard.
            .ignoresSafeArea(.keyboard, edges: .bottom)
    }
    private func tabButton(_ index: Int, _ title: String, _ icon: String) -> some View {
        Button {
            tab = index; host.selectTab(index)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 20)); Text(title).font(.system(size: 11, weight: .semibold))
            }
            .frame(maxWidth: .infinity).frame(height: 48)
            .foregroundStyle(tab == index ? Color(red: 0.94, green: 0.40, blue: 0.29) : .secondary)
            .background(tab == index ? Color.primary.opacity(0.06) : .clear, in: Capsule())
        }.accessibilityLabel(title).accessibilityAddTraits(tab == index ? [.isSelected] : [])
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
