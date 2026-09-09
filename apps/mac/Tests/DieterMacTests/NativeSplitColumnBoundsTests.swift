import AppKit
import Testing
@testable import DieterMac

@Test @MainActor func nativeSplitColumnStopsAtMaximumAndStillResizesBelowIt() async {
    let controller = NSSplitViewController()
    controller.splitView.isVertical = true
    let sidebar = NSViewController()
    sidebar.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
    let content = NSViewController()
    content.view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
    controller.addSplitViewItem(NSSplitViewItem(sidebarWithViewController: sidebar))
    controller.addSplitViewItem(NSSplitViewItem(viewController: content))
    let probe = SplitColumnBoundsView()
    probe.minimum = 210
    probe.maximum = 300
    sidebar.view.addSubview(probe)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    defer { probe.stopObserving(); window.close() }
    window.contentView?.layoutSubtreeIfNeeded()
    probe.scheduleConfiguration()
    try? await Task.sleep(for: .milliseconds(40))
    controller.splitView.setPosition(800, ofDividerAt: 0)
    try? await Task.sleep(for: .milliseconds(40))
    #expect(controller.splitView.arrangedSubviews[0].frame.width <= 301)
    controller.splitView.setPosition(250, ofDividerAt: 0)
    try? await Task.sleep(for: .milliseconds(40))
    #expect(abs(controller.splitView.arrangedSubviews[0].frame.width - 250) < 2)
}
