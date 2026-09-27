import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Stream identity is confined to stateQueue. Shared-display membership is
/// serialized by CaptureRunner's configurationGate, including shutdown.
/// Detaching removes ownership before awaiting the framework/pool callback.
final class CaptureSessionOwner {
    private let stateQueue: DispatchQueue
    private var nativeStream: SCStream?
    private(set) var sharedDisplay: CGDirectDisplayID?
    init(stateQueue: DispatchQueue) { self.stateQueue = stateQueue }

    var stream: SCStream? {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        return nativeStream
    }
    func install(_ stream: SCStream) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        precondition(nativeStream == nil)
        nativeStream = stream
    }
    func takeStream() -> SCStream? {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        let previous = nativeStream
        nativeStream = nil
        return previous
    }
    func attachShared(_ display: CGDirectDisplayID) {
        precondition(sharedDisplay == nil)
        sharedDisplay = display
    }
    func detachShared(streamID: UInt64) async {
        guard let display = sharedDisplay else { return }
        sharedDisplay = nil
        await SharedDisplayPool.shared.remove(display: display, id: streamID)
    }
}
