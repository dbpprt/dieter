import Foundation
import SwiftUI
import Testing
@testable import DieterMac

@Test func activityIndicatorDoesNotOwnATimeline() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sourceURL = packageRoot.appendingPathComponent("Sources/DieterMac/UI/DieterTheme.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    let start = try #require(source.range(of: "struct DieterActivityIndicator: View"))
    let end = try #require(source.range(
        of: "struct DieterIconButtonStyle: ButtonStyle",
        range: start.upperBound..<source.endIndex
    ))
    let implementation = source[start.lowerBound..<end.lowerBound]

    #expect(!implementation.contains("TimelineView"))
    #expect(implementation.contains("ProgressView"))
}

@Test @MainActor func aLargeRunningIndicatorFixtureRendersInBothAppearances() {
    let columns = Array(repeating: GridItem(.fixed(12), spacing: 3), count: 10)

    for scheme in [ColorScheme.light, .dark] {
        let fixture = LazyVGrid(columns: columns, spacing: 3) {
            ForEach(0..<100, id: \.self) { _ in
                DieterActivityIndicator()
            }
        }
        .padding(8)
        .background(DieterTheme.background)
        .preferredColorScheme(scheme)
        let renderer = ImageRenderer(content: fixture)
        renderer.proposedSize = .init(width: 166, height: 166)

        #expect(renderer.nsImage != nil)
    }
}
