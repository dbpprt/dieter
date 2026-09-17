import CoreVideo
import Foundation
import Testing
@preconcurrency import WebRTC
@testable import DieterMac

private func renderTestFrame(_ id: Int32) throws -> RTCVideoFrame {
    var pixel: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixel)
    #expect(status == kCVReturnSuccess)
    let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try #require(pixel)), rotation: ._0, timeStampNs: 0)
    frame.timeStamp = id
    return frame
}

@Test func remoteDesktopRenderMailboxReplacesFramesAndRejectsReleasedDecoders() throws {
    let mailbox = RemoteDesktopRenderMailbox()
    let token = mailbox.currentToken
    #expect(mailbox.offer(try renderTestFrame(1), expectedToken: token))
    for id: Int32 in 2...1000 { #expect(!mailbox.offer(try renderTestFrame(id), expectedToken: token)) }
    #expect(mailbox.take()?.0.timeStamp == 1000)
    #expect(mailbox.take() == nil)
    // A reset during GPU use must not grant a second draw ownership.
    let nextToken = mailbox.reset()
    #expect(!mailbox.offer(try renderTestFrame(1001), expectedToken: token))
    #expect(!mailbox.offer(try renderTestFrame(1002), expectedToken: nextToken))
    #expect(mailbox.complete())
    #expect(mailbox.take()?.0.timeStamp == 1002)
    #expect(!mailbox.complete())
    #expect(mailbox.offer(try renderTestFrame(1003), expectedToken: nextToken))
    mailbox.close()
    #expect(!mailbox.offer(try renderTestFrame(1004)))
    #expect(!mailbox.isCurrent(nextToken))
    #expect(mailbox.take() == nil)
}

@Test func remoteDesktopRenderMetricsCoalesceUIAndInvalidateLateGPUCallbacks() throws {
    let stats = RemoteDesktopRenderStatistics()
    let frame = try renderTestFrame(1)
    var wakeups = 0
    for _ in 0..<1000 {
        if stats.update(
            token: 0,
            { state in
                state.framesPresented += 1
                state.presentation = RemoteDesktopPresentation(frame: frame, presentedAt: 12)
            })
        {
            wakeups += 1
        }
    }
    #expect(wakeups == 1)
    #expect(stats.snapshot.framesPresented == 1000)
    #expect(stats.consume().presentation?.frame.timeStamp == 1)
    #expect(stats.consume().presentation == nil)
    stats.reset(token: 1)
    #expect(!stats.update(token: 0, { $0.framesPresented += 1 }))
    #expect(stats.snapshot.framesPresented == 0)
    #expect(stats.update(token: 1, { $0.framesPresented += 1 }))
}

@Test @MainActor func remoteDesktopRenderExecutorProgressesWhileUIIsBusy() throws {
    let executor = RemoteDesktopRenderExecutor()
    defer { executor.stop() }
    let completed = DispatchSemaphore(value: 0)
    let onMain = RenderThreadProbe()
    executor.perform {
        onMain.record(Thread.isMainThread)
        completed.signal()
    }
    // Deliberately block the UI actor: the renderer must not need it to run.
    #expect(completed.wait(timeout: .now() + 2) == .success)
    #expect(onMain.value == false)
}

private final class RenderThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: Bool?
    func record(_ value: Bool) { lock.withLock { recorded = value } }
    var value: Bool? { lock.withLock { recorded } }
}
