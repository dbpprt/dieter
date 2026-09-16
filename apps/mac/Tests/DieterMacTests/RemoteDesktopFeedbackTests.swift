import DieterAPI
import Foundation
import Testing
@testable import DieterMac

private final class ScreenFeedbackSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Dieter_V1_RemoteDesktopReceiverFeedback] = []
    func append(_ value: Dieter_V1_RemoteDesktopReceiverFeedback) { lock.withLock { samples.append(value) } }
    var values: [Dieter_V1_RemoteDesktopReceiverFeedback] { lock.withLock { samples } }
}

@Test func remoteDesktopHeartbeatsPreserveStatisticsAgeAndIdentity() async throws {
    let samples = ScreenFeedbackSamples()
    let pump = RemoteDesktopFeedbackPump { samples.append($0) }
    var feedback = Dieter_V1_RemoteDesktopReceiverFeedback()
    feedback.protocolVersion = 2
    pump.start(channel: nil, initial: feedback)
    defer { pump.stop() }
    feedback.decodeMs = 100; feedback.framesPerSecond = 30
    pump.update(feedback, measuredAt: ProcessInfo.processInfo.systemUptime - 3)
    try await Task.sleep(for: .milliseconds(1200))
    let repeated = samples.values.filter { $0.measurementSequence == 2 }
    try #require(repeated.count >= 2)
    #expect(repeated.allSatisfy { $0.measurementAgeMs >= 3000 && $0.decodeMs == 100 })
    #expect(repeated.last!.sequence > repeated.first!.sequence)
    #expect(repeated.last!.measurementAgeMs > repeated.first!.measurementAgeMs)
    feedback.decodeMs = 4
    pump.update(feedback)
    try await Task.sleep(for: .milliseconds(600))
    let fresh = try #require(samples.values.last)
    #expect(fresh.measurementSequence == 3)
    #expect(fresh.measurementAgeMs < 1000)
    #expect(fresh.decodeMs == 4)
}
