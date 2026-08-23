import AppKit
import Foundation
import DieterAPI
import SwiftUI
import Testing
@testable import DieterMac

// Temporary visual-verification harness: renders the menu bar icon and popover to /tmp PNGs.

private func isoDate(secondsAgo: TimeInterval) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date().addingTimeInterval(-secondsAgo))
}

private func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    NSImage(size: image.size, flipped: false) { rect in
        image.draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

private func writePNG(_ image: NSImage, scale: CGFloat, to path: String) throws {
    let size = image.size
    let pixelWide = Int(size.width * scale)
    let pixelHigh = Int(size.height * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelWide, pixelsHigh: pixelHigh, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0,
    ) else { Issue.record("Could not create bitmap rep"); return }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        Issue.record("Could not encode PNG"); return
    }
    try data.write(to: URL(fileURLWithPath: path))
}

@Test @MainActor func renderMenuBarIconPreview() throws {
    let icon = MenuBarIcon.template
    let canvas = NSImage(size: NSSize(width: 120, height: 60), flipped: false) { _ in
        NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.16, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 60, height: 60).fill()
        NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
        NSRect(x: 60, y: 0, width: 60, height: 60).fill()
        tinted(icon, .white).draw(in: NSRect(x: 12, y: 12, width: 36, height: 36))
        tinted(icon, .black).draw(in: NSRect(x: 72, y: 12, width: 36, height: 36))
        return true
    }
    try writePNG(canvas, scale: 4, to: "/tmp/dieter-menubar-icon.png")
}

@Test @MainActor func renderMenuBarPopoverPreview() throws {
    let store = DieterStore()
    store.phase = .connected(version: "1.0.0")

    let miniHome = DieterEndpoint(name: "mac-mini", host: "100.121.53.82", port: 4242, daemonID: "d1", online: true)
    let laptop = DieterEndpoint(name: "macbook-pro", host: "192.168.254.70", port: 4242, daemonID: "d2", online: false, lastSeenAt: isoDate(secondsAgo: 7_200))
    store.endpoints = [miniHome, laptop]
    store.endpoint = miniHome
    store.machineConnectionStatuses[miniHome.id] = MachineConnectionStatus(route: .local, latencyMilliseconds: 23)

    var boardOne = Dieter_V1_Board(); boardOne.id = "b1"; boardOne.name = "Agent workspace"
    var boardTwo = Dieter_V1_Board(); boardTwo.id = "b2"; boardTwo.name = "Main"
    store.state.boards = [boardOne, boardTwo]

    var review = Dieter_V1_Card()
    review.id = "c1"; review.title = "Lets understand the code"; review.lane = "review"; review.boardID = "b1"
    review.runtimeUpdatedAt = isoDate(secondsAgo: 18 * 60)
    var finished = Dieter_V1_Card()
    finished.id = "c2"; finished.title = "start 3 sub agents for testing"; finished.lane = "done"; finished.boardID = "b2"
    finished.runtime = "completed"; finished.runtimeUpdatedAt = isoDate(secondsAgo: 2 * 60)
    store.state.cards = [review, finished]

    var chat = Dieter_V1_Card()
    chat.id = "c3"; chat.title = "Standalone chat"; chat.runtime = "running"
    chat.activeSubagents = [Dieter_V1_Subagent(), Dieter_V1_Subagent(), Dieter_V1_Subagent()]
    store.chats = [chat]

    let renderer = ImageRenderer(content: MenuBarContent().environment(store))
    renderer.scale = 2
    guard let image = renderer.nsImage else { Issue.record("ImageRenderer produced no image"); return }
    try writePNG(image, scale: 2, to: "/tmp/dieter-menubar-popover.png")
}
