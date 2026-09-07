import AppKit
import DieterAPI
import SwiftUI
import Testing
@testable import DieterMac

@Test @MainActor func outsideSheetClickOnlyDismissesAnUnchangedDraftInItsParent() {
    let frame = NSRect(x: 100, y: 100, width: 620, height: 600)
    #expect(OutsideClickSheetView.shouldDismiss(enabled: true, belongsToParent: true, point: .zero, sheetFrame: frame))
    #expect(!OutsideClickSheetView.shouldDismiss(enabled: false, belongsToParent: true, point: .zero, sheetFrame: frame))
    #expect(!OutsideClickSheetView.shouldDismiss(enabled: true, belongsToParent: false, point: .zero, sheetFrame: frame))
    #expect(!OutsideClickSheetView.shouldDismiss(enabled: true, belongsToParent: true, point: NSPoint(x: 200, y: 200), sheetFrame: frame))
}

@Test @MainActor func editCardSheetFitsSmallScreensWithScrollableFields() throws {
    DieterTheme.install(palette: .monochrome, colorScheme: .dark)
    defer { DieterTheme.install(palette: .monochrome, colorScheme: .light) }
    var card = Dieter_V1_Card()
    card.title = "Edit a task with a long title and detailed instructions"
    card.initialPrompt = String(repeating: "Keep the task editor usable on a smaller screen.\n", count: 8)
    card.workspaceMode = "worktree"
    card.workspaceBaseBranch = "main"
    for height in [600.0, 900.0] {
        let content = EditCardSheet(card: card, availableHeight: height)
            .environment(DieterStore())
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        #expect(size.height <= height - 80)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/dieter-edit-card-\(Int(height)).png"))
    }
}
