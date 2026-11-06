import AppKit
import SwiftUI

/// Keep the bounded navigation directory attached when changing destinations.
/// Hiding its native host prevents drawing, hit testing and accessibility;
/// unlike removing a SwiftUI branch, it preserves scroll and layout state.
struct RetainedWorkspacePane<Content: View>: NSViewRepresentable {
    let active: Bool
    let content: Content

    init(active: Bool, @ViewBuilder content: () -> Content) {
        self.active = active
        self.content = content()
    }

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(content.environment(\.self, context.environment)))
        host.sizingOptions = []
        host.isHidden = !active
        return host
    }

    func updateNSView(_ host: NSHostingView<AnyView>, context: Context) {
        host.rootView = AnyView(content.environment(\.self, context.environment))
        host.isHidden = !active
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<AnyView>, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
            width.isFinite, height.isFinite
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
