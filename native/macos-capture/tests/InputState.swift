import CoreGraphics
import Foundation

@main struct InputStateTest {
    static func main() async throws {
        try testDisplayModeLeases()
        let damageBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        precondition(captureChangedFraction(rects: [], bounds: damageBounds) == 0)
        precondition(captureChangedFraction(rects: [CGRect(x: 200, y: 0, width: 50, height: 50)], bounds: damageBounds) == nil,
            "Out-of-space damage cannot suppress a frame")
        precondition(captureChangedFraction(rects: [CGRect(x: 0, y: 0, width: 50, height: 50)], bounds: damageBounds) == 0.25)
        precondition(captureChangedFraction(rects: [], bounds: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)) == nil)
        var recovery = CaptureRecoverySchedule()
        precondition(recovery.request(now: 1_000_000_000, windowMS: 50, referenceAvailable: true, pending: false) == true)
        precondition(recovery.request(now: 1_010_000_000, windowMS: 50, referenceAvailable: true, pending: true) == nil)
        precondition(recovery.request(now: 1_050_000_000, windowMS: 50, referenceAvailable: true, pending: true) == false)
        precondition(recovery.request(now: 1_100_000_000, windowMS: 50, referenceAvailable: false, pending: false) == nil,
            "Repeated loss must not produce an IDR storm")
        precondition(recovery.request(now: 1_250_000_000, windowMS: 50, referenceAvailable: false, pending: false) == false)
        precondition(recovery.request(now: 1_300_000_000, windowMS: 50, referenceAvailable: true, pending: false) == true)
        precondition(recovery.referenceDeadline == 1_450_000_000, "Fallback must preserve the IDR throttle")
        precondition(!recovery.expireReference(now: 1_449_999_999))
        precondition(recovery.expireReference(now: 1_450_000_000))
        precondition(!recovery.expireReference(now: 1_450_000_001), "Only one fallback per episode")
        precondition(recovery.request(now: 1_450_000_000, windowMS: 50, referenceAvailable: false, pending: true) == false)
        precondition(recovery.request(now: 1_700_000_000, windowMS: 250, referenceAvailable: true, pending: false) == true)
        precondition(recovery.producedReference(now: 1_800_000_000))
        precondition(recovery.referenceDeadline == 2_050_000_000)
        precondition(!recovery.producedReference(now: 1_900_000_000), "One output cannot repeatedly extend ACK admission")
        precondition(recovery.referenceDeadline == 2_050_000_000)
        precondition(!recovery.expireReference(now: 2_049_999_999))
        recovery.acknowledgeRecovery()
        precondition(!recovery.expireReference(now: 2_100_000_000), "Decoded ACK cancels escalation")
        precondition(EncoderBurstEnvelope(milliseconds: 250).byteLimit(kbps: 12000) == 562500)
        precondition(EncoderBurstEnvelope(milliseconds: -1).seconds == 1)
        var burstAttempts = 0
        let fallback = EncoderBurstEnvelope(milliseconds: 250).apply(kbps: 12000) { _ in
            burstAttempts += 1; return burstAttempts == 1 ? -1 : 0
        }
        precondition(burstAttempts == 2 && fallback.contains("burst=1.0s") && fallback.contains("burstFallback=-1"))
        burstAttempts = 0
        let rejected = EncoderBurstEnvelope(milliseconds: 250).apply(kbps: 12000) { _ in burstAttempts += 1; return -1 }
        precondition(burstAttempts == 2 && rejected.contains("burst=unsupported"))
        burstAttempts = 0
        _ = EncoderBurstEnvelope(milliseconds: nil).apply(kbps: 12000) { _ in burstAttempts += 1; return -1 }
        precondition(burstAttempts == 1, "Do not retry an already rejected ordinary envelope")
        var credits = CaptureFrameCredits()
        precondition(credits.produced(id: 1, generation: 1, bytes: 1000))
        precondition(!credits.canEncode(generation: 1, now: 1, frameAge: 0, encodeEstimate: 1))
        credits.sending(id: 1, generation: 1, now: 1, budgetMS: 30)
        precondition(credits.canEncode(generation: 1, now: 1, frameAge: 0, encodeEstimate: 1))
        precondition(credits.produced(id: 2, generation: 1, bytes: 1000))
        precondition(!credits.canEncode(generation: 1, now: 1, frameAge: 0, encodeEstimate: 1))
        precondition(!credits.produced(id: 3, generation: 1, bytes: 1000))
        precondition(!credits.consumed(id: 1, generation: 2))
        precondition(credits.consumed(id: 1, generation: 1))
        precondition(!credits.consumed(id: 1, generation: 1))
        precondition(!credits.canEncode(generation: 1, now: 1, frameAge: 0, encodeEstimate: 1), "Consumption cannot invent another send-start token")
        credits.sending(id: 2, generation: 1, now: 1, budgetMS: 30)
        credits.sending(id: 2, generation: 1, now: 40_000_000, budgetMS: 30)
        precondition(!credits.canEncode(generation: 1, now: 40_000_000, frameAge: 0, encodeEstimate: 1), "Duplicate send-start extended admission")
        precondition(!credits.canEncode(generation: 2, now: 2, frameAge: 0, encodeEstimate: 1))
        let liveness = NativeDaemonLiveness(now: 0)
        precondition(liveness.timeoutDiagnostic(now: 3_000_000_000) == nil)
        liveness.receive("frame_consumed", now: 2_900_000_000)
        precondition(
            liveness.timeoutDiagnostic(now: 5_000_000_000) == nil,
            "Live command traffic must prevent an idle-heartbeat timeout")
        precondition(
            liveness.timeoutDiagnostic(now: 6_000_000_000)?.contains("lastCommand=frame_consumed") == true,
            "A silent owner must still expire and retain the last command kind")
        liveness.receive("heartbeat", now: 6_000_000_000)
        precondition(liveness.timeoutDiagnostic(now: 6_100_000_000) == nil)
        let input = InputInjector(bounds: CGRect(x: -1280, y: 0, width: 1280, height: 720), dryRun: true)
        var value = NativeInput(); value.kind = "key"; value.physicalKey = 4; value.generation = 1
        value.down = true; try input.handle(value)
        precondition(input.heldKeys == [0])
        value.down = false; try input.handle(value)
        precondition(input.heldKeys.isEmpty)
        for usage: UInt32 in [225, 229] {
            value.physicalKey = usage; value.down = true; value.modifiers = 1; try input.handle(value)
        }
        value.physicalKey = 225; value.down = false; try input.handle(value)
        precondition(input.heldKeys == [60])
        value.kind = "pointer_button"; value.button = 1; value.x = 0; value.y = 0; value.down = true
        try input.handle(value)
        precondition(input.position == CGPoint(x: -1280, y: 0))
        value.kind = "pointer_move"; value.x = 1_000_000; value.y = 1_000_000; try input.handle(value)
        precondition(input.position.x < 0 && input.position.y < 720 && input.heldButtons == [1])
        input.releaseAll()
        precondition(input.heldKeys.isEmpty && input.heldButtons.isEmpty)
        input.update(bounds: CGRect(x: 0, y: 0, width: 1600, height: 900), generation: 2)
        do { try input.handle(value); preconditionFailure("stale display accepted") } catch {}
        let first = InputInjector(bounds: CGRect(x: 0, y: 0, width: 100, height: 100), dryRun: true)
        let second = InputInjector(bounds: CGRect(x: 0, y: 0, width: 100, height: 100), dryRun: true)
        var held = NativeInput(); held.kind = "key"; held.physicalKey = 4; held.down = true; held.generation = 1
        try SharedInputAuthority.shared.handle(held, injector: first)
        SharedInputAuthority.shared.remove(second)
        precondition(first.heldKeys == [0], "Spectator teardown released the controller")
        try SharedInputAuthority.shared.handle(held, injector: second)
        precondition(first.heldKeys.isEmpty && second.heldKeys == [0], "Encoder move left held keys behind")
        held.kind = "release_all"
        try SharedInputAuthority.shared.handle(held, injector: first)
        precondition(second.heldKeys.isEmpty, "Handoff must release the machine's active injector")
        let queue = NativeCommandQueue(capacity: 2)
        let gate = CommandTestGate()
        precondition(queue.submit { await gate.wait() })
        for _ in 0..<200 {
            if await gate.entered { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let entered = await gate.entered
        precondition(entered)
        precondition(queue.submit { await gate.finish() })
        precondition(!queue.submit { preconditionFailure("unbounded native command queue") })
        await gate.release()
        for _ in 0..<200 {
            if await gate.finished { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let finished = await gate.finished
        precondition(finished)
        queue.close()
        precondition(!queue.submit { preconditionFailure("stopped native command queue") })
        let configurationGate = ConfigurationGate()
        await configurationGate.shutdown()
        do {
            try await configurationGate.acquire()
            preconditionFailure("stopped capture accepted configuration")
        } catch {
            precondition(error.localizedDescription == "native capture rendition stopped")
        }
        let stoppedRunner = CaptureRunner(options: CaptureOptions())
        await stoppedRunner.stopAndWait()
        let finalCredit = NativeCommand(
            version: CaptureContract.version, id: 1, kind: "frame_consumed", input: nil,
            configuration: nil, frameId: 1, streamId: nil, profile: nil, codec: nil)
        stoppedRunner.enqueue(finalCredit) { error in
            precondition(error == "native capture rendition stopped", "Final frame credit lost shutdown cause")
        }
        print(
            "Native input state: physical key zero, independent Shift sides, drag bounds, release and display generation passed"
        )
    }
}

private func testDisplayModeLeases() throws {
    let driver = SyntheticDesktopModeDriver()
    let lease = DesktopModeLease(driver: driver)
    let changed = try lease.set("synthetic", mode: "720", expected: "1080")
    precondition(changed.temporary && changed.originalModeId == "1080")
    do {
        _ = try lease.set("synthetic", mode: "1080", expected: "1080")
        preconditionFailure("Stale modes accepted")
    } catch {}
    let restored = try lease.restore("synthetic")
    precondition(restored.currentModeId == "1080" && !restored.temporary)
    _ = try lease.set("synthetic", mode: "720", expected: "1080")
    try driver.apply("synthetic", mode: "local-change")
    let manual = try lease.restore("synthetic")
    precondition(manual.currentModeId == "local-change" && manual.superseded)
    try driver.apply("synthetic", mode: "1080")
    _ = try lease.set("synthetic", mode: "720", expected: "1080")
    let original = try lease.set("synthetic", mode: "1080", expected: "720")
    precondition(!original.temporary)
    _ = try lease.set("synthetic", mode: "720", expected: "1080")
    lease.restoreOnExit()
    let exited = try driver.snapshot("synthetic")
    precondition(exited.currentModeId == "1080")
}

private actor CommandTestGate {
    var entered = false
    var finished = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
        }
    }
    func release() { continuation?.resume(); continuation = nil }
    func finish() { finished = true }
}
