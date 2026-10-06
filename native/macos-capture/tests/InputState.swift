import CoreGraphics
import Foundation
import IOKit.pwr_mgt
import ScreenCaptureKit

@main struct InputStateTest {
    static func main() async throws {
        try testPrivacyLease()
        if ProcessInfo.processInfo.environment["DIETER_TEST_PRIVACY_PHYSICAL"] == "1" { try await testPrivacyDesktop() }
        try testRemoteDisplayActivity()
        try testDisplayModeLeases()
        let damageBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        precondition(captureChangedFraction(rects: [], bounds: damageBounds) == 0)
        precondition(
            captureChangedFraction(rects: [CGRect(x: 200, y: 0, width: 50, height: 50)], bounds: damageBounds) == nil,
            "Out-of-space damage cannot suppress a frame")
        precondition(
            captureChangedFraction(rects: [CGRect(x: 0, y: 0, width: 50, height: 50)], bounds: damageBounds) == 0.25)
        precondition(
            captureChangedFraction(rects: [], bounds: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)) == nil)
        var recovery = CaptureRecoverySchedule()
        precondition(
            recovery.request(now: 1_000_000_000, windowMS: 50, referenceAvailable: true, pending: false) == true)
        precondition(recovery.request(now: 1_010_000_000, windowMS: 50, referenceAvailable: true, pending: true) == nil)
        precondition(
            recovery.request(now: 1_050_000_000, windowMS: 50, referenceAvailable: true, pending: true) == false)
        precondition(
            recovery.request(now: 1_100_000_000, windowMS: 50, referenceAvailable: false, pending: false) == nil,
            "Repeated loss must not produce an IDR storm")
        precondition(
            recovery.request(now: 1_250_000_000, windowMS: 50, referenceAvailable: false, pending: false) == false)
        precondition(
            recovery.request(now: 1_300_000_000, windowMS: 50, referenceAvailable: true, pending: false) == true)
        precondition(recovery.referenceDeadline == 1_450_000_000, "Fallback must preserve the IDR throttle")
        precondition(!recovery.expireReference(now: 1_449_999_999))
        precondition(recovery.expireReference(now: 1_450_000_000))
        precondition(!recovery.expireReference(now: 1_450_000_001), "Only one fallback per episode")
        precondition(
            recovery.request(now: 1_450_000_000, windowMS: 50, referenceAvailable: false, pending: true) == false)
        precondition(
            recovery.request(now: 1_700_000_000, windowMS: 250, referenceAvailable: true, pending: false) == true)
        precondition(recovery.producedReference(now: 1_800_000_000))
        precondition(recovery.referenceDeadline == 2_050_000_000)
        precondition(
            !recovery.producedReference(now: 1_900_000_000), "One output cannot repeatedly extend ACK admission")
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
        let rejected = EncoderBurstEnvelope(milliseconds: 250).apply(kbps: 12000) { _ in
            burstAttempts += 1; return -1
        }
        precondition(burstAttempts == 2 && rejected.contains("burst=unsupported"))
        burstAttempts = 0
        _ = EncoderBurstEnvelope(milliseconds: nil).apply(kbps: 12000) { _ in
            burstAttempts += 1; return -1
        }
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
        precondition(
            !credits.canEncode(generation: 1, now: 1, frameAge: 0, encodeEstimate: 1),
            "Consumption cannot invent another send-start token")
        credits.sending(id: 2, generation: 1, now: 1, budgetMS: 30)
        credits.sending(id: 2, generation: 1, now: 40_000_000, budgetMS: 30)
        precondition(
            !credits.canEncode(generation: 1, now: 40_000_000, frameAge: 0, encodeEstimate: 1),
            "Duplicate send-start extended admission")
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
            version: CaptureInputProtocol.version, id: 1, kind: "frame_consumed", input: nil,
            configuration: nil, frameId: 1, streamId: nil, profile: nil, codec: nil)
        stoppedRunner.enqueue(finalCredit) { error in
            precondition(error == "native capture rendition stopped", "Final frame credit lost shutdown cause")
        }
        print(
            "Native input state: physical key zero, independent Shift sides, drag bounds, release and display generation passed"
        )
    }
}

private func testRemoteDisplayActivity() throws {
    var calls = 0
    let activity = RemoteDisplayActivity { name, userType, assertionID in
        calls += 1
        precondition(name as String == "Dieter remote desktop connection")
        precondition(userType == kIOPMUserActiveRemote)
        precondition(assertionID.pointee == IOPMAssertionID(calls - 1))
        assertionID.pointee = IOPMAssertionID(calls)
        return kIOReturnSuccess
    }
    try activity.wake()
    try activity.wake()
    precondition(calls == 2, "Remote activity must reuse its IOKit assertion")

    let failing = RemoteDisplayActivity { _, _, _ in kIOReturnError }
    do {
        try failing.wake()
        preconditionFailure("A failed display wake was accepted")
    } catch {
        precondition(error.localizedDescription.contains("Unable to wake the macOS display"))
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

private final class FailingPrivacyDriver: PrivacyDesktopDriver {
    var failing = false
    var held = false
    func availability() -> PrivacySnapshot { .init(supported: true, displayCount: 2) }
    func acquire() throws { held = true }
    func maintain() throws { if failing { throw CaptureError.invalidArgument("lost protection") } }
    func release() throws { if failing { throw CaptureError.invalidArgument("restore failed") }; held = false }
}
private func testPrivacyLease() throws {
    let driver = FailingPrivacyDriver(), lease = PrivacyLease(driver: FailingPrivacyDriver())
    precondition(lease.snapshot().state == 0)
    let active = PrivacyLease(driver: driver)
    let enabled = try active.set(true)
    precondition(enabled.state == 1)
    precondition(driver.held)
    driver.failing = true
    active.audit()
    precondition(active.snapshot().state == 2 && active.snapshot().requested)
    do { _ = try active.set(false); preconditionFailure("failed restore reported unlocked") } catch {}
    precondition(active.snapshot().state == 2 && active.snapshot().requested && driver.held)
    driver.failing = false
    active.audit()
    precondition(active.snapshot().state == 1)
    let disabled = try active.set(false)
    precondition(disabled.state == 0)
    precondition(!driver.held)
    let physical = CGEvent(source: CGEventSource(stateID: .hidSystemState))!
    let remote = CGEvent(source: CGEventSource(stateID: .privateState))!
    precondition(SystemPrivacyDesktopDriver.isPhysical(physical))
    precondition(!SystemPrivacyDesktopDriver.isPhysical(remote))
    print("Privacy lease: degraded protection, retryable restoration and physical input classification passed")
}

private final class PrivacyInputObservation {
    var physical = 0
    var remote = 0
}

@MainActor private func testPrivacyDesktop() async throws {
    let driver = SystemPrivacyDesktopDriver()
    let original = try Dictionary(
        uniqueKeysWithValues: SystemPrivacyDesktopDriver.displays().map { ($0, try PrivacyGammaTable.read($0)) })
    let seen = PrivacyInputObservation()
    let reference = Unmanaged.passUnretained(seen).toOpaque()
    guard
        let observer = CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1) << CGEventType.mouseMoved.rawValue,
            callback: { _, _, event, reference in
                let seen = Unmanaged<PrivacyInputObservation>.fromOpaque(reference!).takeUnretainedValue()
                if event.getIntegerValueField(.eventSourceUserData) == 901 { seen.physical += 1 }
                if event.getIntegerValueField(.eventSourceUserData) == 902 { seen.remote += 1 }
                return Unmanaged.passUnretained(event)
            }, userInfo: reference)
    else { throw CaptureError.invalidArgument("privacy test observer unavailable") }
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, observer, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    defer { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    do {
        try driver.acquire()
        try driver.maintain()
        for display in original.keys {
            guard try PrivacyGammaTable.read(display).black else {
                throw CaptureError.invalidArgument("display output is not black")
            }
        }
        let position = CGEvent(source: nil)!.location
        for (state, marker) in [(CGEventSourceStateID.hidSystemState, Int64(901)), (.privateState, Int64(902))] {
            let event = CGEvent(
                mouseEventSource: CGEventSource(stateID: state), mouseType: .mouseMoved, mouseCursorPosition: position,
                mouseButton: .left)!
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.post(tap: .cgSessionEventTap)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        guard seen.physical == 0, seen.remote == 1 else {
            throw CaptureError.invalidArgument("privacy event filter: physical=\(seen.physical), remote=\(seen.remote)")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CaptureError.invalidArgument("privacy capture needs a display")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration(); configuration.width = 640; configuration.height = 360;
        configuration.showsCursor = false
        let capture = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let bytes = Array(capture.dataProvider!.data! as Data)
        let rgb = bytes.enumerated().filter { $0.offset % 4 != 3 }.map(\.element)
        guard rgb.filter({ $0 > 20 }).count > rgb.count / 10 else {
            throw CaptureError.invalidArgument("privacy obscured desktop captures")
        }
    } catch {
        try driver.release()
        throw error
    }
    try driver.release()
    for (display, previous) in original {
        let restored = try PrivacyGammaTable.read(display)
        guard restored.red == previous.red, restored.green == previous.green, restored.blue == previous.blue else {
            throw CaptureError.invalidArgument("privacy did not restore original display tables")
        }
    }
    print(
        "Privacy desktop: black output tables, unfiltered capture pixels, physical-source suppression, remote input and exact restoration passed"
    )
}
