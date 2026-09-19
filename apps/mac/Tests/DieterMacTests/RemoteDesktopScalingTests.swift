import AppKit
import Testing
@testable import DieterMac

@Test func remoteDesktopRequestsSettledBackingPixelsWithoutCoarseUpscaling() {
    let expected = CGSize(width: 1000, height: 600)
    #expect(RemoteDesktopVideoGeometry.requestedSize(points: CGSize(width: 1001, height: 600), scale: 1) == expected)
    #expect(RemoteDesktopVideoGeometry.requestedSize(points: CGSize(width: 500.5, height: 300), scale: 2) == expected)
    #expect(
        RemoteDesktopVideoGeometry.requestedSize(points: CGSize(width: 832, height: 468), scale: 1)
            == CGSize(width: 832, height: 468))
    #expect(
        RemoteDesktopVideoGeometry.requestedSize(points: CGSize(width: 100, height: 100), scale: 1)
            == CGSize(width: 640, height: 360))
    #expect(
        RemoteDesktopVideoGeometry.requestedSize(points: CGSize(width: 4000, height: 3000), scale: 2)
            == CGSize(width: 3840, height: 2160))
    for scale: CGFloat in [0, -1, .nan, .infinity] {
        #expect(RemoteDesktopVideoGeometry.requestedSize(points: expected, scale: scale) == nil)
    }
    for size in [CGSize.zero, CGSize(width: CGFloat.infinity, height: 600), CGSize(width: 1000, height: CGFloat.nan)] {
        #expect(RemoteDesktopVideoGeometry.requestedSize(points: size, scale: 1) == nil)
        #expect(RemoteDesktopVideoGeometry.contentRect(pixelSize: size, videoSize: expected) == .zero)
    }
}

@Test func remoteDesktopOddLetterboxesPreservePixelAlignment() {
    let video = CGSize(width: 640, height: 360)
    for pixels in [video, CGSize(width: 641, height: 360), CGSize(width: 641, height: 361)] {
        #expect(
            RemoteDesktopVideoGeometry.contentRect(pixelSize: pixels, videoSize: video)
                == CGRect(origin: .zero, size: video))
    }
    #expect(
        RemoteDesktopVideoGeometry.contentRect(pixelSize: CGSize(width: 642, height: 362), videoSize: video)
            == CGRect(x: 1, y: 1, width: 640, height: 360))
    #expect(
        RemoteDesktopVideoGeometry.contentRect(pixelSize: CGSize(width: 1281, height: 721), videoSize: video)
            == CGRect(x: 0, y: 0, width: 1280, height: 720))
}

@Test func remoteDesktopAspectFitStaysBoundedAcrossPortraitAndFractionalSizes() {
    for video in [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1920)] {
        for pixels in [
            CGSize(width: 833, height: 469), CGSize(width: 1201, height: 701), CGSize(width: 500, height: 901),
        ] {
            let rect = RemoteDesktopVideoGeometry.contentRect(pixelSize: pixels, videoSize: video)
            #expect(CGRect(origin: .zero, size: pixels).contains(rect))
            for edge in [rect.minX, rect.minY, rect.maxX, rect.maxY] { #expect(edge == edge.rounded()) }
            let idealScale = min(pixels.width / video.width, pixels.height / video.height)
            #expect(abs(rect.width - video.width * idealScale) <= 0.5)
            #expect(abs(rect.height - video.height * idealScale) <= 0.5)
        }
    }
}

@Test func remoteDesktopInputUsesTheAlignedImageIncludingRetinaAndLetterboxes() {
    let pixels = RemoteDesktopVideoGeometry.contentRect(
        pixelSize: CGSize(width: 643, height: 363), videoSize: CGSize(width: 640, height: 360))
    for scale: CGFloat in [1, 2] {
        let rect = CGRect(
            x: pixels.minX / scale, y: pixels.minY / scale,
            width: pixels.width / scale, height: pixels.height / scale)
        #expect(
            RemoteDesktopInputGeometry.normalized(point: CGPoint(x: rect.midX, y: rect.midY), content: rect)
                == CGPoint(x: 0.5, y: 0.5))
        #expect(
            RemoteDesktopInputGeometry.normalized(
                point: CGPoint(x: rect.minX, y: rect.maxY), content: rect, clamp: true)
                == .zero)
        #expect(
            RemoteDesktopInputGeometry.normalized(
                point: CGPoint(x: rect.maxX, y: rect.minY), content: rect, clamp: true)
                == CGPoint(x: 1, y: 1))
        #expect(
            RemoteDesktopInputGeometry.normalized(point: CGPoint(x: rect.minX - 0.1, y: rect.midY), content: rect)
                == nil)
    }
}
