import CoreGraphics
import Foundation

@main struct InputStateTest {
    static func main() async throws {
        let liveness = NativeDaemonLiveness(now: 0)
        precondition(liveness.timeoutDiagnostic(now: 3_000_000_000) == nil)
        liveness.receive("frame_consumed", now: 2_900_000_000)
        precondition(liveness.timeoutDiagnostic(now: 5_000_000_000) == nil,
            "Live command traffic must prevent an idle-heartbeat timeout")
        precondition(liveness.timeoutDiagnostic(now: 6_000_000_000)?.contains("lastCommand=frame_consumed") == true,
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
        let finalCredit = NativeCommand(version: 2, id: 1, kind: "frame_consumed", input: nil,
            configuration: nil, frameId: 1, streamId: nil, profile: nil, codec: nil)
        stoppedRunner.enqueue(finalCredit) { error in
            precondition(error == "native capture rendition stopped", "Final frame credit lost shutdown cause")
        }
        print(
            "Native input state: physical key zero, independent Shift sides, drag bounds, release and display generation passed"
        )
    }
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
