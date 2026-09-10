import AppKit
import SwiftUI
import Testing
@testable import DieterMac

@Test @MainActor func nativeHelpRegistersForButtonsAndDisabledMenusWithoutInterceptingClicks() async throws {
    let root = NSHostingView(
        rootView: NativeHelpTestContent(buttonHelp: "Attach a file", menuHelp: "Choose the model", width: 180))
    root.sizingOptions = []
    let window = makeNativeHelpTestWindow(root: root)
    defer { window.close() }
    let settled = await settleNativeHelp(root) { views in
        views.count == 2 && views.allSatisfy { abs($0.bounds.width - 180) < 1 && abs($0.bounds.height - 32) < 1 }
    }
    #expect(settled)

    let registered = nativeHelpViews(in: root)
    #expect(registered.count == 2)
    let button = try #require(registered.first { $0.toolTip == "Attach a file" })
    let disabledMenu = try #require(registered.first { $0.toolTip == "Choose the model" })
    for view in [button, disabledMenu] {
        #expect(view.window === window)
        #expect(abs(view.bounds.width - 180) < 1)
        #expect(abs(view.bounds.height - 32) < 1)
        #expect(!view.acceptsFirstResponder)
        #expect(!view.isAccessibilityElement())

        let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        let point = view.convert(center, to: root.superview)
        let hit = try #require(root.hitTest(point))
        #expect(!(hit is NativeHelpView))
        #expect(!hit.isDescendant(of: view))
    }
    #expect(!window.isVisible)
}

@Test @MainActor func nativeHelpUpdatesWithSwiftUILayoutAndClearsWhenRemoved() async throws {
    let root = NSHostingView(
        rootView: NativeHelpTestContent(buttonHelp: "Attach a file", menuHelp: "Choose the model", width: 180))
    root.sizingOptions = []
    let window = makeNativeHelpTestWindow(root: root)
    defer { window.close() }
    let initiallyRegistered = await settleNativeHelp(root) { views in
        views.count == 2 && views.allSatisfy { abs($0.bounds.width - 180) < 1 && $0.toolTip?.isEmpty == false }
    }
    #expect(initiallyRegistered)
    let original = nativeHelpViews(in: root)
    let button = try #require(original.first { $0.toolTip == "Attach a file" })
    let menu = try #require(original.first { $0.toolTip == "Choose the model" })

    root.rootView = NativeHelpTestContent(
        buttonHelp: "Upload a file or take a screenshot", menuHelp: "Model is unavailable during this turn", width: 240)
    let refreshed = await settleNativeHelp(root) { views in
        views.contains { $0 === button } && views.contains { $0 === menu }
            && button.toolTip == "Upload a file or take a screenshot"
            && menu.toolTip == "Model is unavailable during this turn"
            && abs(button.bounds.width - 240) < 1 && abs(menu.bounds.width - 240) < 1
    }
    #expect(refreshed)
    let updated = nativeHelpViews(in: root)
    #expect(updated.contains { $0 === button })
    #expect(updated.contains { $0 === menu })
    #expect(button.toolTip == "Upload a file or take a screenshot")
    #expect(menu.toolTip == "Model is unavailable during this turn")
    #expect(abs(button.bounds.width - 240) < 1)
    #expect(abs(menu.bounds.width - 240) < 1)
    #expect(button.window === window)
    #expect(menu.window === window)

    root.rootView = NativeHelpTestContent(buttonHelp: "", menuHelp: "", width: 240, includesHelp: false)
    let removed = await settleNativeHelp(root) { views in
        views.isEmpty && button.toolTip == nil && menu.toolTip == nil && button.window == nil && menu.window == nil
    }
    #expect(removed)
    #expect(nativeHelpViews(in: root).isEmpty)
    #expect(button.toolTip == nil)
    #expect(menu.toolTip == nil)
    #expect(button.window == nil)
    #expect(menu.window == nil)
}

private struct NativeHelpTestContent: View {
    let buttonHelp: String
    let menuHelp: String
    let width: CGFloat
    var includesHelp = true

    var body: some View {
        VStack(spacing: 20) {
            if includesHelp {
                attachButton.nativeHelp(buttonHelp)
                modelMenu.nativeHelp(menuHelp)
            } else {
                attachButton
                modelMenu
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var attachButton: some View {
        Button("Attach") {}
            .frame(width: width, height: 32)
    }

    private var modelMenu: some View {
        Menu("Model") { Button("Default") {} }
            .frame(width: width, height: 32)
            .disabled(true)
    }
}

@MainActor
private func makeNativeHelpTestWindow(root: NSView) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root
    window.setContentSize(NSSize(width: 420, height: 200))
    return window
}

@MainActor
private func settleNativeHelp(_ root: NSView, until condition: ([NativeHelpView]) -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        root.layoutSubtreeIfNeeded()
        if condition(nativeHelpViews(in: root)) { return true }
        try? await DieterTaskSleep.milliseconds(20)
    }
    root.layoutSubtreeIfNeeded()
    return condition(nativeHelpViews(in: root))
}

@MainActor
private func nativeHelpViews(in root: NSView) -> [NativeHelpView] {
    var pending = [root]
    var result: [NativeHelpView] = []
    while let view = pending.popLast() {
        if let help = view as? NativeHelpView { result.append(help) }
        pending.append(contentsOf: view.subviews)
    }
    return result
}
