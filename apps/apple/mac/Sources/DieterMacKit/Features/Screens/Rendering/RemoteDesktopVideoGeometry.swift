import Foundation

enum RemoteDesktopVideoGeometry {
    // Coordinates are backing pixels with an AppKit (bottom-left) origin.
    // Integer edges prevent bilinear filtering of an otherwise 1:1 image just
    // because the letterbox has an odd number of pixels to divide between sides.
    static func contentRect(pixelSize: CGSize, videoSize: CGSize) -> CGRect {
        guard valid(pixelSize), valid(videoSize) else { return .zero }
        let width = pixelSize.width.rounded(), height = pixelSize.height.rounded()
        guard width > 0, height > 0 else { return .zero }
        let scale = min(width / videoSize.width, height / videoSize.height)
        let integerScale = floor(scale)
        var fitted = CGSize(
            width: max(1, min(width, (videoSize.width * scale).rounded())),
            height: max(1, min(height, (videoSize.height * scale).rounded())))
        let multiple = CGSize(width: videoSize.width * integerScale, height: videoSize.height * integerScale)
        if integerScale >= 1 && fitted.width - multiple.width <= 2 && fitted.height - multiple.height <= 2 {
            // Even-sized encoder output can leave one or two spare pixels.
            // Compare raster dimensions, avoiding rounding error at exactly two.
            fitted = multiple
        }
        return CGRect(
            x: floor((width - fitted.width) / 2), y: floor((height - fitted.height) / 2),
            width: fitted.width, height: fitted.height)
    }

    private static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
