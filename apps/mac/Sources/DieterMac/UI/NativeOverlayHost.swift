import AppKit
import SwiftUI

/// Hosts SwiftUI overlay content in a native sibling so it stays above nested
/// AppKit-backed workspace panes such as the maximized board conversation.
struct NativeOverlayHost<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let view = NSHostingView(rootView: content)
        view.sizingOptions = []
        view.setAccessibilityIdentifier("workspace.native-overlay-host")
        return view
    }

    func updateNSView(_ view: NSHostingView<Content>, context: Context) {
        view.rootView = content
    }
}

struct MachinePopoverNativeOverlay: View {
    let store: DieterStore
    let workspaceLeadingEdge: CGFloat

    var body: some View {
        NativeOverlayHost {
            MachinePopoverOverlay(workspaceLeadingEdge: workspaceLeadingEdge)
                .environment(store)
                .dieterThemeRoot(
                    palette: store.themeSelection.palette,
                    appearance: store.themeSelection.appearance
                )
        }
    }
}

private struct MachinePopoverOverlay: View {
    @Environment(DieterStore.self) private var store
    let workspaceLeadingEdge: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let popupWidth = min(820, max(560, geometry.size.width - workspaceLeadingEdge - 32))
            let processCount =
                store.selectedMachineID
                .flatMap { store.machineInformation[$0]?.processes.count } ?? 1
            let desiredPopupHeight = 420 + CGFloat(min(max(processCount, 1), 4) * 54)
            let popupHeight = min(max(460, desiredPopupHeight), geometry.size.height - 32)
            let popupTop = max(16, geometry.size.height - popupHeight - 28)

            ZStack(alignment: .topLeading) {
                Color.black.opacity(DieterTheme.usesTransparency ? 0.16 : 0.08)
                    .contentShape(Rectangle())
                    .onTapGesture { store.dismissMachinePopover() }
                    .accessibilityHidden(true)
                MachinePopover()
                    .frame(width: popupWidth, height: popupHeight)
                    .offset(x: workspaceLeadingEdge + 14, y: popupTop)
            }
        }
    }
}
