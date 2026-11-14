import CoreGraphics
import Testing
@testable import DieterMacKit

/// Pointer coordinates over the letterboxed remote desktop video.
struct RemoteDesktopInputGeometryTests {
    @Test func remoteDesktopInputGeometryExcludesLetterboxingAndUsesTopLeftCoordinates() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        let video = CGSize(width: 1_600, height: 900)
        #expect(
            RemoteDesktopInputGeometry.normalized(
                point: CGPoint(x: 500, y: 100), bounds: bounds, videoSize: video) == nil)
        let topLeft = try #require(
            RemoteDesktopInputGeometry.normalized(
                point: CGPoint(x: 0, y: 781.24), bounds: bounds, videoSize: video))
        #expect(abs(topLeft.x) < 0.0001)
        #expect(abs(topLeft.y) < 0.0001)
        let center = try #require(
            RemoteDesktopInputGeometry.normalized(
                point: CGPoint(x: 500, y: 500), bounds: bounds, videoSize: video))
        #expect(abs(center.x - 0.5) < 0.0001)
        #expect(abs(center.y - 0.5) < 0.0001)
    }
}
