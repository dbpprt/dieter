import AppKit
import SwiftUI

/// The empty part of the title band behaves like a native title bar: dragging
/// moves the window and a double-click performs the system's title-bar action.
/// Place it behind a top bar; the controls above it keep their own clicks.
struct DieterTitleBandRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> DieterTitleBandRegionView { DieterTitleBandRegionView() }

    func updateNSView(_ view: DieterTitleBandRegionView, context: Context) {}
}

@MainActor
final class DieterTitleBandRegionView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            Self.performDoubleClickAction(in: window)
        } else {
            window.performDrag(with: event)
        }
    }

    /// System Settings › Desktop & Dock › "Double-click a window's title bar to".
    static func performDoubleClickAction(
        in window: NSWindow, defaults: UserDefaults = .standard
    ) {
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }
}
