import AppKit
import SwiftUI
import Testing
@testable import DieterMac

private func writeWorkspaceFreshnessPreview(_ image: NSImage, to path: String) throws {
    guard let data = image.tiffRepresentation,
          let representation = NSBitmapImageRep(data: data),
          let png = representation.representation(using: .png, properties: [:]) else {
        Issue.record("Could not encode workspace freshness preview")
        return
    }
    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
}

@Test @MainActor func renderRefreshingWorkspaceBannerInBothAppearances() throws {
    let lastUpdate = Date().addingTimeInterval(-360)
    for (name, scheme) in [("dark", ColorScheme.dark), ("light", .light)] {
        let preview = ZStack {
            DieterTheme.surface
            WorkspaceFreshnessBanner(
                freshness: .syncing,
                lastSyncedAt: lastUpdate
            )
        }
        .frame(width: 1_146, height: 40)
        .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: preview)
        renderer.proposedSize = .init(width: 1_146, height: 40)
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            Issue.record("Could not render \(name) workspace freshness preview")
            continue
        }
        try writeWorkspaceFreshnessPreview(image, to: "/tmp/dieter-workspace-refreshing-\(name).png")
    }
}
