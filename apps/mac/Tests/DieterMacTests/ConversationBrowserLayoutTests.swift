import AppKit
import SwiftUI
import Testing
@testable import DieterMac

@Test @MainActor func emptyConversationBrowserPinsItsAddressBarToTheTop() async throws {
    let browser = ConversationBrowserModel()
    let host = NSHostingView(
        rootView: ConversationBrowserView(browser: browser)
            .frame(width: 640, height: 700)
    )
    host.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }

    let address = try #require(await waitForBrowserAddress(in: host))
    let frame = address.convert(address.bounds, to: host)
    let topGap = host.isFlipped ? frame.minY - host.bounds.minY : host.bounds.maxY - frame.maxY

    #expect(topGap >= 0 && topGap < 60)
    #expect(frame.width > host.bounds.width * 0.6)
}

@MainActor private func waitForBrowserAddress(in host: NSView) async -> NSTextField? {
    for _ in 0..<100 {
        host.layoutSubtreeIfNeeded()
        if let field = browserTextFields(in: host).first(where: { $0.placeholderString == "Enter a URL" }) {
            return field
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return nil
}

@MainActor private func browserTextFields(in view: NSView) -> [NSTextField] {
    var values = view.subviews.flatMap { browserTextFields(in: $0) }
    if let field = view as? NSTextField { values.insert(field, at: 0) }
    return values
}
