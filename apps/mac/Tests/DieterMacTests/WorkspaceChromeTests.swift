import AppKit
import SwiftUI
import Testing
@testable import DieterMac

@Suite(.serialized) struct WorkspaceChromeTests {
    @Test @MainActor func destinationsShareOneStableBackdrop() async throws {
        let suite = "WorkspaceChromeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = DieterStore(environment: .testing(defaults: defaults), restoreSync: false)
        store.phase = .connected(version: "test")
        let host = NSHostingController(
            rootView: DieterRootView(navigationDefaults: defaults).environment(store)
                .dieterThemeRoot(palette: .monochrome, appearance: .dark))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1080, height: 680),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1080, height: 680))
        defer {
            window.close()
            defaults.removePersistentDomain(forName: suite)
            DieterTheme.install(selection: .load())
        }
        window.makeKeyAndOrderFront(nil)
        var originalBackdrop: DieterWindowBackdropView?
        for transparent in [true, false, true] {
            store.themeSelection = .init(appearance: .dark, palette: .monochrome, transparencyEnabled: transparent)
            for section in [AppSection.inbox, .screens, .settings, .chats, .inbox] {
                store.section = section
                try await Task.sleep(for: .milliseconds(180))
                host.view.layoutSubtreeIfNeeded()
                let views = descendants(host.view)
                let backdrops = views.compactMap { $0 as? DieterWindowBackdropView }
                #expect(backdrops.count == 1)
                let backdrop = try #require(backdrops.first)
                if let originalBackdrop { #expect(backdrop === originalBackdrop) } else { originalBackdrop = backdrop }
                #expect(backdrop.state == .active)
                #expect(window.isOpaque == !DieterTheme.usesTransparency)
                #expect(abs(backdrop.bounds.height - host.view.bounds.height) < 1)
                let splits = views.compactMap { ($0 as? NSSplitView)?.delegate as? WorkspaceSplitController }
                let split = try #require(splits.first)
                // A system glass wrapper here would tint navigation independently
                // of the content and change it when switching active destinations.
                var ancestor: NSView? = split.sidebarHost.superview
                while let view = ancestor {
                    #expect(!(view is NSGlassEffectView))
                    ancestor = view.superview
                }
                #expect(abs(split.sidebarHost.frame.width - SidebarSizing.defaultWidth) < 1)
                if let output = ProcessInfo.processInfo.environment["DIETER_CHROME_EVIDENCE"],
                    let rep = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds)
                {
                    host.view.cacheDisplay(in: host.view.bounds, to: rep)
                    let url = URL(fileURLWithPath: output).appending(path: "fixed-\(section)-\(transparent).png")
                    try rep.representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
    }

    @Test @MainActor func sidebarResizeAndCollapsePreserveWidth() async throws {
        let split = WorkspaceSplitController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1080, height: 680))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        var width: CGFloat = 234
        var visible = true
        split.onWidthChange = { width = $0 }
        split.onVisibilityChange = { visible = $0 }
        split.configure(width: width, visible: true)
        try await Task.sleep(for: .milliseconds(100))
        split.splitView.setPosition(800, ofDividerAt: 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(split.sidebarHost.frame.width <= SidebarSizing.maximumWidth + 1)
        split.splitView.setPosition(285, ofDividerAt: 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(width - 285) < 1)
        split.toggleSidebar(nil)
        #expect(!visible)
        #expect(split.splitViewItems[0].isCollapsed)
        split.toggleSidebar(nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(visible)
        #expect(abs(split.sidebarHost.frame.width - 285) < 1)
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
