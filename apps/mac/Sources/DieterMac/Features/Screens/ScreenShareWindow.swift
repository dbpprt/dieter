import AppKit
import SwiftUI

// A session owns one input surface and one Metal renderer. Moving that surface
// preserves the peer, decoder, last frame, and clipboard session across windows.
struct RemoteDesktopVideoSurface: NSViewRepresentable {
    let session: ScreenShareSession
    var detached = false
    var toggleFullScreen: (@MainActor () -> Void)?

    func makeNSView(context: Context) -> RemoteDesktopSurfaceHost {
        let host = RemoteDesktopSurfaceHost()
        updateNSView(host, context: context)
        return host
    }
    func updateNSView(_ host: RemoteDesktopSurfaceHost, context: Context) {
        guard session.isDetached == detached else { return }
        let surface = session.videoSurface
        surface.onToggleFullScreen = toggleFullScreen
        host.mount(surface)
        surface.refreshCursor()
    }
    static func dismantleNSView(_ host: RemoteDesktopSurfaceHost, coordinator: ()) { host.unmount() }
}

@MainActor final class RemoteDesktopSurfaceHost: NSView {
    private weak var surface: RemoteDesktopInputView?
    func mount(_ surface: RemoteDesktopInputView) {
        self.surface = surface
        if surface.superview !== self {
            surface.removeFromSuperview()
            addSubview(surface)
        }
        surface.frame = bounds
        surface.autoresizingMask = [.width, .height]
    }
    func unmount() {
        if let surface, surface.superview === self { surface.removeFromSuperview() }
        surface = nil
    }
}

@MainActor final class ScreenShareWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let session: ScreenShareSession
    private var dockPending = false
    private(set) var transitioning = false
    private var disposed = false
    // Native integration fixtures supply stable client geometry without changing
    // the operator's monitor; production always uses the window's actual screen.
    var displayTarget: (NSScreen) -> RemoteDesktopDisplayTarget = { screen in
        .init(
            width: Int(screen.frame.width), height: Int(screen.frame.height), scale: screen.backingScaleFactor,
            refresh: Double(screen.maximumFramesPerSecond))
    }
    private let dock: @MainActor () -> Void
    private static let controls = NSToolbarItem.Identifier("screen.controls")
    private static let dockItem = NSToolbarItem.Identifier("screen.dock")
    private static let fullScreenItem = NSToolbarItem.Identifier("screen.fullscreen")

    init(session: ScreenShareSession, dock: @escaping @MainActor () -> Void) {
        self.session = session; self.dock = dock
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 750),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = session.machineName + " — Screen Share"
        window.identifier = NSUserInterfaceItemIdentifier("screen.window." + session.id)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 640, height: 400)
        window.backgroundColor = .black
        window.delegate = self
        let toolbar = NSToolbar(identifier: "Dieter.ScreenShare")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
        let host = NSHostingView(
            rootView: DetachedScreenShareView(session: session) { [weak self] in self?.toggleFullScreen() })
        host.sizingOptions = []
        window.contentView = host
        window.center()
    }
    required init?(coder: NSCoder) { nil }

    func present(fullScreen: Bool) {
        guard !disposed, let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.contentView?.layoutSubtreeIfNeeded()
        focusVideo()
        if fullScreen && !window.styleMask.contains(.fullScreen) && !transitioning { toggleFullScreen() }
    }
    @objc func toggleFullScreen() {
        guard !disposed, !transitioning, let window else { return }
        session.videoSurface.releaseFocus()
        transitioning = true
        window.toggleFullScreen(nil)
    }
    @objc func returnToDieter() {
        guard !disposed else { return }
        dockPending = true
        guard !transitioning else { return }
        if window?.styleMask.contains(.fullScreen) == true { toggleFullScreen() } else { dock() }
    }
    func dispose() {
        guard !disposed else { return }
        disposed = true
        session.videoSurface.fullScreenActive = false
        session.controller.setDisplayMatchingTarget(nil)
        session.videoSurface.releaseFocus()
        if session.videoSurface.window === window { session.videoSurface.removeFromSuperview() }
        window?.delegate = nil
        window?.contentView = nil
        window?.close()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { returnToDieter(); return false }
    func windowWillEnterFullScreen(_ notification: Notification) {
        transitioning = true; session.videoSurface.releaseFocus()
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        session.videoSurface.fullScreenActive = false
        updateDisplayMatching()
        transitioning = true; session.videoSurface.releaseFocus()
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        transitioning = false
        session.videoSurface.fullScreenActive = true
        updateDisplayMatching()
        if dockPending { returnToDieter() } else { focusVideo() }
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        transitioning = false
        if dockPending { dock() } else { focusVideo() }
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        transitioning = false
        if dockPending { dock() } else { focusVideo() }
    }
    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        transitioning = false; dockPending = false; session.videoSurface.fullScreenActive = true; focusVideo()
        updateDisplayMatching()
    }
    func windowDidChangeScreen(_ notification: Notification) { updateDisplayMatching() }
    func windowDidChangeBackingProperties(_ notification: Notification) { updateDisplayMatching() }

    func updateDisplayMatching() {
        guard !disposed, session.matchClientResolution, session.videoSurface.fullScreenActive,
            let screen = window?.screen
        else { session.controller.setDisplayMatchingTarget(nil); return }
        session.controller.setDisplayMatchingTarget(displayTarget(screen))
    }
    func window(
        _ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
    ) -> NSApplication.PresentationOptions {
        proposedOptions.union(.autoHideToolbar)
    }
    private func focusVideo() {
        window?.contentView?.layoutSubtreeIfNeeded()
        if session.videoSurface.window === window {
            window?.makeFirstResponder(session.videoSurface)
            session.videoSurface.resumeInput()
        }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.dockItem, .flexibleSpace, Self.controls, Self.fullScreenItem]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }
    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.dockItem:
            item.label = "Return to Dieter"; item.toolTip = "Return this live screen share to Dieter"
            item.image = NSImage(systemSymbolName: "rectangle.inset.filled", accessibilityDescription: item.label)
            item.target = self; item.action = #selector(returnToDieter)
        case Self.fullScreenItem:
            item.label = "Toggle full screen"; item.toolTip = "Toggle full screen (⌃⌘F)"
            item.image = NSImage(
                systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: item.label)
            item.target = self; item.action = #selector(toggleFullScreen)
        case Self.controls:
            item.label = "Screen controls"
            item.view = NSHostingView(
                rootView: HStack(spacing: 12) {
                    Text(
                        session.controller.keyboardCaptureStatus.isEmpty
                            ? "⌘⇧Esc releases input" : session.controller.keyboardCaptureStatus
                    )
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    ScreenShareOptions(controller: session.controller)
                }.padding(.horizontal, 6))
        default: return nil
        }
        return item
    }
}

private struct DetachedScreenShareView: View {
    let session: ScreenShareSession
    let toggleFullScreen: @MainActor () -> Void
    @State private var keyboardHint = ""
    var body: some View {
        ZStack {
            Color.black
            RemoteDesktopVideoSurface(session: session, detached: true, toggleFullScreen: toggleFullScreen)
            if session.controller.phase != .streaming {
                VStack(spacing: 12) {
                    Text(session.machineName).font(.headline)
                    Text(session.controller.errorMessage ?? session.inactivityMessage ?? session.controller.phase.label)
                        .multilineTextAlignment(.center)
                    if case .permissionRequired(let reason) = session.controller.phase {
                        Text(reason).multilineTextAlignment(.center)
                        Button("Check Again") { session.reconnect() }
                    } else if session.keepsConnectionOpen {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Reconnect") { session.reconnect() }
                    }
                }
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .overlay(alignment: .bottom) {
            if !keyboardHint.isEmpty {
                Text(keyboardHint)
                    .font(.callout)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 28)
                    .allowsHitTesting(false)
            }
        }
        .task(id: session.controller.keyboardCaptureStatus) {
            keyboardHint = session.controller.keyboardCaptureStatus
            guard !keyboardHint.isEmpty else { return }
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            keyboardHint = ""
        }
        .accessibilityIdentifier("screens.detached.video")
    }
}
