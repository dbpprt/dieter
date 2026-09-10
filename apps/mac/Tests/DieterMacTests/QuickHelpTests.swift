import AppKit
import SwiftUI
import Testing
@testable import DieterMac

@Suite(.serialized)
@MainActor
struct QuickHelpTests {
    @Test func quickHelpCoversControlsAndDisabledMenusWithoutInterceptingClicks() async throws {
        let root = NSHostingView(rootView: QuickHelpTestContent(buttonHelp: "Attach", menuHelp: "Model", width: 180))
        root.sizingOptions = []
        let window = makeQuickHelpTestWindow(root: root)
        defer { window.close() }
        let settled = await settleQuickHelp(root) { views in
            views.count == 2 && views.allSatisfy { abs($0.bounds.width - 180) < 1 && abs($0.bounds.height - 32) < 1 }
        }
        #expect(settled)

        let views = quickHelpViews(in: root)
        let button = try #require(views.first { $0.title == "Attach" })
        let disabledMenu = try #require(views.first { $0.title == "Model" })
        for view in [button, disabledMenu] {
            #expect(view.window === window)
            #expect(view.toolTip == nil)
            #expect(!view.acceptsFirstResponder)
            #expect(!view.isAccessibilityElement())
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: root.superview)
            let hit = try #require(root.hitTest(point))
            #expect(!(hit is QuickHelpView))
            #expect(!hit.isDescendant(of: view))

            view.mouseEntered(with: try quickHelpEvent(.mouseEntered, in: window))
            // No run-loop yield: hover feedback must be visible immediately.
            let panel = try #require(view.helpWindow)
            #expect(panel.isVisible)
            #expect(panel.parent === window)
            #expect(panel.frame.width > 0 && panel.frame.height > 0)
            view.mouseExited(with: try quickHelpEvent(.mouseExited, in: window))
            #expect(view.helpWindow == nil)
            #expect(!panel.isVisible)
            #expect(panel.parent == nil)
        }
    }

    @Test func quickHelpShowsOnlyOnePanelWithoutTakingFocusAndDismissesOnFocusLoss() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        let first = QuickHelpView(frame: NSRect(x: 20, y: 30, width: 80, height: 28))
        first.title = "Provider"
        let second = QuickHelpView(frame: NSRect(x: 120, y: 30, width: 80, height: 28))
        second.title = "Reasoning"
        let input = NSTextField(frame: NSRect(x: 20, y: 90, width: 240, height: 24))
        input.stringValue = "Keep this draft"
        let controls: [NSView] = [first, second, input]
        controls.forEach { root.addSubview($0) }
        let window = makeQuickHelpTestWindow(root: root, nonactivating: true)
        defer {
            first.dismissHelp()
            second.dismissHelp()
            window.close()
        }
        _ = window.makeFirstResponder(input)
        let originalKey = NSApp.keyWindow
        let originalMain = NSApp.mainWindow
        let originalResponder = window.firstResponder
        let event = try quickHelpEvent(.mouseEntered, in: window)

        first.mouseEntered(with: event)
        let firstPanel = try #require(first.helpWindow)
        #expect(firstPanel.isVisible)
        second.mouseEntered(with: event)
        let secondPanel = try #require(second.helpWindow)
        #expect(secondPanel.isVisible)
        #expect(first.helpWindow == nil)
        #expect(!firstPanel.isVisible && firstPanel.parent == nil)
        #expect(window.childWindows?.count == 1)
        #expect(secondPanel.ignoresMouseEvents)
        #expect(secondPanel.styleMask.contains(.nonactivatingPanel))
        #expect(!secondPanel.canBecomeKey && !secondPanel.canBecomeMain)
        #expect(!secondPanel.isAccessibilityElement())
        #expect(!secondPanel.hidesOnDeactivate)
        #expect(second.trackingAreas.contains { $0.options.contains(.activeAlways) })
        #expect(NSApp.keyWindow === originalKey)
        #expect(NSApp.mainWindow === originalMain)
        #expect(window.firstResponder === originalResponder)
        #expect(input.stringValue == "Keep this draft")

        // Re-entering a control replaces its label instead of leaking a panel.
        second.mouseEntered(with: event)
        let replacement = try #require(second.helpWindow)
        #expect(replacement !== secondPanel)
        #expect(!secondPanel.isVisible && secondPanel.parent == nil)
        #expect(window.childWindows?.count == 1)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(second.helpWindow == nil)
        #expect(!replacement.isVisible && replacement.parent == nil)
        #expect(window.childWindows?.isEmpty != false)
        second.dismissHelp()
        #expect(second.helpWindow == nil)
    }

    @Test func quickHelpUpdatesAndDismissesBeforeItsControlIsRemoved() async throws {
        let root = NSHostingView(rootView: QuickHelpTestContent(buttonHelp: "Attach", menuHelp: "Model", width: 180))
        root.sizingOptions = []
        let window = makeQuickHelpTestWindow(root: root)
        defer { window.close() }
        let initial = await settleQuickHelp(root) { views in
            views.count == 2 && views.allSatisfy { abs($0.bounds.width - 180) < 1 }
        }
        #expect(initial)
        let views = quickHelpViews(in: root)
        let button = try #require(views.first { $0.title == "Attach" })
        let menu = try #require(views.first { $0.title == "Model" })
        button.mouseEntered(with: try quickHelpEvent(.mouseEntered, in: window))
        let originalPanel = try #require(button.helpWindow)
        #expect(originalPanel.isVisible)

        root.rootView = QuickHelpTestContent(buttonHelp: "Upload", menuHelp: "Provider", width: 240)
        let updated = await settleQuickHelp(root) { current in
            current.contains { $0 === button } && current.contains { $0 === menu }
                && button.title == "Upload" && menu.title == "Provider"
                && abs(button.bounds.width - 240) < 1 && abs(menu.bounds.width - 240) < 1
                && button.helpWindow == nil
        }
        #expect(updated)
        #expect(!originalPanel.isVisible && originalPanel.parent == nil)
        #expect(button.toolTip == nil && menu.toolTip == nil)

        menu.mouseEntered(with: try quickHelpEvent(.mouseEntered, in: window))
        let removedPanel = try #require(menu.helpWindow)
        #expect(removedPanel.isVisible)
        root.rootView = QuickHelpTestContent(buttonHelp: "", menuHelp: "", width: 240, includesHelp: false)
        let removed = await settleQuickHelp(root) { current in
            current.isEmpty && button.window == nil && menu.window == nil && menu.helpWindow == nil
        }
        #expect(removed)
        #expect(!removedPanel.isVisible && removedPanel.parent == nil)
        #expect(window.childWindows?.isEmpty != false)
    }

    @Test func metadataHelpWrapsWithinItsMaximumWidthWithoutInterceptingInteraction() async throws {
        let details = "Codex · GPT-5.6-Sol · Xhigh reasoning · Fast mode · Worktree · 42,000 tokens used"
        let root = NSHostingView(
            rootView: QuickHelpTestContent(
                buttonHelp: details, menuHelp: "Model", width: 180, maximumHelpWidth: 240))
        root.sizingOptions = []
        let window = makeQuickHelpTestWindow(root: root)
        defer { window.close() }
        let settled = await settleQuickHelp(root) { views in
            views.contains { $0.title == details && $0.maximumWidth == 240 }
        }
        #expect(settled)
        let view = try #require(quickHelpViews(in: root).first { $0.title == details })
        view.mouseEntered(with: try quickHelpEvent(.mouseEntered, in: window))
        let panel = try #require(view.helpWindow)
        #expect(panel.isVisible)
        #expect(panel.frame.width <= 240)
        #expect(panel.frame.height > 40)
        #expect(panel.ignoresMouseEvents)
        #expect(view.hitTest(.zero) == nil)
        #expect(view.toolTip == nil)

        // Changing the width retires the old panel; short labels remain content-sized.
        view.maximumWidth = nil
        #expect(view.helpWindow == nil)
        #expect(!panel.isVisible)
        view.title = "Model"
        view.mouseEntered(with: try quickHelpEvent(.mouseEntered, in: window))
        let shortPanel = try #require(view.helpWindow)
        #expect(shortPanel.frame.width < 100)
        #expect(shortPanel.frame.height < 40)
        view.dismissHelp()
    }
}

private struct QuickHelpTestContent: View {
    let buttonHelp: String
    let menuHelp: String
    let width: CGFloat
    var includesHelp = true
    var maximumHelpWidth: CGFloat?

    var body: some View {
        VStack(spacing: 20) {
            if includesHelp {
                attachButton.quickHelp(buttonHelp, maximumWidth: maximumHelpWidth)
                modelMenu.quickHelp(menuHelp)
            } else {
                attachButton
                modelMenu
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var attachButton: some View {
        Button("Attach") {}.frame(width: width, height: 32)
    }

    private var modelMenu: some View {
        Menu("Model") { Button("Default") {} }.frame(width: width, height: 32).disabled(true)
    }
}

@MainActor
private func makeQuickHelpTestWindow(root: NSView, nonactivating: Bool = false) -> NSWindow {
    let frame = NSRect(x: -2_000, y: -2_000, width: 420, height: 200)
    let window: NSWindow =
        nonactivating
        ? NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        : NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root
    window.setContentSize(NSSize(width: 420, height: 200))
    // Visibility permits hover presentation; ordering behind does not activate
    // the test app or displace the operator's key window.
    window.orderBack(nil)
    return window
}

@MainActor
private func quickHelpEvent(_ type: NSEvent.EventType, in window: NSWindow) throws -> NSEvent {
    try #require(
        NSEvent.enterExitEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
}

@MainActor
private func settleQuickHelp(_ root: NSView, until condition: ([QuickHelpView]) -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        root.layoutSubtreeIfNeeded()
        if condition(quickHelpViews(in: root)) { return true }
        try? await DieterTaskSleep.milliseconds(20)
    }
    root.layoutSubtreeIfNeeded()
    return condition(quickHelpViews(in: root))
}

@MainActor
private func quickHelpViews(in root: NSView) -> [QuickHelpView] {
    var pending = [root]
    var result: [QuickHelpView] = []
    while let view = pending.popLast() {
        if let help = view as? QuickHelpView { result.append(help) }
        pending.append(contentsOf: view.subviews)
    }
    return result
}
