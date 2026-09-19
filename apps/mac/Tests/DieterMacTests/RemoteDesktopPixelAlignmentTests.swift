import AppKit
import CoreVideo
import Testing
@preconcurrency import WebRTC
@testable import DieterMac

// Capture only the disposable window. This checks actual Metal/compositor pixels,
// including redraw of an idle desktop after resize, rather than geometry alone.
@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["DIETER_TEST_SCREEN_FIXTURE"] != nil,
        "Requires the disposable native screen fixture"))
@MainActor func remoteDesktopPixelAlignmentSurvivesOddWindowResizes() async throws {
    let output = FileManager.default.temporaryDirectory.appending(path: "dieter-pixel-alignment-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = NSWindow(
        contentRect: CGRect(x: 80, y: 80, width: 640, height: 360),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.hasShadow = false
    let controller = RemoteDesktopController()
    let surface = RemoteDesktopInputView(renderer: controller.renderer, controller: controller)
    let container = NSView()
    window.contentView = container
    container.addSubview(surface)
    window.orderFrontRegardless()
    app.activate(ignoringOtherApps: true)
    defer {
        controller.disconnect()
        window.close()
        print("Pixel alignment evidence: \(output.path)")
    }
    #expect(controller.renderer.initializationFailure == nil)
    let scale = window.backingScaleFactor
    var samples: [[String: Any]] = []
    for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
        controller.renderer.reset()
        let pixel = try alignmentPattern(format: format)
        for (index, size) in [
            CGSize(width: 640, height: 360), CGSize(width: 641, height: 360),
            CGSize(width: 641, height: 361), CGSize(width: 642, height: 362),
            CGSize(width: 641, height: 361),
        ].enumerated() {
            let before = controller.renderer.drawSubmissions
            // SwiftUI can place the native view at a fractional backing origin.
            let offset: CGFloat = index == 4 ? 0.25 : 0
            let canvas = CGSize(width: size.width + ceil(offset), height: size.height + ceil(offset))
            window.setContentSize(CGSize(width: canvas.width / scale, height: canvas.height / scale))
            surface.frame = CGRect(
                x: offset / scale, y: offset / scale,
                width: size.width / scale, height: size.height / scale)
            surface.layoutSubtreeIfNeeded(); surface.layout()
            if index == 0 {
                controller.renderer.renderFrame(
                    RTCVideoFrame(
                        buffer: RTCCVPixelBuffer(pixelBuffer: pixel),
                        rotation: ._0, timeStampNs: Int64(format)))
            }
            let deadline = Date().addingTimeInterval(5)
            while (controller.renderer.drawSubmissions <= before || controller.renderer.framesPresented == 0),
                Date() < deadline
            {
                try await Task.sleep(for: .milliseconds(25))
            }
            try #require(controller.renderer.drawSubmissions > before)
            try #require(controller.renderer.framesPresented > 0)
            // The resize redraw keeps the same frame identity. Allow its
            // compositor transaction to settle before reading the window.
            try await Task.sleep(for: .milliseconds(200))
            #expect(controller.renderer.drawablePixelSize == size)
            let actual = container.convertToBacking(container.convert(surface.videoContentRect, from: surface))
            let expected = RemoteDesktopVideoGeometry.contentRect(
                pixelSize: size, videoSize: CGSize(width: 640, height: 360))
            #expect(actual == expected, "Input and Metal must use the same backing pixels")
            let path = output.appending(path: "\(format)-\(Int(size.width))x\(Int(size.height))-\(index).png")
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), path.path]
            try capture.run()
            let captureDeadline = Date().addingTimeInterval(5)
            while capture.isRunning, Date() < captureDeadline { try await Task.sleep(for: .milliseconds(25)) }
            if capture.isRunning { capture.terminate() }
            try #require(!capture.isRunning && capture.terminationStatus == 0)
            let image = try #require(NSBitmapImageRep(data: Data(contentsOf: path)))
            try #require(image.pixelsWide == Int(canvas.width) && image.pixelsHigh == Int(canvas.height))
            var black = 0.0, white = 0.0
            for x in 100..<164 {
                let color = try #require(
                    image.colorAt(x: Int(expected.minX) + x, y: image.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
                if x % 2 == 0 { black += color.redComponent / 32 } else { white += color.redComponent / 32 }
            }
            #expect(
                black < 0.15 && white > 0.85,
                "One-pixel stripes were blurred: black=\(black), white=\(white), size=\(size), format=\(format)")
            samples.append([
                "format": format, "width": size.width, "height": size.height,
                "backingScale": scale, "originOffset": offset, "black": black, "white": white,
            ])
        }
    }
    try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appending(path: "contrast.json"))
}

private func alignmentPattern(format: OSType) throws -> CVPixelBuffer {
    var pixel: CVPixelBuffer?
    let attributes: [String: Any] = [
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
    try #require(CVPixelBufferCreate(nil, 640, 360, format, attributes as CFDictionary, &pixel) == kCVReturnSuccess)
    let buffer = try #require(pixel)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if format == kCVPixelFormatType_32BGRA {
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<360 {
            for x in 0..<640 {
                let offset = y * stride + x * 4
                let value: UInt8 = x % 2 == 0 ? 0 : 255
                base[offset] = value; base[offset + 1] = value; base[offset + 2] = value; base[offset + 3] = 255
            }
        }
    } else {
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<360 { for x in 0..<640 { base[y * stride + x] = x % 2 == 0 ? 16 : 235 } }
        memset(
            CVPixelBufferGetBaseAddressOfPlane(buffer, 1), 128,
            CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
    }
    return buffer
}
