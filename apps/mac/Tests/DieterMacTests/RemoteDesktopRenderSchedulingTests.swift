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

@Test func remoteDesktopPresentationOwnsGPUAndCompositorIndependently() throws {
    for presentationFirst in [false, true] {
        var ledger = RemoteDesktopPresentationLedger(limit: 1)
        let started = ledger.begin(token: 0, at: 1)
        let first = try #require(started)
        #expect(!ledger.canSubmit)
        if presentationFirst {
            let presented = ledger.presented(first)
            #expect(presented != nil)
            #expect(!ledger.canSubmit, "Presentation must not release GPU ownership")
            let completed = ledger.completedGPU(first)
            #expect(completed)
        } else {
            let completed = ledger.completedGPU(first)
            #expect(completed)
            #expect(!ledger.canSubmit, "GPU completion must not release compositor budget")
            let presented = ledger.presented(first)
            #expect(presented != nil)
        }
        #expect(ledger.canSubmit)
        let completedAgain = ledger.completedGPU(first), presentedAgain = ledger.presented(first)
        #expect(!completedAgain)
        #expect(presentedAgain == nil)
        #expect(ledger.entries.isEmpty)
    }
}

@Test func remoteDesktopPresentationExpiryAndResetNeverReleaseGPU() throws {
    var ledger = RemoteDesktopPresentationLedger(limit: 2)
    let startedFirst = ledger.begin(token: 0, at: 1)
    let first = try #require(startedFirst)
    let completedFirst = ledger.completedGPU(first)
    #expect(completedFirst)
    let startedSecond = ledger.begin(token: 0, at: 1.05)
    let second = try #require(startedSecond)
    let expired = ledger.expire(at: 1.11)
    #expect(expired == 1)
    #expect(ledger.gpuOwner == second)
    ledger.invalidatePresentations()
    #expect(!ledger.canSubmit)
    let oldPresentation = ledger.presented(first), completedSecond = ledger.completedGPU(second)
    #expect(oldPresentation == nil)
    #expect(completedSecond)
    let startedReplacement = ledger.begin(token: 1, at: 1.2)
    let replacement = try #require(startedReplacement)
    let repeatedCompletion = ledger.completedGPU(second)
    #expect(!repeatedCompletion)
    #expect(ledger.gpuOwner == replacement)
    #expect(ledger.entries.count == 1)
}

@Test func remoteDesktopRenderTraceBoundsRecordsAndRejectsLateUpdates() {
    let trace = RemoteDesktopRenderTrace(capacity: 2)
    for id in 1...1000 {
        trace.append(
            RemoteDesktopRenderTraceRecord(
                submission: UInt64(id), epoch: 1, rtpTimestamp: UInt32(id),
                decodedAt: 1, drawableRequestedAt: 1, drawableReadyAt: 2, committedAt: 3))
    }
    trace.update(1) { $0.presentedAt = 99 }
    trace.update(1000) { $0.presentedAt = 4 }
    #expect(trace.snapshot.map(\.submission) == [999, 1000])
    #expect(trace.snapshot.first?.presentedAt == nil)
    #expect(trace.snapshot.last?.presentedAt == 4)
}

@Test func remoteDesktopPresentationCadencePipelinesMotionAndReturnsToIdle() {
    var cadence = RemoteDesktopPresentationCadence()
    cadence.observe(timestamp: 1, at: 1)
    #expect(cadence.budget(at: 1) == 1)
    cadence.observe(timestamp: 2, at: 1.016)
    cadence.observe(timestamp: 2, at: 1.02)  // redraw is not a fresh decoded frame
    #expect(cadence.budget(at: 1.02) == 1)
    cadence.observe(timestamp: 3, at: 1.032)
    #expect(cadence.budget(at: 1.033) == 2)
    #expect(cadence.budget(at: 1.2) == 1)
    cadence.observe(timestamp: 4, at: 2)
    #expect(cadence.budget(at: 2) == 1)
}
