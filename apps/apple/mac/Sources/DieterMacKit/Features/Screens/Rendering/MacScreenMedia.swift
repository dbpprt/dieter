import AppKit
import DieterCore
import DieterPlatform
import DieterTransport
import Foundation
import Metal
@preconcurrency import WebRTC

/// The Mac's screen renderer: the Metal view draws every decoded frame.
extension RemoteDesktopMetalView: ScreenRenderer {
    nonisolated var presentationCounters: ScreenPresentationCounters {
        let snapshot = renderSnapshot
        return ScreenPresentationCounters(
            framesPresented: snapshot.framesPresented, totalRenderMilliseconds: snapshot.totalRenderMilliseconds)
    }
}

extension CoreScreenMedia {
    /// The Mac's engine: screens need Metal.
    static func mac() -> CoreScreenMedia {
        CoreScreenMedia { MTLCreateSystemDefaultDevice() == nil ? "Metal is unavailable on this Mac." : nil }
    }
}
